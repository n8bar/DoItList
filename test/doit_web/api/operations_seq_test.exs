defmodule DoItWeb.Api.OperationsSeqTest do
  @moduledoc """
  The delivery sequence on the wire (m04.03 items 1.1 / 1.2): a committed
  batch answers with `seq` per Initiative it advanced, an idempotent replay
  echoes the stored body unchanged, the envelope the batch flushes carries the
  request's idempotency key and actor, and the snapshot carries the sequence
  it is current to.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}

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

  defp sign_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  defp post_ops(user, operations, key \\ nil) do
    conn =
      build_conn()
      |> sign_in(user)
      |> put_req_header("content-type", "application/json")
      |> then(fn c -> if key, do: put_req_header(c, "idempotency-key", key), else: c end)
      |> post(~p"/app/api/operations", %{"operations" => operations})

    {conn.status, json_response(conn, conn.status)}
  end

  defp add_op(ini, title) do
    %{
      "op" => "add",
      "type" => "task",
      "data" => %{"initiative_id" => ini.id, "parent_id" => ini.root_task_id, "title" => title}
    }
  end

  setup do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Seq"})
    :ok = Tasks.subscribe(ini.id)
    %{owner: owner, ini: ini}
  end

  test "a committed batch answers with the sequence it advanced, and a replay echoes it", ctx do
    key = "seq-#{System.unique_integer([:positive])}"
    before = Initiatives.get_initiative!(ctx.ini.id).seq

    {200, body} = post_ops(ctx.owner, [add_op(ctx.ini, "One"), add_op(ctx.ini, "Two")], key)
    assert body["seq"] == %{Integer.to_string(ctx.ini.id) => before + 1}
    assert [%{"status" => "ok"}, %{"status" => "ok"}] = body["results"]

    {200, replay} = post_ops(ctx.owner, [add_op(ctx.ini, "One"), add_op(ctx.ini, "Two")], key)
    assert replay == body
    assert Initiatives.get_initiative!(ctx.ini.id).seq == before + 1
  end

  test "the envelope names the request's key and actor", ctx do
    key = "origin-#{System.unique_integer([:positive])}"
    {200, _body} = post_ops(ctx.owner, [add_op(ctx.ini, "Mine")], key)

    assert_receive {:initiative_delta, env}, 1000
    assert env.origin_key == key
    assert env.actor.id == ctx.owner.id and env.actor.username == ctx.owner.username
  end

  test "an unkeyed request's envelope has no origin key but still an actor", ctx do
    {200, body} = post_ops(ctx.owner, [add_op(ctx.ini, "Unkeyed")])
    assert %{"seq" => %{}} = body

    assert_receive {:initiative_delta, env}, 1000
    assert env.origin_key == nil
    assert env.actor.id == ctx.owner.id
  end

  test "a rolled-back batch answers without a sequence", ctx do
    {422, body} =
      post_ops(ctx.owner, [%{"op" => "add", "type" => "task", "data" => %{"title" => "x"}}])

    refute Map.has_key?(body, "seq")
  end

  test "the snapshot carries the sequence it is current to", ctx do
    {200, _} = post_ops(ctx.owner, [add_op(ctx.ini, "One")])

    conn = build_conn() |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives/#{ctx.ini.id}")
    %{"data" => snapshot} = json_response(conn, 200)

    assert snapshot["seq"] == Initiatives.get_initiative!(ctx.ini.id).seq
    assert snapshot["seq"] >= 1
  end
end
