defmodule DoItWeb.Api.OperationsInitiativePositionTest do
  @moduledoc """
  `update initiative` with `position` (m04.02 item 4.4) — the caller's own
  slot in their Manual index order, through `Initiatives.set_index_order/2`.

  Covers: to the front, to the end, into the middle, a slot past the end
  clamps to last, a never-placed row sits after the placed ones, a viewer's
  order is their own and leaves the owner's alone, a non-member is refused,
  and a non-integer position or a content field in the same op is a per-op
  error.

  Each `post_ops` mints a fresh token, so the per-token rate limit never bites.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives}

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

  defp post_ops(user, operations) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token(user))
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/operations", %{"operations" => operations})

    {conn.status, json_response(conn, conn.status)}
  end

  defp position_op(id, data),
    do: %{"op" => "update", "type" => "initiative", "id" => id, "data" => data}

  defp place(user, id, position) do
    {status, body} = post_ops(user, [position_op(id, %{"position" => position})])
    assert status == 200
    assert [%{"status" => "ok", "data" => data}] = body["results"]
    data
  end

  # `ids` with `id` lifted out and put back at `at`: the order a placement
  # should leave behind.
  defp moved(ids, id, at), do: ids |> List.delete(id) |> List.insert_at(at, id)

  # Three Initiatives; nobody has placed any yet, so each member's index starts
  # in the list's own order (`start`; the three share a timestamp, so it is
  # read rather than assumed).
  setup do
    owner = user("owner")
    viewer = user("viewer")
    stranger = user("stranger")

    [a, b, c] =
      for name <- ~w(Alpha Beta Gamma) do
        {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => name}, agent_access: true)
        {:ok, _} = Initiatives.add_member(ini.id, viewer.id, "viewer")
        ini
      end

    start = Initiatives.index_order(owner)
    assert Enum.sort(start) == Enum.sort([a.id, b.id, c.id])
    assert start == Initiatives.index_order(viewer)

    %{owner: owner, viewer: viewer, stranger: stranger, a: a, b: b, c: c, start: start}
  end

  test "moves to the front", ctx do
    id = List.last(ctx.start)
    data = place(ctx.owner, id, 0)

    assert data["sort_order"] == 0
    assert data["order"] == moved(ctx.start, id, 0)
    assert Initiatives.index_order(ctx.owner) == moved(ctx.start, id, 0)
  end

  test "moves to the end", ctx do
    id = hd(ctx.start)
    data = place(ctx.owner, id, 2)

    assert data["sort_order"] == 2
    assert Initiatives.index_order(ctx.owner) == moved(ctx.start, id, 2)
  end

  test "moves into the middle", ctx do
    id = hd(ctx.start)
    data = place(ctx.owner, id, 1)

    assert data["sort_order"] == 1
    assert Initiatives.index_order(ctx.owner) == moved(ctx.start, id, 1)
  end

  test "a slot past the end lands last, and a negative one first", ctx do
    first = hd(ctx.start)
    assert place(ctx.owner, first, 99)["sort_order"] == 2
    after_first = moved(ctx.start, first, 2)
    assert Initiatives.index_order(ctx.owner) == after_first

    last = List.last(after_first)
    assert place(ctx.owner, last, -5)["sort_order"] == 0
    assert Initiatives.index_order(ctx.owner) == moved(after_first, last, 0)
  end

  test "a row created after a placement sits after the placed ones", ctx do
    id = List.last(ctx.start)
    place(ctx.owner, id, 0)
    {:ok, d} = Initiatives.create_initiative(ctx.owner, %{"name" => "Delta"}, agent_access: true)

    assert Initiatives.index_order(ctx.owner) == moved(ctx.start, id, 0) ++ [d.id]

    # The list read shows the same slots.
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token(ctx.owner))
      |> get(~p"/api/v1/initiatives")

    by_id = Map.new(json_response(conn, 200)["data"], &{&1["id"], &1["sort_order"]})
    assert by_id[id] == 0
    assert by_id[d.id] == nil
  end

  test "a viewer's order is their own; the owner's does not move", ctx do
    id = List.last(ctx.start)
    version = Initiatives.get_initiative(id).version
    place(ctx.viewer, id, 0)

    assert Initiatives.index_order(ctx.viewer) == moved(ctx.start, id, 0)
    assert Initiatives.index_order(ctx.owner) == ctx.start
    assert Initiatives.get_initiative(id).version == version
  end

  test "a non-member is refused", ctx do
    {status, body} = post_ops(ctx.stranger, [position_op(ctx.a.id, %{"position" => 0})])

    assert status == 403
    assert [%{"status" => "error", "error" => %{"code" => "forbidden"}}] = body["results"]
    assert Initiatives.index_order(ctx.owner) == ctx.start
  end

  test "a non-integer position is a per-op error at position", ctx do
    {status, body} = post_ops(ctx.owner, [position_op(ctx.a.id, %{"position" => "first"})])

    assert status == 422
    assert [%{"status" => "error", "error" => %{"pointer" => "position"}}] = body["results"]
  end

  test "position travels alone", ctx do
    {status, body} =
      post_ops(ctx.owner, [position_op(ctx.a.id, %{"position" => 0, "name" => "Renamed"})])

    assert status == 422
    assert [%{"status" => "error", "error" => %{"pointer" => "name"}}] = body["results"]
    assert Initiatives.get_initiative(ctx.a.id).name == "Alpha"
  end
end
