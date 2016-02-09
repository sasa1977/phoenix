defmodule Phoenix.Transports.WebSocket do
  @moduledoc """
  Socket transport for websocket clients.

  ## Configuration

  The websocket is configurable in your socket:

      transport :websocket, Phoenix.Transports.WebSocket,
        timeout: :infinity,
        serializer: Phoenix.Transports.WebSocketSerializer,
        transport_log: false

    * `:timeout` - the timeout for keeping websocket connections
      open after it last received data, defaults to 60_000ms

    * `:transport_log` - if the transport layer itself should log and, if so, the level

    * `:serializer` - the serializer for websocket messages

    * `:check_origin` - if we should check the origin of requests when the
      origin header is present. It defaults to true and, in such cases,
      it will check against the host value in `YourApp.Endpoint.config(:url)[:host]`.
      It may be set to `false` (not recommended) or to a list of explicitly
      allowed origins

    * `:code_reloader` - optionally override the default `:code_reloader` value
      from the socket's endpoint

  ## Serializer

  By default, JSON encoding is used to broker messages to and from clients.
  A custom serializer may be given as module which implements the `encode!/1`
  and `decode!/2` functions defined by the `Phoenix.Transports.Serializer`
  behaviour.

  The `encode!/1` function must return a tuple in the format
  `{:text | :binary, String.t | binary}`.
  """

  @behaviour Phoenix.Socket.Transport

  def default_config() do
    [serializer: Phoenix.Transports.WebSocketSerializer,
     timeout: 60_000,
     transport_log: false]
  end

  ## Callbacks

  import Plug.Conn, only: [fetch_query_params: 1, send_resp: 3]

  @doc false
  def init(%Plug.Conn{method: "GET"} = conn, {endpoint, handler, transport}) do
    {_, opts} = handler.__transport__(transport)

    conn
    |> Phoenix.Transports.Utils.init_plug_conn(endpoint, handler, transport)
    |> case do
      %{halted: false} = conn ->
        case Phoenix.Channel.Driver.init(endpoint, handler, transport, __MODULE__, conn.params) do
          {:ok, driver_state} ->
            {:ok, conn, {__MODULE__, {driver_state, opts}}}
          :error ->
            send_resp(conn, 403, "")
            {:error, conn}
        end
      %{halted: true} = conn ->
        {:error, conn}
    end
  end

  def init(conn, _) do
    send_resp(conn, :bad_request, "")
    {:error, conn}
  end

  @doc false
  def ws_init({driver_state, opts}) do
    {
      :ok,
      %{
        driver_state: driver_state,
        serializer: Keyword.fetch!(opts, :serializer)
      },
      Keyword.fetch!(opts, :timeout)
    }
  end

  @doc false
  def ws_handle(opcode, payload, state) do
    payload
    |> state.serializer.decode!(opcode: opcode)
    |> Phoenix.Channel.Driver.handle_in(state.driver_state)
    |> handle_driver_response(state)
  end

  @doc false
  def ws_info(message, state) do
    message
    |> Phoenix.Channel.Driver.handle_info(state.driver_state)
    |> handle_driver_response(state)
  end

  @doc false
  def ws_terminate(reason, state) do
    Phoenix.Channel.Driver.terminate(reason, state.driver_state)
  end

  @doc false
  def ws_close(state) do
    Phoenix.Channel.Driver.close(state.driver_state)
  end


  defp handle_driver_response({:stop, reason, driver_state}, state) do
    {:shutdown, reason, %{state | driver_state: driver_state}}
  end
  defp handle_driver_response({:ok, messages, driver_state}, state) do
    {:ok, messages, %{state | driver_state: driver_state}}
  end
  defp handle_driver_response({:error, _reason, messages, driver_state}, state) do
    # Error info is ignored, because there's no standard way to propagate it on websocket
    {:ok, messages, %{state | driver_state: driver_state}}
  end
end
