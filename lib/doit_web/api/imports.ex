defmodule DoItWeb.Api.Imports do
  @moduledoc """
  Text import — the service behind `POST /api/v1/imports` (m03.04 2.3–2.6).

  A document goes in; a Task tree comes out. The shape of the tree is decided
  once, in `DoIt.Imports.Parser` (pure, no Repo), and every write goes through
  `DoItWeb.Api.Operations.apply_batch/2` — the same engine, authorization and
  broadcasts as `POST /api/v1/operations`. This module adds no domain logic: it
  validates the request, resolves and authorizes the target, chunks the parsed
  operations, and reports.

  ## Request

      {"text": "...",                                   // non-blank; or "preview_id"
       "filename": "plan.md",                           // optional
       "target": {"initiative_name": "Q3 Plan"}         // a NEW Initiative
              | {"initiative_id": 12,                   // or an existing one,
                 "parent_task_id": 34,                  //   optionally under a Task
                 "section": "Arc 4"},                   // either form: one heading's content
       "preview": false}                                // default false

  Exactly one of `text` and `preview_id` (see "Apply by preview_id"). A
  missing/blank `text`, a non-boolean `preview`, a malformed target, or both
  target forms at once is a `422` single-error. Source text with no items in it
  is a `422` too. `target.section` names a heading (`DoIt.Imports.Parser.section/2`
  decides the match); only the lines under it are imported, the heading
  itself left out, so the section's first child lands at index 1. A heading
  that is absent or matches more than once is a `422` naming it, and the
  summary's `target` echoes the section. An existing target runs through
  `DoItWeb.Api.Authz.fetch_initiative/3` at `:edit` (`404` unknown / agent
  access off, `403` role denies); a `parent_task_id` that isn't a live Task in
  that Initiative is a `404`.

  ## Summary (both modes)

  Every 200 carries the same read of the document — what the caller is about to
  get, or just got:

      {"title": "Q3 Plan" | null,
       "style": "numerical",
       "counts": {"items": 42, "done": 7, "depth": 3, "title_overflow": 0},
       "outline": "1 Ship the thing\\n  1.1 Draft [x]\\n...",
       "target": {"kind": "initiative", "id": 12, "parent_task_id": null}}

  `outline` is one line per item, indented two spaces per level, labeled with
  `DoIt.Tasks.Index.label/2` under the detected style (unlabeled when the style
  is `"none"`), and suffixed ` [x]` when the item is done. It is the operator's
  read-back: the tree they are approving, in the numbering they will see it in.

  ## Preview vs apply

  `preview: true` returns `{"preview": true, "preview_id": "...", ...summary}`
  and writes **nothing** to the tree — no Tasks, no comment, no import record.
  It does store the preview itself (`DoIt.Imports.put_preview/4`) so the caller
  can apply it by id.

  Against an **existing** target the preview also carries a `"diff"` (2.5): the
  document read against the live tree already there — Tasks the document has
  and the tree doesn't (`missing`), the tree has and the document doesn't
  (`extra`), pairs whose completion disagrees, and levels whose order
  disagrees, with a `"clean"` flag when they agree completely. The comparison
  is scoped to the target: an Initiative target diffs its top-level Tasks, a
  `parent_task_id` target diffs that Task's children. The math is
  `DoIt.Imports.Diff`, pure; the preview is still read-only. A new-Initiative
  preview has nothing to diff against and carries no `"diff"` key.

  An apply builds the operations with `DoIt.Imports.Parser.operations/2`, splits
  them into batches of at most `DoItWeb.Api.Operations.max_batch_size/0`, and
  applies them in order — **one transaction per batch**, not one for the
  document. Parents always precede children in the parser's emission order, so
  after each batch commits its `lid -> id` map is harvested and later batches'
  `parent_lid` / `initiative_lid` references are rewritten to real ids. A batch
  that fails rolls back *itself*; earlier batches stay committed and the
  response says so.

  A committed apply also reports `"items"` (6.12.3) — `{"line": n, "id": 42}`
  for every Task it created, in source order, where `line` is the 1-based line
  of the source document that produced it. A `section` import reports lines in
  the **whole** document, not the slice, so the caller's own file is the one
  the numbers point into and a mirror can be annotated with the ids it just
  created. A preview creates nothing and carries no `"items"`.

  When every batch has committed, the **source comment** (2.4) lands once on
  the imported root — the new Initiative's root Task, the existing Initiative's
  root Task, or the parent Task — reading `Imported from <filename>` or
  `Imported from pasted text`. A preamble (prose above the first item) rides
  with it: on a new Initiative it becomes the Initiative's description instead.

  ## Apply by preview_id (6.7)

  A request carrying `"preview_id"` instead of `"text"` applies the stored
  preview: its source text, filename and target — anything sent alongside is
  ignored. The preview must belong to the same access token and be under an
  hour old; an unknown, expired, other-token or already-applied id is a `404`
  telling the caller to preview again. If the target Initiative's `version`
  moved since the preview, the apply is refused with the standard stale-write
  reply — `409`, code `conflict`, the current record under `error.current` —
  exactly as a conflicting `expected_version` op reports. An apply consumes the
  preview, whichever way it ends; `preview_id` with `preview: true` is a `422`.

  ## Idempotency (2.3.5)

  The source text is its own key: an apply that commits stores its exact 200
  body against `(target, sha256(text))` in `DoIt.Imports`. A repeat apply of the
  same text into the same target replays that body plus `"replayed": true` and
  writes nothing. Different text into the same target is a new import — the
  ledger is per document, not per target.

  ## Limits (2.6)

  A document is measured **before** anything is written, and an over-limit one
  is a `422` that writes nothing — no truncation, no invented Tasks:

    * source text over `@max_source_bytes`;
    * more items than `@max_items` (see that attribute for the arithmetic);
    * any item whose description would exceed `@max_description`.

  An over-long *title* is not a rejection: the parser splits it at 200
  characters and moves the rest to the front of that item's description
  (`counts.title_overflow` says how many were split). The description check
  runs on that final text, so an accepted item always fits in one Task. A
  preview echoes all four numbers under `"limits"`, so a client can size a
  document without spending a failed request.
  """

  alias DoIt.{Initiatives, Tasks}
  alias DoIt.Imports.{Diff, Import, Parser, Preview}
  alias DoIt.Initiatives.Initiative
  alias DoIt.Tasks.{Index, Task}
  alias DoItWeb.Api
  alias DoItWeb.Api.{Authz, Operations, Serializer}

  # Comment bodies and Initiative descriptions are both capped at 4000 by their
  # changesets; the preamble is checked against the cap BEFORE any write so an
  # over-long one never leaves a half-imported tree behind.
  @text_limit 4000

  # Retunable default: the largest source document accepted, in bytes (1 MiB).
  @max_source_bytes 1_048_576

  # Retunable default: the most items one import may carry. Bandit (the
  # endpoint's adapter, `config/config.exs`) sets no processing deadline —
  # Thousand Island's 60 s `read_timeout` bounds waiting for client DATA, not a
  # handler already running — and nothing in `config/*.exs` or the endpoint
  # overrides it, so the real end-to-end ceiling is the adapter client's 90 s
  # `receive_timeout` (`DoitMcp.Client`). At the ~24 ms/op the batch engine
  # applies, 2000 items is ~48 s of work: inside a minute, and well under that
  # 90 s with room for a slow host.
  @max_items 2000

  # Retunable default: mirrors the Task schema's description cap, so an
  # accepted item — title overflow included — always fits in one description.
  @max_description 8000

  @doc """
  The import size limits, string-keyed for the response body.

  Public so a client can read them from a preview instead of a failed request.
  """
  @spec limits() :: %{optional(String.t()) => pos_integer()}
  def limits do
    %{
      "max_source_bytes" => @max_source_bytes,
      "max_items" => @max_items,
      "max_description" => @max_description,
      "max_title" => Parser.max_title()
    }
  end

  @doc """
  Run an import request for `user`, acting under access token `token_id`
  (stored previews are keyed by it).

  Returns `{:ok, status, body}` or `{:error, status, body}` — the controller
  renders either verbatim.
  """
  @spec run(DoIt.Accounts.User.t(), integer(), map()) ::
          {:ok, 200, map()} | {:error, 403 | 404 | 409 | 422, map()}
  def run(user, token_id, params) when is_map(params) do
    with {:ok, preview?} <- fetch_preview(params),
         {:ok, source} <- fetch_source(params) do
      case source do
        {:text, text} ->
          run_text(user, token_id, text, preview?, params)

        {:preview_id, _id} when preview? ->
          error(
            422,
            "\"preview_id\" applies a stored preview; to preview again, send the source in \"text\"."
          )

        {:preview_id, id} ->
          run_preview_id(user, token_id, id)
      end
    end
  end

  def run(_user, _token_id, _params), do: error(422, "Request body must be a JSON object.")

  defp run_text(user, token_id, text, preview?, params) do
    with {:ok, filename} <- fetch_filename(params),
         {:ok, request} <- fetch_target(params),
         {:ok, section} <- fetch_section(params),
         {:ok, target, initiative} <- resolve_target(user, request),
         {:ok, text, offset} <- slice(text, section),
         {:ok, manifest} <- parse(text),
         :ok <- enforce_limits(text, manifest) do
      summary = manifest |> summary(target, initiative) |> put_section(section)
      source = %{text: text, filename: filename, line_offset: offset}

      if preview? do
        preview(token_id, source, manifest, target, initiative, summary)
      else
        apply_import(user, source, manifest, target, initiative, summary)
      end
    end
  end

  # --- Request validation -----------------------------------------------------

  # Exactly one of `text` (the document) and `preview_id` (a stored preview).
  defp fetch_source(params) do
    case {Map.get(params, "text"), Map.get(params, "preview_id")} do
      {nil, nil} ->
        error(
          422,
          "Missing required \"text\" — the source document to import — or \"preview_id\" from a preview."
        )

      {text, nil} ->
        fetch_text(text)

      {nil, id} when is_binary(id) and id != "" ->
        {:ok, {:preview_id, id}}

      {nil, other} ->
        error(
          422,
          "\"preview_id\" must be the non-empty string a preview returned (got #{inspect(other)})."
        )

      {_text, _id} ->
        error(
          422,
          "\"preview_id\" replaces \"text\"; send one or the other, not both."
        )
    end
  end

  defp fetch_text(text) when is_binary(text) do
    if String.trim(text) == "",
      do: error(422, "\"text\" is blank; send the source document to import."),
      else: {:ok, {:text, text}}
  end

  defp fetch_text(other), do: error(422, "\"text\" must be a string (got #{inspect(other)}).")

  defp fetch_preview(params) do
    case Map.get(params, "preview") do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      other -> error(422, "\"preview\" must be true or false (got #{inspect(other)}).")
    end
  end

  # A blank filename is no filename — the comment says "pasted text".
  defp fetch_filename(params) do
    case Map.get(params, "filename") do
      nil -> {:ok, nil}
      name when is_binary(name) -> {:ok, if(String.trim(name) == "", do: nil, else: name)}
      other -> error(422, "\"filename\" must be a string (got #{inspect(other)}).")
    end
  end

  defp fetch_target(params) do
    case Map.get(params, "target") do
      target when is_map(target) -> target_form(target)
      nil -> error(422, target_help("Missing required \"target\"."))
      other -> error(422, target_help("\"target\" must be an object (got #{inspect(other)})."))
    end
  end

  defp target_form(target) do
    name? = Map.has_key?(target, "initiative_name")
    id? = Map.has_key?(target, "initiative_id")

    cond do
      name? and id? ->
        error(
          422,
          target_help(
            "\"target\" carries both \"initiative_name\" and \"initiative_id\"; an import lands in one place."
          )
        )

      name? ->
        new_initiative_target(target)

      id? ->
        {:ok, {:existing, target["initiative_id"], Map.get(target, "parent_task_id")}}

      true ->
        error(422, target_help("\"target\" names neither a new nor an existing Initiative."))
    end
  end

  defp new_initiative_target(%{"initiative_name" => name}) when is_binary(name) do
    if String.trim(name) == "",
      do: error(422, "\"initiative_name\" is blank; name the Initiative to create."),
      else: {:ok, {:new_initiative, name}}
  end

  defp new_initiative_target(%{"initiative_name" => other}),
    do: error(422, "\"initiative_name\" must be a string (got #{inspect(other)}).")

  # `target.section` narrows the import to one heading's content (6.10). Read
  # after `fetch_target/1`, so the target is already known to be a map.
  defp fetch_section(params) do
    case get_in(params, ["target", "section"]) do
      nil ->
        {:ok, nil}

      heading when is_binary(heading) ->
        if String.trim(heading) == "",
          do: error(422, "\"section\" is blank; name the heading whose content to import."),
          else: {:ok, String.trim(heading)}

      other ->
        error(422, "\"section\" must be a heading's text (got #{inspect(other)}).")
    end
  end

  # From here on the section IS the document: it is what gets parsed, measured,
  # stored for a preview, hashed for idempotency, and written. The offset is
  # the one thing that still refers to the whole document — the apply's
  # `items` report lines the caller's own file can be annotated by (6.12.3).
  defp slice(text, nil), do: {:ok, text, 0}

  defp slice(text, heading) do
    case Parser.section(text, heading) do
      {:ok, _slice, _offset} = sliced ->
        sliced

      {:error, :not_found} ->
        error(
          422,
          "No heading #{inspect(heading)} in the source document. \"section\" must match one " <>
            "heading's text exactly (leading #s and a [ ]/[x] box aside); check the heading and retry."
        )

      {:error, {:ambiguous, n}} ->
        error(
          422,
          "The heading #{inspect(heading)} appears #{n} times in the source document; " <>
            "\"section\" must name one. Import the whole document, or a section whose heading is unique."
        )
    end
  end

  defp put_section(summary, nil), do: summary
  defp put_section(summary, heading), do: put_in(summary, ["target", "section"], heading)

  defp target_help(problem) do
    problem <>
      " Send {\"initiative_name\": \"...\"} for a new Initiative, or" <>
      " {\"initiative_id\": 12, \"parent_task_id\": 34} to import into an existing one" <>
      " (\"parent_task_id\" optional)."
  end

  # --- Target resolution ------------------------------------------------------

  defp resolve_target(_user, {:new_initiative, name}), do: {:ok, {:new_initiative, name}, nil}

  defp resolve_target(user, {:existing, initiative_id, parent_task_id}) do
    case Authz.fetch_initiative(user, initiative_id, :edit) do
      {:ok, %Initiative{} = initiative} ->
        resolve_parent(initiative, parent_task_id)

      {:error, :not_found} ->
        error(404, "No such Initiative with id #{inspect(initiative_id)}.", :not_found)

      {:error, :forbidden} ->
        error(
          403,
          "You don't have edit permission for Initiative #{inspect(initiative_id)}.",
          :forbidden
        )
    end
  end

  defp resolve_parent(%Initiative{} = initiative, nil),
    do: {:ok, {:initiative, initiative.id}, initiative}

  defp resolve_parent(%Initiative{} = initiative, parent_task_id) do
    with id when is_integer(id) <- normalize_id(parent_task_id),
         %Task{deleted_at: nil, initiative_id: ini_id} <- Tasks.get_task(id),
         true <- ini_id == initiative.id do
      {:ok, {:task, id}, initiative}
    else
      _ ->
        error(
          404,
          "No such Task with id #{inspect(parent_task_id)} in Initiative #{initiative.id}.",
          :not_found
        )
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp normalize_id(_), do: nil

  defp parse(text) do
    case Parser.parse(text) do
      {:ok, manifest} ->
        {:ok, manifest}

      {:error, :empty} ->
        error(
          422,
          "No tasks found in the source text. Items are Markdown headings, bullets (- * +), or numbered lines."
        )
    end
  end

  # --- Limits (2.6) -----------------------------------------------------------

  # `check_limits/2` speaks plain messages; the endpoint turns one into a 422.
  defp enforce_limits(text, manifest) do
    case check_limits(text, manifest) do
      :ok -> :ok
      {:error, message} -> error(422, message)
    end
  end

  # Every size rule, measured on the source text and on the parser's OWN output
  # — the descriptions checked here are the ones that would be written, title
  # overflow included. Nothing is truncated and no item is split into extra
  # Tasks; a document that doesn't fit is refused whole.
  @spec check_limits(String.t(), map()) :: :ok | {:error, String.t()}
  defp check_limits(text, manifest) do
    with :ok <- check_source_size(text),
         :ok <- check_item_count(manifest) do
      check_descriptions(manifest.items, [])
    end
  end

  defp check_source_size(text) do
    bytes = byte_size(text)

    if bytes <= @max_source_bytes do
      :ok
    else
      {:error,
       "The source document is #{bytes} bytes; the limit is #{@max_source_bytes}. " <>
         "Nothing was imported — split it and import the pieces separately."}
    end
  end

  defp check_item_count(%{counts: %{items: items}}) do
    if items <= @max_items do
      :ok
    else
      {:error,
       "The source document holds #{items} items; the limit is #{@max_items} per import. " <>
         "Nothing was imported — split it and import the pieces separately."}
    end
  end

  defp check_descriptions([], _path), do: :ok

  defp check_descriptions([item | rest], path) do
    here = path ++ [item.title]

    with :ok <- check_description(item, here),
         :ok <- check_descriptions(item.children, here) do
      check_descriptions(rest, path)
    end
  end

  defp check_description(%{description: nil}, _path), do: :ok

  defp check_description(%{description: description}, path) do
    length = String.length(description)

    if length <= @max_description do
      :ok
    else
      {:error,
       "\"#{Enum.join(path, " > ")}\" carries a #{length}-character description; the limit " <>
         "is #{@max_description}. Nothing was imported — shorten that item in the source and " <>
         "retry."}
    end
  end

  # --- Summary ----------------------------------------------------------------

  defp summary(manifest, target, initiative) do
    %{
      "title" => manifest.title,
      "style" => manifest.style,
      "counts" => %{
        "items" => manifest.counts.items,
        "done" => manifest.counts.done,
        "depth" => manifest.counts.depth,
        "title_overflow" => manifest.counts.title_overflow
      },
      "outline" => outline(manifest),
      "target" => target_echo(target, initiative)
    }
  end

  defp target_echo({:new_initiative, name}, _initiative),
    do: %{"kind" => "new_initiative", "name" => name}

  defp target_echo({:initiative, id}, _initiative),
    do: %{"kind" => "initiative", "id" => id, "parent_task_id" => nil}

  defp target_echo({:task, task_id}, %Initiative{id: id}),
    do: %{"kind" => "initiative", "id" => id, "parent_task_id" => task_id}

  # One line per item: two spaces of indent per level, the index label for the
  # detected style, the verbatim title, and ` [x]` when done.
  defp outline(%{items: items, style: style}) do
    items |> outline_lines(style, [], 0) |> Enum.join("\n")
  end

  defp outline_lines(items, style, ancestors, depth) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, position} ->
      positions = ancestors ++ [position]

      line =
        String.duplicate("  ", depth) <>
          labeled(Index.label(positions, style), item.title) <>
          if(item.done, do: " [x]", else: "")

      [line | outline_lines(item.children, style, positions, depth + 1)]
    end)
  end

  defp labeled("", title), do: title
  defp labeled(label, title), do: label <> " " <> title

  # --- Preview diff (2.5) -----------------------------------------------------

  # A new Initiative has no live tree to disagree with, so there is nothing to
  # diff and no key. An existing target reads the tree it would import into —
  # read-only, exactly like the rest of a preview.
  defp put_diff(body, _manifest, {:new_initiative, _name}, _initiative), do: body

  defp put_diff(body, manifest, target, initiative),
    do: Map.put(body, "diff", Diff.compare(manifest.items, live_items(target, initiative)))

  defp live_items({:initiative, id}, _initiative),
    do: id |> Tasks.initiative_task_tree() |> Diff.from_tasks()

  # A parent Task target compares against that Task's children only — the rest
  # of the Initiative is out of scope for this import.
  defp live_items({:task, task_id}, %Initiative{id: id}) do
    case id |> Tasks.initiative_task_tree() |> Diff.from_tasks() |> find_node(task_id) do
      %{children: children} -> children
      nil -> []
    end
  end

  defp find_node(items, task_id) do
    Enum.find_value(items, fn item ->
      if item.id == task_id, do: item, else: find_node(item.children, task_id)
    end)
  end

  # --- Stored previews (6.7) --------------------------------------------------

  # Runs after `enforce_limits/2`, so the stored text is within
  # `@max_source_bytes`. A newer preview for the same (token, target Initiative)
  # replaces the older one inside `put_preview/4`.
  defp preview(token_id, source, manifest, target, initiative, summary) do
    {:ok, %Preview{id: preview_id}} =
      DoIt.Imports.put_preview(token_id, target, initiative, %{
        text: source.text,
        filename: source.filename,
        line_offset: source.line_offset
      })

    {:ok, 200,
     summary
     |> Map.merge(%{"preview" => true, "preview_id" => preview_id, "limits" => limits()})
     |> put_diff(manifest, target, initiative)}
  end

  # The stored target is re-resolved (authorization may have changed) and the
  # document re-parsed; then the row is consumed BEFORE the write, so a second
  # apply of the same id is refused whichever way this one ends.
  defp run_preview_id(user, token_id, id) do
    case DoIt.Imports.fetch_preview(id, token_id) do
      nil ->
        minutes = div(DoIt.Imports.preview_ttl_seconds(), 60)

        error(
          404,
          "No applicable preview #{inspect(id)} for this access token — it is unknown, " <>
            "expired (previews last #{minutes} minutes), or already applied. Send the source " <>
            "in \"text\" with \"preview\": true again, then apply the new \"preview_id\".",
          :not_found
        )

      %Preview{text: text, filename: filename, line_offset: offset} = stored ->
        with {:ok, target, initiative} <- resolve_target(user, preview_target(stored)),
             :ok <- check_preview_version(stored, initiative),
             {:ok, manifest} <- parse(text),
             :ok <- enforce_limits(text, manifest) do
          DoIt.Imports.delete_preview(stored)
          summary = summary(manifest, target, initiative)
          source = %{text: text, filename: filename, line_offset: offset || 0}
          apply_import(user, source, manifest, target, initiative, summary)
        end
    end
  end

  # Rebuild the request target the preview was made with — the shape
  # `fetch_target/1` produces.
  defp preview_target(%Preview{target_kind: "new_initiative", target_name: name}),
    do: {:new_initiative, name}

  defp preview_target(%Preview{target_kind: "initiative", target_id: id}),
    do: {:existing, id, nil}

  defp preview_target(%Preview{target_kind: "task", initiative_id: ini_id, target_id: task_id}),
    do: {:existing, ini_id, task_id}

  # The standard stale-write reply (m03.04 2.7.4): 409 `conflict` with the
  # CURRENT record, so the caller re-reads from the response.
  defp check_preview_version(%Preview{initiative_version: nil}, _initiative), do: :ok

  defp check_preview_version(%Preview{initiative_version: v}, %Initiative{version: v}), do: :ok

  defp check_preview_version(%Preview{}, %Initiative{} = current) do
    body =
      Api.error_body(
        409,
        :conflict,
        "Initiative #{current.id} is at version #{current.version} — it changed since your " <>
          "preview. Nothing was applied. Re-read from this error's `current` record, preview " <>
          "again, then apply the new preview_id."
      )
      |> put_in([:error, :current], Operations.initiative_result(current))

    {:error, 409, body}
  end

  # --- Apply ------------------------------------------------------------------

  defp apply_import(user, source, manifest, target, initiative, summary) do
    hash = DoIt.Imports.source_hash(source.text)

    case DoIt.Imports.fetch(user, target, hash) do
      %Import{response: body} ->
        # Same document, same target: replay what the first apply sent.
        {:ok, 200, Map.put(body, "replayed", true)}

      nil ->
        preamble = Map.get(manifest, :title_description)
        {ops, lines} = Parser.operations_and_lines(manifest, target)

        with {:ok, ops, comment_body} <- prepare(ops, target, preamble, source.filename) do
          write(user, {ops, lines, comment_body}, hash, source, target, initiative, summary)
        end
    end
  end

  # Decide where the preamble goes and build the source comment, checking both
  # against the 4000-char cap BEFORE anything is written.
  defp prepare(ops, {:new_initiative, _name}, preamble, filename) do
    with :ok <- within_limit(preamble, "the new Initiative's description") do
      {:ok, put_description(ops, preamble), source_comment(filename, nil)}
    end
  end

  defp prepare(ops, _target, preamble, filename) do
    body = source_comment(filename, preamble)

    with :ok <- within_limit(body, "the source comment") do
      {:ok, ops, body}
    end
  end

  defp within_limit(nil, _where), do: :ok

  defp within_limit(text, where) do
    length = String.length(text)

    if length <= @text_limit do
      :ok
    else
      error(
        422,
        "The source document's preamble makes #{where} #{length} characters; the limit is " <>
          "#{@text_limit}. Nothing was imported — trim the prose above the first item and retry."
      )
    end
  end

  defp put_description(ops, nil), do: ops

  defp put_description([%{"type" => "initiative", "data" => data} = head | rest], preamble),
    do: [%{head | "data" => Map.put(data, "description", preamble)} | rest]

  defp source_comment(filename, preamble) do
    source = if filename, do: "Imported from #{filename}", else: "Imported from pasted text"
    if preamble, do: source <> "\n\n" <> preamble, else: source
  end

  defp write(user, {ops, lines, comment_body}, hash, source, target, initiative, summary) do
    chunks = Enum.chunk_every(ops, Operations.max_batch_size())
    context = %{target: target, initiative: initiative, total: length(chunks)}

    case run_chunks(chunks, user, %{}, 0, context) do
      {:ok, resolved, batches} ->
        initiative_id = imported_initiative_id(target, initiative, resolved)
        record_source(initiative_id, target, user, comment_body)

        body =
          summary
          |> Map.merge(%{
            "preview" => false,
            "batches" => batches,
            "items" => items(lines, resolved, source.line_offset),
            "initiative" => %{
              "id" => initiative_id,
              "url" => Serializer.initiative_url(initiative_id)
            }
          })

        # Only a fully committed import is recorded; a failed one must re-run.
        DoIt.Imports.record(user, target, hash, initiative_id, body)
        {:ok, 200, body}

      {:error, status, body} ->
        {:error, status, body}
    end
  end

  # Which source line became which Task (6.12.3), in source order: the lines
  # the parser recorded against each op's lid, joined to the ids those ops
  # committed as. `offset` puts a section import's lines back in the caller's
  # whole document, so the file they hold is the one the numbers refer to.
  defp items(lines, resolved, offset) do
    Enum.flat_map(lines, fn {lid, line} ->
      case Map.fetch(resolved, lid) do
        {:ok, id} -> [%{"line" => line + offset, "id" => id}]
        :error -> []
      end
    end)
  end

  # Apply the batches in order. Each commits on its own; the lids it created are
  # harvested and rewritten into the batches that follow (parents always precede
  # children, so a later reference is always to an already-committed row).
  defp run_chunks([], _user, resolved, applied, _context), do: {:ok, resolved, applied}

  defp run_chunks([chunk | rest], user, resolved, applied, context) do
    local = MapSet.new(chunk, & &1["lid"])
    rewritten = Enum.map(chunk, &rewrite(&1, resolved, local))

    case Operations.apply_batch(user, rewritten) do
      {:ok, results} ->
        run_chunks(rest, user, harvest(results, resolved), applied + 1, context)

      outcome ->
        batch_failure(outcome, applied, resolved, context)
    end
  end

  defp rewrite(%{"data" => data} = op, resolved, local) when is_map(data) do
    data =
      data
      |> swap_ref("parent_lid", "parent_id", resolved, local)
      |> swap_ref("initiative_lid", "initiative_id", resolved, local)

    %{op | "data" => data}
  end

  defp rewrite(op, _resolved, _local), do: op

  # A lid created in THIS batch stays a lid (the engine resolves it in-batch);
  # one created in an earlier batch becomes the real id it committed as.
  defp swap_ref(data, lid_key, id_key, resolved, local) do
    with lid when is_binary(lid) <- Map.get(data, lid_key),
         false <- MapSet.member?(local, lid),
         {:ok, id} <- Map.fetch(resolved, lid) do
      data |> Map.delete(lid_key) |> Map.put(id_key, id)
    else
      _ -> data
    end
  end

  defp harvest(results, resolved) do
    Enum.reduce(results, resolved, fn
      %{lid: lid, status: "ok", data: %{id: id}}, acc when is_binary(lid) -> Map.put(acc, lid, id)
      _result, acc -> acc
    end)
  end

  defp batch_failure({:error, status, results, top_error}, applied, resolved, context) do
    body =
      %{
        "error" => %{
          "status" => status,
          "code" => top_error.code,
          "message" => top_error.message <> partial_note(applied, context.total)
        },
        "applied_batches" => applied,
        "failed_batch" => applied + 1,
        "total_batches" => context.total,
        "results" => results
      }
      |> maybe_put_initiative(context, resolved)

    {:error, status, body}
  end

  # Neither is reachable through this path (batches are cut at the cap and are
  # never empty), but a silent 500 would be worse than an honest 422.
  defp batch_failure({:error, :batch_too_large, message}, applied, resolved, context),
    do: batch_failure(synthetic(message), applied, resolved, context)

  defp batch_failure({:error, :invalid_request}, applied, resolved, context),
    do:
      batch_failure(
        synthetic("The import produced no applicable operations."),
        applied,
        resolved,
        context
      )

  defp synthetic(message),
    do: {:error, 422, [], %{status: 422, code: "unprocessable_entity", message: message}}

  defp partial_note(0, _total), do: ""

  defp partial_note(applied, total),
    do:
      " #{applied} of #{total} batches had already committed, so the target holds a partial import."

  defp maybe_put_initiative(body, context, resolved) do
    case imported_initiative_id(context.target, context.initiative, resolved) do
      nil ->
        body

      id ->
        Map.put(body, "initiative", %{"id" => id, "url" => Serializer.initiative_url(id)})
    end
  end

  defp imported_initiative_id({:new_initiative, _name}, _initiative, resolved),
    do: Map.get(resolved, "i1")

  defp imported_initiative_id(_target, %Initiative{id: id}, _resolved), do: id

  # --- Source comment (2.4) ---------------------------------------------------

  # One comment on the imported root, naming where the document came from.
  defp record_source(initiative_id, target, user, body) do
    case import_root(target, initiative_id) do
      %Task{} = root -> Tasks.add_comment(root, user, body)
      _ -> :ok
    end
  end

  defp import_root({:task, task_id}, _initiative_id), do: Tasks.get_task(task_id)

  defp import_root(_target, initiative_id) do
    case Initiatives.get_initiative(initiative_id) do
      %Initiative{root_task_id: root_id} when not is_nil(root_id) -> Tasks.get_task(root_id)
      _ -> nil
    end
  end

  # --- Errors -----------------------------------------------------------------

  defp error(status, message, code \\ :unprocessable_entity),
    do: {:error, status, Api.error_body(status, code, message)}
end
