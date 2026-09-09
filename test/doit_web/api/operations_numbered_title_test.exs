defmodule DoItWeb.Api.OperationsNumberedTitleTest do
  @moduledoc """
  Positional numbering in agent-written titles (m03.04 6.4): under an indexed
  Initiative, `add task` and `update task` refuse a title opening with `1.`,
  `2.3`, `4)`, `I.`, or `A)` plus a space unless `numbered_title: true` rides
  along; under `none` anything goes; a bare word (`A big task`) is never a
  marker.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}

  @message "Titles carry no positional numbering; the Initiative's index supplies it. " <>
             "Retry without the prefix, or pass `numbered_title: true` if the user asked for it."

  defp user do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "numbered-#{System.unique_integer([:positive])}@example.com",
        "username" => "numbered-#{System.unique_integer([:positive])}",
        "name" => "Numbered",
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

  defp initiative(owner, style) do
    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Numbered", "index_style" => style},
        agent_access: true
      )

    ini
  end

  defp add_op(ini, title, extra \\ %{}) do
    %{
      "op" => "add",
      "type" => "task",
      "lid" => "t1",
      "data" => Map.merge(%{"initiative_id" => ini.id, "title" => title}, extra)
    }
  end

  defp update_op(task, title, extra \\ %{}) do
    %{
      "op" => "update",
      "type" => "task",
      "id" => task.id,
      "data" => Map.merge(%{"title" => title}, extra)
    }
  end

  defp refused?({422, body}) do
    [%{"error" => error}] = body["results"]
    error["pointer"] == "title" and error["message"] == @message
  end

  defp refused?(_), do: false

  setup do
    owner = user()
    %{owner: owner}
  end

  test "under numerical, a marker prefix is refused on add and update", %{owner: owner} do
    ini = initiative(owner, "numerical")
    {:ok, task} = Tasks.create_task(owner, %{"initiative_id" => ini.id, "title" => "Plain"})

    for title <- ["1. Kickoff", "2.3 Draft", "4) Ship", "I. Plan", "A) Sort"] do
      assert refused?(post_ops(owner, [add_op(ini, title)])), "add #{title}"
      assert refused?(post_ops(owner, [update_op(task, title)])), "update #{title}"
    end

    assert Tasks.get_task!(task.id).title == "Plain"
  end

  test "under numerical, a bare word followed by a space is not a marker", %{owner: owner} do
    ini = initiative(owner, "numerical")

    for title <- ["A big task", "I want this"] do
      {200, body} = post_ops(owner, [add_op(ini, title)])
      [%{"data" => %{"title" => ^title}}] = body["results"]
    end
  end

  test "under none, a marker prefix is accepted", %{owner: owner} do
    ini = initiative(owner, "none")
    {:ok, task} = Tasks.create_task(owner, %{"initiative_id" => ini.id, "title" => "Plain"})

    {200, _} = post_ops(owner, [add_op(ini, "1. Kickoff")])
    {200, _} = post_ops(owner, [update_op(task, "I. Plan")])
    assert Tasks.get_task!(task.id).title == "I. Plan"
  end

  test "under numerical, numbered_title: true overrides and never reaches the task", %{
    owner: owner
  } do
    ini = initiative(owner, "numerical")
    {:ok, task} = Tasks.create_task(owner, %{"initiative_id" => ini.id, "title" => "Plain"})
    override = %{"numbered_title" => true}

    {200, body} = post_ops(owner, [add_op(ini, "1. Kickoff", override)])
    [%{"data" => %{"title" => "1. Kickoff"}}] = body["results"]

    {200, _} = post_ops(owner, [update_op(task, "I. Plan", override)])
    assert Tasks.get_task!(task.id).title == "I. Plan"

    assert refused?(post_ops(owner, [add_op(ini, "1. Kickoff", %{"numbered_title" => false})]))
  end
end
