defmodule Phoenix.Transports.SocketDriverTest do
  use ExUnit.Case, async: true
  use RouterHelper

  alias Phoenix.Socket.Driver

  test "provides the protocol version" do
    assert Version.match?(Driver.protocol_version(), "~> 1.0")
  end
end
