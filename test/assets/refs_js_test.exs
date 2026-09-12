defmodule DoIt.RefsJsTest do
  use ExUnit.Case, async: false

  # The %-notation core (assets/js/refs.js) is browser code with no Elixir
  # counterpart, so its unit suite is Node's built-in runner. This wrapper runs
  # that suite so `mix test` stays the single gate (m03.04 item 6.2.2): a broken
  # tokenizer fails the Elixir build.
  #
  # `nodejs` is installed by the Dockerfile for exactly this reason. The repo is
  # bind-mounted, so JS edits need no rebuild.

  @root Path.expand("../..", __DIR__)
  @suite "assets/js/refs_test.mjs"

  @tag timeout: 120_000
  test "the %-notation core's Node suite passes" do
    {output, status} =
      try do
        System.cmd("node", ["--test", @suite], cd: @root, stderr_to_stdout: true)
      rescue
        e in ErlangError ->
          flunk("""
          could not run node (#{inspect(e.original)}).

          The %-notation suite needs node on PATH; the Dockerfile installs it.
          Rebuild the image: docker compose up -d --build web
          """)
      end

    assert status == 0, """
    the %-notation core's Node suite failed (exit #{status}).

    Reproduce: docker compose exec -T web node --test #{@suite}

    #{output}
    """
  end
end
