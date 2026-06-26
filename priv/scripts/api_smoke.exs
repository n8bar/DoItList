# =============================================================================
# THROWAWAY MCP SMOKE-CLIENT — m03.01 worklist 2.4
# =============================================================================
#
# An ergonomics probe, NOT the Arc 2 MCP server. It drives the read endpoints
# the way an agent would — list Initiatives, pull a tree, walk into a task's
# activity/comments — and prints the shapes, so we can pressure-test whether the
# API is composable for an agent *before* the MCP lands and while the contract
# is still cheap to change. A write call is stubbed in, ready to flip on once
# worklist 3 (POST /api/v1/operations) exists.
#
# Delete this once Arc 2's real MCP server supersedes it.
#
# Uses Erlang's built-in :httpc (via :inets) on purpose: Req/Finch aren't deps
# in this project and we don't add one for a throwaway probe. Jason (a real dep)
# decodes. App code must still use Req per the project guidelines — this is a
# script, not the app.
#
# Run (against a running server, with a minted token):
#
#   API_BASE_URL=http://localhost:4000 API_TOKEN=doit_pat_... \
#     docker compose exec -T web mix run priv/scripts/api_smoke.exs
#
# You do NOT need to run it to land worklist 2 — it's an ergonomics probe.
# =============================================================================

:inets.start()
:ssl.start()

base_url = System.get_env("API_BASE_URL", "http://localhost:4000")
token = System.get_env("API_TOKEN") || raise "set API_TOKEN to a minted /api/v1 bearer token"

defmodule Smoke do
  @moduledoc false

  def get(base_url, token, path) do
    url = String.to_charlist(base_url <> path)
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]

    case :httpc.request(:get, {url, headers}, [], body_format: :binary) do
      {:ok, {{_http, status, _reason}, _resp_headers, body}} ->
        {status, decode(body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(""), do: nil

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, json} -> json
      {:error, _} -> body
    end
  end

  def section(title), do: IO.puts("\n=== #{title} ===")

  def show({status, body}) do
    IO.puts("HTTP #{status}")
    IO.puts(Jason.encode!(body, pretty: true))
  end

  def show(other), do: IO.inspect(other, label: "unexpected")
end

g = fn path -> Smoke.get(base_url, token, path) end

Smoke.section("GET /api/v1/me")
Smoke.show(g.("/api/v1/me"))

Smoke.section("GET /api/v1/initiatives (list)")
list = g.("/api/v1/initiatives")
Smoke.show(list)

first_id =
  case list do
    {200, %{"data" => [%{"id" => id} | _]}} -> id
    _ -> nil
  end

if is_nil(first_id) do
  IO.puts("\n(no Initiatives visible to this token — stopping after the list)")
else
  Smoke.section("GET /api/v1/initiatives/#{first_id} (tree)")
  tree = g.("/api/v1/initiatives/#{first_id}")
  Smoke.show(tree)

  first_task_id =
    case tree do
      {200, %{"data" => %{"tasks" => [%{"id" => id} | _]}}} -> id
      _ -> nil
    end

  Smoke.section("GET /api/v1/initiatives/#{first_id}/members")
  Smoke.show(g.("/api/v1/initiatives/#{first_id}/members"))

  Smoke.section("GET /api/v1/initiatives/#{first_id}/activity?limit=5 (rollup, paginated)")
  Smoke.show(g.("/api/v1/initiatives/#{first_id}/activity?limit=5"))

  if first_task_id do
    Smoke.section("GET /api/v1/initiatives/#{first_id}/activity?task_id=#{first_task_id} (subtree)")
    Smoke.show(g.("/api/v1/initiatives/#{first_id}/activity?task_id=#{first_task_id}&limit=5"))

    Smoke.section("GET /api/v1/initiatives/#{first_id}/tasks/#{first_task_id}/comments")
    Smoke.show(g.("/api/v1/initiatives/#{first_id}/tasks/#{first_task_id}/comments"))
  else
    IO.puts("\n(no top-level tasks — skipping the task-scoped reads)")
  end
end

# --- Ready for worklist 3 (the write surface) --------------------------------
# Once POST /api/v1/operations lands, an atomic batch would go here, e.g.:
#
#   Smoke.post(base_url, token, "/api/v1/operations", %{
#     "operations" => [
#       %{"op" => "create_task", "lid" => "t1",
#         "data" => %{"initiative_id" => first_id, "title" => "probe task"}}
#     ]
#   })
#
# Left as a comment so this probe stays read-only until that endpoint exists.

IO.puts("\n=== smoke probe complete ===")
