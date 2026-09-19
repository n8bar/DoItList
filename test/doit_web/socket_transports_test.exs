defmodule DoItWeb.SocketTransportsTest do
  use ExUnit.Case, async: true

  # UX_GUARDRAILS §6.9 (m04.03 6.7): the live channel's guarantees hold on the
  # LongPoll fallback too. Phoenix falls back on its own — but only if the
  # endpoint offers both transports on the socket the client uses. The client
  # above the socket is transport-agnostic by construction
  # (assets/js/client/live/transport_agnostic.test.ts); this pins the server half.
  test "the browser's socket offers WebSocket and LongPoll, both with the session" do
    assert {"/socket", DoItWeb.UserSocket, opts} =
             List.keyfind(DoItWeb.Endpoint.__sockets__(), "/socket", 0)

    for transport <- [:websocket, :longpoll] do
      transport_opts = Keyword.fetch!(opts, transport)

      assert Keyword.has_key?(transport_opts[:connect_info], :session),
             "#{transport} needs the session cookie"
    end
  end
end
