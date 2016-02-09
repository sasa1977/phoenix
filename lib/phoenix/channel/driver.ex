defmodule Phoenix.Channel.Driver do
  @behaviour Phoenix.Socket.Dialogue

  alias Phoenix.Socket.Broadcast
  alias Phoenix.Socket.Transport

  @doc false
  def init(dlg_params, {endpoint, handler, transport_name, transport}) do
    {_, opts} = handler.__transport__(transport_name)
    serializer = Keyword.fetch!(opts, :serializer)

    case Transport.connect(endpoint, handler, transport_name, transport, serializer, dlg_params) do
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
    case Transport.dispatch(message, state.channels, state.socket) do
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
        encode_reply(Transport.on_exit_message(topic, reason), new_state)
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
  def terminate(_reason, _state), do: :ok

  @doc false
  def close(state) do
    for {pid, _} <- state.channels_inverse do
      Phoenix.Channel.Server.close(pid)
    end
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
end
