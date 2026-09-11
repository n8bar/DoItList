defmodule DoIt.TransportJsTest do
  use ExUnit.Case, async: false

  # The transport bootstrap (assets/js/transport.js) is browser code with no
  # Elixir counterpart, so its unit suite is Node's built-in runner. This
  # wrapper runs that suite so `mix test` stays the single gate (m03.04 item
  # 6.11.2). Same shape as refs_js_test.exs.

  @root Path.expand("../..", __DIR__)
  @suite "assets/js/transport_test.mjs"

  @tag timeout: 120_000
  test "the transport bootstrap's Node suite passes" do
    {output, status} =
      try do
        System.cmd("node", ["--test", @suite], cd: @root, stderr_to_stdout: true)
      rescue
        e in ErlangError ->
          flunk("""
          could not run node (#{inspect(e.original)}).

          The transport suite needs node on PATH; the Dockerfile installs it.
          Rebuild the image: docker compose up -d --build web
          """)
      end

    assert status == 0, """
    the transport bootstrap's Node suite failed (exit #{status}).

    Reproduce: docker compose exec -T web node --test #{@suite}

    #{output}
    """
  end
end
