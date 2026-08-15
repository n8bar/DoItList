defmodule DoitMcp.LogRedaction do
  @moduledoc """
  Credentials never reach the container log (m03.04 2.2.1.7).

  The dep's transport-error path logs whole requests: a failed session call
  inspects the `GenServer.call` exit reason, which carries the request
  context — bearer header included — so one failed call writes a live API
  token in plaintext. On a resident multi-user service that is a credential
  disclosure to anyone who can read the container's log.

  So the guarantee sits at the logger, not at the call site: a Logger
  PRIMARY filter, installed at boot, sees every event from every dependency
  and from our own code before any handler formats it.
  Chasing individual dep log statements would leave the next dep version or
  the next error path free to reintroduce the leak silently.

  Redaction is structural where the term still has shape — a credential
  field of a map, keyword list, struct or tagged tuple — and pattern-based
  in text a dep has already formatted, which is how the known instance
  (`session_call_failed`) arrives. Shapes and replacements are
  `DoitMcp.Redaction`'s, shared with the frame log.

  A filter that raises is removed by the logger, taking the guarantee with
  it, and a filter that runs long stalls every logging process — so the walk
  passes unexpected term shapes through rather than matching on them, and is
  bounded in depth and node count. Past those bounds a subtree is replaced
  by the redaction marker rather than passed through: a bound that leaks is
  not a bound. Nothing else about an event changes — level, message and
  metadata arrive at the handlers exactly as logged.
  """

  alias DoitMcp.Redaction

  @filter_id :doit_mcp_credential_redaction

  # Generous enough that real log terms are walked whole, small enough that
  # a term built by structural sharing (cheap to build, astronomical to
  # walk) cannot stall logging.
  @max_depth 32
  @max_nodes 20_000

  # A list is treated as text when its first this-many elements are
  # printable — the neighbourhood of Logger's own 8096-byte truncation.
  @max_text 8_192

  @doc "The primary filter's id, as `:logger` knows it."
  @spec filter_id() :: atom()
  def filter_id, do: @filter_id

  @doc """
  Install the filter. Called once per VM at boot; installing twice is a
  no-op, and a failure to install is loud — serving without redaction is
  the thing this exists to prevent.
  """
  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
      {:error, reason} -> raise "could not install the log redaction filter: #{inspect(reason)}"
    end
  end

  @doc """
  The filter itself: the event with every credential replaced, never
  `:stop` and never `:ignore` — this filter drops nothing.
  """
  @spec filter(:logger.log_event(), term()) :: :logger.log_event()
  def filter(%{msg: msg, meta: meta} = event, _config) do
    {msg, budget} = redact_msg(msg, @max_nodes)
    {meta, _budget} = walk(meta, 0, budget)
    %{event | msg: msg, meta: meta}
  catch
    _kind, _reason -> event
  end

  def filter(event, _config), do: event

  # The three message shapes :logger carries. `:string` is chardata, and a
  # formatted one is a binary — the shape the known leak arrives in.
  defp redact_msg({:string, text}, budget) when is_binary(text) do
    {{:string, Redaction.scrub_text(text)}, budget - 1}
  end

  # Chardata that is still a tree gets the structural walk rather than a
  # flatten: flattening an iolist assembled by structural sharing would
  # build a binary far larger than the term that produced it.
  defp redact_msg({:string, chardata}, budget) do
    {chardata, budget} = walk(chardata, 0, budget)
    {{:string, chardata}, budget}
  end

  defp redact_msg({:report, report}, budget) do
    {report, budget} = walk(report, 0, budget)
    {{:report, report}, budget}
  end

  defp redact_msg({format, args}, budget) when is_list(args) do
    {format, budget} = walk(format, 0, budget)
    {args, budget} = walk(args, 0, budget)
    {{format, args}, budget}
  end

  defp redact_msg(msg, budget), do: {msg, budget}

  defp walk(_term, _depth, budget) when budget <= 0, do: {Redaction.redacted(), budget}

  defp walk(_term, depth, budget) when depth >= @max_depth,
    do: {Redaction.redacted(), budget - 1}

  defp walk(term, _depth, budget) when is_binary(term),
    do: {Redaction.scrub_text(term), budget - 1}

  defp walk(term, depth, budget) when is_struct(term) do
    module = term.__struct__
    {fields, budget} = walk_map(Map.from_struct(term), depth, budget - 1)
    {Map.put(fields, :__struct__, module), budget}
  end

  defp walk(term, depth, budget) when is_map(term), do: walk_map(term, depth, budget - 1)

  defp walk(term, depth, budget) when is_list(term) do
    if List.ascii_printable?(term, @max_text),
      do: walk_charlist(term, depth, budget),
      else: walk_list(term, depth, budget - 1)
  end

  # A tagged pair — a keyword entry, a header, a two-element field tuple.
  defp walk({key, _value} = pair, depth, budget) do
    case Redaction.replacement_for(key) do
      nil -> walk_tuple(pair, depth, budget)
      replacement -> {{key, replacement}, budget - 1}
    end
  end

  defp walk(term, depth, budget) when is_tuple(term), do: walk_tuple(term, depth, budget)

  # Atoms, numbers, pids, refs, ports, functions: nothing to redact.
  defp walk(term, _depth, budget), do: {term, budget - 1}

  # Text that a dep already formatted into a charlist. A list that only
  # looked printable up to the sample falls back to the structural walk.
  defp walk_charlist(list, depth, budget) do
    {list |> List.to_string() |> Redaction.scrub_text() |> String.to_charlist(), budget - 1}
  rescue
    _error -> walk_list(list, depth, budget - 1)
  end

  defp walk_map(map, depth, budget) do
    {pairs, budget} =
      Enum.reduce(map, {[], budget}, fn {key, value}, {pairs, budget} ->
        case Redaction.replacement_for(key) do
          nil ->
            {value, budget} = walk(value, depth + 1, budget - 1)
            {[{key, value} | pairs], budget}

          replacement ->
            {[{key, replacement} | pairs], budget - 1}
        end
      end)

    {Map.new(pairs), budget}
  end

  # Element by element rather than through walk_list/3, which truncates: a
  # tuple that loses an element loses its meaning to whoever matches on it.
  defp walk_tuple(tuple, depth, budget) do
    {elements, budget} =
      Enum.reduce(Tuple.to_list(tuple), {[], budget - 1}, fn element, {acc, budget} ->
        {element, budget} = walk(element, depth + 1, budget - 1)
        {[element | acc], budget}
      end)

    {elements |> Enum.reverse() |> List.to_tuple(), budget}
  end

  defp walk_list([], _depth, budget), do: {[], budget}

  defp walk_list([head | tail], depth, budget) when budget > 0 do
    {head, budget} = walk(head, depth + 1, budget - 1)
    {tail, budget} = walk_list(tail, depth, budget)
    {[head | tail], budget}
  end

  # The budget ran out mid-list, or the tail is improper.
  defp walk_list(tail, _depth, budget) when is_list(tail), do: {[Redaction.redacted()], budget}
  defp walk_list(tail, depth, budget), do: walk(tail, depth + 1, budget)
end
