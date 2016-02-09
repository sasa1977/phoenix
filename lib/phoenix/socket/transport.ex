defmodule Phoenix.Socket.Transport do
  # TODO(sj): this doc needs to be revisited. Some of the stuff must be moved elsewhere, some
  #           should be removed.
  @moduledoc """
  API for building transports.

  This module describes what is required to build a Phoenix transport.
  The transport sits between the socket and channels, forwarding client
  messages to channels and vice-versa.

  A transport is responsible for:

    * Implementing the transport behaviour
    * Establishing the socket connection
    * Handling of incoming messages
    * Handling of outgoing messages
    * Managing channels
    * Providing secure defaults

  ## The transport behaviour

  The transport requires two functions:

    * `default_config/0` - returns the default transport configuration
      to be merged when the transport is declared in the socket module

    * `handlers/0` - returns a map of handlers. For example, if the
      transport can be run cowboy, it just need to specify the
      appropriate cowboy handler

  ## Socket connections

  Once a connection is established, the transport is responsible
  for invoking the `Phoenix.Socket.connect/2` callback and acting
  accordingly. Once connected, the transport should request the
  `Phoenix.Socket.id/1` and subscribe to the topic if one exists.
  On subscribed, the transport must be able to handle "disconnect"
  broadcasts on the given id topic.

  The `connect/6` function in this module can be used as a
  convenience or a documentation on such steps.

  ## Incoming messages

  Incoming messages are encoded in whatever way the transport
  chooses. Those messages must be decoded in the transport into a
  `Phoenix.Socket.Message` before being forwarded to a channel.

  Most of those messages are user messages except by:

    * "heartbeat" events in the "phoenix" topic - should just emit
      an OK reply
    * "phx_join" on any topic - should join the topic
    * "phx_leave" on any topic - should leave the topic

  The function `dispatch/3` can help with handling of such messages.

  ## Outgoing messages

  Channels can send two types of messages back to a transport:
  `Phoenix.Socket.Message` and `Phoenix.Socket.Reply`. Those
  messages are encoded in the channel into a format defined by
  the transport. That's why transports are required to pass a
  serializer that abides to the behaviour described in
  `Phoenix.Transports.Serializer`.

  ## Managing channels

  Because channels are spawned from the transport process, transports
  must trap exists and correctly handle the `{:EXIT, _, _}` messages
  arriving from channels, relaying the proper response to the client.

  The function `on_exit_message/2` should aid with that.

  ## Security

  This module also provides functions to enable a secure environment
  on transports that, at some point, have access to a `Plug.Conn`.

  The functionality provided by this module help with doing "origin"
  header checks and ensuring only SSL connections are allowed.

  ## Remote Client

  Channels can reply, synchronously, to any `handle_in/3` event. To match
  pushes with replies, clients must include a unique `ref` with every
  message and the channel server will reply with a matching ref where
  the client and pick up the callback for the matching reply.

  Phoenix includes a JavaScript client for WebSocket and Longpolling
  support using JSON encodings.

  However, a client can be implemented for other protocols and encodings by
  abiding by the `Phoenix.Socket.Message` format.

  ## Protocol Versioning

  Clients are expected to send the Channel Transport protocol version that they
  expect to be talking to. The version can be retrieved on the server from
  `Phoenix.Channel.Transport.protocol_version/0`. If no version is provided, the
  Transport adapters should default to assume a `"1.0.0"` version number.
  See `web/static/js/phoenix.js` for an example transport client
  implementation.
  """

  require Logger

  @protocol_version "1.0.0"

  @doc """
  Provides a keyword list of default configuration for socket transports.
  """
  @callback default_config() :: Keyword.t

  @doc """
  Returns the Channel Transport protocol version.
  """
  def protocol_version, do: @protocol_version

  @doc """
  Forces SSL in the socket connection.

  Uses the endpoint configuration to decide so. It is a
  noop if the connection has been halted.
  """
  def force_ssl(%Plug.Conn{halted: true} = conn, _socket, _endpoint, _opts) do
    conn
  end

  def force_ssl(conn, socket, endpoint, opts) do
    if force_ssl = force_ssl_config(socket, endpoint, opts) do
      Plug.SSL.call(conn, force_ssl)
    else
      conn
    end
  end

  defp force_ssl_config(socket, endpoint, opts) do
    Phoenix.Config.cache(endpoint, {:force_ssl, socket}, fn _ ->
      opts =
        if force_ssl = Keyword.get(opts, :force_ssl, endpoint.config(:force_ssl)) do
          force_ssl
          |> Keyword.put_new(:host, endpoint.config(:url)[:host] || "localhost")
          |> Plug.SSL.init()
        end
      {:cache, opts}
    end)
  end

  @doc """
  Logs the transport request.

  Available for transports that generate a connection.
  """
  def transport_log(conn, level) do
    if level do
      Plug.Logger.call(conn, Plug.Logger.init(log: level))
    else
      conn
    end
  end

  @doc """
  Checks the origin request header against the list of allowed origins.

  Should be called by transports before connecting when appropriate.
  If the origin header matches the allowed origins, no origin header was
  sent or no origin was configured, it will return the given connection.

  Otherwise a otherwise a 403 Forbidden response will be sent and
  the connection halted.  It is a noop if the connection has been halted.
  """
  def check_origin(conn, handler, endpoint, opts, sender \\ &Plug.Conn.send_resp/1)

  def check_origin(%Plug.Conn{halted: true} = conn, _handler, _endpoint, _opts, _sender),
    do: conn

  def check_origin(conn, handler, endpoint, opts, sender) do
    import Plug.Conn
    origin       = get_req_header(conn, "origin") |> List.first
    check_origin = check_origin_config(handler, endpoint, opts)

    cond do
      is_nil(origin) or check_origin == false ->
        conn
      origin_allowed?(check_origin, URI.parse(origin), endpoint) ->
        conn
      true ->
        Logger.error """
        Could not check origin for Phoenix.Socket transport.

        This happens when you are attempting a socket connection to
        a different host than the one configured in your config/
        files. For example, in development the host is configured
        to "localhost" but you may be trying to access it from
        "127.0.0.1". To fix this issue, you may either:

          1. update [url: [host: ...]] to your actual host in the
             config file for your current environment (recommended)

          2. pass the :check_origin option when configuring your
             endpoint or when configuring the transport in your
             UserSocket module, explicitly outlining which origins
             are allowed:

                check_origin: ["https://example.com",
                               "//another.com:888", "//other.com"]
        """
        resp(conn, :forbidden, "")
        |> sender.()
        |> halt()
    end
  end

  defp check_origin_config(handler, endpoint, opts) do
    Phoenix.Config.cache(endpoint, {:check_origin, handler}, fn _ ->
      check_origin =
        case Keyword.get(opts, :check_origin, endpoint.config(:check_origin)) do
          origins when is_list(origins) ->
            Enum.map(origins, &parse_origin/1)
          boolean when is_boolean(boolean) ->
            boolean
        end
      {:cache, check_origin}
    end)
  end

  defp parse_origin(origin) do
    case URI.parse(origin) do
      %{host: nil} ->
        raise ArgumentError,
          "invalid check_origin: #{inspect origin} (expected an origin with a host)"
      %{scheme: scheme, port: port, host: host} ->
        {scheme, host, port}
    end
  end

  defp origin_allowed?(_check_origin, %URI{host: nil}, _endpoint),
    do: true
  defp origin_allowed?(true, uri, endpoint),
    do: compare?(uri.host, endpoint.config(:url)[:host])
  defp origin_allowed?(check_origin, uri, _endpoint) when is_list(check_origin),
    do: origin_allowed?(uri, check_origin)

  defp origin_allowed?(uri, allowed_origins) do
    %{scheme: origin_scheme, host: origin_host, port: origin_port} = uri

    Enum.any?(allowed_origins, fn {allowed_scheme, allowed_host, allowed_port} ->
      compare?(origin_scheme, allowed_scheme) and
      compare?(origin_port, allowed_port) and
      compare_host?(origin_host, allowed_host)
    end)
  end

  defp compare?(request_val, allowed_val) do
    is_nil(allowed_val) or request_val == allowed_val
  end

  defp compare_host?(_request_host, nil),
    do: true
  defp compare_host?(request_host, "*." <> allowed_host),
    do: String.ends_with?(request_host, allowed_host)
  defp compare_host?(request_host, allowed_host),
    do: request_host == allowed_host
end
