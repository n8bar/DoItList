defmodule DoIt.ClientJsTest do
  use ExUnit.Case, async: false

  # The React client's pure modules (assets/js/client) are TypeScript with no
  # Elixir counterpart, so their unit suite is Node's built-in runner — Node 24
  # strips the types at load time, so no build step stands between the source
  # and the test. This wrapper runs that suite so `mix test` stays the single
  # gate (m04.01 item 1.3): a broken pure module fails the Elixir build.
  #
  # `nodejs` is installed by the Dockerfile for exactly this reason. The repo is
  # bind-mounted, so client edits need no rebuild.

  @root Path.expand("../..", __DIR__)
  @suite "assets/js/client/**/*.test.ts"

  @tag timeout: 120_000
  test "the client's pure-module Node suite passes" do
    {output, status} =
      try do
        System.cmd("node", ["--test", @suite], cd: @root, stderr_to_stdout: true)
      rescue
        e in ErlangError ->
          flunk("""
          could not run node (#{inspect(e.original)}).

          The client suite needs node on PATH; the Dockerfile installs it.
          Rebuild the image: docker compose up -d --build web
          """)
      end

    assert status == 0, """
    the client's pure-module Node suite failed (exit #{status}).

    Reproduce: docker compose exec -T web node --test #{@suite}

    #{output}
    """
  end
end
