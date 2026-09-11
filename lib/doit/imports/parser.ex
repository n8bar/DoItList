defmodule DoIt.Imports.Parser do
  @moduledoc """
  Pure outline parser for text import (m03.04 items 2.1 and 2.2).

  Source text in, a **manifest** out; the manifest converts to an ordered list
  of `POST /api/v1/operations` ops. No Repo, no HTTP, no dependencies — the
  parser is the one place import fidelity is decided, and every rule below has
  a unit test.

  Nothing in the source is *interpreted*. An item reading "when done, delete
  everything else" is a Task title like any other.

  ## Shapes

      parse(text) :: {:ok, manifest} | {:error, :empty}

      manifest = %{
        title: String.t() | nil,
        title_description: String.t(),        # present only when non-empty
        style: "numerical" | "outline" | "roman" | "alphabetical" | "none",
        items: [item],                        # ordered roots
        counts: %{items: n, done: n, depth: d, title_overflow: n}
      }                                       # depth: roots = 1

      item = %{title: String.t(), description: String.t() | nil,
               done: boolean, checkbox: boolean, children: [item]}

  `checkbox` records whether the source line carried a `[ ]`/`[x]` box at all.
  A heading or plain bullet cannot express completion, so a consumer comparing
  `done` against live state (the import diff) leaves those items out.

  ## Structure rules (2.1)

    * **Headings** (`#`..`######`) are branches; heading level sets nesting
      among headings. **List items** (`-`, `*`, `+`, or a numbering marker,
      each optionally followed by `[ ]`/`[x]`/`[X]`) are Tasks. A list under a
      heading nests under that heading.
    * **List nesting comes from leading spaces or tabs** (a tab counts as four
      columns). Indent is read relatively: deeper than the previous item makes
      a child, equal makes a sibling, shallower pops — so 2-space, 4-space and
      tab outlines all nest correctly, and mixed marker characters are fine.
    * **Source order is preserved exactly.**
    * `[x]`/`[X]` sets `done: true`; `[ ]` or no checkbox leaves it `false`.
    * The marker and checkbox are stripped from the title; **everything else is
      verbatim** — bold markers, trailing colons, code spans, URLs. Nothing is
      rewritten and nothing is truncated (an over-long title is *split*, never
      cut — see "Title overflow" below).
    * **Top heading.** If the first non-blank line is a heading, its level is
      the shallowest in the document, and it is the only heading at that level,
      it becomes the manifest `title` and its content becomes the roots — never
      a wrapper Task. Otherwise `title` is `nil` and every heading is a branch.
    * Empty text, or text with no items at all, is `{:error, :empty}`.

  ## Prose (2.1.5)

  Prose is any non-blank line that is neither a heading nor a list item —
  paragraph text, table rows, blockquotes, and everything inside a fenced code
  block (fences are prose too; a fence's inner lines keep their indentation,
  other prose is trimmed). Prose attaches as the description of the nearest
  preceding item, paragraphs separated by one blank line.

  It attaches **only when it adds to the title**: a line that (marker,
  checkbox and heading hashes aside) just repeats its item's title is dropped.
  An item left with nothing has `description: nil`.

  Prose that precedes the first item — the preamble under a top heading, or a
  document's opening paragraph — is the manifest's `title_description`. It
  lands on the import target, never on a Task.

  ## Title overflow (2.6.1)

  A Task title is capped at 200 characters by the schema, so a longer source
  line is split rather than refused: the title keeps everything up to the last
  whitespace at or before 200 (a hard cut at 200 when the first 200 characters
  hold no whitespace) and the remainder moves to the front of that item's
  description, ahead of any prose already there. Nothing is dropped and no
  extra Task is invented. `counts.title_overflow` is how many items were split.

  The manifest `title` is never split — it is a document heading, not a Task,
  and the endpoint names the Initiative from the caller's request anyway.

  ## Numbering markers and style detection (2.2)

  Recognized markers: `1.` `1)`, `M1`/`M01` (a capital letter plus digits,
  counted only when the same letter recurs with a different digit run
  elsewhere in the document — `M1`/`M2`, never a lone `Q3`), roman `I.`/`II)`,
  alphabetic `A.`/`B)`, and dotted paths like `1.2`, `I.A.2`, `1.a.i`. A
  dotted path with no trailing terminator needs at least one numeric segment,
  so prose openers like "e.g." and "i.e." stay prose.

  The document's index style is detected once, from the markers at the
  shallowest depth that carries any (nested levels may differ):

    * no markers anywhere → `"none"`;
    * any dotted path mixing numeric and non-numeric segments (`I.A.2`,
      `1.a.i`) → `"outline"`;
    * all-numeric markers (`1.`, `2)`, `M1`, `1.2`) → `"numerical"`;
    * roman numerals — any multi-character one (`II`, `IV`), or single letters
      decoding as a run (`I`, `II`, `III`) → `"roman"`;
    * single letters progressing (`A`, `B`, `C`), or a lone letter that is not
      a roman character → `"alphabetical"`;
    * anything else with numbering present — mixed, unrecognized, or ambiguous
      (a lone `I.`) → `"numerical"`, the ambiguity default.

  ## Operations (`operations/2`)

  `target` is `{:new_initiative, name}`, `{:initiative, id}`, or `{:task, id}`.
  Ops come out depth-first in source order with `lid`s numbered `t1`, `t2`, …
  in emission order — a parent is always emitted before its children, so the
  caller can chunk the list and rewrite `parent_lid` → `parent_id` across
  chunks. No `position` is set; appends land in order.

  For `{:new_initiative, name}` the first op creates the Initiative as `"i1"`
  with the detected `index_style` (the name is the caller's, not the manifest
  title) and the roots carry `"initiative_lid" => "i1"`. For
  `{:initiative, id}` the roots carry `"initiative_id" => id` (top-level under
  its root task); for `{:task, id}` they carry `"parent_id" => id`.
  `title_description` is deliberately not an op — the endpoint decides where a
  preamble goes.
  """

  # A tab indents one level; four columns keeps it comparable to space indents.
  @tab_width 4

  # The schema's own Task title cap (2.6.1). Overflow past it is preserved in
  # the description, never truncated.
  @max_title 200

  # One segment of a numbering marker: digits, a roman run, or a single letter.
  @seg "(?:[0-9]+|[IVXLCDM]+|[ivxlcdm]+|[A-Za-z])"

  @heading ~r/^[ ]{0,3}(\#{1,6})[ \t]+(.*)$/
  @fence ~r/^[ \t]*(?:`{3,}|~{3,})/
  @checkbox ~r/^\[([ xX])\](?:[ \t]+(.*))?$/
  @letter_number ~r/^[A-Z][0-9]+[.)]?$/
  @dotted ~r/^#{@seg}(?:\.#{@seg})*[.)]$/
  @dotted_bare ~r/^#{@seg}(?:\.#{@seg})+$/
  @roman ~r/^(?:[IVXLCDM]+|[ivxlcdm]+)$/
  @numeric ~r/^[0-9]+$/
  @letter ~r/^[A-Za-z]$/

  @bullets ~w(- * +)

  @roman_values %{
    ?I => 1,
    ?V => 5,
    ?X => 10,
    ?L => 50,
    ?C => 100,
    ?D => 500,
    ?M => 1000
  }

  @doc """
  Parse source text into a manifest.

  Returns `{:error, :empty}` for blank input or input with no items.
  """
  def parse(text) when is_binary(text) do
    {nodes, lead, seq_letters} = scan(text)

    case nodes do
      [] ->
        {:error, :empty}

      _ ->
        {title, title_desc, roots, style_nodes} = split_title(nodes, lead, seq_letters)

        case roots do
          [] -> {:error, :empty}
          _ -> {:ok, manifest(title, title_desc, build_tree(roots, seq_letters), style_nodes)}
        end
    end
  end

  def parse(_), do: {:error, :empty}

  @doc """
  Number of ops a manifest (or an already-built op list) turns into.

  A manifest counts its Tasks; an op list is just its length (which includes
  the Initiative op, when there is one).
  """
  def count_ops(ops) when is_list(ops), do: length(ops)
  def count_ops(%{counts: %{items: n}}), do: n

  @doc """
  The character cap a parsed Task title is held to — the schema's own limit.

  Everything past it lands at the front of the item's description; see "Title
  overflow" above.
  """
  @spec max_title() :: pos_integer()
  def max_title, do: @max_title

  @doc """
  Turn a manifest into the ordered `POST /api/v1/operations` op list for
  `target`.
  """
  def operations(manifest, target)

  def operations(%{items: items, style: style}, {:new_initiative, name}) do
    initiative = %{
      "op" => "add",
      "type" => "initiative",
      "lid" => "i1",
      "data" => %{"name" => name, "index_style" => style}
    }

    {ops, _n} = task_ops(items, %{"initiative_lid" => "i1"}, 1)
    [initiative | ops]
  end

  def operations(%{items: items}, {:initiative, id}) do
    {ops, _n} = task_ops(items, %{"initiative_id" => id}, 1)
    ops
  end

  def operations(%{items: items}, {:task, id}) do
    {ops, _n} = task_ops(items, %{"parent_id" => id}, 1)
    ops
  end

  defp task_ops(items, link, n) do
    {chunks, next} =
      Enum.map_reduce(items, n, fn item, n ->
        lid = "t#{n}"

        data =
          %{"title" => item.title}
          |> Map.merge(link)
          |> maybe_put("description", item.description)
          |> maybe_put("done", item.done && true)

        op = %{"op" => "add", "type" => "task", "lid" => lid, "data" => data}
        {children, next} = task_ops(item.children, %{"parent_lid" => lid}, n + 1)
        {[op | children], next}
      end)

    {Enum.concat(chunks), next}
  end

  defp maybe_put(map, _key, value) when value in [nil, false], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- Scanning ---------------------------------------------------------------

  # Walk the lines once, emitting a flat list of nodes carrying their tree
  # depth, and collecting any prose that precedes the first node.
  defp scan(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing(&1, "\r"))

    seq_letters = sequence_letters(lines)
    state = %{fence: false, headings: [], list: [], nodes: [], lead: [], seq_letters: seq_letters}
    state = Enum.reduce(lines, state, &scan_line/2)

    nodes =
      state.nodes
      |> Enum.reverse()
      |> Enum.map(fn node -> %{node | desc: Enum.reverse(node.desc)} end)

    {nodes, Enum.reverse(state.lead), seq_letters}
  end

  defp scan_line(line, state) do
    trimmed = String.trim(line)

    cond do
      Regex.match?(@fence, line) ->
        state |> Map.put(:fence, not state.fence) |> add_prose(String.trim_trailing(line))

      state.fence ->
        add_prose(state, String.trim_trailing(line))

      trimmed == "" ->
        add_prose(state, :blank)

      match = Regex.run(@heading, line) ->
        [_, hashes, rest] = match
        add_heading(state, String.length(hashes), rest)

      true ->
        scan_item(state, line, trimmed)
    end
  end

  defp scan_item(state, line, trimmed) do
    [ws] = Regex.run(~r/^[ \t]*/, line)
    {token, rest} = split_token(trimmed)

    case marker_of(token, state.seq_letters) do
      # A letter+digits token outside a sequence is a word, not a marker: the
      # line is prose like any other unmarked line.
      none_or_word when none_or_word in [:none, :word] ->
        add_prose(state, trimmed)

      {kind, marker} ->
        {checkbox, done, title} = checkbox(rest)

        case String.trim(title) do
          "" -> add_prose(state, trimmed)
          title -> add_item(state, indent_width(ws), kind, marker, checkbox, done, title)
        end
    end
  end

  defp split_token(trimmed) do
    case String.split(trimmed, ~r/[ \t]+/, parts: 2) do
      [token, rest] -> {token, rest}
      [token] -> {token, ""}
    end
  end

  # `{checkbox?, done, title}` — whether a box was present, whether it was
  # ticked, and the line with the box stripped.
  defp checkbox(rest) do
    case Regex.run(@checkbox, String.trim_leading(rest)) do
      [_, mark] -> {true, mark != " ", ""}
      [_, mark, title] -> {true, mark != " ", title}
      nil -> {false, false, rest}
    end
  end

  defp indent_width(ws) do
    ws
    |> String.graphemes()
    |> Enum.reduce(0, fn
      "\t", acc -> acc + @tab_width
      _, acc -> acc + 1
    end)
  end

  # A heading pops every heading at or below its own level; what is left is its
  # ancestry, and its depth. A heading always starts a fresh list context.
  defp add_heading(state, level, text) do
    headings = Enum.drop_while(state.headings, fn {lvl, _} -> lvl >= level end)
    depth = length(headings)
    {_kind, marker, title} = strip_marker(text, state.seq_letters)

    state
    |> Map.put(:headings, [{level, depth} | headings])
    |> Map.put(:list, [])
    |> push(%{
      depth: depth,
      title: title,
      marker: marker,
      checkbox: false,
      done: false,
      level: level,
      desc: []
    })
  end

  # A list item nests below the open heading, then by relative indent.
  defp add_item(state, indent, kind, marker, checkbox, done, title) do
    base =
      case state.headings do
        [{_lvl, depth} | _] -> depth + 1
        [] -> 0
      end

    list = Enum.drop_while(state.list, fn {ind, _} -> ind >= indent end)
    depth = base + length(list)
    marker = if kind == :bullet, do: nil, else: marker

    state
    |> Map.put(:list, [{indent, depth} | list])
    |> push(%{
      depth: depth,
      title: title,
      marker: marker,
      checkbox: checkbox,
      done: done,
      level: nil,
      desc: []
    })
  end

  defp push(state, node), do: Map.put(state, :nodes, [node | state.nodes])

  defp add_prose(%{nodes: []} = state, line), do: Map.put(state, :lead, [line | state.lead])

  defp add_prose(%{nodes: [node | rest]} = state, line),
    do: Map.put(state, :nodes, [%{node | desc: [line | node.desc]} | rest])

  # --- Title, tree, manifest --------------------------------------------------

  # The opening heading is the document's title when it is the only heading at
  # the shallowest heading level.
  defp split_title([first | rest] = nodes, lead, seq_letters) do
    levels = for n <- nodes, n.level, do: n.level

    title? =
      first.level != nil and levels != [] and first.level == Enum.min(levels) and
        Enum.count(levels, &(&1 == first.level)) == 1

    if title? do
      {first.title, finalize_desc(first.desc, first.title, seq_letters), rest, rest}
    else
      {nil, finalize_desc(lead, nil, seq_letters), nodes, nodes}
    end
  end

  # `nodes` is the flat, pre-tree node list the items were built from — the
  # source of both the detected style and the count of titles that overflowed.
  defp manifest(title, title_desc, items, nodes) do
    %{
      title: title,
      style: detect_style(nodes),
      items: items,
      counts: %{
        items: count_items(items),
        done: count_done(items),
        depth: tree_depth(items),
        title_overflow: Enum.count(nodes, &overflow?(&1.title))
      }
    }
    |> maybe_put(:title_description, title_desc)
  end

  defp build_tree(nodes, seq_letters) do
    {items, _rest} = do_build(nodes, 0, seq_letters)
    items
  end

  defp do_build([], _min, _seq_letters), do: {[], []}

  defp do_build([%{depth: depth} = node | rest], min, seq_letters) when depth >= min do
    {children, rest} = do_build(rest, depth + 1, seq_letters)

    {title, description} =
      split_overflow(node.title, finalize_desc(node.desc, node.title, seq_letters))

    item = %{
      title: title,
      description: description,
      done: node.done,
      checkbox: node.checkbox,
      children: children
    }

    {siblings, rest} = do_build(rest, depth, seq_letters)
    {[item | siblings], rest}
  end

  defp do_build(nodes, _min, _seq_letters), do: {[], nodes}

  defp count_items(items),
    do: Enum.reduce(items, 0, fn i, acc -> acc + 1 + count_items(i.children) end)

  defp count_done(items) do
    Enum.reduce(items, 0, fn i, acc ->
      acc + if(i.done, do: 1, else: 0) + count_done(i.children)
    end)
  end

  defp tree_depth([]), do: 0
  defp tree_depth(items), do: 1 + Enum.max(Enum.map(items, &tree_depth(&1.children)))

  # --- Title overflow (2.6.1) -------------------------------------------------

  defp overflow?(title), do: String.length(title) > @max_title

  # Split, never truncate: the title keeps up to the last whitespace at or
  # before the cap, and the rest of the line leads the description.
  defp split_overflow(title, description) do
    if overflow?(title) do
      {kept, remainder} = cut_title(title)
      {kept, lead_description(remainder, description)}
    else
      {title, description}
    end
  end

  defp cut_title(title) do
    head = String.slice(title, 0, @max_title)
    tail = String.slice(title, @max_title..-1//1)

    case Regex.run(~r/\s\S*$/u, head, return: :index) do
      # A whitespace inside the first @max_title characters: cut there, and the
      # remainder is everything from it onward.
      [{at, _len}] when at > 0 ->
        {String.trim(binary_part(head, 0, at)),
         String.trim(binary_part(head, at, byte_size(head) - at) <> tail)}

      # One unbroken run of @max_title characters: cut hard at the cap.
      _ ->
        {String.trim(head), String.trim(tail)}
    end
  end

  defp lead_description(remainder, nil), do: remainder
  defp lead_description(remainder, description), do: remainder <> "\n\n" <> description

  # --- Descriptions -----------------------------------------------------------

  defp finalize_desc(buffer, title, seq_letters) do
    buffer
    |> Enum.reject(&echo?(&1, title, seq_letters))
    |> Enum.drop_while(&(&1 == :blank))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == :blank))
    |> Enum.reverse()
    |> Enum.chunk_by(&(&1 == :blank))
    |> Enum.map_join("\n", fn
      [:blank | _] -> ""
      lines -> Enum.join(lines, "\n")
    end)
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp echo?(:blank, _title, _seq_letters), do: false
  defp echo?(_line, nil, _seq_letters), do: false

  defp echo?(line, title, seq_letters) do
    {_kind, _marker, stripped} =
      line
      |> String.replace(@heading, "\\2")
      |> strip_marker(seq_letters)

    {_checkbox, _done, stripped} = checkbox(stripped)
    String.downcase(String.trim(stripped)) == String.downcase(String.trim(title))
  end

  # --- Sequence pre-scan -------------------------------------------------------

  # A letter+digits token (`M1`, `Q3`) only reads as numbering when the
  # document uses the same letter at least twice with different digit runs
  # (`M1`/`M2`, `M01.`/`M02.`) — otherwise it is an ordinary capitalized word
  # (`Q3 Plan`). Scanned once, from the same heading and list-item lines
  # `marker_of/2` reads tokens from, so it can tell the two apart.
  defp sequence_letters(lines) do
    {digits_by_letter, _fence} =
      Enum.reduce(lines, {%{}, false}, fn line, {digits_by_letter, fence} ->
        cond do
          Regex.match?(@fence, line) -> {digits_by_letter, not fence}
          fence -> {digits_by_letter, fence}
          true -> {note_letter_digits(digits_by_letter, line), fence}
        end
      end)

    digits_by_letter
    |> Enum.filter(fn {_letter, digit_runs} -> MapSet.size(digit_runs) > 1 end)
    |> Enum.into(MapSet.new(), fn {letter, _digit_runs} -> letter end)
  end

  defp note_letter_digits(digits_by_letter, line) do
    content =
      case Regex.run(@heading, line) do
        [_, _hashes, rest] -> String.trim(rest)
        nil -> String.trim(line)
      end

    {token, _rest} = split_token(content)

    if Regex.match?(@letter_number, token) do
      stripped = String.replace(token, ~r/[.)]$/, "")
      <<letter::binary-size(1), digits::binary>> = stripped
      Map.update(digits_by_letter, letter, MapSet.new([digits]), &MapSet.put(&1, digits))
    else
      digits_by_letter
    end
  end

  # --- Markers ----------------------------------------------------------------

  defp strip_marker(text, seq_letters) do
    {token, rest} = split_token(String.trim(text))

    case marker_of(token, seq_letters) do
      none_or_word when none_or_word in [:none, :word] ->
        {:none, nil, String.trim(text)}

      {kind, marker} ->
        {_checkbox, _done, title} = checkbox(rest)
        marker = if kind == :bullet, do: nil, else: marker

        case String.trim(title) do
          "" -> {:none, nil, String.trim(text)}
          title -> {kind, marker, title}
        end
    end
  end

  defp marker_of(token, seq_letters) do
    stripped = String.replace(token, ~r/[.)]$/, "")

    cond do
      token in @bullets -> {:bullet, nil}
      Regex.match?(@letter_number, token) -> letter_number_kind(stripped, seq_letters)
      Regex.match?(@dotted, token) and plausible?(stripped) -> {:number, stripped}
      Regex.match?(@dotted_bare, token) and plausible?(token) -> {:number, token}
      true -> :none
    end
  end

  # A capital-letter-plus-digits token is numbering only when its letter is
  # part of a sequence (see `sequence_letters/1`); otherwise it is just a word
  # that happens to look like one, and must not be stripped from the title.
  defp letter_number_kind(stripped, seq_letters) do
    <<letter::binary-size(1), _digits::binary>> = stripped
    if MapSet.member?(seq_letters, letter), do: {:number, stripped}, else: :word
  end

  # A dotted path needs a numeric segment somewhere, so sentence openers like
  # "e.g." and "i.e." are never mistaken for numbering.
  defp plausible?(marker) do
    segments = String.split(marker, ".")
    length(segments) == 1 or Enum.any?(segments, &Regex.match?(@numeric, &1))
  end

  # --- Style detection (2.2) --------------------------------------------------

  defp detect_style(nodes) do
    marked = Enum.filter(nodes, & &1.marker)

    cond do
      marked == [] ->
        "none"

      Enum.any?(marked, &outline_marker?(&1.marker)) ->
        "outline"

      true ->
        min_depth = marked |> Enum.map(& &1.depth) |> Enum.min()

        marked
        |> Enum.filter(&(&1.depth == min_depth))
        |> Enum.map(& &1.marker)
        |> classify_markers()
    end
  end

  # A dotted path that mixes numeric and non-numeric segments is outline
  # numbering; an all-numeric path (`1.2`) is not.
  defp outline_marker?(marker) do
    segments = String.split(marker, ".")

    length(segments) >= 2 and Enum.any?(segments, &Regex.match?(@numeric, &1)) and
      Enum.any?(segments, &(not Regex.match?(@numeric, &1)))
  end

  defp classify_markers(markers) do
    cond do
      Enum.all?(markers, &numeric_marker?/1) -> "numerical"
      Enum.all?(markers, &Regex.match?(~r/^[A-Za-z]+$/, &1)) -> letter_style(markers)
      true -> "numerical"
    end
  end

  defp numeric_marker?(marker) do
    Regex.match?(@letter_number, marker) or
      Enum.all?(String.split(marker, "."), &Regex.match?(@numeric, &1))
  end

  defp letter_style(markers) do
    cond do
      Enum.any?(markers, &(String.length(&1) > 1 and Regex.match?(@roman, &1))) -> "roman"
      roman_run?(markers) -> "roman"
      alpha_run?(markers) -> "alphabetical"
      lone_non_roman_letter?(markers) -> "alphabetical"
      true -> "numerical"
    end
  end

  # `I`, `II`, `III` — consecutive roman values disambiguate from letters.
  defp roman_run?(markers) do
    length(markers) >= 2 and Enum.all?(markers, &Regex.match?(@roman, &1)) and
      markers |> Enum.map(&from_roman/1) |> consecutive?()
  end

  # `A`, `B`, `C` — single letters, same case, stepping by one.
  defp alpha_run?(markers) do
    length(markers) >= 2 and Enum.all?(markers, &Regex.match?(@letter, &1)) and
      same_case?(markers) and
      markers |> Enum.map(&(&1 |> String.to_charlist() |> hd())) |> consecutive?()
  end

  # A single `A.` is unambiguous; a single `I.` is not (it reads as roman one).
  defp lone_non_roman_letter?([marker]),
    do: Regex.match?(@letter, marker) and not Regex.match?(@roman, marker)

  defp lone_non_roman_letter?(_), do: false

  defp same_case?(markers) do
    Enum.all?(markers, &(&1 == String.upcase(&1))) or
      Enum.all?(markers, &(&1 == String.downcase(&1)))
  end

  defp consecutive?(values) do
    values
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b - a == 1 end)
  end

  defp from_roman(marker) do
    marker
    |> String.upcase()
    |> String.to_charlist()
    |> Enum.map(&Map.fetch!(@roman_values, &1))
    |> Enum.reverse()
    |> Enum.reduce({0, 0}, fn value, {total, highest} ->
      if value < highest, do: {total - value, highest}, else: {total + value, value}
    end)
    |> elem(0)
  end
end
