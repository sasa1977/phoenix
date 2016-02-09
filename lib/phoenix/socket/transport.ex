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
end
