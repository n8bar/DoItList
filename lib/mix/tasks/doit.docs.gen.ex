defmodule Mix.Tasks.Doit.Docs.Gen do
  @shortdoc "Regenerate the fenced blocks in docs/reference/agent_surfaces.md"

  @moduledoc """
  Rewrites the fenced generated blocks in `docs/reference/agent_surfaces.md`
  from the live code (m03.05 worklist 2):

    * the endpoint list, from `DoItWeb.Router`
    * the op table, from `DoItWeb.Api.Operations`
    * the response shapes, from `DoItWeb.Api.Serializer`
    * the MCP tool list, from `DoitMcp.Server`
    * the scripted client's verbs and options, from `scripts/doitlist.py --help`

  Prose outside the fences is left untouched. Refuses to write — naming the
  file — when a fence is missing or unbalanced; see `DoIt.DocsGen`.

      $ mix doit.docs.gen

  `--check` verifies without writing, exiting non-zero when the file is
  stale — the form `mix precommit` runs, so a contract change that skips
  regenerating fails the build instead of landing silently.

      $ mix doit.docs.gen --check
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [check: :boolean])
    check? = Keyword.get(opts, :check, false)

    path = DoIt.DocsGen.doc_path()
    original = File.read!(path)

    updated =
      with_endpoint(fn ->
        try do
          DoIt.DocsGen.regenerate(original)
        rescue
          e in DoIt.DocsGen.FenceError -> Mix.raise(e.message)
        end
      end)

    cond do
      updated == original ->
        Mix.shell().info("docs/reference/agent_surfaces.md is already up to date.")

      check? ->
        Mix.raise(
          "docs/reference/agent_surfaces.md is stale — run `mix doit.docs.gen` and commit the result."
        )

      true ->
        File.write!(path, updated)
        Mix.shell().info("Regenerated docs/reference/agent_surfaces.md.")
    end
  end

  # The connect pastes read the endpoint's public URL, which lives in a
  # persistent term written when the endpoint starts — so compiling isn't
  # enough. Start it with `server: false` (no port bound, so a running server
  # keeps 4000), then stop it again: `mix precommit` runs this task before
  # `mix test`, and an endpoint left running makes the app's own start fail.
  defp with_endpoint(fun) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:telemetry)

    previous = Application.get_env(:doit, DoItWeb.Endpoint, [])
    Application.put_env(:doit, DoItWeb.Endpoint, Keyword.put(previous, :server, false))

    case DoItWeb.Endpoint.start_link() do
      {:ok, pid} ->
        try do
          fun.()
        after
          Supervisor.stop(pid)
          Application.put_env(:doit, DoItWeb.Endpoint, previous)
        end

      {:error, {:already_started, _pid}} ->
        Application.put_env(:doit, DoItWeb.Endpoint, previous)
        fun.()
    end
  end
end
