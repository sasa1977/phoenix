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

  @behaviour Phoenix.Transport

  def default_config() do
    [serializer: Phoenix.Transports.WebSocketSerializer,
     timeout: 60_000,
     transport_log: false]
  end

  ## Callbacks

  import Plug.Conn, only: [fetch_query_params: 1, send_resp: 3]

  @doc false
  def init(%Plug.Conn{method: "GET"} = conn, {endpoint, driver, config}) do
    alias Phoenix.Transports

    transport_opts = config.transport_opts

    with %{halted: false} = conn <- Transports.Utils.code_reload(conn, transport_opts, endpoint),
         %{halted: false} = conn <- fetch_query_params(conn),
         %{halted: false} = conn <- Transports.Utils.transport_log(conn, transport_opts[:transport_log]),
         %{halted: false} = conn <- Transports.Utils.force_ssl(conn, transport_opts),
         do: Transports.Utils.check_origin(conn, endpoint, transport_opts)
    |> init_driver(endpoint, driver, config)
  end

  def init(conn, _) do
    send_resp(conn, :bad_request, "")
    {:error, conn}
  end

  @doc false
  def ws_init({driver, driver_state, config}) do
    {
      :ok,
      %{
        driver: driver,
        driver_state: driver_state,
        serializer: Keyword.fetch!(config.transport_opts, :serializer)
      },
      Keyword.fetch!(config.transport_opts, :timeout)
    }
  end

  @doc false
  def ws_handle(opcode, payload, state) do
    payload
    |> state.serializer.decode!(opcode: opcode)
    |> state.driver.handle_in(state.driver_state)
    |> handle_driver_response(state)
  end

  @doc false
  def ws_info(message, state) do
    message
    |> state.driver.handle_info(state.driver_state)
    |> handle_driver_response(state)
  end

  @doc false
  def ws_terminate(_reason, _state) do
    :ok
  end

  @doc false
  def ws_close(state) do
    state.driver.close(state.driver_state)
  end


  defp init_driver(%{halted: true} = conn, _, _, _), do: {:error, conn}
  defp init_driver(conn, endpoint, driver, config) do
    case driver.init(endpoint, config, conn.params) do
      {:ok, driver_state} ->
        {:ok, conn, {__MODULE__, {driver, driver_state, config}}}
      :error ->
        send_resp(conn, 403, "")
        {:error, conn}
    end
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
