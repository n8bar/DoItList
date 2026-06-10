# Browser (e2e) tests — tagged :e2e — drive headless Chromium on the
# `playwright` compose service. They run only when PLAYWRIGHT_WS_ENDPOINT is
# set (the `mix test.e2e` alias sets it); otherwise they're excluded and no
# Playwright connection is attempted.
ws_endpoint = System.get_env("PLAYWRIGHT_WS_ENDPOINT")

if ws_endpoint do
  playwright = Application.get_env(:phoenix_test, :playwright, [])

  Application.put_env(
    :phoenix_test,
    :playwright,
    Keyword.merge(playwright,
      ws_endpoint: ws_endpoint,
      browser_pool: false,
      # The 2s default is too tight for a first page load on a shared dev box.
      timeout: to_timeout(second: 10),
      browser_launch_timeout: to_timeout(second: 30)
    )
  )

  # The browser runs in a different container, so the base URL must be this
  # container's network address, not loopback.
  {:ok, hostname} = :inet.gethostname()
  {:ok, ip} = :inet.getaddr(hostname, :inet)
  port = Application.fetch_env!(:doit, DoItWeb.Endpoint)[:http][:port]
  Application.put_env(:phoenix_test, :base_url, "http://#{:inet.ntoa(ip)}:#{port}")

  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
end

ExUnit.start(exclude: if(ws_endpoint, do: [], else: [:e2e]))
Ecto.Adapters.SQL.Sandbox.mode(DoIt.Repo, :manual)
