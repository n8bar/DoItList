defmodule DoItWeb.AssignedComponents do
  @moduledoc """
  The Assigned-to-Me list (m02.08 worklist 1) — a reusable function component
  shared by the full `/assigned` page (item 1.1) and the ultrawide index's
  right pane (item 1.3). Flat, cross-Initiative rows distinguishing direct
  (primary) from co-assignee, each with the mode-aware leaf/child badge.

  The rows are a LiveView stream. Group-by-Initiative (item 1.6) is achieved by
  ordering the stream by Initiative and flagging the first row of each group so
  it renders a header — keeping the whole collection in one stream rather than
  re-grouping a plain list.

  Controls (completed reveal, archived/hidden reveal, Group-by-Initiative) are
  rendered here; the host LiveView handles their events through the shared
  `DoItWeb.AssignedActions` helpers so the page and the pane behave identically.
  """
  use Phoenix.Component

  import DoItWeb.CoreComponents

  alias DoIt.Tasks.Assigned

  @doc """
  The Assigned-to-Me list.

    * `:id` — DOM id prefix so the page and pane instances don't collide
    * `:rows` — the `@streams.<name>` stream of enriched `%Task{}` rows
    * `:empty?` — true when the stream has no rows (streams can't self-report)
    * `:show_completed` / `:show_archived_hidden` — reveal toggle states
    * `:group_by_initiative` — persistent group-by toggle state
    * `:variant` — `:page` (full width) or `:pane` (compact ultrawide pane)
  """
  attr :id, :string, required: true
  attr :rows, :any, required: true
  attr :empty?, :boolean, default: false
  attr :show_completed, :boolean, default: false
  attr :show_archived_hidden, :boolean, default: false
  attr :group_by_initiative, :boolean, default: false
  attr :variant, :atom, values: [:page, :pane], default: :page

  def assigned_list(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-col gap-3"
      data-keep="assigned-group"
      data-grouped={to_string(@group_by_initiative)}
    >
      <%!-- Controls (WL3 3.2). The two reveal toggles are server-GATED — their
           rows are filtered out of the DOM, so the client can't reveal them
           alone. Keep the round-trip but acknowledge at the click (§6.7): the
           native tick flips optimistically (held by the "reveal-toggle"
           preserve-path applier) while aria-busy + the trailing spinner signal
           in-flight until the server's re-render agrees. Group-by is pure
           arrangement (§6.5) — it reflows client-side at the click (CSS keys off
           the wrapper's data-grouped, below) and only persists the pref on the
           round-trip. --%>
      <div class="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-zinc-600 dark:text-zinc-300">
        <label class="flex items-center gap-1.5 select-none cursor-pointer">
          <input
            type="checkbox"
            id={"#{@id}-show-completed"}
            phx-click="assigned_toggle_completed"
            checked={@show_completed}
            data-keep="reveal-toggle"
            class="checkbox checkbox-xs"
          /> Show completed
          <span
            class="doit-reveal-slot inline-flex w-3.5 flex-none items-center justify-center"
            aria-hidden="true"
          >
            <.icon
              name="hero-arrow-path"
              class="doit-reveal-spinner size-3.5 animate-spin text-emerald-600 dark:text-emerald-400"
            />
          </span>
        </label>
        <label class="flex items-center gap-1.5 select-none cursor-pointer">
          <input
            type="checkbox"
            id={"#{@id}-show-archived-hidden"}
            phx-click="assigned_toggle_archived_hidden"
            checked={@show_archived_hidden}
            data-keep="reveal-toggle"
            class="checkbox checkbox-xs"
          /> Show archived &amp; hidden
          <span
            class="doit-reveal-slot inline-flex w-3.5 flex-none items-center justify-center"
            aria-hidden="true"
          >
            <.icon
              name="hero-arrow-path"
              class="doit-reveal-spinner size-3.5 animate-spin text-emerald-600 dark:text-emerald-400"
            />
          </span>
        </label>
        <label class="flex items-center gap-1.5 select-none cursor-pointer">
          <input
            type="checkbox"
            id={"#{@id}-group-by"}
            phx-click="assigned_toggle_group_by"
            checked={@group_by_initiative}
            data-keep="assigned-group-box"
            data-group-wrap={@id}
            class="checkbox checkbox-xs"
          /> Group by Initiative
        </label>
      </div>

      <%!-- Empty state (UX_GUARDRAILS 2.4): streams can't report emptiness, so
           the host tracks it in @empty?. --%>
      <div
        :if={@empty?}
        class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-zinc-300 px-6 py-12 text-center dark:border-zinc-700"
      >
        <.botanical_icon kind={:leaf} class="w-8 h-8 text-emerald-500/70 dark:text-emerald-400/70" />
        <p class="text-sm font-medium text-zinc-600 dark:text-zinc-300">Nothing on your plate</p>
        <p class="text-xs text-zinc-500 dark:text-zinc-400">
          Tasks assigned to you across your Initiatives will gather here.
        </p>
      </div>

      <ul id={"#{@id}-rows"} phx-update="stream" class="flex flex-col gap-1.5">
        <li :for={{dom_id, task} <- @rows} id={dom_id}>
          <%!-- Group header (item 1.6): the first row of each Initiative carries
               it. group_start? is precomputed by the host so streamed rows need
               no peeking at neighbors. WL3 3.2: rendered for every group_start?
               row regardless of group-by; .assigned-group-header is hidden by
               CSS unless the wrapper's data-grouped is set, so the toggle is a
               client-side reflow (§6.5) instead of a re-stream. --%>
          <h3
            :if={task.group_start?}
            class="assigned-group-header mt-3 mb-1.5 flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-zinc-500 first:mt-0 dark:text-zinc-400"
          >
            <.botanical_icon kind={:grove} class="w-3.5 h-3.5 text-emerald-600 dark:text-emerald-400" />
            {task.initiative_name}
          </h3>
          <.assigned_row task={task} group_by_initiative={@group_by_initiative} />
        </li>
      </ul>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :group_by_initiative, :boolean, default: false

  defp assigned_row(assigns) do
    ~H"""
    <.link
      id={"assigned-task-#{@task.id}"}
      navigate={"/initiatives/#{@task.initiative_id}?task=#{@task.id}"}
      data-nav-spinner
      class="group flex items-center gap-2 rounded border border-zinc-200 bg-white px-3 py-2 transition hover:border-emerald-400 hover:shadow-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-emerald-500 motion-reduce:transition-none dark:border-zinc-800 dark:bg-zinc-900 dark:hover:border-emerald-500"
    >
      <%!-- Direct (primary) vs co-assignee — a filled vs outlined chip so the
           distinction reads at a glance (item 1.5). --%>
      <span
        class={[
          "flex-none rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
          if(@task.assigned_as == :primary,
            do: "bg-emerald-600 text-white dark:bg-emerald-500",
            else: "border border-amber-500 text-amber-700 dark:border-amber-500 dark:text-amber-400"
          )
        ]}
        title={
          if(@task.assigned_as == :primary,
            do: "You're the primary assignee",
            else: "You're a co-assignee"
          )
        }
      >
        {if(@task.assigned_as == :primary, do: "Direct", else: "Co")}
      </span>

      <span class="min-w-0 flex-1">
        <%!-- data-card-ref-field (5.10.3): a `%<id>` token in the title gets the
             label-less card treatment (renderCardRefEl — neutral glyph, escape
             resolution), never a raw id. --%>
        <span
          data-card-ref-field
          class="block truncate text-sm text-zinc-800 dark:text-zinc-100"
        >
          {@task.title}
        </span>
        <%!-- WL3 3.2: always rendered; .assigned-row-subtitle is hidden by CSS
             when the wrapper's data-grouped is set (the group header carries the
             Initiative name then), so group-by is a pure client-side reflow. --%>
        <span class="assigned-row-subtitle block truncate text-xs text-zinc-500 dark:text-zinc-400">
          {@task.initiative_name}
        </span>
      </span>

      <%!-- Done marker (visible only when completed are revealed). --%>
      <span
        :if={@task.status == "done"}
        class="flex-none text-emerald-600 dark:text-emerald-400"
        title="Completed"
      >
        <.icon name="hero-check-circle" class="w-4 h-4" />
      </span>

      <%!-- Mode-aware leaf/child badge (item 1.5) — the unit the Initiative's
           progress mode counts. Leaf-only tasks show no badge: it conveys
           subtree size, and a leaf has none. --%>
      <span
        :if={badge_count(@task) > 0}
        class="flex-none inline-flex items-center gap-0.5 rounded bg-zinc-100 px-1.5 py-0.5 text-[10px] font-medium text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
        title={badge_title(@task)}
      >
        <.botanical_icon kind={badge_icon(@task)} class={badge_icon_class(@task)} />
        {badge_count(@task)}
      </span>
    </.link>
    """
  end

  # The badge counts what the Initiative's progress mode counts (mirrors the
  # tree's chevron badge): direct children (single_level) or subtree leaves
  # (leaf_average). A leaf task counts as a single leaf — nothing worth a badge.
  defp badge_count(%{progress_calc: "single_level"} = task), do: task.child_count || 0
  defp badge_count(%{child_count: 0}), do: 0
  defp badge_count(task), do: task.assigned_leaf_count || 0

  defp badge_icon(%{progress_calc: "single_level"}), do: :branch
  defp badge_icon(_task), do: :leaf

  defp badge_icon_class(%{progress_calc: "single_level"}),
    do: "w-3 h-3 flex-none text-amber-700 dark:text-amber-600"

  defp badge_icon_class(_task), do: "w-3 h-3 flex-none text-emerald-600 dark:text-emerald-400"

  defp badge_title(%{progress_calc: "single_level"}), do: "Direct children"
  defp badge_title(_task), do: "Leaves in this branch"

  @doc """
  Re-runs the query with the current reveal flags, then flags each row that
  starts a new Initiative group (item 1.6). Shared by the page and the pane host
  so both surfaces fetch identically.
  """
  def fetch_assigned(user, %{show_completed: completed?, show_archived_hidden: ah?}) do
    Assigned.list_assigned_to(user,
      include_completed: completed?,
      include_archived_hidden: ah?
    )
    |> flag_group_starts()
  end

  # Mark the first row of each Initiative (the query already sorts by Initiative
  # then title) so a streamed row can render its header without peeking at the
  # previous one.
  defp flag_group_starts(tasks) do
    tasks
    |> Enum.reduce({[], nil}, fn task, {acc, prev_name} ->
      task = Map.put(task, :group_start?, task.initiative_name != prev_name)
      {[task | acc], task.initiative_name}
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
