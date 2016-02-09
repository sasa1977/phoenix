defmodule Phoenix.Integration.SocketDriverTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Phoenix.Socket.Driver
  alias Phoenix.Socket.Message
  alias Phoenix.Socket.Reply
  alias Phoenix.Socket.Broadcast
  alias __MODULE__.Endpoint

  Application.put_env(:phoenix, Endpoint, [
    secret_key_base: String.duplicate("abcdefgh", 8),
    debug_errors: false,
    server: true,
    pubsub: [adapter: Phoenix.PubSub.PG2, name: __MODULE__]
  ])

  defmodule MyTransport do
    @behaviour Phoenix.Transport

    def default_config do
      [
        serializer: Phoenix.ChannelTest.NoopSerializer
      ]
    end
  end

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :phoenix
  end

  defmodule MyChannel do
    use Phoenix.Channel

    def join(_topic, message, socket) do
      if message[:alias], do: Process.register(self, message[:alias])

      if message[:error] == true do
        {:error, %{foo: :bar}}
      else
        send(self, {:after_join, message})
        {:ok, socket}
      end
    end

    def handle_info({:after_join, message}, socket) do
      broadcast socket, "user_entered", %{user: message["user"]}
      push socket, "joined", Map.merge(%{status: "connected"}, socket.assigns)
      {:noreply, socket}
    end

    def handle_in("new_msg", message, socket) do
      broadcast! socket, "new_msg", message
      {:noreply, socket}
    end

    def handle_in("ping", message, socket) do
      {:reply, {:ok, %{pong: message}}, socket}
    end

    def handle_in("stop", _message, socket) do
      {:stop, :normal, socket}
    end

    def terminate(_reason, socket) do
      push socket, "you_left", %{message: "bye!"}
      :ok
    end
  end

  defmodule MySocket do
    use Phoenix.Socket

    transport :transport, MyTransport

    channel "rooms:*", MyChannel

    def connect(params, socket) do
      Logger.disable(self())

      if params[:error] == true do
        :error
      else
        {:ok, assign(socket, :socket_id, params[:socket_id])}
      end
    end

    def id(socket), do: socket.assigns[:socket_id]
  end


  setup_all do
    capture_log fn -> Endpoint.start_link() end
    :ok
  end

  test "provides the protocol version" do
    assert Version.match?(Driver.protocol_version(), "~> 1.0")
  end

  test "successful initialization" do
    assert {:ok, _state} = init_driver()
  end

  test "invalid vsn" do
    capture_log(fn -> assert :error = init_driver(%{"vsn" => "0.1.0"}) end)
  end

  test "initialization error" do
    assert :error = init_driver(%{error: true})
  end

  test "join" do
    {:ok, state} = init_driver()

    assert {:ok, [%Reply{status: :ok, topic: "rooms:lobby"}], state} = join(state, "rooms:lobby")
    assert_receive {:channel_push, %Message{topic: "rooms:lobby", event: "user_entered"} = out_msg} = msg
    assert {:ok, [^out_msg], _state} = Driver.handle_info(msg, state)
  end

  test "double join" do
    {:ok, state} = init_driver()
    {:ok, _, state} = join(state, "rooms:lobby")

    log = capture_log fn ->
      assert  {:ok, [], _state} = join(state, "rooms:lobby")
      assert_receive(
        {
          :channel_push,
          %Reply{topic: "rooms:lobby", payload: %{reason: "already joined"}} = out_msg
        } = msg
      )
      assert {:ok, [^out_msg], _state} = Driver.handle_info(msg, state)
    end

    assert log =~ "received join event with topic \"rooms:lobby\" but channel already joined"
  end

  test "joining an unmatched channel" do
    {:ok, state} = init_driver()

    assert  {
              :error,
              :unmatched_topic,
              [%Reply{topic: "unmatched:channel", status: :error, payload: %{reason: "unmatched topic"}}],
              _state
            } = join(state, "unmatched:channel")
  end

  test "send before join" do
    {:ok, state} = init_driver()

    assert  {
              :error,
              :unmatched_topic,
              [%Reply{topic: "rooms:lobby", status: :error, payload: %{reason: "unmatched topic"}}],
              _state
            } = send_in(state, "rooms:lobby", "new_msg")
  end

  test "in, info, and out messages" do
    {:ok, state} = init_driver()
    {:ok, _, state} = join(state, "rooms:lobby")

    assert  {:ok, [], state} = send_in(state, "rooms:lobby", "new_msg")

    assert_receive {:channel_push, %Message{topic: "rooms:lobby", event: "new_msg"} = out_msg} = msg
    assert {:ok, [^out_msg], _state} = Driver.handle_info(msg, state)

    assert  {:ok, [], state} = send_in(state, "rooms:lobby", "ping", %{foo: :bar})
    assert_receive(
      {
        :channel_push,
        %Reply{topic: "rooms:lobby", status: :ok, payload: %{pong: %{foo: :bar}}, ref: "123"} = out_msg
      } = msg
    )
    assert {:ok, [^out_msg], _state} = Driver.handle_info(msg, state)
  end

  test "heartbeat message" do
    {:ok, state} = init_driver()

    assert  {:ok, [%Reply{topic: "phoenix", status: :ok, ref: "123"}], _state} =
            send_in(state, "phoenix", "heartbeat")
  end

  test "receiving disconnect broadcasts on socket's id" do
    {:ok, state} = init_driver(%{socket_id: "my_socket"})
    {:ok, _, state} = join(state, "rooms:lobby")

    Endpoint.broadcast("my_socket", "disconnect", %{})

    assert_receive %Broadcast{event: "disconnect", topic: "my_socket"} = msg
    assert {:stop, {:shutdown, :disconnected}, _state} = Driver.handle_info(msg, state)
  end

  test "closing a socket" do
    {:ok, state} = init_driver()
    {:ok, _, state} = join(state, "rooms:lobby", %{alias: :lobby})
    channel_pid = Process.whereis(:lobby)
    assert :ok = Driver.close(state)
    assert_receive {:EXIT, ^channel_pid, {:shutdown, :closed}}
  end

  test "stopping a channel" do
    {:ok, state} = init_driver()
    {:ok, _, state} = join(state, "rooms:lobby")
    {:ok, _, state} = send_in(state, "rooms:lobby", "stop")

    assert_receive {:EXIT, _, :normal} = msg
    assert  {:ok, [%Message{topic: "rooms:lobby", event: "phx_close", payload: %{}}], state} =
            Driver.handle_info(msg, state)
    assert  {:error, :unmatched_topic, _, _} = send_in(state, "rooms:lobby", "new_msg")
  end

  test "client leaving" do
    {:ok, state} = init_driver()
    {:ok, _, state} = join(state, "rooms:lobby")
    {:ok, _, state} = send_in(state, "rooms:lobby", "phx_leave")

    assert_receive(
      {
        :channel_push,
        %Message{event: "you_left", payload: %{message: "bye!"}, topic: "rooms:lobby"} = out_msg
      } = msg
    )
    assert {:ok, [^out_msg], state} = Driver.handle_info(msg, state)

    assert_receive {:channel_push, %Reply{status: :ok, topic: "rooms:lobby", ref: "123"} = out_msg} = msg
    assert {:ok, [^out_msg], state} = Driver.handle_info(msg, state)

    assert_receive {:EXIT, _, {:shutdown, :left}} = msg
    assert  {:ok, [%Message{topic: "rooms:lobby", event: "phx_close", payload: %{}}], state} =
            Driver.handle_info(msg, state)
    assert  {:error, :unmatched_topic, _, _} = send_in(state, "rooms:lobby", "new_msg")
  end

  test "channel crash" do
    {:ok, state} = init_driver()
    {:ok, _, state} = join(state, "rooms:1", %{alias: :room1})
    {:ok, _, state} = join(state, "rooms:2", %{alias: :room2})

    room1 = Process.whereis(:room1)
    room2 = Process.whereis(:room2)

    capture_log fn ->
      {:ok, _, state} = send_in(state, "rooms:1", "boom")

      assert_receive {:EXIT, ^room1, _} = msg
      assert  {:ok, [%Message{event: "phx_error", topic: "rooms:1"}], state} = Driver.handle_info(msg, state)
      assert  {:error, :unmatched_topic, _, state} = send_in(state, "rooms:1", "new_msg")
      refute_receive {:EXIT, ^room2, _}
      assert  {:ok, _, _state} = send_in(state, "rooms:2", "new_msg")
    end
  end

  test "termination of a socket process" do
    test_pid = self

    socket_pid = spawn_link(fn ->
      {:ok, state} = init_driver()
      {:ok, _, state} = join(state, "rooms:1", %{alias: :room5})
      {:ok, _, _state} = join(state, "rooms:2", %{alias: :room6})

      send(test_pid, {:channel_pids, Process.whereis(:room5), Process.whereis(:room6)})
      :timer.sleep(:infinity)
    end)
    Process.flag(:trap_exit, true)

    assert_receive {:channel_pids, room5, room6}
    Process.monitor(room5)
    Process.monitor(room6)

    Process.exit(socket_pid, :kill)
    assert_receive {:DOWN, _, :process, ^room5, :killed}
    assert_receive {:DOWN, _, :process, ^room6, :killed}
  end


  defp init_driver(params \\ %{}) do
    Driver.init(
      Endpoint,
      MySocket,
      :transport,
      MyTransport,
      Map.merge(%{"vsn" => Driver.protocol_version}, params)
    )
  end

  defp join(state, topic, payload \\ %{}) do
    send_in(state, topic, "phx_join", payload)
  end

  defp send_in(state, topic, event, payload \\ %{}, ref \\ "123") do
    Driver.handle_in(%Message{topic: topic, event: event, payload: payload, ref: ref}, state)
  end
end
