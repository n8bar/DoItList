defmodule DoItWeb.Api.AuthzTest do
  @moduledoc """
  The 403 path (m03.01 worklist 1.4): authorization reuses the existing
  owner/editor/viewer checks unchanged, and a denial renders as a 403 in the
  single-error JSON shape via the FallbackController.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives}
  alias DoItWeb.Api.{Authz, FallbackController}

  defp user(name) do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
        "username" => "#{name}-#{System.unique_integer([:positive])}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  setup do
    owner = user("owner")
    editor = user("editor")
    viewer = user("viewer")
    stranger = user("stranger")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})
    {:ok, _} = Initiatives.add_member(ini.id, editor.id, "editor")
    {:ok, _} = Initiatives.add_member(ini.id, viewer.id, "viewer")

    %{ini: ini, owner: owner, editor: editor, viewer: viewer, stranger: stranger}
  end

  test "owner/editor can edit; viewer/stranger are forbidden", ctx do
    assert Authz.authorize(ctx.owner, ctx.ini, :edit) == :ok
    assert Authz.authorize(ctx.editor, ctx.ini, :edit) == :ok
    assert Authz.authorize(ctx.viewer, ctx.ini, :edit) == {:error, :forbidden}
    assert Authz.authorize(ctx.stranger, ctx.ini, :edit) == {:error, :forbidden}
  end

  test "view is allowed for any member but not a stranger", ctx do
    assert Authz.authorize(ctx.viewer, ctx.ini, :view) == :ok
    assert Authz.authorize(ctx.editor, ctx.ini, :view) == :ok
    assert Authz.authorize(ctx.stranger, ctx.ini, :view) == {:error, :forbidden}
  end

  test "admin is owner-only", ctx do
    assert Authz.authorize(ctx.owner, ctx.ini, :admin) == :ok
    assert Authz.authorize(ctx.editor, ctx.ini, :admin) == {:error, :forbidden}
  end

  test "the fallback renders {:error, :forbidden} as a 403 JSON body", %{conn: conn} do
    conn = FallbackController.call(conn, {:error, :forbidden})

    assert %{"error" => error} = json_response(conn, 403)
    assert error["status"] == 403
    assert error["code"] == "forbidden"
    assert is_binary(error["message"])
  end
end
