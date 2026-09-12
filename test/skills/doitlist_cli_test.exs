defmodule DoIt.DoitListCliTest do
  use ExUnit.Case, async: false

  # The scripted client (skills/doitlist/scripts/doitlist.py) is a standalone
  # Python 3 program — it runs on the agent's machine, not in this app — so its
  # own unittest suite is where argument parsing, request shapes, and outline
  # rendering are pinned. This wrapper runs that suite so `mix test` stays the
  # single gate (m03.04 item 4.6): a broken client fails the Elixir build.
  #
  # `python3` is installed by the Dockerfile for exactly this reason. The repo
  # is bind-mounted, so script edits need no rebuild.

  @root Path.expand("../..", __DIR__)
  @scripts "skills/doitlist/scripts"

  @tag timeout: 120_000
  test "the scripted client's unittest suite passes" do
    {output, status} =
      try do
        System.cmd(
          "python3",
          ["-m", "unittest", "discover", "-s", @scripts, "-p", "test_*.py", "-v"],
          cd: @root,
          env: [{"PYTHONDONTWRITEBYTECODE", "1"}],
          stderr_to_stdout: true
        )
      rescue
        e in ErlangError ->
          flunk("""
          could not run python3 (#{inspect(e.original)}).

          The scripted client's suite needs python3 on PATH; the Dockerfile
          installs it. Rebuild the image: docker compose up -d --build web
          """)
      end

    assert status == 0, """
    the scripted client's unittest suite failed (exit #{status}).

    Reproduce: docker compose exec -T web python3 -m unittest discover \
    -s #{@scripts} -p 'test_*.py' -v

    #{output}
    """
  end
end
