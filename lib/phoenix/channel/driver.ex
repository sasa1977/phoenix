# TODO(sj): move the file to the proper place
defmodule Phoenix.Socket.Driver do
  @moduledoc """
  Implementation of the Phoenix Channels protocol.

  The Phoenix Channels protocol describes how to hold multiple separate conversations
  (channels) over a single persistent connection (socket). The connection is
  powered by transports, such as websocket or long polling, while this module
  provides the stock implementation of the protocol, with following properties:

    * Each channel runs in a separate process.

    * Channel processes are direct children of the socket process.

    * Termination of a channel process doesn't affect other channel processes or
      the socket process.

    * If the socket process terminates, all channel processes will be stopped as well,
      regardless of the exit reason.

  This module was not meant to be used directly. Instead you can pass it as an option
  to the transport (TODO(sj): explain how, once we settle on the approach). This
  happens by default when your module is powered by `Phoenix.Socket`.
  """
  @behaviour Phoenix.Transports.Driver

  require Logger
  alias Phoenix.Socket
  alias Phoenix.Socket.Broadcast
  alias Phoenix.Socket.Message
  alias Phoenix.Socket.Reply

  @client_vsn_requirements "~> 1.0"
  @protocol_version "1.0.0"

  @doc """
  Returns the Channel Transport protocol version.
  """
  # TODO(sj): do we really need to expose this? It seems to be used only in tests.
  def protocol_version, do: @protocol_version

  @doc false
  def init(endpoint, socket_handler, transport_name, transport, params) do
    {_, opts} = socket_handler.__transport__(transport_name)
    serializer = Keyword.fetch!(opts, :serializer)

    case connect(endpoint, socket_handler, transport_name, transport, serializer, params) do
      :error -> :error

      {:ok, socket} ->
        # trap exit to deal with crashes of channel processes
        Process.flag(:trap_exit, true)

        if socket.id, do: socket.endpoint.subscribe(self, socket.id, link: true)

        {:ok, %{
          socket: socket,
          channels: %{}, # topic -> channel_pid
          channels_inverse: %{}, # channel_pid -> topic
          serializer: serializer
        }}
    end
  end

  @doc false
  def handle_in(message, state) do
    case dispatch(message, state.channels, state.socket) do
      :noreply ->
        {:ok, [], state}
      {:reply, reply_msg} ->
        {:ok, [state.serializer.encode!(reply_msg)], state}
      {:joined, channel_pid, reply_msg} ->
        {:ok, [state.serializer.encode!(reply_msg)], add_channel(state, message.topic, channel_pid)}
      {:error, reason, error_reply_msg} ->
        {:error, reason, [state.serializer.encode!(error_reply_msg)], state}
    end
  end


  @doc false
  def handle_info(message, state)

  def handle_info({:EXIT, channel_pid, reason}, state) do
    case Map.get(state.channels_inverse, channel_pid) do
      nil   ->
        {:stop, {:shutdown, :pubsub_server_terminated}, state}
      topic ->
        new_state = delete_channel(state, topic, channel_pid)
        encode_reply(on_exit_message(topic, reason), new_state)
    end
  end

  def handle_info(%Broadcast{event: "disconnect"}, state) do
    {:stop, {:shutdown, :disconnected}, state}
  end

  def handle_info({:channel_push, out_message}, state) do
    {:ok, [out_message], state}
  end

  def handle_info(_message, state), do: {:ok, [], state}


  @doc false
  def close(state) do
    for {pid, _} <- state.channels_inverse do
      Phoenix.Channel.Server.close(pid)
    end

    :ok
  end


  defp encode_reply(reply, state) do
    {:ok, [state.serializer.encode!(reply)], state}
  end

  defp add_channel(state, topic, channel_pid) do
    %{state | channels: Map.put(state.channels, topic, channel_pid),
              channels_inverse: Map.put(state.channels_inverse, channel_pid, topic)}
  end

  defp delete_channel(state, topic, channel_pid) do
    %{state | channels: Map.delete(state.channels, topic),
              channels_inverse: Map.delete(state.channels_inverse, channel_pid)}
  end

  @doc false
  def connect(endpoint, socket_handler, transport_name, transport, serializer, params) do
    vsn = params["vsn"] || "1.0.0"

    if Version.match?(vsn, @client_vsn_requirements) do
      connect_vsn(endpoint, socket_handler, transport_name, transport, serializer, params)
    else
      Logger.error "The client's requested channel transport version \"#{vsn}\" " <>
                   "does not match server's version requirements of \"#{@client_vsn_requirements}\""
      :error
    end
  end
  defp connect_vsn(endpoint, socket_handler, transport_name, transport, serializer, params) do
    socket = %Socket{endpoint: endpoint,
                     transport: transport,
                     transport_pid: self(),
                     transport_name: transport_name,
                     handler: socket_handler,
                     pubsub_server: endpoint.__pubsub_server__,
                     serializer: serializer}

    case socket_handler.connect(params, socket) do
      {:ok, socket} ->
        case socket_handler.id(socket) do
          nil                   -> {:ok, socket}
          id when is_binary(id) -> {:ok, %Socket{socket | id: id}}
          invalid               ->
            Logger.error "#{inspect socket_handler}.id/1 returned invalid identifier #{inspect invalid}. " <>
                         "Expected nil or a string."
            :error
        end

      :error ->
        :error

      invalid ->
        Logger.error "#{inspect socket_handler}.connect/2 returned invalid value #{inspect invalid}. " <>
                     "Expected {:ok, socket} or :error"
        :error
    end
  end

  defp dispatch(%{ref: ref, topic: "phoenix", event: "heartbeat"}, _channels, _socket) do
    {:reply, %Reply{ref: ref, topic: "phoenix", status: :ok, payload: %{}}}
  end

  defp dispatch(%Message{} = msg, channels, socket) do
    channels
    |> Map.get(msg.topic)
    |> do_dispatch(msg, socket)
  end

  defp do_dispatch(nil, %{event: "phx_join", topic: topic} = msg, socket) do
    if channel = socket.handler.__channel__(topic, socket.transport_name) do
      socket = %Socket{socket | topic: topic, channel: channel}

      log_info topic, fn ->
        "JOIN #{topic} to #{inspect(channel)}\n" <>
        "  Transport:  #{inspect socket.transport}\n" <>
        "  Parameters: #{inspect msg.payload}"
      end

      case Phoenix.Channel.Server.join(socket, msg.payload) do
        {:ok, response, pid} ->
          log_info topic, fn -> "Replied #{topic} :ok" end
          {:joined, pid, %Reply{ref: msg.ref, topic: topic, status: :ok, payload: response}}

        {:error, reason} ->
          log_info topic, fn -> "Replied #{topic} :error" end
          {:error, reason, %Reply{ref: msg.ref, topic: topic, status: :error, payload: reason}}
      end
    else
      reply_ignore(msg, socket)
    end
  end

  defp do_dispatch(nil, msg, socket) do
    reply_ignore(msg, socket)
  end

  defp do_dispatch(channel_pid, msg, _socket) do
    send(channel_pid, msg)
    :noreply
  end

  defp log_info("phoenix" <> _, _func), do: :noop
  defp log_info(_topic, func), do: Logger.info(func)

  defp reply_ignore(msg, socket) do
    Logger.debug fn -> "Ignoring unmatched topic \"#{msg.topic}\" in #{inspect(socket.handler)}" end
    {:error, :unmatched_topic, %Reply{ref: msg.ref, topic: msg.topic, status: :error,
                                      payload: %{reason: "unmatched topic"}}}
  end

  defp on_exit_message(topic, reason) do
    case reason do
      :normal        -> %Message{topic: topic, event: "phx_close", payload: %{}}
      :shutdown      -> %Message{topic: topic, event: "phx_close", payload: %{}}
      {:shutdown, _} -> %Message{topic: topic, event: "phx_close", payload: %{}}
      _              -> %Message{topic: topic, event: "phx_error", payload: %{}}
    end
  end
end
