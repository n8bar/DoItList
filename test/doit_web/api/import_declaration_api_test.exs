defmodule DoItWeb.Api.ImportDeclarationApiTest do
  @moduledoc """
  `POST /api/v1/import_declarations` (m03.04 2.8.10): the MCP adapter's
  record write for an accepted first-import declaration — edit-gated,
  idempotent (first declaration wins), 422 on arithmetic nonsense.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, ImportDeclarations, Initiatives}

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

  defp token(user) do
    {:ok, {plaintext, _}} = Accounts.mint_api_token(user, "test")
    plaintext
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  setup do
    owner = user("owner")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Import"}, agent_access: true)

    %{owner: owner, ini: ini}
  end

  defp body(ini_id, extra \\ %{}) do
    Map.merge(
      %{
        "initiative_id" => ini_id,
        "source_total" => 20,
        "source_completed" => 5,
        "excluded_count" => 2,
        "exclusions" => "2 × appendix notes",
        "ordering" => "outline"
      },
      extra
    )
  end

  test "records the declaration and serves its shape; a re-post returns the standing row", ctx do
    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> post(~p"/api/v1/import_declarations", body(ctx.ini.id))

    assert %{
             "data" => %{
               "initiative_id" => ini_id,
               "source_total" => 20,
               "source_completed" => 5,
               "excluded_count" => 2,
               "exclusions" => "2 × appendix notes",
               "ordering" => "outline",
               "inserted_at" => _
             }
           } = json_response(conn, 200)

    assert ini_id == ctx.ini.id

    # First declaration wins — the re-post's changed numbers don't land.
    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> post(~p"/api/v1/import_declarations", body(ctx.ini.id, %{"source_total" => 99}))

    assert %{"data" => %{"source_total" => 20}} = json_response(conn, 200)
    assert ImportDeclarations.for_initiative(ctx.ini.id).source_total == 20
  end

  test "edit-gated like the writes: stranger 403, unknown 404, viewer 403", ctx do
    stranger = user("stranger")

    conn =
      build_conn()
      |> bearer(token(stranger))
      |> post(~p"/api/v1/import_declarations", body(ctx.ini.id))

    assert json_response(conn, 403)

    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> post(~p"/api/v1/import_declarations", body(999_999_999))

    assert json_response(conn, 404)

    viewer = user("viewer")
    {:ok, _} = Initiatives.add_member(ctx.ini.id, viewer.id, "viewer")

    conn =
      build_conn()
      |> bearer(token(viewer))
      |> post(~p"/api/v1/import_declarations", body(ctx.ini.id))

    assert json_response(conn, 403)
  end

  test "arithmetic nonsense and missing fields are a 422", ctx do
    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> post(~p"/api/v1/import_declarations", body(ctx.ini.id, %{"source_completed" => 25}))

    assert %{"error" => %{"message" => message}} = json_response(conn, 422)
    assert message =~ "source_completed"

    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> post(~p"/api/v1/import_declarations", %{"source_total" => 20})

    assert %{"error" => %{"message" => message}} = json_response(conn, 422)
    assert message =~ "initiative_id"
  end
end
