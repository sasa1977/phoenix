defmodule Phoenix.Transports.LongPoll.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    children = [
      worker(Phoenix.Transports.LongPoll.Server, [], restart: :temporary)
    ]
    supervise(children, strategy: :simple_one_for_one)
  end
end

defmodule Phoenix.Transports.LongPoll.Server do
  @moduledoc false

  use GenServer

  alias Phoenix.PubSub

  @doc """
  Starts the Server.

    * `socket` - The `Phoenix.Socket` struct returend from `connect/2`
      of the socket handler.
    * `window_ms` - The longpoll session timeout, in milliseconds

  If the server receives no message within `window_ms`, it terminates
  and clients are responsible for opening a new session.
  """
  def start_link(endpoint, handler, transport_name, transport,
                 params, window_ms, priv_topic) do
    GenServer.start_link(__MODULE__, [endpoint, handler, transport_name, transport,
                                      params, window_ms, priv_topic])
  end

  ## Callbacks

  def init([endpoint, handler, transport_name, transport,
            params, window_ms, priv_topic]) do
    case Phoenix.Socket.Driver.init(endpoint, handler, transport_name, transport, params) do
      {:ok, driver_state} ->
        state = %{buffer: [],
                  driver_state: driver_state,
                  window_ms: trunc(window_ms * 1.5),
                  priv_topic: priv_topic,
                  last_client_poll: now_ms(),
                  endpoint: endpoint,
                  client_ref: nil}

        :ok = endpoint.subscribe(self, priv_topic, link: true)
        schedule_inactive_shutdown(state.window_ms)

        {:ok, state}
      :error ->
        :ignore
    end
  end

  def handle_call(:stop, _from, state), do: {:stop, :shutdown, :ok, state}

  # Handle client dispatches
  def handle_info({:dispatch, client_ref, msg, ref}, state) do
    msg
    |> Phoenix.Socket.Driver.handle_in(state.driver_state)
    |> case do
      {:stop, reason, driver_state} ->
        {:stop, reason, %{state | driver_state: driver_state}}

      {:ok, messages, driver_state} ->
        broadcast_from!(state, client_ref, {:dispatch, ref})
        publish_replies(messages, %{state | driver_state: driver_state})

      {:error, reason, messages, driver_state} ->
        broadcast_from!(state, client_ref, {:error, reason, ref})
        publish_replies(messages, %{state | driver_state: driver_state})
    end
  end

  def handle_info({:subscribe, client_ref, ref}, state) do
    broadcast_from!(state, client_ref, {:subscribe, ref})
    {:noreply, state}
  end

  def handle_info({:flush, client_ref, ref}, state) do
    case state.buffer do
      [] ->
        {:noreply, %{state | client_ref: {client_ref, ref}, last_client_poll: now_ms()}}
      buffer ->
        broadcast_from!(state, client_ref, {:messages, Enum.reverse(buffer), ref})
        {:noreply, %{state | client_ref: nil, last_client_poll: now_ms(), buffer: []}}
    end
  end

  def handle_info(:shutdown_if_inactive, state) do
    if now_ms() - state.last_client_poll > state.window_ms do
      {:stop, {:shutdown, :inactive}, state}
    else
      schedule_inactive_shutdown(state.window_ms)
      {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    msg
    |> Phoenix.Socket.Driver.handle_info(state.driver_state)
    |> case do
      {:stop, reason, driver_state} ->
        {:stop, reason, %{state | driver_state: driver_state}}

      {:ok, messages, driver_state} ->
        publish_replies(messages, %{state | driver_state: driver_state})
    end
  end

  def terminate(reason, state) do
    Phoenix.Socket.Driver.terminate(reason, state.driver_state)
  end

  defp broadcast_from!(state, client_ref, msg) when is_binary(client_ref),
    do: PubSub.broadcast_from!(state.endpoint.__pubsub_server__, self, client_ref, msg)
  defp broadcast_from!(_state, client_ref, msg) when is_pid(client_ref),
    do: send(client_ref, msg)

  defp publish_replies(messages, state) do
    case state.client_ref do
      {client_ref, ref} ->
        broadcast_from!(state, client_ref, {:now_available, ref})
      nil ->
        :ok
    end

    {:noreply, %{state | buffer: messages ++ state.buffer}}
  end

  defp time_to_ms({mega, sec, micro}),
    do: div(((((mega * 1000000) + sec) * 1000000) + micro), 1000)
  defp now_ms, do: :os.timestamp() |> time_to_ms()

  defp schedule_inactive_shutdown(window_ms) do
    Process.send_after(self, :shutdown_if_inactive, window_ms)
  end
end
