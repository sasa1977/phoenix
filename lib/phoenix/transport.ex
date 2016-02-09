defmodule Phoenix.Transport do
  @moduledoc """
  API for building transports.

  This module describes what is required to build a Phoenix transport.
  The transport forwards client messages to the transport driver and vice-versa.

  A transport is responsible for:

    * Implementing the transport behaviour
    * Establishing the persistent connection
    * Handling of incoming messages
    * Handling of outgoing messages

  ## The transport behaviour

  The transport behaviour requires the following function:

    * `default_config/0` - returns the default transport configuration
  """
  # TODO(sj): explain the responsibilities of the concrete implementation in more details,
  #           once we're settled on the exact interface

  @doc """
  Provides a keyword list of default configuration for transports.
  """
  @callback default_config() :: Keyword.t
end
