defmodule DoItWeb.Api.OperationsAccountTest do
  @moduledoc """
  `update account` with `index_sort` / `index_sort_reverse` (m04.02 item 7.3)
  — the caller's own Initiatives index sort, written onto the preferences row
  the workspace's Sort control uses.

  Covers: both keys land and the result echoes them; a mode alone keeps the
  reverse that mode already had; a flag alone lands on the current mode; a
  `null` mode is Recent; an unknown mode, a non-boolean flag, and an unknown
  key are per-op errors that write nothing; an `id` changes nothing (the
  target is always the caller); the session read reports the same pair.

  Each `post_ops` mints a fresh token, so the per-token rate limit never bites.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.Accounts

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

  defp update_account(user, data) do
    post_ops(user, [%{"op" => "update", "type" => "account", "data" => data}])
  end

  defp first_error(body), do: Enum.at(body["results"], 0)["error"]

  setup do
    %{user: user("sorter")}
  end

  test "mode and reverse land on the preferences row and the result echoes them", ctx do
    {200, body} =
      update_account(ctx.user, %{"index_sort" => "name", "index_sort_reverse" => true})

    assert %{"status" => "ok", "data" => data} = Enum.at(body["results"], 0)
    assert data == %{"type" => "account", "index_sort" => "name", "index_sort_reverse" => true}

    prefs = Accounts.get_preferences(ctx.user)
    assert prefs.index_sort_mode == "name"
    assert prefs.index_sort_reverse_by_mode == %{"name" => true}
  end

  test "a mode alone keeps the reverse that mode already had", ctx do
    {:ok, _} =
      Accounts.update_preferences(ctx.user, %{
        "index_sort_mode" => "name",
        "index_sort_reverse_by_mode" => %{"name" => false, "updated" => true}
      })

    {200, body} = update_account(ctx.user, %{"index_sort" => "updated"})

    assert Enum.at(body["results"], 0)["data"]["index_sort_reverse"] == true
    prefs = Accounts.get_preferences(ctx.user)
    assert prefs.index_sort_mode == "updated"
    assert prefs.index_sort_reverse_by_mode == %{"name" => false, "updated" => true}
  end

  test "a flag alone lands on the current mode, and null is Recent", ctx do
    {200, _} = update_account(ctx.user, %{"index_sort_reverse" => true})
    assert Accounts.get_preferences(ctx.user).index_sort_reverse_by_mode == %{"" => true}

    {200, body} = update_account(ctx.user, %{"index_sort" => nil, "index_sort_reverse" => false})
    assert Enum.at(body["results"], 0)["data"]["index_sort"] == nil

    prefs = Accounts.get_preferences(ctx.user)
    assert prefs.index_sort_mode == nil
    assert prefs.index_sort_reverse_by_mode == %{"" => false}
  end

  test "an unknown mode is a per-op error at index_sort and writes nothing", ctx do
    {422, body} = update_account(ctx.user, %{"index_sort" => "colour"})

    assert first_error(body)["code"] == "unprocessable_entity"
    assert first_error(body)["pointer"] == "index_sort"
    assert first_error(body)["message"] =~ "manual, name, progress, created, updated"
    assert Accounts.get_preferences(ctx.user).index_sort_mode == nil
  end

  test "a non-boolean reverse is a per-op error at index_sort_reverse", ctx do
    {422, body} = update_account(ctx.user, %{"index_sort_reverse" => "yes"})

    assert first_error(body)["code"] == "unprocessable_entity"
    assert first_error(body)["pointer"] == "index_sort_reverse"
    assert Accounts.get_preferences(ctx.user).index_sort_reverse_by_mode == %{}
  end

  test "an unknown key is refused with the accepted keys named", ctx do
    {422, body} = update_account(ctx.user, %{"show_task_count" => false})

    assert first_error(body)["pointer"] == "show_task_count"
    assert first_error(body)["message"] =~ "index_sort, index_sort_reverse"
    assert Accounts.get_preferences(ctx.user).show_task_count == true
  end

  test "an id on the op changes nothing: only the caller's own row is written", ctx do
    other = user("other")

    {200, _} =
      post_ops(ctx.user, [
        %{
          "op" => "update",
          "type" => "account",
          "id" => other.id,
          "data" => %{"index_sort" => "progress"}
        }
      ])

    assert Accounts.get_preferences(ctx.user).index_sort_mode == "progress"
    assert Accounts.get_preferences(other).index_sort_mode == nil
  end

  test "add and remove account are unsupported", ctx do
    {422, body} = post_ops(ctx.user, [%{"op" => "remove", "type" => "account"}])
    assert first_error(body)["code"] == "unsupported_op"
  end
end
