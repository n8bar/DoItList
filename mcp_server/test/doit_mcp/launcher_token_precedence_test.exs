defmodule DoitMcp.LauncherTokenPrecedenceTest do
  use ExUnit.Case, async: false

  alias DoitMcp.TokenRecovery

  # Runs the REAL host launcher (bin/mcp_server.sh — the repo is mounted at
  # /app, so the container sees the same file the host execs) with a fake
  # `docker` on PATH that prints the env the adapter would receive. That
  # keeps the precedence tests honest: they exercise the exact sourcing and
  # mtime logic a connect runs, not a re-implementation.
  #
  # Precedence under test (launcher comments are canonical):
  #   freshest of [mcp.env, refresh file]  >  client-config env
  # and the 2.13 constraint behind it: a token refreshed in-session and
  # persisted MUST win the next connect over a stale env token.

  @launcher Path.expand("../../../bin/mcp_server.sh", __DIR__)

  @old {{2026, 1, 1}, {0, 0, 0}}
  @new {{2026, 1, 2}, {0, 0, 0}}

  setup do
    tmp = Path.join(System.tmp_dir!(), "launcher-test-#{System.unique_integer([:positive])}")
    fake_bin = Path.join(tmp, "bin")
    File.mkdir_p!(fake_bin)

    fake_docker = Path.join(fake_bin, "docker")

    File.write!(fake_docker, """
    #!/bin/sh
    # Stand-in for `docker compose exec ...` — print what the adapter would see.
    echo "TOKEN=$DOITLIST_API_TOKEN"
    echo "ENVPATH=$DOITLIST_MCP_ENV_PATH"
    echo "ARGS=$*"
    """)

    File.chmod!(fake_docker, 0o755)

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{
      tmp: tmp,
      fake_bin: fake_bin,
      mcp_env: Path.join(tmp, "mcp.env"),
      refresh: Path.join(tmp, "refresh.env")
    }
  end

  defp run_launcher(ctx, extra_env) do
    env =
      Map.merge(
        %{
          "PATH" => ctx.fake_bin <> ":" <> System.get_env("PATH"),
          "DOITLIST_MCP_ENV" => ctx.mcp_env,
          "DOITLIST_MCP_REFRESH_FILE" => ctx.refresh,
          # The test VM itself carries a DOITLIST_API_TOKEN (test_helper) —
          # scrub it so each case states its own env explicitly.
          "DOITLIST_API_TOKEN" => nil,
          "DOITLIST_MCP_ENV_PATH" => nil
        },
        Map.new(extra_env)
      )

    # </dev/null so the frame-log `tee` sees EOF instead of waiting on stdin.
    System.cmd("sh", ["-c", "exec #{@launcher} </dev/null"],
      env: Map.to_list(env),
      stderr_to_stdout: true
    )
  end

  test "client-config env alone works when neither token file exists", ctx do
    assert {out, 0} = run_launcher(ctx, %{"DOITLIST_API_TOKEN" => "env-token"})
    assert out =~ "TOKEN=env-token"
  end

  test "mcp.env beats a stale client-config env token", ctx do
    File.write!(ctx.mcp_env, "DOITLIST_API_TOKEN=file-token\n")

    assert {out, 0} = run_launcher(ctx, %{"DOITLIST_API_TOKEN" => "stale-env-token"})
    assert out =~ "TOKEN=file-token"
  end

  test "a newer refresh file beats both mcp.env and env — the 2.13 constraint", ctx do
    File.write!(ctx.mcp_env, "DOITLIST_API_TOKEN=stale-file-token\n")
    File.touch!(ctx.mcp_env, @old)
    File.write!(ctx.refresh, "DOITLIST_API_TOKEN=refreshed-token\n")
    File.touch!(ctx.refresh, @new)

    assert {out, 0} = run_launcher(ctx, %{"DOITLIST_API_TOKEN" => "stale-env-token"})
    assert out =~ "TOKEN=refreshed-token"
  end

  test "a hand-edit of mcp.env newer than an old refresh wins back", ctx do
    File.write!(ctx.refresh, "DOITLIST_API_TOKEN=old-refresh-token\n")
    File.touch!(ctx.refresh, @old)
    File.write!(ctx.mcp_env, "DOITLIST_API_TOKEN=hand-fixed-token\n")
    File.touch!(ctx.mcp_env, @new)

    assert {out, 0} = run_launcher(ctx, %{})
    assert out =~ "TOKEN=hand-fixed-token"
  end

  test "the refresh file alone suffices when mcp.env is absent", ctx do
    File.write!(ctx.refresh, "DOITLIST_API_TOKEN=refreshed-token\n")

    assert {out, 0} = run_launcher(ctx, %{})
    assert out =~ "TOKEN=refreshed-token"
  end

  test "the adapter's own persisted format (comments + assignment) passes the read-side check",
       ctx do
    # Exactly what TokenRecovery.persist/1 writes — the guard must never reject
    # the adapter's own output, or in-session recovery would break on reconnect.
    File.write!(ctx.refresh, TokenRecovery.persist_content("refreshed-token"))

    assert {out, 0} = run_launcher(ctx, %{})
    assert out =~ "TOKEN=refreshed-token"
  end

  test "a refresh file carrying anything beyond a token assignment is refused, not sourced",
       ctx do
    # The file is `.`-sourced, so a bare command would run on the host. Make it
    # NEWER than mcp.env so only the safety check — not mtime — can block it.
    File.write!(ctx.refresh, "DOITLIST_API_TOKEN=injected-token\necho INJECTED-BY-REFRESH\n")
    File.touch!(ctx.refresh, @new)

    assert {out, 0} = run_launcher(ctx, %{"DOITLIST_API_TOKEN" => "env-token"})
    # The injected command never ran and its token never took effect; the
    # launcher fell back to the client-config env and warned.
    refute out =~ "INJECTED-BY-REFRESH"
    refute out =~ "injected-token"
    assert out =~ "TOKEN=env-token"
    assert out =~ "refusing to source"
  end

  test "no token anywhere fails loudly instead of connecting doomed", ctx do
    assert {out, code} = run_launcher(ctx, %{})
    assert code != 0
    assert out =~ "DOITLIST_API_TOKEN"
  end

  test "the operator token-file path is exported and forwarded into the container", ctx do
    File.write!(ctx.mcp_env, "DOITLIST_API_TOKEN=file-token\n")

    assert {out, 0} = run_launcher(ctx, %{})
    assert out =~ "ENVPATH=#{ctx.mcp_env}"
    assert out =~ "-e DOITLIST_MCP_ENV_PATH"
  end

  test "a token persisted by TokenRecovery is what the next connect resolves", ctx do
    # The adapter-side write (the real persist/1, aimed at this test's path)…
    Application.put_env(:doit_mcp, :token_persist_path, ctx.refresh)
    on_exit(fn -> Application.delete_env(:doit_mcp, :token_persist_path) end)
    assert :ok = TokenRecovery.persist("fresh-abc123")

    # …beats a stale mcp.env and a stale client-config env on the next connect.
    File.write!(ctx.mcp_env, "DOITLIST_API_TOKEN=stale-file-token\n")
    File.touch!(ctx.mcp_env, @old)

    assert {out, 0} = run_launcher(ctx, %{"DOITLIST_API_TOKEN" => "stale-env-token"})
    assert out =~ "TOKEN=fresh-abc123"
  end
end
