defmodule DoIt.CdpJsTest do
  use ExUnit.Case, async: false

  # The CDP harness itself is opt-in — it needs a browser and a signed-in
  # session (m04.01 item 1.4). Its PURE modules are not: the protocol framing in
  # `bin/cdp/cdp.mjs` and the tab-acquisition rule in `bin/cdp/check_client.mjs`
  # are plain JavaScript over injected fakes, and the rule they encode — never
  # leak a tab in the operator's browser — is exactly the one nobody wants to
  # find out about by hand. So the unit suite runs in the gate even though the
  # harness does not (m04.01 item 6.2).
  #
  # Importing `check_client.mjs` must not reach for a browser; the file guards
  # its `main()` on being run as the script.

  @root Path.expand("../..", __DIR__)
  @suite "bin/cdp/*.test.mjs"

  @tag timeout: 120_000
  test "the CDP harness's unit suite passes" do
    {output, status} =
      try do
        System.cmd("node", ["--test", @suite], cd: @root, stderr_to_stdout: true)
      rescue
        e in ErlangError ->
          flunk("""
          could not run node (#{inspect(e.original)}).

          The harness suite needs node on PATH; the Dockerfile installs it.
          Rebuild the image: docker compose up -d --build web
          """)
      end

    assert status == 0, """
    the CDP harness's unit suite failed (exit #{status}).

    Reproduce: docker compose exec -T web node --test #{@suite}

    #{output}
    """
  end
end
