defmodule DoItWeb.Api.OperationsRemoveInitiativeTest do
  @moduledoc """
  `remove initiative` — the Trash's Delete (m04.02 item 7.4.1). The gate is
  the workspace's: only the owner, only once the Initiative is in Trash.

  Covers: owner on a trashed Initiative purges it and it leaves the archive
  read; a live Initiative is refused as irreversible and survives; an editor
  and a stranger are refused and it survives; a stale `expected_version` is a
  conflict that writes nothing.

  Each `post_ops` mints a fresh token, so the per-token rate limit never bites.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Repo}
  alias DoIt.Initiatives.Initiative
  alias DoItWeb.Api.Reads

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

  defp remove(user, id, data \\ nil) do
    op = %{"op" => "remove", "type" => "initiative", "id" => id}
    post_ops(user, [if(data, do: Map.put(op, "data", data), else: op)])
  end

  defp first_error(body), do: Enum.at(body["results"], 0)["error"]["code"]

  setup do
    owner = user("owner")
    editor = user("editor")
    stranger = user("stranger")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Old Launch"}, agent_access: true)

    {:ok, _} = Initiatives.add_member(ini.id, editor.id, "editor")

    %{owner: owner, editor: editor, stranger: stranger, ini: ini}
  end

  test "the owner purges a trashed Initiative and it leaves the archive read", ctx do
    {:ok, trashed} = Initiatives.trash_initiative(ctx.ini)
    assert [%{id: id}] = Reads.initiative_archive(ctx.owner).trashed
    assert id == ctx.ini.id

    {status, body} = remove(ctx.owner, ctx.ini.id)

    assert status == 200
    assert [%{"status" => "ok", "data" => data}] = body["results"]
    assert data == %{"type" => "initiative", "id" => id, "removed" => true}
    assert Repo.get(Initiative, trashed.id) == nil
    assert Reads.initiative_archive(ctx.owner).trashed == []
  end

  test "a live Initiative is refused as irreversible and survives", ctx do
    {status, body} = remove(ctx.owner, ctx.ini.id)

    assert status == 422
    assert first_error(body) == "irreversible_op"
    assert Repo.get(Initiative, ctx.ini.id) != nil
  end

  test "an editor and a stranger are refused and it survives", ctx do
    {:ok, _} = Initiatives.trash_initiative(ctx.ini)

    for user <- [ctx.editor, ctx.stranger] do
      {status, body} = remove(user, ctx.ini.id)
      assert status == 403
      assert first_error(body) == "forbidden"
    end

    assert Repo.get(Initiative, ctx.ini.id) != nil
    assert [%{id: _}] = Reads.initiative_archive(ctx.owner).trashed
  end

  test "a stale expected_version is a conflict that writes nothing", ctx do
    {:ok, trashed} = Initiatives.trash_initiative(ctx.ini)

    {status, body} = remove(ctx.owner, ctx.ini.id, %{"expected_version" => trashed.version - 1})

    assert status == 409
    assert first_error(body) == "conflict"
    assert Repo.get(Initiative, ctx.ini.id) != nil
  end
end
