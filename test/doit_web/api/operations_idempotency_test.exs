defmodule DoItWeb.Api.OperationsIdempotencyTest do
  @moduledoc """
  Idempotent retries on `POST /api/v1/operations` (m03.03 worklist 2.2).

  A repeat request carrying the same `Idempotency-Key` and the same payload
  replays the first attempt's stored response and does NOT re-execute — proven
  by the side effect happening exactly once. The key binds to its payload
  (m03.04 fix 20): a same-key request with a changed payload is a 422 naming
  the key conflict, and a rolled-back batch stores nothing, so an honest retry
  after a rollback re-executes. A committed payload re-sent under a NEW key is
  a 422 naming the earlier key and its commit time (m03.04 2.7.6) — only a
  changed payload takes a new key; unkeyed re-sends stay uncheckable and
  apply. Also covers the no-key baseline (unchanged, nothing stored).

  Each `post_ops` mints a fresh token, so the per-token rate limit (5/window in
  `config/test.exs`) never bites across a test's few requests. Idempotency is
  keyed by `(user, key)`, not by token — a fresh token, same user, same key
  still replays.
  """
  use DoItWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias DoIt.{Accounts, Initiatives}
  alias DoIt.Api.IdempotencyKey
  alias DoIt.Repo
  alias DoIt.Tasks.Task

  defp user(name) do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{n}@example.com",
        "username" => "#{name}-#{n}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  defp token(user) do
    {:ok, {plaintext, _}} = Accounts.mint_api_token(user, "test")
    plaintext
  end

  # POST a batch as `user`, optionally with an Idempotency-Key header; returns
  # `{status, decoded_body}`.
  defp post_ops(user, operations, key \\ nil) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token(user))
      |> put_req_header("content-type", "application/json")
      |> maybe_key(key)
      |> post(~p"/api/v1/operations", %{"operations" => operations})

    {conn.status, json_response(conn, conn.status)}
  end

  defp maybe_key(conn, nil), do: conn
  defp maybe_key(conn, key), do: put_req_header(conn, "idempotency-key", key)

  defp add_task(ini, title) do
    %{
      "op" => "add",
      "type" => "task",
      "data" => %{
        "initiative_id" => ini.id,
        "parent_id" => ini.root_task_id,
        "title" => title
      }
    }
  end

  defp count_tasks(title), do: Repo.aggregate(from(t in Task, where: t.title == ^title), :count)

  setup do
    owner = user("owner")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Q3 Launch"}, agent_access: true)

    %{owner: owner, ini: ini}
  end

  test "same key + same payload replays the committed response and does not execute twice",
       ctx do
    key = "idem-#{System.unique_integer([:positive])}"
    ops = [add_task(ctx.ini, "OnceOnly")]

    {s1, b1} = post_ops(ctx.owner, ops, key)
    assert s1 == 200
    assert [%{"status" => "ok", "data" => %{"id" => id}}] = b1["results"]
    assert count_tasks("OnceOnly") == 1

    # Second identical request, same key: byte-identical replay, no re-execution.
    {s2, b2} = post_ops(ctx.owner, ops, key)
    assert s2 == 200
    assert b2 == b1
    # The side effect happened exactly once — not a second task.
    assert count_tasks("OnceOnly") == 1
    assert [%{"data" => %{"id" => ^id}}] = b2["results"]
  end

  test "same key + changed payload is a 422 naming the key conflict, not a replay", ctx do
    key = "idem-#{System.unique_integer([:positive])}"

    {s1, b1} = post_ops(ctx.owner, [add_task(ctx.ini, "FirstPayload")], key)
    assert s1 == 200
    assert count_tasks("FirstPayload") == 1

    # Same key, different batch: rejected — neither replayed nor executed.
    {s2, b2} = post_ops(ctx.owner, [add_task(ctx.ini, "ChangedPayload")], key)
    assert s2 == 422
    assert b2["error"]["code"] == "unprocessable_entity"
    assert b2["error"]["message"] =~ "Idempotency-Key conflict"
    assert b2["error"]["message"] =~ "One key per batch"
    assert count_tasks("ChangedPayload") == 0

    # The stored response is untouched — the original payload still replays.
    {s3, b3} = post_ops(ctx.owner, [add_task(ctx.ini, "FirstPayload")], key)
    assert s3 == 200
    assert b3 == b1
    assert count_tasks("FirstPayload") == 1
  end

  test "a rolled-back batch stores nothing — an honest retry on the same key re-executes",
       ctx do
    key = "idem-#{System.unique_integer([:positive])}"

    # op 0 would create a task; op 1 targets a non-existent task, so the WHOLE
    # batch rolls back with a 422 — nothing persists, and nothing is stored.
    bad_ops = [
      add_task(ctx.ini, "RolledBack"),
      %{"op" => "update", "type" => "task", "id" => 999_999_999, "data" => %{"done" => true}}
    ]

    {s1, b1} = post_ops(ctx.owner, bad_ops, key)
    assert s1 == 422
    assert b1["error"]["status"] == 422
    assert count_tasks("RolledBack") == 0

    assert Repo.aggregate(from(r in IdempotencyKey, where: r.user_id == ^ctx.owner.id), :count) ==
             0

    # The honest retry — same key, batch revised to drop the bad op — really
    # re-executes (a stored 422 would have replayed or key-conflicted instead).
    {s2, b2} = post_ops(ctx.owner, [add_task(ctx.ini, "RolledBack")], key)
    assert s2 == 200
    assert [%{"status" => "ok"}] = b2["results"]
    assert count_tasks("RolledBack") == 1
  end

  test "no key: behavior unchanged, re-sends apply, and nothing is stored", ctx do
    ops = [add_task(ctx.ini, "NoKey")]

    {status, body} = post_ops(ctx.owner, ops)
    assert status == 200
    assert [%{"status" => "ok"}] = body["results"]
    assert count_tasks("NoKey") == 1

    # An unkeyed same-payload re-send stays as today: without a key the server
    # can't distinguish retry from intent, so it applies (a second copy).
    {status2, _} = post_ops(ctx.owner, ops)
    assert status2 == 200
    assert count_tasks("NoKey") == 2

    # No idempotency row recorded for this user.
    assert Repo.aggregate(from(r in IdempotencyKey, where: r.user_id == ^ctx.owner.id), :count) ==
             0
  end

  test "the same payload under a new key is refused naming the earlier key and its time",
       ctx do
    n = System.unique_integer([:positive])
    key_a = "key-a-#{n}"
    ops = [add_task(ctx.ini, "OneCopy")]

    {s1, b1} = post_ops(ctx.owner, ops, key_a)
    assert s1 == 200
    assert count_tasks("OneCopy") == 1

    committed_at =
      Repo.one!(
        from r in IdempotencyKey,
          where: r.user_id == ^ctx.owner.id and r.idempotency_key == ^key_a,
          select: r.inserted_at
      )

    # Identical payload, fresh key: refused — the 422 names the earlier key,
    # its commit time, and both recoveries. No second subtree (m03.04 2.7.6).
    {s2, b2} = post_ops(ctx.owner, ops, "key-b-#{n}")
    assert s2 == 422
    assert b2["error"]["code"] == "unprocessable_entity"
    assert b2["error"]["message"] =~ "Duplicate batch"
    assert b2["error"]["message"] =~ "\"#{key_a}\""
    assert b2["error"]["message"] =~ DateTime.to_iso8601(committed_at)
    assert b2["error"]["message"] =~ "change the payload if a second copy is meant"
    assert count_tasks("OneCopy") == 1

    # The named recovery works: the earlier key still replays its response.
    {s3, b3} = post_ops(ctx.owner, ops, key_a)
    assert s3 == 200
    assert b3 == b1
    assert count_tasks("OneCopy") == 1

    # KEYED batches only: the same payload unkeyed still applies.
    {s4, _} = post_ops(ctx.owner, ops)
    assert s4 == 200
    assert count_tasks("OneCopy") == 2
  end

  test "a changed payload under a new key applies", ctx do
    n = System.unique_integer([:positive])

    {s1, _} = post_ops(ctx.owner, [add_task(ctx.ini, "CopyOne")], "key-a-#{n}")
    {s2, _} = post_ops(ctx.owner, [add_task(ctx.ini, "CopyTwo")], "key-b-#{n}")

    assert s1 == 200
    assert s2 == 200
    # Distinct payloads under distinct keys are distinct requests.
    assert count_tasks("CopyOne") == 1
    assert count_tasks("CopyTwo") == 1
  end
end
