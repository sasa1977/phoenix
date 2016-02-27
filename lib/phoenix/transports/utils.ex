defmodule Phoenix.Transports.Utils do
  @moduledoc """
  Helper functions that can be used by Plug based transports.

  This module provides various utility functions, such as ssl and log
  configuration, origin verification, and code reloading.

  Usage of these functions is not mandatory, but it is recommended. If you
  want to retain the same semantics as stock transports, you're advised to
  invoke `init_plug_conn/5` before doing any other work.

  ## Security

  This module also provides functions to enable a secure environment
  on transports that, at some point, have access to a `Plug.Conn`.

  The functionality provided by this module help with doing "origin"
  header checks and ensuring only SSL connections are allowed. See
  `force_ssl/4` and `check_origin/5` for more details.
  """
  require Logger

  @doc """
  Invokes the code reloader if it is configured in the endpoint.
  """
  def code_reload(conn, opts, endpoint) do
    reload? = Keyword.get(opts, :code_reloader, endpoint.config(:code_reloader))
    if reload?, do: Phoenix.CodeReloader.reload!(endpoint)

    conn
  end

  @doc """
  Forces SSL in the socket connection.

  Uses the endpoint configuration to decide so.
  """
  def force_ssl(conn, transport_opts) do
    if force_ssl = transport_opts[:force_ssl] do
      Plug.SSL.call(conn, force_ssl)
    else
      conn
    end
  end

  @doc """
  Configures the `:force_ssl` transport option.

  This function can be used by custom drivers when they are initializing transport
  options. The function returns the modified transport options keyword list with
  force ssl setting configured based on input transport and endpoint settings.
  """
  def force_ssl_config(transport_opts, endpoint) do
    if force_ssl = Keyword.get(transport_opts, :force_ssl, endpoint.config(:force_ssl)) do
      Keyword.put(transport_opts, :force_ssl,
        force_ssl
        |> Keyword.put_new(:host, endpoint.config(:url)[:host] || "localhost")
        |> Plug.SSL.init()
      )
    else
      transport_opts
    end
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
  the connection halted. It is the responsibility of the caller to verify
  whether the connection has been halted, and take corresponding action.
  """
  def check_origin(conn, endpoint, transport_opts, sender \\ &Plug.Conn.send_resp/1) do
    import Plug.Conn
    origin       = get_req_header(conn, "origin") |> List.first
    check_origin = transport_opts[:check_origin]

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

  @doc """
  Configures the `:check_origin` transport option.

  This function can be used by custom drivers when they are initializing transport
  options. The function returns the modified transport options keyword list with
  check origin setting configured based on input transport and endpoint settings.
  """
  def check_origin_config(transport_opts, endpoint) do
    check_origin =
      case Keyword.get(transport_opts, :check_origin, endpoint.config(:check_origin)) do
        origins when is_list(origins) ->
          Enum.map(origins, &parse_origin/1)
        boolean when is_boolean(boolean) ->
          boolean
      end

    Keyword.put(transport_opts, :check_origin, check_origin)
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
