# A VM-wide API token nothing may use — the negative control for the rule
# that a session's credential is its own (m03.04 2.2.1.2): a session that
# presents no bearer header must get the 401 guidance, never a token lying
# around in the environment.
System.put_env("DOITLIST_API_TOKEN", "test-token")

# Always-on infrastructure the transport tree carries (m03.04 2.2.1.3):
# session-keyed elicitation waiters and per-session 401-recovery state.
# Started once for the whole suite — entries key on session PIDs, so
# concurrent tests can't collide — while the app tree itself stays empty
# under ExUnit (DoitMcp.Application.children(:test) == []).
{:ok, _} = Registry.start_link(keys: :unique, name: DoitMcp.Elicitation.Registry)
{:ok, _} = DoitMcp.TokenRecovery.Sessions.start_link([])

ExUnit.start()
