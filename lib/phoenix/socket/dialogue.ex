defmodule Phoenix.Socket.Dialogue do
  @callback init(dlg_params :: any, dlg_opts :: any) ::
    {:ok, initial_state :: any} | :error

  @callback handle_in(message :: any, dlg_state :: any) ::
    {:ok, [out_messages :: any], dlg_state :: any} |
    {:error, reason :: any, [out_messages :: any], dlg_state :: any} |
    {:stop, reason :: any, dlg_state :: any}

  @callback handle_info(message :: any, dlg_state :: any) ::
    {:ok, [out_messages :: any], dlg_state :: any} |
    {:stop, reason :: any, dlg_state :: any}

  @callback close(dlg_state :: any) :: any

  @callback terminate(reason :: any, dlg_state :: any) :: any
end
