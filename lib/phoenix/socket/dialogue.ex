# TODO(sj): rename and move the file to the proper place
defmodule Phoenix.Transports.Driver do
  # TODO(sj): consider bundling these args into a struct
  @callback init(endpoint :: atom, socket_handler :: atom, transport_name :: atom, transport :: atom, params :: any) ::
    {:ok, initial_state :: any} | :error

  @callback handle_in(message :: any, driver_state :: any) ::
    {:ok, [out_messages :: any], driver_state :: any} |
    {:error, reason :: any, [out_messages :: any], driver_state :: any} |
    {:stop, reason :: any, driver_state :: any}

  @callback handle_info(message :: any, driver_state :: any) ::
    {:ok, [out_messages :: any], driver_state :: any} |
    {:stop, reason :: any, driver_state :: any}

  @callback close(driver_state :: any) :: any

  @callback terminate(reason :: any, driver_state :: any) :: any
end
