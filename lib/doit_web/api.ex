defmodule DoItWeb.Api do
  @moduledoc """
  JSON request/response and error conventions for the `/api/v1` HTTP API
  (m03.01 worklist 1.6).

  All bodies are JSON. Field casing is `snake_case`; timestamps are ISO-8601
  UTC strings (e.g. `"2026-06-26T21:16:46Z"`). Additions within `/api/v1` stay
  additive (Q3) — a breaking change earns `/api/v2`.

  ## Success envelope

  A successful response wraps its payload in a top-level `data` key. The payload
  is either a single resource (an object) or a list:

      # GET /api/v1/me
      {
        "data": {
          "id": 42,
          "email": "ada@example.com",
          "username": "ada",
          "name": "Ada Lovelace"
        }
      }

  ## Single-error shape

  A request that fails as a whole (bad/missing auth, permission denied, not
  found, an invalid request body, or a rate-limit trip) returns a top-level
  `error` object carrying `status`, `code`, and `message`:

      {
        "error": {
          "status": 401,
          "code": "unauthorized",
          "message": "Missing or invalid bearer token."
        }
      }

  Status / code pairings used by the API:

  | HTTP | `code`                 | When                                            |
  |------|------------------------|-------------------------------------------------|
  | 401  | `unauthorized`         | Missing / malformed / invalid / revoked token   |
  | 403  | `forbidden`            | Authenticated but the role check denies the op  |
  | 404  | `not_found`            | The resource doesn't exist (or isn't visible)   |
  | 422  | `unprocessable_entity` | The request body failed validation              |
  | 429  | `rate_limited`         | Per-token rate limit exceeded (see `Retry-After`)|

  ## Per-op error shape (worklist 3 — the atomic-operations endpoint)

  `POST /api/v1/operations` (worklist 3) takes an **ordered list of operations**
  applied all-or-nothing in one transaction. It reports per operation rather
  than with the single-error shape above. Each op echoes its position (`index`)
  and, for creates, the client-assigned local id (`lid`). On success the batch
  returns each op's result:

      {
        "results": [
          {"index": 0, "lid": "t1", "status": "ok", "data": {"id": 100, ...}},
          {"index": 1, "status": "ok", "data": {"id": 101, ...}}
        ]
      }

  On **any** op failing, the whole batch rolls back (nothing is applied) and the
  response identifies the offending op with the per-op error shape — `code` and
  `message` mirror the single-error vocabulary, plus an optional `pointer` to the
  offending field:

      {
        "error": {
          "status": 422,
          "code": "unprocessable_entity",
          "message": "One or more operations failed; the batch was rolled back."
        },
        "results": [
          {"index": 0, "lid": "t1", "status": "ok"},
          {
            "index": 1,
            "status": "error",
            "error": {"code": "unprocessable_entity", "message": "title can't be blank", "pointer": "title"}
          }
        ]
      }

  This module owns the shape builders so the single rendering path (used by both
  the auth/rate-limit plugs and `DoItWeb.Api.FallbackController`) stays
  consistent. The per-op builders are referenced here and consumed in worklist 3.
  """

  @doc "Wrap a payload in the success envelope."
  def data(payload), do: %{data: payload}

  @doc "Build the single-error body."
  def error_body(status, code, message) when is_integer(status) do
    %{error: %{status: status, code: to_string(code), message: message}}
  end
end
