defmodule DoItWeb.Client.Api do
  @moduledoc """
  The contract for `/app/api` — the **browser client's private, session-
  authenticated data boundary** (m04.01 worklist 5).

  This is the surface the React client at `/app` reads and writes through. It is
  not a second API: every endpoint under it is a thin edge over the same
  contexts, the same `DoItWeb.Api.Authz` role checks, the same
  `DoItWeb.Api.Serializer` shapes, and the same `DoItWeb.Api.Operations` engine
  the bearer API and the LiveView already use. Nothing here forks business
  logic.

  ## Authentication

  The browser authenticates with the **web session cookie** it already has —
  it never holds an API bearer token (resilient-client spec §1/§12). Writes
  additionally carry the CSRF token as an `x-csrf-token` request header (the
  same token the root layout publishes as `<meta name="csrf-token">`, and the
  one `GET /app/api/session` hands back).

  ## Credential separation

  The two surfaces are sealed against each other, in both directions:

    * `/app/api/*` reads **only** the session. An `Authorization: Bearer …`
      header is never inspected, so a valid token with no session is a `401`.
    * `/api/v1/*` reads **only** the bearer token (`DoItWeb.Api.AuthPlug`); its
      pipeline never fetches the session, so a logged-in browser with no token
      is a `401`.

  Neither surface can pick up the other's credential by accident.

  ## Endpoints

    * `GET  /app/api/session` — the signed-in user plus a fresh CSRF token:
      `{"data": {"user": {"id", "email", "username", "name"}, "csrf_token": "…"}}`.
      The client re-reads this to recover from a `stale_session` error.
    * `GET  /app/api/initiatives` — every Initiative the user can see, as
      `Serializer.initiative_summary/4` maps. Unlike `/api/v1/initiatives`
      this is **not** filtered to agent-accessible Initiatives: the agent-access
      checkbox gates agents, not a member using their own browser.
    * `GET  /app/api/initiatives/:id` — the whole nested tree,
      `Serializer.initiative_tree/8`, identical to `GET /api/v1/initiatives/:id`.
    * `POST /app/api/operations` — the atomic batch, identical semantics,
      per-op result shape, and `Idempotency-Key` handling to
      `POST /api/v1/operations` (both are `DoItWeb.Api.OperationsEndpoint`).

  ## Errors

  Every failure renders JSON — **never** HTML, including for an unauthenticated
  call and a CSRF failure — in the single-error envelope of `DoItWeb.Api`:

      {"error": {"status": 403, "code": "stale_session", "message": "…"}}

  | HTTP | `code`                 | When                                                        |
  |------|------------------------|-------------------------------------------------------------|
  | 401  | `unauthorized`         | No signed-in session (a bearer token alone does not count)  |
  | 403  | `stale_session`        | Missing / stale CSRF token — re-read `GET /app/api/session` and retry |
  | 403  | `forbidden`            | Signed in, but the role check denies it — including a resource not visible to this user |
  | 404  | `not_found`            | No such resource                                             |
  | 409  | `conflict`             | Stale `expected_version` — the record changed since the read |
  | 422  | `unprocessable_entity` | Validation failure; a batch also carries per-op `results`   |

  A `409` / `422` from `POST /app/api/operations` carries the sibling `results`
  array documented in `DoItWeb.Api` — the offending op flagged `error`, every
  other op `not_applied`, the whole batch rolled back.
  """

  alias DoItWeb.Api.Errors

  @doc "401 — no signed-in session on `/app/api`."
  def unauthorized(conn) do
    Errors.send_error(conn, 401, :unauthorized, "You must be signed in.")
  end

  @doc "403 — the CSRF token was missing or stale; the client should re-read the session."
  def stale_session(conn) do
    Errors.send_error(
      conn,
      403,
      :stale_session,
      "Your session token is missing or stale. Re-read GET /app/api/session for a fresh csrf_token and retry."
    )
  end
end
