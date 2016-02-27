# TODO(sj): rename and move the file to the proper place
defmodule Phoenix.Transports.Driver do
  defmodule Config do
    @moduledoc ~S"""
    This module defines the struct which is used to pass various parameters
    describing the transports driver connection. The struct contains following
    fields:

      * `transport` - the transport module responsible for communication between
        the client and the server. This module is the first pluggable point which
        receives the request from the underlying web server.
      * `transport_name` - an atom which uniquely identifies the transport,
        for example `:websocket` or `:longpoll`
      * `transport_opts` - transport specific options
      * `driver_opts` - driver specific options
    """

    @type t :: %__MODULE__{
                  transport: module,
                  transport_name: atom,
                  transport_opts: any,
                  driver_opts: any
                }

    defstruct [:driver_opts, :transport, :transport_name, :transport_opts]
  end

  @moduledoc """
  Defines a contract for transport drivers.

  A transport driver is the module which sits on top of a Phoenix transport (such
  as websockets or long polling) and drives the communication between the client
  and the server. A driver is responsible for:

  - interpreting decoded messages from the connected client
  - interpreting Erlang messages sent to the owner process
  - maintaining the state of the connection
  - producing outgoing messages

  An example of a driver is `Phoenix.Socket.Driver` which implements the Phoenix
  Channels protocol. You can easily create your own drivers, which allows you
  to use some different messaging protocol on top of existing transports, or
  create alternative implementations of the existing protocol (such as Phoenix
  Channels).
  """
  # TODO(sj): an example would be nice, but I'll wait until we cleanup the parameters to init and
  #           settle on the configuration mechanism

  @doc """
  Returns all transport specifications for the given endpoint.

  This function is invoked to provide dispatch specifications for each desired
  transport mechanism. The result is a list of elements, each element being a
  tuple that specifies the full path and driver configuration for the transport.
  See `Phoenix.Transports.Driver.Config` for description of driver configuration.

  It is the responsibility of the implementation to merge any user specific
  options with the default transport options. The latter can be obtained by
  calling `default_config` on the transport module (see `Phoenix.Transport`).

  The implementation can also use some helper functions from `Phoenix.Transports.Utils`
  to configure some transport settings, such as ssl or origin check. Refer to the
  implementation in `Phoenix.Socket.Driver` for an example.
  """
  @callback transports(endpoint :: atom, driver_opts :: any) ::
    [{path :: String.t, config :: Config.t}]

  @doc """
  Initializes the driver.

  The implementation must produce the initial state, or otherwise return an
  `:error` atom, in which case the connection will be closed.
  """
  @callback init(endpoint :: atom, config :: Config.t, params :: any) ::
    {:ok, initial_state :: any} | :error

  @doc """
  Handles an incoming message and produces outgoing messages.

  Return values:

  - `{:ok, [out_messages], driver_state}` - Instructs the transport to send output
    messages.
  - `{:error, reason, [out_messages], driver_state}` - Instructs the transport that
    there was an error processing the incoming message. The `reason` term provides
    an error hint to the transport. The transport should keep the connection open
    and send outgoing messages.
  - `{:stop, reason, driver_state}` - Instructs the transport to close the connection.
  """
  @callback handle_in(message :: any, driver_state :: any) ::
    {:ok, [out_messages :: any], driver_state :: any} |
    {:error, reason :: any, [out_messages :: any], driver_state :: any} |
    {:stop, reason :: any, driver_state :: any}

  @doc """
  Handles an Erlang message sent to the transport process.

  Return values have the same meaning as in `handle_in/2`
  """
  @callback handle_info(message :: any, driver_state :: any) ::
    {:ok, [out_messages :: any], driver_state :: any} |
    {:stop, reason :: any, driver_state :: any}

  @doc """
  Invoked when the connection is about to be closed normally.

  Gives an opportunity to release associated resources in the case of a
  normal termination. Note that this function won't be invoked if the transport
  process terminates abnormally. In such cases, the implementation must ensure
  its resources are cleaned up, for example by linking any started processes to
  the transport process.
  """
  @callback close(driver_state :: any) :: any
end
