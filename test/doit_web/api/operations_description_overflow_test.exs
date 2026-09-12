defmodule DoItWeb.Api.OperationsDescriptionOverflowTest do
  @moduledoc """
  Overflow doctrine on the description cap (m03.04 fix 22): the
  description-length 422 message appends the guidance — trim and cite the
  source doc, never split into continuation tasks — read at the exact moment
  an agent would otherwise invent them. Asserts the rendered message content;
  other fields' validation messages stay unadorned.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives}

  @guidance "description should be at most 8000 character(s) — trim the prose and " <>
              "cite the source doc path in the provenance comment; do not split the " <>
              "remainder into continuation tasks."

  defp user do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "overflow-#{n}@example.com",
        "username" => "overflow-#{n}",
        "name" => "Overflow",
        "password" => "password123"
      })

    u
  end

  defp post_ops(user, operations) do
    {:ok, {token, _}} = Accounts.mint_api_token(user, "test")

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/operations", %{"operations" => operations})

    {conn.status, json_response(conn, conn.status)}
  end

  setup do
    owner = user()

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Q3 Launch"}, agent_access: true)

    %{owner: owner, ini: ini}
  end

  test "an over-cap description op's 422 message carries the overflow guidance", ctx do
    {status, body} =
      post_ops(ctx.owner, [
        %{
          "op" => "add",
          "type" => "task",
          "data" => %{
            "initiative_id" => ctx.ini.id,
            "parent_id" => ctx.ini.root_task_id,
            "title" => "Oversized",
            "description" => String.duplicate("x", 8001)
          }
        }
      ])

    assert status == 422
    assert [%{"status" => "error", "error" => error}] = body["results"]
    assert error["code"] == "unprocessable_entity"
    assert error["pointer"] == "description"
    assert error["message"] == @guidance
  end

  test "another field's validation message stays unadorned", ctx do
    {status, body} =
      post_ops(ctx.owner, [
        %{
          "op" => "add",
          "type" => "task",
          "data" => %{
            "initiative_id" => ctx.ini.id,
            "parent_id" => ctx.ini.root_task_id,
            "title" => ""
          }
        }
      ])

    assert status == 422
    assert [%{"status" => "error", "error" => error}] = body["results"]
    assert error["pointer"] == "title"
    refute error["message"] =~ "continuation tasks"
  end
end
