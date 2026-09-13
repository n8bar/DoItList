defmodule DoIt.DocsGen do
  @moduledoc """
  Generates the fenced blocks in `docs/reference/agent_surfaces.md` from the
  live code (m03.05 worklist 2) — the endpoint list, the op table, the response
  shapes, the MCP tool list, and the scripted client's verbs and options.
  Anything mechanical lives here so it can't drift from the code it describes;
  the surrounding prose is untouched.

  `regenerate/1` is the one entry point, used by both `mix doit.docs.gen`
  (which writes the result) and the gate test (which only compares it). It
  raises `DoIt.DocsGen.FenceError`, naming the file, when a fence is missing
  or unbalanced.
  """

  alias DoItWeb.AgentConnect
  alias DoItWeb.Api.{Operations, Serializer}
  alias DoItWeb.Router

  defmodule FenceError do
    defexception [:message]
  end

  @doc_relpath "docs/reference/agent_surfaces.md"
  @mcp_relpath "mcp_server"
  @cli_relpath "skills/doitlist/scripts/doitlist.py"

  # The sources every fence in the file must name — checked for presence and
  # balance regardless of which block a given regenerate/1 call touches.
  @sources [
    "DoItWeb.Router",
    "DoItWeb.Api.Operations",
    "DoItWeb.Api.Serializer",
    "DoitMcp.Server",
    "scripts/doitlist.py",
    "DoItWeb.AgentConnect"
  ]

  @doc "Absolute path to the generated doc, rooted at the current project."
  def doc_path, do: Path.join(File.cwd!(), @doc_relpath)

  @doc """
  Returns `text` with every fenced `<!-- generated: SOURCE --> ... <!--
  /generated: SOURCE -->` block replaced by freshly generated content.
  Content outside the fences is returned byte-for-byte.

  Raises `FenceError` — naming `docs/reference/agent_surfaces.md` — when a
  fence is missing, or any fence in the file is unbalanced (an unmatched
  open or close, or a close that names the wrong source).
  """
  def regenerate(text) when is_binary(text) do
    check_fences!(text)

    text
    |> replace_block("DoItWeb.Router", fn -> router_table() end)
    |> replace_block("DoItWeb.Api.Operations", fn -> operations_table() end)
    |> replace_block("DoItWeb.Api.Serializer", fn -> serializer_table() end)
    |> replace_block("DoitMcp.Server", fn -> mcp_table() end)
    |> replace_block("scripts/doitlist.py", fn -> cli_table() end)
    |> replace_block("DoItWeb.AgentConnect", fn -> setup_blocks() end)
  end

  # --- fence validation -------------------------------------------------------

  defp check_fences!(text) do
    markers = Regex.scan(~r/<!--\s*(\/?)generated:\s*(.+?)\s*-->/, text, capture: :all_but_first)

    leftover =
      Enum.reduce(markers, [], fn [slash, source], stack ->
        case {slash, stack} do
          {"", stack} ->
            [source | stack]

          {"/", [^source | rest]} ->
            rest

          {"/", [other | _rest]} ->
            fence_error(
              "<!-- /generated: #{source} --> closes #{other}, not #{source} — unbalanced fence."
            )

          {"/", []} ->
            fence_error("<!-- /generated: #{source} --> has no matching begin marker.")
        end
      end)

    if leftover != [] do
      fence_error("never closed: #{Enum.join(Enum.reverse(leftover), ", ")}.")
    end

    for source <- @sources do
      unless Regex.match?(~r/<!--\s*generated:\s*#{Regex.escape(source)}\s*-->/, text) do
        fence_error("missing fence for #{source}.")
      end
    end

    :ok
  end

  defp fence_error(detail), do: raise(FenceError, message: "#{@doc_relpath}: #{detail}")

  defp replace_block(text, source, body_fun) do
    esc = Regex.escape(source)
    regex = ~r/(<!-- generated: #{esc} -->)(.*?)(<!-- \/generated: #{esc} -->)/s

    unless Regex.match?(regex, text) do
      fence_error("fence for #{source} not found or malformed.")
    end

    body = body_fun.() |> String.trim()

    Regex.replace(regex, text, fn _whole, head, _mid, tail ->
      head <> "\n" <> body <> "\n" <> tail
    end)
  end

  # --- DoItWeb.Router -----------------------------------------------------------

  # Every `/api/v1` route the router actually defines, in router order — the
  # list can't be hand-maintained, so a new endpoint documents itself.
  defp router_table do
    rows =
      for route <- Router.__routes__(), String.starts_with?(route.path, "/api/v1") do
        [route.verb |> Atom.to_string() |> String.upcase(), route.path, action_purpose(route)]
      end

    build_table(["Method", "Path", "Purpose"], rows)
  end

  # The purpose is the controller action's own `@doc`, read the way
  # serializer_table/0 reads the shapes. An undocumented action fails the run
  # rather than emitting an empty cell.
  defp action_purpose(%{plug: controller, plug_opts: action}) do
    {:docs_v1, _anno, _lang, _format, _moduledoc, _meta, docs} = Code.fetch_docs(controller)

    purpose =
      Enum.find_value(docs, fn
        {{:function, ^action, 2}, _anno, _sig, doc, _meta} when doc not in [:none, :hidden] ->
          first_sentence(doc_text(doc))

        _other ->
          nil
      end)

    purpose ||
      raise "#{inspect(controller)}.#{action}/2 has no @doc — every /api/v1 action needs one."
  end

  # --- DoItWeb.Api.Operations --------------------------------------------------

  # The connect pastes the account page hands out, with the instance's own
  # address and the reader's token replaced by placeholders so the block is
  # the same in every environment.
  @placeholder_token "doit_pat_YOUR_TOKEN"

  defp setup_blocks do
    posix = AgentConnect.client_pastes(@placeholder_token, :posix)
    powershell = AgentConnect.client_pastes(@placeholder_token, :powershell)

    Enum.zip(posix, powershell)
    |> Enum.map_join("\n\n", fn {{_slug, label, sh}, {_ps_slug, _ps_label, ps}} ->
      "#### #{label}\n\n" <> shells(mask_urls(sh), mask_urls(ps))
    end)
  end

  # A paste that reads the same in both shells is printed once.
  defp shells(same, same), do: "```sh\n#{same}\n```"

  defp shells(posix, powershell) do
    "```sh\n#{posix}\n```\n\n```powershell\n#{powershell}\n```"
  end

  defp mask_urls(text) do
    mcp = AgentConnect.mcp_url()

    Regex.replace(~r{https?://[^\s'"]+}, text, fn url ->
      if url == mcp, do: "https://doitlist.app/mcp/", else: "https://doitlist.app"
    end)
  end

  defp operations_table do
    rows =
      Enum.map(Operations.__doc_rows__(), fn r ->
        [r.op, r.type, Enum.join(r.data_keys, ", ")]
      end)

    build_table(["Op", "Type", "Data keys"], rows)
  end

  # --- DoItWeb.Api.Serializer ---------------------------------------------------

  defp serializer_table do
    {:docs_v1, _anno, _lang, _format, _moduledoc, _meta, docs} = Code.fetch_docs(Serializer)

    rows =
      docs
      |> Enum.filter(fn {{kind, _name, _arity}, _anno, _sig, doc, _meta} ->
        kind == :function and doc not in [:none, :hidden]
      end)
      |> Enum.sort_by(fn {_id, anno, _sig, _doc, _meta} -> anno_line(anno) end)
      |> Enum.map(fn {{_kind, name, _arity}, _anno, _sig, doc, _meta} ->
        [Atom.to_string(name), first_sentence(doc_text(doc))]
      end)

    build_table(["Shape", "Purpose"], rows)
  end

  defp doc_text(%{"en" => text}), do: text
  defp anno_line(anno) when is_integer(anno), do: anno
  defp anno_line({line, _column}), do: line

  # --- DoitMcp.Server -----------------------------------------------------------

  defp mcp_table do
    rows =
      fetch_mcp_tools()
      |> Enum.map(fn %{"name" => name, "description" => description} ->
        [name, first_sentence(description)]
      end)
      |> Enum.sort_by(&List.first/1)

    build_table(["Tool", "Purpose"], rows)
  end

  # Reads the adapter's own tool registry in-process (mcp_server/ is a
  # separate Mix project with no dependency either way — mounted alongside
  # this app with its own _build/deps) rather than a live server's
  # `tools/list`, so the gate doesn't depend on the MCP server being up.
  # `--no-start` skips booting the HTTP listener; `__components__/0` is a
  # plain function over data already fixed at compile time.
  defp fetch_mcp_tools do
    mcp_dir = Path.join(File.cwd!(), @mcp_relpath)

    code = """
    tools =
      DoitMcp.Server.__components__(:tool)
      |> Enum.map(fn t -> %{"name" => t.name, "description" => t.description} end)

    IO.write(Jason.encode!(tools))
    """

    with {_out, 0} <- System.cmd("mix", ["compile"], cd: mcp_dir, stderr_to_stdout: true),
         {out, 0} <- System.cmd("mix", ["run", "--no-start", "-e", code], cd: mcp_dir) do
      Jason.decode!(out)
    else
      {out, status} ->
        raise "reading the MCP tool registry (mix run --no-start in #{mcp_dir}) exited #{status}:\n#{out}"
    end
  end

  # --- scripts/doitlist.py -------------------------------------------------------

  defp cli_table do
    script = Path.join(File.cwd!(), @cli_relpath)

    top_help = python_help(script, [])

    rows =
      for {verb, purpose} <- parse_verb_purposes(top_help) do
        {args, options} = script |> python_help([verb]) |> parse_usage(verb)
        [verb, args, options, purpose]
      end

    build_table(["Verb", "Args", "Options", "Purpose"], rows)
  end

  defp python_help(script, verb_args) do
    {output, _status} =
      System.cmd("python3", [script] ++ verb_args ++ ["--help"], stderr_to_stdout: true)

    output
  end

  # The top-level `--help` lists each verb at 4-space indent, one line each,
  # e.g. "    list                list the Initiatives you can reach" — two
  # levels deeper than an option line's 2-space indent, so the two never
  # collide.
  defp parse_verb_purposes(text) do
    ~r/^ {4}(\S+) {2,}(.+)$/m
    |> Regex.scan(text)
    |> Enum.map(fn [_whole, verb, purpose] -> {verb, String.trim(purpose)} end)
  end

  # Parsed straight from argparse's own `usage:` line rather than the
  # "positional arguments:"/"options:" sections below it, so an optional
  # positional (`[position]`) reads as optional without a second heuristic.
  defp parse_usage(text, verb) do
    usage_block =
      case Regex.run(~r/usage:.*?(?=\n\n|\z)/s, text) do
        [block] -> block
        nil -> raise "no usage line in `#{verb} --help` output:\n#{text}"
      end

    normalized = usage_block |> String.replace(~r/\s+/, " ") |> String.trim()
    prefix = "usage: doitlist #{verb} "

    args_str =
      if String.starts_with?(normalized, prefix),
        do: String.trim_leading(normalized, prefix),
        else: normalized

    tokens = ~r/\[[^\]]*\]|\S+/ |> Regex.scan(args_str) |> List.flatten()

    {option_tokens, positional_tokens} = Enum.split_with(tokens, &option_token?/1)

    options =
      option_tokens
      |> Enum.map(&flag_name/1)
      |> Enum.reject(&(&1 == "-h"))
      |> Enum.join(", ")

    {Enum.join(positional_tokens, " "), options}
  end

  defp option_token?(token), do: token |> String.trim_leading("[") |> String.starts_with?("-")

  defp flag_name(token) do
    token
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split()
    |> List.first()
  end

  # --- shared -------------------------------------------------------------------

  # The first sentence of the first paragraph, whitespace collapsed to one
  # line — "one short purpose per row" (worklist 2), not the whole moduledoc.
  defp first_sentence(text) do
    paragraph =
      text
      |> String.trim()
      |> String.split(~r/\n\s*\n/, parts: 2)
      |> List.first()

    sentence =
      case Regex.run(~r/\A(.*?[.!?])(\s|$)/s, paragraph) do
        [_whole, sentence, _rest] -> sentence
        nil -> paragraph
      end

    sentence
    |> String.replace(~r/\s+/, " ")
    |> cell_phrase()
  end

  # A cell is a phrase, not a sentence (m03.05 6.4). The clause after an em
  # dash is the sentence explaining itself, a doc reference like
  # "(m03.04 2.1.3)" is an action list leaking into a spec, and the trailing
  # period is the last thing making a cell read as prose. A parenthetical
  # that names an endpoint stays — that is the row's other half.
  defp cell_phrase(sentence) do
    sentence
    |> String.replace(~r/\s*\(m?\d+\.\d+[^)]*\)/, "")
    |> String.split(" — ", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.trim()
  end

  @doc """
  The file's hand-written word count: everything outside the generated
  fences, code fences and table rows. The prose half is the half a person
  maintains, so it is the half with a budget (m03.05 6.3).
  """
  def prose_word_count(text) when is_binary(text) do
    text
    |> String.replace(~r/<!-- generated:.*?<!-- \/generated:.*?-->/s, "")
    |> String.replace(~r/```.*?```/s, "")
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "|"))
    |> Enum.join(" ")
    |> String.split()
    |> length()
  end

  defp build_table(header, rows) do
    header_line = "| " <> Enum.join(header, " | ") <> " |"
    sep_line = "|" <> Enum.map_join(header, "|", fn _ -> "---" end) <> "|"

    row_lines =
      Enum.map(rows, fn cells -> "| " <> Enum.map_join(cells, " | ", &escape_cell/1) <> " |" end)

    Enum.join([header_line, sep_line | row_lines], "\n")
  end

  defp escape_cell(value) do
    cell =
      value
      |> to_string()
      |> String.replace(~r/\s+/, " ")
      |> String.replace("|", "\\|")
      |> String.trim()

    if cell == "", do: "—", else: cell
  end
end
