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

      {"text": "...",                                   // required, non-blank
       "filename": "plan.md",                           // optional
       "target": {"initiative_name": "Q3 Plan"}         // a NEW Initiative
              | {"initiative_id": 12,                   // or an existing one,
                 "parent_task_id": 34},                 //   optionally under a Task
       "preview": false}                                // default false

  A missing/blank `text`, a non-boolean `preview`, a malformed target, or both
  target forms at once is a `422` single-error. Source text with no items in it
  is a `422` too. An existing target runs through
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

  `preview: true` returns `{"preview": true, ...summary}` and writes **nothing**
  — no Tasks, no comment, no import record.

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

  When every batch has committed, the **source comment** (2.4) lands once on
  the imported root — the new Initiative's root Task, the existing Initiative's
  root Task, or the parent Task — reading `Imported from <filename>` or
  `Imported from pasted text`. A preamble (prose above the first item) rides
  with it: on a new Initiative it becomes the Initiative's description instead.

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
  alias DoIt.Imports.{Diff, Import, Parser}
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
  Run an import request for `user`.

  Returns `{:ok, status, body}` or `{:error, status, body}` — the controller
  renders either verbatim.
  """
  @spec run(DoIt.Accounts.User.t(), map()) ::
          {:ok, 200, map()} | {:error, 403 | 404 | 409 | 422, map()}
  def run(user, params) when is_map(params) do
    with {:ok, text} <- fetch_text(params),
         {:ok, preview?} <- fetch_preview(params),
         {:ok, filename} <- fetch_filename(params),
         {:ok, request} <- fetch_target(params),
         {:ok, target, initiative} <- resolve_target(user, request),
         {:ok, manifest} <- parse(text),
         :ok <- enforce_limits(text, manifest) do
      summary = summary(manifest, target, initiative)

      if preview? do
        {:ok, 200,
         summary
         |> Map.merge(%{"preview" => true, "limits" => limits()})
         |> put_diff(manifest, target, initiative)}
      else
        apply_import(user, text, filename, manifest, target, initiative, summary)
      end
    end
  end

  def run(_user, _params), do: error(422, "Request body must be a JSON object.")

  # --- Request validation -----------------------------------------------------

  defp fetch_text(params) do
    case Map.get(params, "text") do
      text when is_binary(text) ->
        if String.trim(text) == "",
          do: error(422, "\"text\" is blank; send the source document to import."),
          else: {:ok, text}

      nil ->
        error(422, "Missing required \"text\" — the source document to import.")

      other ->
        error(422, "\"text\" must be a string (got #{inspect(other)}).")
    end
  end

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

  # --- Apply ------------------------------------------------------------------

  defp apply_import(user, text, filename, manifest, target, initiative, summary) do
    hash = DoIt.Imports.source_hash(text)

    case DoIt.Imports.fetch(user, target, hash) do
      %Import{response: body} ->
        # Same document, same target: replay what the first apply sent.
        {:ok, 200, Map.put(body, "replayed", true)}

      nil ->
        preamble = Map.get(manifest, :title_description)

        with {:ok, ops, comment_body} <-
               prepare(Parser.operations(manifest, target), target, preamble, filename) do
          write(user, ops, comment_body, hash, target, initiative, summary)
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

  defp write(user, ops, comment_body, hash, target, initiative, summary) do
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
