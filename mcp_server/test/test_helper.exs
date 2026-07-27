System.put_env("DOITLIST_API_TOKEN", "test-token")

# Always-on infrastructure the transport trees carry (m03.04 item 23.3):
# session-keyed elicitation waiters and per-session 401-recovery state.
# Started once for the whole suite — entries key on session PIDs, so
# concurrent tests can't collide — while the app tree itself stays empty
# under ExUnit (DoitMcp.Application.children(:test) == []).
{:ok, _} = Registry.start_link(keys: :unique, name: DoitMcp.Elicitation.Registry)
{:ok, _} = DoitMcp.TokenRecovery.Sessions.start_link([])

ExUnit.start()
