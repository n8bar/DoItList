defmodule Mix.Tasks.Doit.Docs.Gen do
  @shortdoc "Regenerate the fenced blocks in docs/specs/agent_integration.md"

  @moduledoc """
  Rewrites the fenced generated blocks in `docs/specs/agent_integration.md`
  from the live code (m03.05 worklist 2):

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
    Mix.Task.run("compile")
    {opts, _rest} = OptionParser.parse!(args, strict: [check: :boolean])
    check? = Keyword.get(opts, :check, false)

    path = DoIt.DocsGen.doc_path()
    original = File.read!(path)

    updated =
      try do
        DoIt.DocsGen.regenerate(original)
      rescue
        e in DoIt.DocsGen.FenceError -> Mix.raise(e.message)
      end

    cond do
      updated == original ->
        Mix.shell().info("docs/specs/agent_integration.md is already up to date.")

      check? ->
        Mix.raise(
          "docs/specs/agent_integration.md is stale — run `mix doit.docs.gen` and commit the result."
        )

      true ->
        File.write!(path, updated)
        Mix.shell().info("Regenerated docs/specs/agent_integration.md.")
    end
  end
end
