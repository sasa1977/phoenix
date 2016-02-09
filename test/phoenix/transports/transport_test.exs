defmodule Phoenix.Transports.TransportTest do
  use ExUnit.Case, async: true
  use RouterHelper

  alias Phoenix.Socket.Transport

  test "provides the protocol version" do
    assert Version.match?(Transport.protocol_version(), "~> 1.0")
  end
end
