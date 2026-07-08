defmodule DoItWeb.InitiativeWorkspaceLive do
  # M02.09 WL5.3/5.4: ONE kept-mounted shell LiveView serving both
  # `/initiatives` (the index/list) and `/initiatives/:id` (the detail). mount
  # runs once and owns the shell (global presence, the rail data, the dead-window
  # livePush registration via the always-present .Workspace root hook). The
  # list<->detail hop is a push_patch driving handle_params with NO remount, so
  # the socket, PubSub subscriptions and presence stay intact and other viewers
  # never flicker. Per-Initiative subscriptions + presence are torn down/entered
  # EXPLICITLY on leave/switch (they no longer ride process death).
  use DoItWeb, :live_view

  import Ecto.Query, only: [from: 2]
  import DoItWeb.AssignedComponents

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Tasks.Task
  alias DoIt.Tasks.Progress
  alias DoIt.Tasks.Tree
  alias DoItWeb.AssignedActions

  # Sort modes the index understands. `nil` = the server's default order
  # (owner-first, recently-updated); "manual" = the user's drag order, stored
  # on their membership rows (m02.04 §2.6).
  @sort_modes ~w(name progress created updated manual)

  # Postgres `bigint` (int8) bounds. An id parsed from the URL that fits
  # `Integer.parse/1`'s `{int, ""}` can still be too large for an int8 column —
  # `Repo.get/2` then raises DBConnection.EncodeError BEFORE it can return nil,
  # crashing the LiveView instead of routing into the not-found path. Range-guard
  # every parsed id against these bounds so an out-of-range id resolves to nil.
  @pg_bigint_min -9_223_372_036_854_775_808
  @pg_bigint_max 9_223_372_036_854_775_807

  @impl true
  # The shell mount — runs ONCE for the kept-mounted workspace, regardless of
  # which route was hit first. It sets up everything that persists across the
  # list<->detail hops (global presence subscription, the rail/collaborator data,
  # the list-mode assigns + streams) and seeds every detail-mode assign to a safe
  # default so a list render never touches a stale detail value. handle_params/3
  # is the mode switch that enters/leaves/switches the per-Initiative detail.
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # Lazy retention sweep (m02.06 item 11): purge anything past the window on
    # the way in, so the Trash never shows stale, already-expired entries.
    Initiatives.purge_expired_trash()

    # Global presence (m02.05 item 8): light up Collaborators avatars for anyone
    # connected to the app. on_mount already TRACKS us once per process; we just
    # subscribe to learn when others come and go. Shell-level — one subscription
    # for the life of the mount, never re-done on a hop.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(DoIt.PubSub, DoItWeb.Presence.global_topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Initiatives")
     |> assign(:rail_collaborators, Initiatives.list_collaborators(user))
     |> assign(
       :collaborator_online_ids,
       if(connected?(socket), do: DoItWeb.Presence.global_online_ids(), else: MapSet.new())
     )
     |> assign_display_prefs(Accounts.get_preferences(user))
     |> assign(:confirm_skips, MapSet.new())
     |> assign_index_data(user)
     |> assign_detail_defaults()
     |> restream_sorted()}
  end

  @impl true
  # The mode switch. :index tears any open detail down and shows the list;
  # :show enters (from the list) or switches (from another Initiative) into a
  # per-Initiative detail. Both run on the disconnected (static) render too.
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :index -> {:noreply, enter_index(socket)}
      :show -> {:noreply, enter_show(socket, params)}
    end
  end

  # --- Index (list) mode -----------------------------------------------------

  # Land on the list. Leaving an open detail tears its per-Initiative
  # subscriptions + presence down EXPLICITLY (they no longer ride process death)
  # and refreshes the list so a change made while inside a detail shows here.
  defp enter_index(socket) do
    socket =
      if socket.assigns.initiative do
        socket
        |> teardown_detail()
        |> clear_detail_assigns()
        |> assign_index_data(socket.assigns.current_user)
      else
        socket
      end

    socket
    |> assign(:page_title, "Initiatives")
    |> restream_sorted()
    |> AssignedActions.restream(socket.assigns.current_user)
  end

  # Seed / refresh the list-mode assigns (initiatives, sort, trash, archive,
  # the Assigned-to-Me pane). Used by mount and on every return to the list.
  defp assign_index_data(socket, user) do
    initiatives = Initiatives.list_visible_initiatives(user)
    prefs = Accounts.get_preferences(user)
    mode = normalize_mode(prefs.index_sort_mode)
    reverse_by_mode = prefs.index_sort_reverse_by_mode || %{}

    sort_state = %{
      mode: mode,
      reverse: !!Map.get(reverse_by_mode, mode || ""),
      order: stored_order(initiatives)
    }

    socket
    |> assign(:initiative_count, length(initiatives))
    |> assign(:initiatives, initiatives)
    |> assign(:sort_state, sort_state)
    |> assign(:reverse_by_mode, reverse_by_mode)
    |> assign(:form, build_empty_form())
    |> assign(:trashed, Initiatives.list_trashed_initiatives(user))
    # `show_hidden` / `show_trash` are plain assign state — deliberately
    # NON-persistent: they reset to false on every mount, so hidden Initiatives
    # and trashed Initiatives both stay out of sight by default.
    |> assign(:archived, Initiatives.list_archived_initiatives(user))
    |> assign(:show_hidden, false)
    |> assign(:show_trash, false)
    |> AssignedActions.assign_initial(user)
  end

  # --- Detail (show) mode ----------------------------------------------------

  # Enter or switch into an Initiative's detail. Guards a nil Initiative / nil
  # role by ejecting to the list (push_navigate remounts, so no manual teardown
  # is needed for the reject path). Re-entering the SAME Initiative (e.g. a
  # ?task= deep-link patch) only honors the param — it never re-subscribes.
  defp enter_show(socket, params) do
    user = socket.assigns.current_user
    initiative = fetch_initiative(params["id"])
    role = initiative && Initiatives.get_role(initiative.id, user.id)
    current = socket.assigns.initiative

    cond do
      is_nil(initiative) ->
        socket
        |> put_flash(:error, "Initiative not found.")
        |> push_navigate(to: ~p"/initiatives")

      is_nil(role) ->
        socket
        |> put_flash(:error, "You don't have access to that initiative.")
        |> push_navigate(to: ~p"/initiatives")

      current && current.id == initiative.id ->
        honor_task_param(socket, params)

      true ->
        socket
        |> teardown_detail()
        |> clear_detail_assigns()
        |> enter_initiative(initiative, role)
        |> honor_task_param(params)
    end
  end

  # Every id that reaches this module from the client — a URL/:id segment, an
  # event payload, a form/phx-value param — arrives as an untrusted string (or,
  # for a malformed payload, a non-string like a map or a repeated-param list).
  # `Repo.get(_, "abc")` raises Ecto.Query.CastError, `String.to_integer("abc")`
  # raises ArgumentError, `Integer.parse(%{})` raises FunctionClauseError, and a
  # numeric id outside the signed-64-bit (int8) range parses cleanly yet raises
  # DBConnection.EncodeError once Repo encodes it — each one crashes the LiveView
  # instead of failing soft. parse_id/1 is the single gate: it returns the integer
  # only for a binary that parses cleanly AND fits the int8 range, and nil for
  # anything else (a non-binary, non-numeric text, trailing garbage, or an
  # out-of-range value). Every client-supplied id parse routes through it and the
  # handler no-ops on nil.
  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= @pg_bigint_min and int <= @pg_bigint_max -> int
      _ -> nil
    end
  end

  # Client hook events (e.g. DragReorder's "move_task") send ids as JSON
  # numbers, not strings — accept a valid in-range integer id as-is so the
  # "never crash, reply not_found" guard doesn't silently reject every move.
  defp parse_id(value) when is_integer(value) and value >= @pg_bigint_min and value <= @pg_bigint_max,
    do: value

  defp parse_id(_), do: nil

  # The :id route segment matches any string, but the Initiative primary key is
  # an integer; a malformed id resolves to nil and routes into the SAME not-found
  # flash+eject as a valid-but-missing id (the guard's "never crash").
  defp fetch_initiative(id) do
    case parse_id(id) do
      nil -> nil
      iid -> Initiatives.get_initiative(iid)
    end
  end

  # Subscribe + track for the entered Initiative and load its detail. Mirrors the
  # old mount's connected-setup, but runs on every list->detail enter and
  # initiative->initiative switch (no remount happens now).
  defp enter_initiative(socket, initiative, role) do
    user = socket.assigns.current_user

    if connected?(socket) do
      Tasks.subscribe(initiative.id)

      # Selection presence (.04.01.12): subscribe first, then track — our own
      # join diff arrives as the initial push and already includes everyone here.
      Phoenix.PubSub.subscribe(DoIt.PubSub, presence_topic(initiative.id))

      {:ok, _} =
        DoItWeb.Presence.track(self(), presence_topic(initiative.id), to_string(user.id), %{
          user_id: user.id,
          task_id: nil,
          name: user.name,
          initials: initials(user),
          bg: avatar_bg(user),
          fg: avatar_fg(user)
        })

      # Live chat (m02.08 worklist 3 item 3.1): a per-Initiative ephemeral topic.
      Phoenix.PubSub.subscribe(DoIt.PubSub, chat_topic(initiative.id))

      # Defer the non-critical loads (undo/redo labels, the cross-Initiative
      # Collaborators rail) off the enter critical path so the tree is interactive
      # the instant it paints; they fill a beat later via :after_mount.
      send(self(), :after_mount)
    end

    socket
    |> assign(:page_title, initiative.name)
    |> assign(:initiative, initiative)
    # The rail shows the visible Initiatives in both modes; refresh on enter so a
    # newly created/renamed Initiative is current.
    |> assign(:initiatives, Initiatives.list_visible_initiatives(user))
    |> assign(:subtitle, Initiatives.subtitle(initiative))
    |> assign(:role, role)
    |> assign(:can_edit, Initiatives.can_edit?(role))
    |> assign(:can_admin, Initiatives.can_admin?(role))
    |> assign(:members, Initiatives.list_members(initiative.id))
    |> assign(:selected_task_id, nil)
    |> assign(:selected_task, nil)
    |> assign(:selected_staff_pool, nil)
    |> assign(:comments, [])
    |> assign(:activity, [])
    |> assign(:chat_messages, [])
    |> assign(:chat_log_id, 0)
    |> assign(
      :online_ids,
      if(connected?(socket), do: online_ids(initiative.id), else: MapSet.new())
    )
    |> assign(:initiative_form, to_form(Initiatives.change_initiative(initiative)))
    |> assign_pending(nil)
    |> assign(:pending_handoff, nil)
    |> assign(:show_archive_prompt, false)
    |> assign(:prompted_archive?, false)
    |> assign(:undo_label, nil)
    |> assign(:redo_label, nil)
    |> load_tree(undo: false)
  end

  # Deep-link to a task (m02.08 item 1.7): the Assigned-to-Me list opens
  # `/initiatives/:id?task=<id>`. Selection is client/DOM-owned, so we push the
  # target plus its ancestor chain to the client, which expands any collapsed
  # ancestors, selects the row, and scrolls it into view. Pure view state
  # (UX_GUARDRAILS 6.5) — no round trip gates it. A missing/foreign task is
  # ignored; absent ?task= is a no-op.
  defp honor_task_param(socket, %{"task" => task_id}) do
    with true <- connected?(socket),
         %{initiative: %{id: initiative_id}} when not is_nil(initiative_id) <- socket.assigns,
         id when not is_nil(id) <- parse_id(task_id),
         %Task{initiative_id: ^initiative_id, deleted_at: nil} <- Tasks.get_task(id) do
      push_event(socket, "deep-link-task", %{id: to_string(id), ancestors: Tasks.ancestor_ids(id)})
    else
      _ -> socket
    end
  end

  defp honor_task_param(socket, _params), do: socket

  # Drop the per-Initiative subscriptions + presence for the currently-open
  # detail. A no-op when no detail is open (list mount, or already torn down).
  # A leaked subscription (a left Initiative's broadcasts still hitting this
  # process) is the top bug this prevents, so be explicit.
  defp teardown_detail(socket) do
    initiative = socket.assigns[:initiative]

    if initiative && connected?(socket) do
      iid = initiative.id
      Tasks.unsubscribe(iid)
      Phoenix.PubSub.unsubscribe(DoIt.PubSub, presence_topic(iid))
      Phoenix.PubSub.unsubscribe(DoIt.PubSub, chat_topic(iid))

      DoItWeb.Presence.untrack(
        self(),
        presence_topic(iid),
        to_string(socket.assigns.current_user.id)
      )
    end

    socket
  end

  # Seed every detail-mode assign to a safe default so a list render never
  # references a stale detail value, and a fresh enter starts clean. confirm_skips
  # and the display prefs are user-level (not per-Initiative), so they live in
  # mount and are deliberately NOT reset here.
  defp assign_detail_defaults(socket) do
    socket
    |> assign(:initiative, nil)
    |> assign(:subtitle, nil)
    |> assign(:role, nil)
    |> assign(:can_edit, false)
    |> assign(:can_admin, false)
    |> assign(:members, [])
    |> assign(:selected_task_id, nil)
    |> assign(:selected_task, nil)
    |> assign(:selected_staff_pool, nil)
    |> assign(:tree, [])
    |> assign(:root_task, nil)
    |> assign(:root_sort_mode, nil)
    # nil (not 0) so the FIRST set_initiative_progress on a detail-enter sees no
    # prior value and an already-complete Initiative does not raise the
    # archive-on-completion nag (it only fires on a live crossing into 100).
    |> assign(:initiative_progress, nil)
    |> assign(:led_task_ids, MapSet.new())
    |> assign(:direct_assignee_ids, MapSet.new())
    |> assign(:comments, [])
    |> assign(:activity, [])
    |> assign(:chat_messages, [])
    |> assign(:chat_log_id, 0)
    |> assign(:online_ids, MapSet.new())
    |> assign(:initiative_form, nil)
    |> assign(:pending_handoff, nil)
    |> assign(:show_archive_prompt, false)
    |> assign(:prompted_archive?, false)
    |> assign(:undo_label, nil)
    |> assign(:redo_label, nil)
    |> assign_pending(nil)
  end

  # clear_detail_assigns reuses the defaults; the name reads as intent at the
  # call sites (leaving/switching a detail).
  defp clear_detail_assigns(socket), do: assign_detail_defaults(socket)

  # The viewing user's Display elements preferences (m02.04 §2.4): the
  # activity-log toggle plus which task attributes render on rows.
  defp assign_display_prefs(socket, prefs) do
    socket
    |> assign(:show_task_activity, prefs.show_task_activity)
    |> assign(:display, %{
      priority: prefs.show_task_priority,
      assignee: prefs.show_task_assignee,
      progress: prefs.show_task_progress,
      count: prefs.show_task_count
    })
  end

  # --- Selection presence (.04.01.12) --------------------------------------

  defp presence_topic(initiative_id), do: "initiative_presence:#{initiative_id}"

  # --- Live chat (m02.08 worklist 3 item 3.1) ------------------------------

  # Per-Initiative chat topic — separate from the task-change topic
  # (Tasks.subscribe) and the presence topics. Ephemeral by construction:
  # broadcast-only, no DB, no GenServer history.
  defp chat_topic(initiative_id), do: "initiative_chat:#{initiative_id}"

  # Recent-messages cap kept in each viewer's socket. Bounds memory and matches
  # the "lightweight, current viewers only" intent — no scrollback history.
  @chat_cap 50

  # Everyone with this initiative open right now — presence keys are the
  # tracked user ids. Feeds the avatar online dots (members panel + pane).
  defp online_ids(initiative_id) do
    initiative_id
    |> presence_topic()
    |> DoItWeb.Presence.list()
    |> Map.keys()
    |> MapSet.new(&String.to_integer/1)
  end

  defp update_presence(socket, task_id) do
    if connected?(socket) do
      user = socket.assigns.current_user
      topic = presence_topic(socket.assigns.initiative.id)

      {:ok, _} =
        DoItWeb.Presence.update(
          self(),
          topic,
          to_string(user.id),
          &Map.put(&1, :task_id, task_id)
        )
    end

    socket
  end

  # Everyone else's current selections, shipped to the client hook. Several
  # windows of the same user collapse to unique (user, task) pairs; my own
  # selections are skipped — presence marks *other* members' rows.
  defp push_presence(socket) do
    me = socket.assigns.current_user.id

    presences =
      socket.assigns.initiative.id
      |> presence_topic()
      |> DoItWeb.Presence.list()

    selections =
      presences
      |> Enum.flat_map(fn {_key, %{metas: metas}} -> metas end)
      |> Enum.filter(&(&1.user_id != me and &1.task_id))
      |> Enum.uniq_by(&{&1.user_id, &1.task_id})
      |> Enum.map(&Map.take(&1, [:user_id, :task_id, :name, :initials, :bg, :fg]))

    # Everyone here (self included) — the client paints assignee-chip online
    # dots from this, so presence changes never re-render the tree.
    online = presences |> Map.keys() |> Enum.map(&String.to_integer/1)

    push_event(socket, "presence-selections", %{selections: selections, online: online})
  end

  # `opts[:undo]` (default true) controls whether the undo/redo labels are
  # recomputed inline. Every post-mount caller wants them fresh; the connected
  # mount passes `undo: false` so the ~60-90ms undo/redo `activity_events` trio
  # stays OFF the critical path and is filled in by :after_mount (a beat later).
  defp load_tree(socket, opts \\ []) do
    initiative_id = socket.assigns.initiative.id
    tree = Tasks.initiative_task_tree(initiative_id)
    root = Tasks.get_task(socket.assigns.initiative.root_task_id)

    # Resolved once here; task_node threads it down (child = own mode ||
    # parent's resolved), so rendering never walks the DB per branch. The
    # header bar shows the system root's roll-up — same leaf-average math as
    # every branch (ProductSpec § Roll-up Progress).
    # Top-level tasks ARE the root's children — attach them so leaf?(@root_task)
    # never falls back to a per-render count query (the pane renders always now).
    root = root && Map.put(root, :children, tree)

    socket =
      socket
      |> assign(:tree, tree)
      |> assign(:root_task, root)
      |> assign(:root_sort_mode, elem(Tasks.resolve_sort(root), 0))
      |> set_initiative_progress((root && root.computed_progress) || 0)
      |> assign(:led_task_ids, viewer_led_ids(socket))
      |> assign(:direct_assignee_ids, tree_assignee_ids(tree))

    if Keyword.get(opts, :undo, true), do: assign_undo_state(socket), else: socket
  end

  # Assign the roll-up % and, on a transition INTO 100, raise the dismissible
  # archive prompt once per session (m02.08 item 4.1 — never auto-archives).
  # `prompted_archive?` (set by dismissal or a prior raise) suppresses repeats;
  # a drop back below 100 re-arms it. Guards a not-yet-assigned prior value, so
  # an Initiative already at 100% on mount does NOT nag.
  defp set_initiative_progress(socket, progress) do
    prev = socket.assigns[:initiative_progress]
    crossed_to_100? = prev not in [nil, 100] and progress == 100

    socket
    |> assign(:initiative_progress, progress)
    |> maybe_raise_archive_prompt(crossed_to_100?, progress)
  end

  defp maybe_raise_archive_prompt(socket, true, _progress) do
    if socket.assigns.prompted_archive? do
      socket
    else
      socket
      |> assign(:show_archive_prompt, true)
      |> assign(:prompted_archive?, true)
    end
  end

  # Below 100 again — re-arm so finishing it once more can prompt anew.
  defp maybe_raise_archive_prompt(socket, false, progress) when progress < 100,
    do: socket |> assign(:show_archive_prompt, false) |> assign(:prompted_archive?, false)

  defp maybe_raise_archive_prompt(socket, false, _progress), do: socket

  # Undo / redo availability for the toolbar (m02.06 items 4/5): the labels of
  # the next undoable / redoable action, or nil when the stack is empty that
  # way. Refreshed wherever the tree is (load_tree / patch_task / after undo).
  defp assign_undo_state(socket) do
    user = socket.assigns.current_user
    iid = socket.assigns.initiative.id
    undo = Tasks.undo_candidate(user, iid)
    redo = Tasks.redo_candidate(user, iid)

    socket
    |> assign(:undo_label, undo && Tasks.describe_event(undo))
    |> assign(:redo_label, redo && Tasks.describe_event(redo))
  end

  # Reversed kinds that change only a task's own fields — the performer patches
  # just that row (item 14.4); everything else changes tree shape and reloads.
  @incremental_undo_kinds ~w(title_changed description_changed progress_changed priority_changed assignee_changed)

  defp do_undo_redo(socket, dir) do
    user = socket.assigns.current_user
    iid = socket.assigns.initiative.id

    # Capture the target before applying, so a successful reversal can update the
    # performer incrementally (item 14.4) and select + scroll it (item 13).
    candidate =
      if dir == :undo, do: Tasks.undo_candidate(user, iid), else: Tasks.redo_candidate(user, iid)

    result = if dir == :undo, do: Tasks.undo(user, iid), else: Tasks.redo(user, iid)
    verb = if dir == :undo, do: "Undid", else: "Redid"

    case result do
      {:ok, desc} ->
        # Match the broadcast: a value edit patches its row, a comment change
        # refreshes the pane's comment list, structural changes reload — so the
        # performer pays the same incremental cost as everyone (item 14.4/14.5).
        socket =
          cond do
            is_nil(candidate) -> load_tree(socket)
            candidate.kind == "commented" -> refresh_selected(socket)
            candidate.kind in @incremental_undo_kinds -> patch_task(socket, candidate.task_id)
            # Completion (item 14): patch the acted task — its lineage covers the
            # leaf flip and any up-cascade. A branch down-cascade's descendants
            # arrive via the per-affected {:task_updated} broadcasts we also receive.
            candidate.kind == "status_changed" -> patch_task(socket, candidate.task_id)
            true -> load_tree(socket)
          end

        socket = put_flash(socket, :info, "#{verb} #{desc}.")
        # Push the id as a string: the client re-emits "select_task" with it, and
        # that handler does String.to_integer/1 — an integer here crashed the
        # LiveView on every undo (item 13 regression).
        if candidate,
          do: push_event(socket, "select-task", %{id: to_string(candidate.task_id)}),
          else: socket

      {:error, :nothing_to_undo} ->
        put_flash(socket, :error, "Nothing to undo.")

      {:error, :nothing_to_redo} ->
        put_flash(socket, :error, "Nothing to redo.")

      {:error, {:conflict, desc}} ->
        socket
        |> load_tree()
        |> put_flash(:error, "Couldn't #{dir} #{desc} — it may have changed since.")
    end
  end

  # User ids that are the direct (primary) assignee of any task in the loaded
  # tree (item 12.6.5). Derived in-memory from the already-loaded tree — no extra
  # query — and refreshed wherever the tree is (load_tree / patch_task). The
  # members panel reads it to label a viewer who holds an assignment "viewer+".
  defp tree_assignee_ids(tree), do: Enum.reduce(tree, MapSet.new(), &collect_assignee_ids/2)

  defp collect_assignee_ids(task, acc) do
    acc = if task.assignee_id, do: MapSet.put(acc, task.assignee_id), else: acc
    Enum.reduce(task.children || [], acc, &collect_assignee_ids/2)
  end

  # Viewer+ (m02.05 item 12.6): the set of tasks the current user leads — only
  # populated for a global *viewer* in a viewer_plus Initiative; editors/owners
  # already edit everything via can_edit, so they get the empty set. Refreshed
  # with the tree, so a changed assignment re-scopes the grant.
  defp viewer_led_ids(socket) do
    if socket.assigns.role == "viewer" and socket.assigns.initiative.viewer_plus do
      Tasks.viewer_plus_led_ids(socket.assigns.initiative.id, socket.assigns.current_user.id)
    else
      MapSet.new()
    end
  end

  # Whether the current user may edit a task's progress / comments: editors and
  # owners anywhere; a viewer+ on a task they lead (item 12.6). NOT title /
  # priority / structure — those stay can_edit only.
  defp leads_task?(socket, task_id),
    do: MapSet.member?(socket.assigns.led_task_ids, task_id)

  defp can_progress?(socket, task_id),
    do: socket.assigns.can_edit or leads_task?(socket, task_id)

  # Sound the rejection thud on a permission denial, so a viewer / viewer+ who
  # attempts a disallowed action gets the feedback no matter how the attempt
  # arrived (form / click / drop, not just a key). The TaskKeys hook's "bonk"
  # listener plays it; pairs with the put_flash error already shown.
  defp bonk(socket), do: push_event(socket, "bonk", %{})

  # Set the selected task and, with it, the current user's staffing pool for it
  # (item 12.6.3/12.6.4) — recomputed only when the selection actually changes,
  # so the editor's selectors and the co/assignee gates read one ready value.
  defp assign_selected(socket, task) do
    socket
    |> assign(:selected_task, task)
    |> assign(:selected_staff_pool, selected_staff_pool(socket, task))
  end

  # The pool of user ids the current user may staff the selected task with:
  #   :all  — an editor/owner (any member; no pool limit)
  #   nil   — may not staff this task (selectors absent / disabled)
  #   MapSet — a viewer+ lead, limited to the people they were handed (item 12.6).
  defp selected_staff_pool(_socket, nil), do: nil

  defp selected_staff_pool(socket, %{} = task) do
    cond do
      socket.assigns.can_edit ->
        :all

      socket.assigns.role == "viewer" and socket.assigns.initiative.viewer_plus ->
        Tasks.viewer_staff_pool(socket.assigns.current_user.id, task)

      true ->
        nil
    end
  end

  # Whether the current user may staff the selected task at all (set primary /
  # co-assignees). Drives the editor's assignee + co surfaces and the co events.
  defp can_staff?(socket), do: socket.assigns.selected_staff_pool != nil

  # Whether `uid` is allowed in the selected task's pool — editors (:all) place
  # anyone; a viewer+ only the handed pool. Empty string (unassign) is allowed
  # for any staffer.
  defp staff_pool_allows?(socket, uid) do
    case socket.assigns.selected_staff_pool do
      :all -> true
      nil -> false
      %MapSet{} = pool -> uid in ["", nil] or MapSet.member?(pool, to_int(uid))
    end
  end

  defp to_int(n) when is_integer(n), do: n
  # A client-supplied uid string (params["assignee_id"] / a co-assignee uid):
  # route through parse_id so a non-numeric / out-of-range value yields nil
  # (MapSet.member?(pool, nil) is false → out of pool) instead of crashing.
  defp to_int(s) when is_binary(s), do: parse_id(s)
  defp to_int(_), do: nil

  defp assign_result(socket, task, {:ok, _}),
    do: {:reply, %{ok: true}, patch_task(socket, task.id)}

  defp assign_result(socket, _task, {:error, _}), do: {:reply, %{ok: false}, socket}

  defp member_id?(socket, uid), do: Enum.any?(socket.assigns.members, &(&1.user_id == uid))

  defp co_assignee?(task_id, uid),
    do: Enum.any?(Tasks.list_co_assignees(task_id), &(&1.user_id == uid))

  # May the current user assign `uid` onto `task` (item 12.8 drop validation)?
  # Editors/owners anywhere; a viewer+ only on a staffable task, from its pool.
  defp assign_allowed?(socket, task, uid) do
    cond do
      socket.assigns.can_edit ->
        true

      socket.assigns.role == "viewer" and socket.assigns.initiative.viewer_plus ->
        case Tasks.viewer_staff_pool(socket.assigns.current_user.id, task) do
          nil -> false
          pool -> MapSet.member?(pool, uid)
        end

      true ->
        false
    end
  end

  # Why a drop was rejected (item 12.6), so the toast names the real reason: a
  # viewer+ on a staffable descendant who picked someone outside the pool gets
  # the offender named and pointed at the source (the led ancestor whose
  # co-assignees ARE the pool); a task they can't staff at all (their own led
  # task's co-list is owner-seeded, or no led ancestor) gets the plainer line.
  defp assign_denied_message(socket, task, uid) do
    user = socket.assigns.current_user

    cond do
      not (socket.assigns.role == "viewer" and socket.assigns.initiative.viewer_plus) ->
        "You don't have permission to assign people here."

      is_nil(Tasks.viewer_staff_pool(user.id, task)) ->
        "You can't assign people to that task."

      true ->
        source = Tasks.viewer_led_ancestor(user.id, task)

        "#{member_username(socket, uid)} isn't a co-assignee on '#{source.title}' - " <>
          "you can only assign its co-assignees here."
    end
  end

  defp member_username(socket, uid) do
    case Enum.find(socket.assigns.members, &(&1.user_id == uid)) do
      nil -> "that person"
      member -> "@#{member.user.username}"
    end
  end

  # The params a viewer+ may actually apply to the selected task: manual_progress
  # (progress grant, item 12.6.2) plus a pool-valid assignee_id when the task is
  # staffable (item 12.6.3). Everything else the form posted is dropped.
  defp viewer_allowed_params(socket, params) do
    progress = Map.take(params, ["manual_progress"])

    if can_staff?(socket) and Map.has_key?(params, "assignee_id") and
         staff_pool_allows?(socket, params["assignee_id"]) do
      Map.put(progress, "assignee_id", params["assignee_id"])
    else
      progress
    end
  end

  # Attribute-level changes patch the loaded tree instead of reloading the
  # initiative (.03.04.03, ProductSpec § Collaboration Model): merge the
  # written task + its ancestor roll-ups, re-key the parent's child order
  # (auto-sorted parents resort on update), and refresh the pane only when it
  # shows an affected task. Structural changes (create / move / delete / sort
  # / cascades) still take the full load_tree.
  defp patch_task(socket, task_id) do
    case patched_lineage(socket, task_id) do
      [] ->
        # The task vanished under us (e.g. deleted concurrently) — reload.
        socket |> load_tree() |> refresh_selected()

      lineage ->
        task = Enum.find(lineage, &(&1.id == task_id))
        root_id = socket.assigns.initiative.root_task_id
        prev_led = socket.assigns.led_task_ids

        socket =
          socket
          |> assign(:tree, patched_tree(socket, task, lineage))
          |> maybe_refresh_root_sort(task, root_id)

        # An assignment may have changed in the patched rows — re-derive both
        # the viewer+ label set (item 12.6.5, from the in-memory tree) and the
        # viewer+ GRANT set (item 14.1: led tasks drive the editable affordances,
        # so a live assignment must grant the subtree without a refresh).
        socket =
          socket
          |> assign(:direct_assignee_ids, tree_assignee_ids(socket.assigns.tree))
          |> assign(:led_task_ids, viewer_led_ids(socket))
          |> assign_undo_state()

        # Any in-tree lineage tops out at the system root — its fresh roll-up
        # drives the header bar and the initiative editor's computed line.
        socket =
          case Enum.find(lineage, &(&1.id == root_id)) do
            nil ->
              socket

            root ->
              socket
              |> set_initiative_progress(root.computed_progress || 0)
              |> assign(:root_task, Map.put(root, :children, socket.assigns.tree))
          end

        # Refresh the open pane when it shows a task in the patched lineage, OR
        # when a viewer+ grant/revoke just flipped the selected task's
        # led-membership (item 15.1). The assignment broadcasts for the granted
        # task, but staffing rights (@selected_staff_pool) are recomputed only on
        # refresh — and the affected task may be a selected DESCENDANT that isn't
        # in that task's lineage. (Progress already updates live: can_progress is
        # re-derived from @led_task_ids in the pane wrapper.)
        sel = socket.assigns.selected_task_id

        led_flipped? =
          sel && MapSet.member?(prev_led, sel) != MapSet.member?(socket.assigns.led_task_ids, sel)

        if (sel && sel in Enum.map(lineage, & &1.id)) || led_flipped?,
          do: refresh_selected(socket),
          else: socket
    end
  end

  defp patched_tree(socket, task, lineage) do
    root_id = socket.assigns.initiative.root_task_id
    tree = Tree.merge(socket.assigns.tree, lineage)

    # Any lineage level may have re-sorted: auto-sorted parents resort when a
    # child's sort key changes, and progress-keyed modes resort when a
    # DESCENDANT's roll-up changes — so simultaneous collaborators must get
    # every level's order, not just the written task's siblings. One query
    # re-keys them all.
    parent_ids =
      [task.parent_id | Enum.map(lineage, & &1.id)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    parent_ids
    |> Tasks.ordered_child_ids_by_parent()
    |> Enum.reduce(tree, fn {parent_id, ids}, acc ->
      key = if parent_id == root_id, do: :root, else: parent_id
      Tree.reorder_children(acc, key, ids)
    end)
  end

  # `patch_task`'s data source: a `Tasks.lineage/1`-shaped list (the task plus
  # every ancestor up to the system root) — but only the changed task's own
  # row comes from the database. A PubSub `{:task_updated, id}` names WHICH
  # task changed, not its new values, so a single cheap row read (not the
  # whole chain — `Tasks.task_row/1`) tells us that; every ancestor's fresh
  # roll-up is then recomputed from the LiveView's OWN already-loaded `@tree`
  # (no DB read at all) via the one shared formula module, `DoIt.Tasks.Progress`
  # — the same math `DoIt.Tasks.reconcile_progress/2` uses server-side, just
  # run here on in-memory data instead of a fresh fetch. Every OTHER connected
  # viewer's process was doing its own redundant `Tasks.lineage/1` DB read in
  # response to the very same broadcast; this replaces all of them with one
  # row read plus pure Elixir. Returns `[]` when the task is gone (mirrors
  # `Tasks.lineage/1`'s empty-list contract for a concurrently deleted task).
  defp patched_lineage(socket, task_id) do
    case Tasks.task_row(task_id) do
      nil ->
        []

      %Task{parent_id: nil} = fresh_task ->
        # The system root itself has no ancestors — its own fresh row (already
        # carrying the backend-persisted roll-up) is the whole "lineage."
        [fresh_task]

      fresh_task ->
        case socket.assigns.root_task do
          nil ->
            [fresh_task]

          root ->
            rooted = Map.put(root, :children, Tree.merge(socket.assigns.tree, [fresh_task]))

            case tree_path(rooted, task_id) do
              nil ->
                # Not (yet) anywhere in the loaded tree — e.g. a broadcast that
                # beat our own load_tree to arrive. The fresh row alone is a
                # harmless no-op through patched_tree's merge for a chain we
                # can't walk.
                [fresh_task]

              path ->
                mode = progress_calc_mode(socket)
                values = Progress.compute_all([rooted], mode)
                statuses = Tasks.statuses_for(Enum.map(path, & &1.id))

                Enum.map(
                  path,
                  &%{
                    &1
                    | computed_progress: Map.get(values, &1.id, &1.computed_progress),
                      status: Map.get(statuses, &1.id, &1.status)
                  }
                )
            end
        end
    end
  end

  # `node` plus every ancestor down to (and including) the one whose id
  # matches `target_id`, root-most first. `nil` when `target_id` isn't
  # anywhere in this subtree.
  defp tree_path(%{id: id} = node, target_id) when id == target_id, do: [node]

  defp tree_path(%{children: children} = node, target_id) when is_list(children) do
    Enum.find_value(children, fn child ->
      case tree_path(child, target_id) do
        nil -> nil
        rest -> [node | rest]
      end
    end)
  end

  defp tree_path(_node, _target_id), do: nil

  defp progress_calc_mode(socket) do
    if socket.assigns.initiative.progress_calc == "single_level",
      do: :single_level,
      else: :leaf_average
  end

  # A sort change on the system root re-resolves every inheriting branch.
  defp maybe_refresh_root_sort(socket, %{id: root_id}, root_id),
    do: assign(socket, :root_sort_mode, elem(Tasks.resolve_sort(root_id), 0))

  defp maybe_refresh_root_sort(socket, _task, _root_id), do: socket

  defp refresh_selected(socket) do
    case socket.assigns.selected_task_id do
      nil ->
        socket

      id ->
        case Tasks.get_task_with_relations(id) do
          nil ->
            assign(socket, :selected_task_id, nil)

          task ->
            socket
            |> assign_selected(task)
            |> assign(:comments, Tasks.list_comments(id))
            |> assign(:activity, Tasks.list_task_activity(id))
        end
    end
  end

  # --- Events ----------------------------------------------------------------

  # --- Index (list) events ---------------------------------------------------

  @impl true
  # The New Initiative form opens/closes client-side (UX_GUARDRAILS 6.5 — typing
  # must never wait on a round trip): a <details> + data-keep="open". Only a
  # successful create closes it from here.
  def handle_event("create", %{"initiative" => params}, socket) do
    user = socket.assigns.current_user

    case Initiatives.create_initiative(user, params) do
      {:ok, initiative} ->
        # Land straight inside the new initiative (WL6 6.3): push_patch — not
        # push_navigate — keeps the single-module workspace mounted, so
        # handle_params just enters detail mode (no remount). The list re-fetches
        # on any return to index (assign_index_data), so no list-assign upkeep is
        # needed here. close-details collapses the create form on the way out.
        {:noreply,
         socket
         |> put_flash(:info, "Initiative created.")
         |> push_event("close-details", %{id: "new-initiative"})
         |> push_patch(to: ~p"/initiatives/#{initiative.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # Sort changes persist server-side (m02.04 §2.6): mode + per-mode reverse onto
  # the prefs record, a pushed manual order onto the membership rows. The control
  # pushes no order; only a drag does — absent, the session's existing order stands.
  def handle_event("apply_sort", params, socket) do
    user = socket.assigns.current_user
    mode = normalize_mode(params["mode"])
    reverse = params["reverse"] in [true, "true"]
    pushed_order = params["order"] || []

    reverse_by_mode = Map.put(socket.assigns.reverse_by_mode, mode || "", reverse)

    {:ok, _} =
      Accounts.update_preferences(user, %{
        "index_sort_mode" => mode,
        "index_sort_reverse_by_mode" => reverse_by_mode
      })

    if pushed_order != [], do: Initiatives.set_index_order(user, pushed_order)

    sort_state = %{
      mode: mode,
      reverse: reverse,
      order: if(pushed_order == [], do: socket.assigns.sort_state.order, else: pushed_order)
    }

    # Reply ok so the drag's drop-time optimistic reorder (WL3.5 Fix A) can settle.
    {:reply, %{ok: true},
     socket
     |> assign(:initiatives, reindex_order(socket.assigns.initiatives, pushed_order))
     |> assign(:sort_state, sort_state)
     |> assign(:reverse_by_mode, reverse_by_mode)
     |> restream_sorted()}
  end

  # Prune a past collaborator from My Collaborators (m02.05 item 12.11).
  # Trash (m02.06 item 10): owner-only restore / permanent delete.
  def handle_event("restore_initiative", %{"id" => id}, socket) do
    {:noreply,
     with_owned_trashed(socket, id, &Initiatives.restore_initiative/1, "Initiative restored.")}
  end

  def handle_event("purge_initiative", %{"id" => id}, socket) do
    {:noreply,
     with_owned_trashed(
       socket,
       id,
       &Initiatives.purge_initiative/1,
       "Initiative permanently deleted."
     )}
  end

  # Per-user Archived list (m02.08 worklist 4). Restore clears `archived_at`,
  # unhide clears `hidden_at` — both on the caller's own membership row only.
  def handle_event("unarchive_initiative", %{"id" => id}, socket) do
    {:noreply,
     with_member_initiative(
       socket,
       id,
       &Initiatives.unarchive_initiative/2,
       "Initiative restored."
     )}
  end

  def handle_event("unhide_initiative", %{"id" => id}, socket) do
    {:noreply,
     with_member_initiative(socket, id, &Initiatives.unhide_initiative/2, "Initiative unhidden.")}
  end

  # Show-hidden toggle: a plain, NON-persistent assign (m02.08 item 4.3).
  def handle_event("toggle_show_hidden", _params, socket) do
    {:noreply, assign(socket, :show_hidden, !socket.assigns.show_hidden)}
  end

  # Show-trash toggle: a plain, NON-persistent assign, same rationale as
  # show_hidden — every trashed Initiative is equally hidden by default, so
  # this reveal is all-or-nothing (unlike show_hidden's partial filter).
  def handle_event("toggle_show_trash", _params, socket) do
    {:noreply, assign(socket, :show_trash, !socket.assigns.show_trash)}
  end

  # Assigned-to-Me pane toggles (m02.08 item 1.3) — same handlers as the
  # standalone /assigned page, via the shared AssignedActions helper.
  def handle_event("assigned_toggle_completed", _params, socket) do
    {:noreply, AssignedActions.toggle_completed(socket, socket.assigns.current_user)}
  end

  def handle_event("assigned_toggle_archived_hidden", _params, socket) do
    {:noreply, AssignedActions.toggle_archived_hidden(socket, socket.assigns.current_user)}
  end

  def handle_event("assigned_toggle_group_by", _params, socket) do
    {:noreply, AssignedActions.toggle_group_by(socket, socket.assigns.current_user)}
  end

  # --- Detail (show) events --------------------------------------------------

  # Confirmation suppression (.03.01.11): the ConfirmSkips hook reads the
  # per-class skip flags from localStorage on mount and pushes them here.
  def handle_event("confirm_skips_loaded", %{"classes" => classes}, socket) do
    {:noreply, assign(socket, :confirm_skips, MapSet.new(classes))}
  end

  def handle_event("create_task", %{"title" => title} = params, socket) do
    user = socket.assigns.current_user
    initiative = socket.assigns.initiative

    if not socket.assigns.can_edit do
      {:noreply, socket |> put_flash(:error, "You don't have permission to add tasks.") |> bonk()}
    else
      # The form carries its own target (client-positioned, UX_GUARDRAILS
      # 6.5): empty parent_id = top level (a child of the system root);
      # after_id places the new task just after that sibling, else at top.
      parent_id = parse_id(params["parent_id"]) || initiative.root_task_id

      position =
        case parse_id(params["after_id"]) do
          nil -> 0
          id -> sibling_after_position(id)
        end

      attrs = %{
        "initiative_id" => initiative.id,
        "parent_id" => parent_id,
        "title" => title,
        "position" => position
      }

      # The client predicts the (only possible) create flip — a new incomplete
      # leaf landing under a complete parent reopens it (scenario 2) — from the
      # DOM and opens #move-flip-confirm itself (UX_GUARDRAILS 6.5), then re-sends
      # with confirmed: true on Proceed. Suppressed commits the same way. Either
      # path commits straight through; the preview_create gate below is the
      # authoritative backstop for a flip the client did NOT predict (stale DOM).
      cond do
        Map.get(params, "confirmed") == true or skip_confirm?(socket, "completion-flip") ->
          {:noreply, commit_create(socket, attrs)}

        true ->
          create_with_flip_check(socket, user, attrs, title)
      end
    end
  end

  # Selection is client-first (UX_GUARDRAILS 6.5): the highlight lives in the
  # DOM, this event only loads the Details pane.
  # Field focus (pill taps, Alt+P/W/A) is pure view state and happens
  # client-side — this event only loads pane data (.03.07.17).
  def handle_event("select_task", %{"id" => id}, socket) do
    # Guard against a stray/foreign id: @initiative must be open (never the list),
    # the id must parse to an in-range integer (a non-binary payload like a map, a
    # non-numeric, or an overflow id would otherwise raise), and the fetched task
    # must belong to THIS Initiative — a select replayed/queued against another
    # tree is a no-op.
    with %{id: iid} <- socket.assigns[:initiative],
         tid when not is_nil(tid) <- parse_id(id) do
      cond do
        # Pane already shows this task — nothing to load.
        socket.assigns.selected_task_id == tid ->
          {:noreply, socket}

        true ->
          case Tasks.get_task_with_relations(tid) do
            %Task{initiative_id: ^iid} = task ->
              {:noreply,
               socket
               |> assign(:selected_task_id, tid)
               |> assign_selected(task)
               |> assign(:comments, Tasks.list_comments(tid))
               |> assign(:activity, Tasks.list_task_activity(tid))
               |> update_presence(tid)}

            _ ->
              {:noreply, socket}
          end
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # Keyboard: P / A — step priority / assignee of the selected task.
  def handle_event("kbd_adjust", %{"field" => field, "dir" => dir} = params, socket)
      when field in ~w(priority assignee) and dir in ~w(up down) do
    case kbd_target(socket, params) do
      nil -> {:noreply, socket}
      task -> apply_kbd_adjust(socket, task, field, dir)
    end
  end

  # Opening / closing the initiative editor is pure VIEW STATE owned entirely by
  # the client (UX_GUARDRAILS 6.5): the pane is server-rendered hidden with
  # #initiative-form pre-populated, so DoitInitiativeEditor reveals/hides it with
  # no round trip. No server handler exists for the open/close — only the real
  # writes below (update_subtitle / update_initiative) touch the server.

  def handle_event("update_subtitle", %{"subtitle" => subtitle}, socket) do
    if not socket.assigns.can_edit do
      {:noreply,
       socket |> put_flash(:error, "You don't have permission to edit this initiative.") |> bonk()}
    else
      case Initiatives.update_subtitle(socket.assigns.initiative, subtitle) do
        {:ok, _root} ->
          # The field already shows the typed text, so the SAVE is the invisible
          # part (§6.7). Pulse a brief "Saved" tick beside the input so the
          # debounced write is acknowledged, not silent; plus a "Linked …" flash
          # when this save added/changed a `%`-reference (item 3.5).
          msg = ref_link_message(socket, socket.assigns.subtitle, subtitle)

          {:noreply,
           socket
           |> assign(:subtitle, Initiatives.subtitle(socket.assigns.initiative))
           |> maybe_flash_links(msg)
           |> push_event("subtitle-saved", %{})}

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  # Initiative delete (.03.07.18): the confirm dialog is client-rendered
  # (content is known at render); this event arrives only after the user
  # confirmed.
  def handle_event("delete_initiative", _params, socket) do
    if not socket.assigns.can_admin do
      {:noreply, put_flash(socket, :error, "Only the owner can delete this initiative.")}
    else
      {:noreply, commit_delete_initiative(socket)}
    end
  end

  # Per-user Archive (m02.08 worklist 4). Sets `archived_at` on the caller's own
  # membership row only. Item 4.2: confirm first ONLY when there's unfinished
  # work (a member's own incomplete assignments, or — as owner — any incomplete
  # task). The confirm opens CLIENT-SIDE (no round trip, UX_GUARDRAILS 6.5): the
  # owner case the client predicts from the DOM (any incomplete row); the member
  # case is caught here as a backstop. So commit when the client already
  # confirmed (confirmed:true) or no confirm is needed; otherwise reply
  # needs_confirm so the client opens the modal.
  def handle_event("archive_initiative", params, socket) do
    user = socket.assigns.current_user
    initiative = socket.assigns.initiative

    if Map.get(params, "confirmed") == true or
         not Initiatives.archive_needs_confirm?(user, initiative) do
      # Reply ok so the client can tell a commit-in-flight (latch + hold the
      # archive button) from the needs_confirm probe (open the modal). The
      # commit ends in push_navigate, which replaces the page and the latch.
      {:reply, %{ok: true}, commit_archive(socket)}
    else
      {:reply, %{needs_confirm: true}, socket}
    end
  end

  # Dismiss the archive-on-completion prompt (m02.08 item 4.1). Pure view
  # state; `prompted_archive?` stays true so it won't re-raise this session.
  def handle_event("dismiss_archive_prompt", _params, socket) do
    {:noreply, assign(socket, :show_archive_prompt, false)}
  end

  # Per-user Hide (m02.08 item 4.3): the lighter "off my dashboard" move. Sets
  # `hidden_at` on the caller's own row only; never confirms.
  def handle_event("hide_initiative", _params, socket) do
    {:ok, _} =
      Initiatives.hide_initiative(socket.assigns.current_user, socket.assigns.initiative)

    {:noreply,
     socket
     |> put_flash(:info, "Initiative hidden from your dashboard.")
     |> push_navigate(to: ~p"/initiatives")}
  end

  # Initiative Settings (.03.07.07): switch the progress calc, recompute the
  # whole initiative under the new mode, and tell members to full-reload.
  def handle_event("set_progress_calc", %{"calc" => calc}, socket)
      when calc in ~w(leaf_average single_level) do
    if not socket.assigns.can_edit do
      {:noreply, socket |> put_flash(:error, "You don't have permission.") |> bonk()}
    else
      case Initiatives.update_initiative(socket.assigns.initiative, %{"progress_calc" => calc}) do
        {:ok, updated} ->
          Tasks.recompute_initiative_progress(updated.id)
          Tasks.notify_tree_changed(updated.id, updated.root_task_id)

          {:noreply,
           socket
           |> assign(:initiative, updated)
           |> load_tree()
           |> refresh_selected()}

        {:error, cs} ->
          {:noreply,
           put_flash(socket, :error, "Couldn't change setting: #{summarize_errors(cs)}.")}
      end
    end
  end

  # m02.07 item 1.7.2: the per-Initiative task-index style. Display-only and
  # derived at render from sibling position, so persisting the style + assigning
  # the updated initiative re-labels the tree — no tree reload needed.
  def handle_event("set_index_style", %{"index_style" => style}, socket) do
    cond do
      not socket.assigns.can_edit ->
        {:noreply, socket |> put_flash(:error, "You don't have permission.") |> bonk()}

      not DoIt.Tasks.Index.valid_style?(style) ->
        {:noreply, put_flash(socket, :error, "Unknown numbering style.")}

      true ->
        case Initiatives.update_initiative(socket.assigns.initiative, %{"index_style" => style}) do
          {:ok, updated} ->
            {:noreply, assign(socket, :initiative, updated)}

          {:error, cs} ->
            {:noreply,
             put_flash(socket, :error, "Couldn't change setting: #{summarize_errors(cs)}.")}
        end
    end
  end

  # m02.05 item 12.6: owner-only — it's a permission policy. Re-notify the tree
  # so any viewer+ lead's edit-ability re-evaluates live for open views.
  def handle_event("set_viewer_plus", params, socket) do
    if not socket.assigns.can_admin do
      {:noreply, put_flash(socket, :error, "Only the owner can change this.")}
    else
      on = params["viewer_plus"] in ["true", "on"]

      case Initiatives.update_initiative(socket.assigns.initiative, %{"viewer_plus" => on}) do
        {:ok, updated} ->
          Tasks.notify_tree_changed(updated.id, updated.root_task_id)

          # Re-enable the checkbox + flash a "Saved" tick — the re-enable IS the
          # success ack for the in-flight signifier armed client-side (§6.7).
          # Sent via push_event because the box is inside a phx-change form (no
          # reply callback), and carries the persisted state so the box's
          # checked stays honest if the value was coerced.
          {:noreply,
           socket
           |> assign(:initiative, updated)
           |> load_tree()
           |> refresh_selected()
           |> push_event("viewer-plus-saved", %{on: updated.viewer_plus})}

        {:error, cs} ->
          {:noreply,
           put_flash(socket, :error, "Couldn't change setting: #{summarize_errors(cs)}.")}
      end
    end
  end

  def handle_event("update_initiative", %{"initiative" => params}, socket) do
    if not socket.assigns.can_edit do
      {:noreply,
       socket |> put_flash(:error, "You don't have permission to edit this initiative.") |> bonk()}
    else
      initiative = socket.assigns.initiative

      case Initiatives.update_initiative(initiative, params) do
        {:ok, updated} ->
          form = to_form(Initiatives.change_initiative(updated))
          msg = ref_link_message(socket, "#{initiative.description}", "#{updated.description}")

          {:noreply,
           socket
           |> assign(:initiative, updated)
           |> assign(:initiative_form, form)
           |> assign(:page_title, updated.name)
           |> maybe_flash_links(msg)}

        {:error, cs} ->
          {:noreply,
           socket
           |> assign(:initiative_form, to_form(cs, action: :validate))
           |> put_flash(:error, "Couldn't save: #{summarize_errors(cs)}.")}
      end
    end
  end

  def handle_event("close_task", _params, socket) do
    {:noreply, socket |> assign(:selected_task_id, nil) |> update_presence(nil)}
  end

  # Undo / redo (m02.06 items 4/5). The engine reverses the user's own newest
  # undoable event; we reload the tree for immediate feedback (the broadcast
  # reloads other members) and flash the outcome.
  # Reply (not noreply) so the client's pushEvent callback fires when the server
  # settles — that's what clears the in-flight latch + working state (item 15.9).
  def handle_event("undo", _params, socket), do: {:reply, %{}, do_undo_redo(socket, :undo)}
  def handle_event("redo", _params, socket), do: {:reply, %{}, do_undo_redo(socket, :redo)}

  # --- Co-assignees (m02.05 item 13) ---------------------------------------

  def handle_event("add_co_assignee", %{"user_id" => uid}, socket) when uid != "" do
    with_co(socket, fn task, user ->
      # Viewer+ may only add from the handed pool (item 12.6.3); an out-of-pool
      # add fails so the optimistic row reverts. Editors place anyone.
      case parse_id(uid) do
        nil ->
          {:error, :invalid}

        id ->
          if staff_pool_allows?(socket, uid),
            do: Tasks.add_co_assignee(task, user, id),
            else: {:error, :not_in_pool}
      end
    end)
  end

  def handle_event("add_co_assignee", _params, socket), do: {:noreply, socket}

  def handle_event("remove_co_assignee", %{"user-id" => uid}, socket) do
    with_co(socket, fn task, user ->
      case parse_id(uid) do
        nil -> {:error, :invalid}
        id -> Tasks.remove_co_assignee(task, user, id)
      end
    end)
  end

  def handle_event("move_co_assignee", %{"user-id" => uid, "dir" => dir}, socket)
      when dir in ~w(up down) do
    with_co(socket, fn task, user ->
      case parse_id(uid) do
        nil ->
          {:error, :invalid}

        id ->
          ids = Enum.map(Tasks.list_co_assignees(task.id), & &1.user_id)
          Tasks.reorder_co_assignees(task, user, shift(ids, id, dir))
      end
    end)
  end

  # Drag a member from the Members panel onto any task row (item 12.8): assign
  # them as PRIMARY when the task has none, else stack them as a CO-assignee —
  # never clobbering an existing primary. Validated per the *dropped* task:
  # editor/owner anywhere; a viewer+ only within a led subtree, from its pool.
  # Replies ok:bool so the drag's optimistic row settles (item 12.5).
  def handle_event("assign_member", %{"user-id" => uid, "task-id" => tid}, socket) do
    uid = parse_id(uid)

    task =
      case parse_id(tid) do
        nil -> nil
        id -> Tasks.get_task(id)
      end

    user = socket.assigns.current_user

    cond do
      is_nil(uid) or is_nil(task) or task.initiative_id != socket.assigns.initiative.id ->
        {:reply, %{ok: false}, socket}

      not member_id?(socket, uid) ->
        {:reply, %{ok: false}, socket}

      not assign_allowed?(socket, task, uid) ->
        {:reply, %{ok: false},
         socket |> put_flash(:error, assign_denied_message(socket, task, uid)) |> bonk()}

      # Already the primary, or already a co — nothing to stack.
      task.assignee_id == uid or co_assignee?(task.id, uid) ->
        {:reply, %{ok: false}, socket}

      is_nil(task.assignee_id) ->
        assign_result(
          socket,
          task,
          Tasks.update_task(task, user, %{"assignee_id" => to_string(uid)})
        )

      true ->
        assign_result(socket, task, Tasks.add_co_assignee(task, user, uid))
    end
  end

  def handle_event("update_task", %{"task" => params} = payload, socket) do
    task = update_task_target(socket, payload)
    user = socket.assigns.current_user

    cond do
      # Stale captured id + no live selection (e.g. the target was deleted before
      # the dead-window edit flushed) — nothing to apply to; a no-op is the honest
      # outcome (no crash, and an edit to a real task always lands via its id).
      is_nil(task) ->
        {:noreply, socket}

      socket.assigns.can_edit ->
        case Tasks.update_task(task, user, params) do
          {:ok, updated} ->
            msg =
              ref_link_message(
                socket,
                "#{task.title} #{task.description}",
                "#{updated.title} #{updated.description}"
              ) || "Saved."

            {:noreply, socket |> put_flash(:info, msg) |> patch_task(task.id)}

          {:error, cs} ->
            {:noreply, put_flash(socket, :error, "Couldn't save task: #{summarize_errors(cs)}.")}
        end

      # Viewer+ (item 12.6): a lead may move progress on the led subtree and set
      # a *descendant's* primary from the handed pool (item 12.6.3) — nothing
      # else. Build the allowed subset explicitly; never trust the posted keys.
      task && leads_task?(socket, task.id) ->
        allowed = viewer_allowed_params(socket, params)

        cond do
          allowed == %{} ->
            {:noreply, socket}

          true ->
            case Tasks.update_task(task, user, allowed) do
              {:ok, _} ->
                {:noreply, patch_task(socket, task.id)}

              {:error, cs} ->
                {:noreply, put_flash(socket, :error, "Couldn't save: #{summarize_errors(cs)}.")}
            end
        end

      true ->
        {:noreply, socket |> put_flash(:error, "You don't have permission.") |> bonk()}
    end
  end

  def handle_event("cascade_sort", params, socket) do
    if not socket.assigns.can_edit do
      {:noreply, socket |> put_flash(:error, "You don't have permission.") |> bonk()}
    else
      task = sort_target(socket, params)

      cond do
        # The client predicts the branch count from the DOM and opens the
        # confirm itself (UX_GUARDRAILS 6.5 — a client-known confirm never waits
        # on the network), then re-sends with confirmed: true on Proceed.
        # Suppressed ("don't ask again") commits the same way. The count gate
        # below is the authoritative backstop for a client that did NOT predict
        # (modal missing, stale DOM).
        Map.get(params, "confirmed") == true or skip_confirm?(socket, "cascade-sort") ->
          {:noreply, commit_cascade_sort(socket, task)}

        Tasks.count_descendant_branches(task.id) > 10 ->
          {:noreply,
           assign_pending(socket, %{
             kind: :cascade_sort,
             task_id: task.id,
             branch_count: Tasks.count_descendant_branches(task.id),
             affected: Tasks.count_descendants(task.id)
           })}

        true ->
          {:noreply, commit_cascade_sort(socket, task)}
      end
    end
  end

  def handle_event("set_sort", params, socket) do
    task = sort_target(socket, params)

    cond do
      not socket.assigns.can_edit ->
        {:noreply, socket |> put_flash(:error, "You don't have permission.") |> bonk()}

      is_nil(task) ->
        # No named target AND no pane task to fall back to — a stale client
        # replaying the sort form with empty values (seen on reconnect after
        # a server restart). Nothing to act on.
        {:noreply, socket}

      true ->
        user = socket.assigns.current_user

        mode =
          case params["mode"] do
            "" -> nil
            m -> m
          end

        reverse = params["reverse"] == "true"

        case Tasks.set_sort(task, user, mode, reverse) do
          {:ok, _updated} ->
            {:noreply, socket |> load_tree() |> refresh_selected()}

          {:error, cs} ->
            {:noreply,
             put_flash(socket, :error, "Couldn't change sort: #{summarize_errors(cs)}.")}
        end
    end
  end

  def handle_event("set_progress", %{"value" => value}, socket) do
    task = socket.assigns.selected_task

    if not (task && can_progress?(socket, task.id)) do
      {:noreply, socket}
    else
      user = socket.assigns.current_user

      case Tasks.update_task(task, user, %{"manual_progress" => value}) do
        {:ok, _} ->
          {:noreply, patch_task(socket, task.id)}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Invalid progress: #{summarize_errors(cs)}.")}
      end
    end
  end

  # Replies so the client's optimistic flip (.03.07.22) can settle: ok: false
  # reverts it, committed: true releases it to the patch.
  def handle_event("toggle_complete", %{"id" => id}, socket) do
    task_id = parse_id(id)

    cond do
      # Bad/absent id (or a valid id whose task was just deleted by a collaborator)
      # → reply ok:false so the client reverts its optimistic flip; never crash.
      is_nil(task_id) ->
        {:reply, %{ok: false}, socket}

      not can_progress?(socket, task_id) ->
        {:reply, %{ok: false},
         socket |> put_flash(:error, "You don't have permission.") |> bonk()}

      true ->
        case Tasks.get_task(task_id) do
          nil ->
            {:reply, %{ok: false}, socket}

          task ->
            case Tasks.toggle_complete(task, socket.assigns.current_user) do
              {:ok, _} ->
                {:reply, %{ok: true, committed: true}, patch_task(socket, task.id)}

              {:error, cs} ->
                {:reply, %{ok: false},
                 put_flash(socket, :error, "Couldn't toggle: #{summarize_errors(cs)}.")}
            end
        end
    end
  end

  # Branch checkbox (.03.01.11): confirm via the styled modal unless the
  # "branch completion changes" class is suppressed, in which case cascade now.
  def handle_event("cascade_complete", %{"id" => id}, socket),
    do: request_cascade(socket, parse_id(id), :cascade_complete)

  def handle_event("cascade_incomplete", %{"id" => id}, socket),
    do: request_cascade(socket, parse_id(id), :cascade_incomplete)

  def handle_event("add_comment", params, socket) do
    %{"comment" => %{"body" => body}} = params
    echo_id = params["echo_id"]
    task = socket.assigns.selected_task

    if not (task && can_progress?(socket, task.id)) do
      # Reply ok:false so the client pulls its optimistic bubble — a rejected
      # comment must not stand (MUST NOT LIE).
      {:reply, %{ok: false, echo_id: echo_id},
       socket |> put_flash(:error, "You don't have permission.") |> bonk()}
    else
      user = socket.assigns.current_user

      case Tasks.add_comment(task, user, body) do
        {:ok, comment} ->
          # A new comment has no prior refs, so any resolved `%` is newly linked.
          msg = ref_link_message(socket, "", body)

          {:reply, %{ok: true, echo_id: echo_id, id: comment.id},
           maybe_flash_links(refresh_selected(socket), msg)}

        {:error, _cs} ->
          {:reply, %{ok: false, echo_id: echo_id},
           put_flash(socket, :error, "Comment cannot be empty.")}
      end
    end
  end

  # Comment lifecycle (m02.08 worklist 3 item 2). Authorization is enforced in
  # the context (Tasks.edit_comment / delete_comment) — these handlers map the
  # result to a flash; the view guards (author-only controls) are convenience.

  # Save acknowledges instantly via the Save button's up-front latch (data-latch,
  # WL4.3 — fires at submit independent of connect, the connect-independent
  # stand-in for phx-disable-with) — a server-gated edit. The editor's open/close is
  # now client-owned (WL3 3.3, §6.5): the row statically renders BOTH the display
  # block and the author's edit form, and DoitState.commentEditId toggles which
  # shows at click. So the server no longer holds an `editing_comment_id` assign;
  # on a granted save it pushes "comment-saved" (handled in the TaskKeys hook) to
  # clear the client's open state, then refresh_selected re-renders the canonical
  # body. We deliberately do NOT optimistically rewrite the body — a faithful
  # rewrite would mean reconstructing markup, and the signifier already keeps the
  # initiator un-stranded honestly. CRUCIALLY, only the server-granted branches
  # ({:ok} / {:error, :not_found} — both terminal) push "comment-saved" to close
  # the editor; an :unauthorized or invalid-body result leaves the editor open
  # (no false success — §6 / optimistic-UI-must-not-lie).
  def handle_event("save_comment", %{"id" => id, "comment" => %{"body" => body}}, socket) do
    case parse_id(id) do
      # Bad/absent comment id — nothing to save; leave the editor open (no false
      # close), no crash.
      nil -> {:noreply, socket}
      cid -> do_save_comment(socket, cid, id, body)
    end
  end

  def handle_event("delete_comment", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case parse_id(id) do
      # Bad/absent comment id — nothing to delete; no-op, no crash.
      nil ->
        {:noreply, socket}

      cid ->
        case Tasks.delete_comment(cid, user) do
          {:ok, _comment} ->
            {:noreply, refresh_selected(socket)}

          {:error, :unauthorized} ->
            {:noreply, put_flash(socket, :error, "You can only delete your own comments.")}

          {:error, :not_found} ->
            {:noreply, refresh_selected(socket)}
        end
    end
  end

  # Live chat (m02.08 worklist 3 item 3.1): broadcast a message to everyone
  # currently viewing this Initiative. Nothing is persisted — the broadcast
  # fans out to each viewer's socket (including ours, via the subscription), so
  # there's a single append path in handle_info. Blank messages are dropped.
  #
  # When NO ONE else is viewing the Initiative right now, the message has no
  # reader: don't broadcast (nobody to receive). Instead sound the rejection
  # bonk and drop a dimmed "system" line into the sender's own log so the dead
  # end is visible IN the chat (not a toast) — operator was explicit on that.
  def handle_event("send_chat", params, socket) do
    body = String.trim(params["body"] || "")
    echo_id = params["echo_id"]
    user = socket.assigns.current_user

    cond do
      body == "" ->
        # Backstop: the hook already trims + guards empty. Reply ok:false so a
        # stray empty submit pulls any optimistic bubble (it must not stand).
        {:reply, %{ok: false}, socket}

      alone?(socket) ->
        system_msg = %{
          system: true,
          user_id: nil,
          body: "Nobody's here to read that yet — no one else is viewing this Initiative."
        }

        # No reader got it — the server's own dimmed system line is the honest
        # acknowledgement. Reply alone:true so the hook REMOVES its optimistic
        # "sent" bubble (MUST NOT LIE: don't leave a faked-sent bubble standing).
        {:reply, %{ok: false, alone: true}, socket |> append_chat(system_msg) |> bonk()}

      true ->
        msg = %{
          # Stamp the source Initiative so a receiver can drop a stale cross-
          # Initiative delivery (async PubSub can arrive after an A->B switch).
          initiative_id: socket.assigns.initiative.id,
          system: false,
          user_id: user.id,
          name: user.name,
          initials: initials(user),
          bg: avatar_bg(user),
          fg: avatar_fg(user),
          # Carry the sender's client nonce on the broadcast so the sender's own
          # hook can match + dedupe its optimistic echo when the real line lands.
          # Other viewers ignore echo_id.
          echo_id: echo_id,
          body: String.slice(body, 0, 2000),
          at: System.system_time(:second)
        }

        Phoenix.PubSub.broadcast(
          DoIt.PubSub,
          chat_topic(socket.assigns.initiative.id),
          {:chat_message, msg}
        )

        {:reply, %{ok: true}, socket}
    end
  end

  # Delete (.03.01.11, .03.07.15): the styled confirm is client-rendered and
  # client-decided — opening a dialog whose content is already in the DOM is
  # view state (UX_GUARDRAILS 6.5). This event arrives only after the user
  # confirmed; the row was already optimistically removed client-side.
  def handle_event("delete_task", %{"id" => id}, socket) do
    if not socket.assigns.can_edit do
      {:noreply, socket |> put_flash(:error, "You don't have permission.") |> bonk()}
    else
      {:noreply, commit_delete_task(socket, parse_id(id))}
    end
  end

  def handle_event("move_task", %{"task_id" => task_id} = params, socket) do
    cond do
      not socket.assigns.can_edit ->
        {:reply, %{ok: false, error: "forbidden"},
         socket |> put_flash(:error, "You don't have permission to move tasks.") |> bonk()}

      true ->
        # Both the moved task id and the destination parent id are client-supplied;
        # a bad/absent/just-deleted task replies ok:false (the drag reverts) instead
        # of crashing.
        case parse_id(task_id) do
          nil ->
            {:reply, %{ok: false, error: "not_found"}, socket}

          tid ->
            case Tasks.get_task(tid) do
              nil -> {:reply, %{ok: false, error: "not_found"}, socket}
              task -> do_move_task(socket, params, task)
            end
        end
    end
  end

  def handle_event("confirm_pending", params, socket) do
    pending = socket.assigns.pending_action
    socket = maybe_suppress(socket, pending, params)

    socket =
      case pending do
        %{kind: :move, task_id: task_id, attrs: attrs} ->
          # The held task may have been deleted by a collaborator while the confirm
          # sat open — resolve the modal without crashing.
          case Tasks.get_task(task_id) do
            nil ->
              assign_pending(socket, nil)

            task ->
              case commit_move(socket, task, attrs) do
                {:ok, socket} -> socket
                {:error, _reason, socket} -> socket
              end
          end

        %{kind: :create, attrs: attrs} ->
          commit_create(socket, attrs)

        %{kind: :cascade_sort, task_id: task_id} ->
          case Tasks.get_task(task_id) do
            nil -> assign_pending(socket, nil)
            task -> commit_cascade_sort(socket, task)
          end

        _ ->
          socket
      end

    # The modal is resolved either way; the client drops any held optimistic
    # state (a failed move commit already pushed "confirm-cancelled" to revert
    # it — that event lands first).
    {:noreply, push_event(socket, "confirm-resolved", %{})}
  end

  def handle_event("cancel_pending", _params, socket) do
    # The client may hold optimistic state for the pending op (a drag's
    # placement, §8.20) — announce the cancellation so it reverts. A create's
    # preview row is server-rendered, so drop it by reloading the tree.
    socket =
      case socket.assigns.pending_action do
        %{kind: :create} -> load_tree(socket)
        _ -> socket
      end

    {:noreply, socket |> assign_pending(nil) |> push_event("confirm-cancelled", %{})}
  end

  # Keyboard alternative for task reorganization (M02 Arc 3 item 6).
  # When a task is selected (Details panel open) and the user has edit rights,
  # Alt+↑/↓ reorder among siblings; Alt+←/→ dedent / indent.
  def handle_event("kbd_move", %{"key" => key, "altKey" => true} = params, socket)
      when key in ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"] do
    case kbd_target(socket, params) do
      nil -> {:noreply, socket}
      task -> do_kbd_move(key, task, socket)
    end
  end

  # Permissive fallthrough: ignore non-arrow keys, missing modifiers, etc.
  def handle_event("kbd_move", _params, socket), do: {:noreply, socket}

  # Ownership transfer (the "transfer first" path of §1.10's delete block).
  # The confirm opens + cancels entirely client-side (app.js, like the delete
  # confirms); only this commit touches the server, carrying the target id the
  # dialog stashed. Not suppressible — transferring ownership always asks.
  def handle_event("confirm_transfer", %{"user-id" => user_id}, socket) do
    initiative = socket.assigns.initiative
    user_id = parse_id(user_id)
    # A nil (malformed) id finds no member, so the `not is_nil(member)` guard below
    # routes it to the ok:false reply — never a crash.
    member = Enum.find(socket.assigns.members, &(&1.user_id == user_id))

    with true <- socket.assigns.can_admin and not is_nil(member),
         {:ok, updated} <- Initiatives.transfer_ownership(initiative, user_id) do
      role = Initiatives.get_role(updated.id, socket.assigns.current_user.id)

      # Reply ok so the client clears the Proceed working state + closes the
      # modal (item 15.16); the swap can't be optimistic, so the modal holds a
      # working state until this lands.
      {:reply, %{ok: true},
       socket
       |> assign(:initiative, updated)
       |> assign(:role, role)
       |> assign(:can_edit, Initiatives.can_edit?(role))
       |> assign(:can_admin, Initiatives.can_admin?(role))
       |> assign(:members, Initiatives.list_members(updated.id))
       |> put_flash(:info, "Ownership transferred to #{member.user.name}. You're now an editor.")}
    else
      _ ->
        {:reply, %{ok: false}, put_flash(socket, :error, "Couldn't transfer ownership.")}
    end
  end

  def handle_event("confirm_transfer", _params, socket),
    do: {:reply, %{ok: false}, socket}

  # Leave (m02.04-era pull-forward of BACKLOG's "Leave an initiative"):
  # remove your own membership. Always confirmed — only the owner can add
  # you back. The commit's members_changed broadcast ejects this view.
  # The confirm opens client-side (app.js, like the delete confirms); only this
  # commit touches the server. Leaving is server-confirmed — we reply ok so the
  # client's "Leaving…" state knows the commit landed (the members_changed
  # broadcast then ejects this view: handle_info → role nil → push_navigate). On
  # the rare refusal (ownership transferred to you a moment ago) ok:false lets
  # the client restore the confirm instead of spinning "Leaving…".
  def handle_event("leave_initiative", _params, socket) do
    me = socket.assigns.current_user.id

    if me == socket.assigns.initiative.owner_id do
      {:reply, %{ok: false},
       socket |> put_flash(:error, "Owners transfer ownership before leaving.") |> bonk()}
    else
      {_count, _} =
        Initiatives.remove_member(socket.assigns.initiative.id, me, socket.assigns.current_user)

      {:reply, %{ok: true}, socket}
    end
  end

  # The "Remove X?" confirm opens client-side (app.js, UX_GUARDRAILS 6.5 — the
  # name is client-known); only Proceed pushes here. A member holding
  # assignments still routes to the hand-off modal — its content (count + who to
  # reassign to) is server data, so that's a legitimate round trip — otherwise
  # commit the removal.
  # The confirm already opened client-side (#remove-member-confirm — the name is
  # client-known); only Proceed pushes here. Proceed holds a working state until
  # this replies (UX_GUARDRAILS 6.7 — the round trip can't be optimistic because
  # whether the member holds assignments is server-known). The reply releases
  # that working state: ok:true on a plain commit / forbidden / owner-guard,
  # ok:true + handoff:true when we escalate to the (server-data) hand-off modal,
  # ok:false on a refusal so the client restores Proceed.
  def handle_event("remove_member", %{"user-id" => user_id}, socket) do
    initiative = socket.assigns.initiative
    user_id = parse_id(user_id)

    cond do
      is_nil(user_id) ->
        {:reply, %{ok: false}, socket}

      not socket.assigns.can_admin ->
        {:reply, %{ok: false},
         socket |> put_flash(:error, "Only the owner can remove members.") |> bonk()}

      user_id == initiative.owner_id ->
        {:reply, %{ok: false},
         socket |> put_flash(:error, "The Initiative's owner can't be removed.") |> bonk()}

      Tasks.member_assignment_count(initiative.id, user_id) > 0 ->
        member = Enum.find(socket.assigns.members, &(&1.user_id == user_id))
        name = (member && member.user.name) || "this member"

        # The hand-off modal's body (count + who to reassign to) is server data,
        # so it renders server-side; the reply releases the client confirm the
        # instant this modal is up.
        {:reply, %{ok: true, handoff: true},
         assign(socket, :pending_handoff, %{
           user_id: user_id,
           name: name,
           count: Tasks.member_assignment_count(initiative.id, user_id),
           promote_default: initiative.auto_promote_co_assignees
         })}

      true ->
        {:reply, %{ok: true}, commit_remove_member(socket, user_id)}
    end
  end

  def handle_event("cancel_handoff", _params, socket) do
    {:noreply, assign(socket, :pending_handoff, nil)}
  end

  def handle_event("confirm_handoff", params, socket) do
    initiative = socket.assigns.initiative
    pending = socket.assigns.pending_handoff

    takeover_id = parse_id(params["takeover"])

    promote_co = params["promote_co"] in ["true", "on"]

    if socket.assigns.can_admin and pending do
      {:ok, _} =
        Tasks.handoff_member_assignments(
          initiative.id,
          socket.assigns.current_user,
          pending.user_id,
          takeover_id: takeover_id,
          promote_co: promote_co
        )

      {_n, _} =
        Initiatives.remove_member(initiative.id, pending.user_id, socket.assigns.current_user)

      {:noreply,
       socket
       |> assign(:pending_handoff, nil)
       |> assign(:members, Initiatives.list_members(initiative.id))
       |> refresh_rail_initiatives()
       |> put_flash(:info, "Removed #{pending.name}; their assignments were handed off.")
       |> load_tree()
       |> refresh_selected()}
    else
      {:noreply, assign(socket, :pending_handoff, nil)}
    end
  end

  def handle_event("update_member_role", %{"user_id" => uid, "role" => role}, socket) do
    initiative = socket.assigns.initiative
    uid = parse_id(uid)

    if not is_nil(uid) and socket.assigns.can_admin and uid != initiative.owner_id and
         role in ~w(editor viewer) do
      {:ok, _} =
        Initiatives.update_member_role(initiative.id, uid, role, socket.assigns.current_user)

      {:noreply,
       socket
       |> assign(:members, Initiatives.list_members(initiative.id))
       |> refresh_rail_initiatives()
       |> put_flash(:info, "Role updated.")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_member", %{"member" => member, "role" => role}, socket) do
    if not socket.assigns.can_admin do
      {:noreply, put_flash(socket, :error, "Only the owner can add members.")}
    else
      initiative = socket.assigns.initiative
      # Email or username, with or without the @ (usernames can't contain
      # one, so stripping a leading @ is unambiguous).
      login = member |> String.trim() |> String.trim_leading("@")

      case Accounts.get_user_by_email_or_username(login) do
        nil ->
          {:noreply, put_flash(socket, :error, "No user with that email or username.")}

        user ->
          case Initiatives.add_member(initiative.id, user.id, role, socket.assigns.current_user) do
            {:ok, _} ->
              # Close the add-member form on success (it opened client-side via a
              # data-keep="open" <details>); close-details collapses it AND evicts
              # its preserved open-state so the preserve path can't re-open it on
              # the members re-render patch. Both panels share this submit, so
              # close whichever is mounted (desktop / mobile).
              {:noreply,
               socket
               |> put_flash(:info, "Added #{user.name}.")
               |> assign(:members, Initiatives.list_members(initiative.id))
               |> refresh_rail_initiatives()
               |> push_event("close-details", %{id: "members-desktop-form"})
               |> push_event("close-details", %{id: "members-mobile-form"})}

            {:error, cs} ->
              {:noreply,
               put_flash(socket, :error, "Couldn't add member: #{summarize_errors(cs)}.")}
          end
      end
    end
  end

  # Add a collaborator as a viewer (m02.05 items 9 + 10) — the menu's "Add"
  # targets the current Initiative; a drag-drop targets whichever rail entry it
  # landed on. Both route through the same permission-checked context call; the
  # role is bumped afterward in that Initiative's Members panel. Removal reuses
  # "remove_member" (with its hand-off flow).
  def handle_event("add_collaborator_to", %{"user-id" => uid, "initiative-id" => iid}, socket) do
    user = socket.assigns.current_user

    # Both ids are client-supplied; a malformed either-side no-ops with ok:false so
    # the optimistic rail chip is pulled (MUST NOT LIE) rather than crashing.
    case {parse_id(iid), parse_id(uid)} do
      {nil, _} -> {:reply, %{ok: false}, socket}
      {_, nil} -> {:reply, %{ok: false}, socket}
      {iid, uid} -> do_add_collaborator_to(socket, user, iid, uid)
    end
  end

  # Prune a past collaborator from My Collaborators (m02.05 item 12.11). Only
  # offered for someone with no current shared Initiative; the context re-guards
  # that and removes just this user's own edge.
  def handle_event("remove_collaborator", %{"user-id" => uid}, socket) do
    user = socket.assigns.current_user

    case parse_id(uid) do
      # Malformed id — un-hide the optimistically-removed row (ok:false), no crash.
      nil ->
        {:reply, %{ok: false}, socket}

      cid ->
        {ok?, socket} =
          case Initiatives.remove_collaborator(user, cid) do
            {:ok, _} ->
              {true,
               socket
               |> assign(:rail_collaborators, Initiatives.list_collaborators(user))
               |> refresh_rail_initiatives()}

            # Still sharing an Initiative → the row stays; ok:false un-hides the
            # optimistically-removed rail row (MUST NOT LIE — they weren't pruned).
            {:error, :still_collaborating} ->
              {false, put_flash(socket, :error, "You still share an Initiative with them.")}
          end

        {:reply, %{ok: ok?}, socket}
    end
  end

  # --- Detail-event helpers (kept out of the handle_event clause group) ------

  defp do_save_comment(socket, cid, id, body) do
    user = socket.assigns.current_user

    old_body =
      case Tasks.get_comment(cid) do
        %{body: b} -> b
        _ -> ""
      end

    case Tasks.edit_comment(cid, user, body) do
      {:ok, _comment} ->
        msg = ref_link_message(socket, old_body, body)

        {:noreply,
         socket |> push_event("comment-saved", %{id: id}) |> refresh_selected() |> maybe_flash_links(msg)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You can only edit your own comments.")}

      {:error, :not_found} ->
        {:noreply, socket |> push_event("comment-saved", %{id: id}) |> refresh_selected()}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Comment cannot be empty.")}
    end
  end

  defp do_move_task(socket, params, task) do
    user = socket.assigns.current_user

    attrs = %{
      # A root-zone drop (promotion) carries no parent → it lands under the
      # Initiative's root task, the new meaning of "root level". A malformed
      # parent id falls back the same way rather than crashing the move.
      "parent_id" =>
        parse_id(Map.get(params, "parent_id")) || socket.assigns.initiative.root_task_id,
      "position" => Map.get(params, "position"),
      "reorder" => Map.get(params, "reorder")
    }

    case Tasks.preview_move(task, user, attrs) do
      {:ok, %{scenario: nil}} ->
        case commit_move(socket, task, attrs) do
          {:ok, socket} ->
            {:reply, %{ok: true, committed: true}, socket}

          {:error, reason, socket} ->
            {:reply, %{ok: false, error: format_move_error(reason)}, socket}
        end

      {:ok, %{scenario: scenario, titles: titles, ids: flip_ids}} ->
        # The client predicts the flip from the DOM and opens the confirm itself
        # (UX_GUARDRAILS 6.5 — a client-known confirm never waits on the network),
        # then re-sends with confirmed: true on Proceed. Suppressed ("don't ask
        # again") commits the same way. Either path commits straight through; the
        # gate below is the authoritative backstop for a move the client did NOT
        # predict as a flip.
        if Map.get(params, "confirmed") == true or skip_confirm?(socket, "completion-flip") do
          case commit_move(socket, task, attrs) do
            {:ok, socket} ->
              {:reply, %{ok: true, committed: true}, socket}

            {:error, reason, socket} ->
              {:reply, %{ok: false, error: format_move_error(reason)}, socket}
          end
        else
          # A completion-flip confirmation is required: the move is NOT yet
          # persisted, but the client KEEPS its optimistic placement while the
          # modal decides (§8.20 — confirmations must not undo optimism).
          # committed: false tells it to hold a revert handle: Cancel / a failed
          # Proceed reverts via "confirm-cancelled"; a Proceed commit re-renders
          # the same placement.
          {:reply, %{ok: true, committed: false},
           assign_pending(socket, %{
             kind: :move,
             task_id: task.id,
             attrs: attrs,
             scenario: scenario,
             titles: titles,
             flip_ids: flip_ids
           })}
        end

      {:error, reason} ->
        {:reply, %{ok: false, error: format_move_error(reason)},
         put_flash(socket, :error, "Couldn't move task: #{format_move_error(reason)}.")}
    end
  end

  defp do_add_collaborator_to(socket, user, iid, uid) do
    {ok?, socket} =
      case Initiatives.add_collaborator_as_viewer(user, iid, uid) do
        {:ok, added} ->
          {true, put_flash(socket, :info, "Added #{added.name} as a viewer.")}

        # Already a member → the real row is already present; treat the optimistic
        # chip as not-needed (ok:false pulls the dimmed stand-in; the flash is
        # informational, no lie left behind).
        {:error, :already_member} ->
          {false, put_flash(socket, :info, "They're already a member there.")}

        {:error, :forbidden} ->
          {false, put_flash(socket, :error, "Only that Initiative's owner can add members.")}

        {:error, :failed} ->
          {false, put_flash(socket, :error, "Couldn't add them.")}
      end

    # Refresh the collaborators pane AND the rail initiatives (their member-
    # avatar rows) so the server render carries the real avatar after the add —
    # otherwise the optimistic rail chip (WL3.5 Fix B) would be pulled on the
    # reply with nothing to replace it (a lie). The rail uses @initiatives in
    # both list and detail modes.
    socket =
      socket
      |> assign(:rail_collaborators, Initiatives.list_collaborators(user))
      |> refresh_rail_initiatives()

    # Only refresh members when the add landed on the currently-open Initiative
    # (detail mode). In list mode @initiative is nil, so guard it.
    socket =
      if socket.assigns.initiative && iid == socket.assigns.initiative.id,
        do: assign(socket, :members, Initiatives.list_members(iid)),
        else: socket

    {:reply, %{ok: ok?}, socket}
  end

  # --- Pending-action commits -----------------------------------------------

  # The authoritative completion-flip backstop for create: only reached when the
  # client did NOT predict the flip (or the modal was missing). No flip → commit
  # straight through; a flip the client missed → splice the preview row and raise
  # the server @pending_action confirm (#completion-confirm).
  defp create_with_flip_check(socket, user, attrs, title) do
    initiative = socket.assigns.initiative

    case Tasks.preview_create(user, attrs) do
      {:ok, %{scenario: nil}} ->
        {:noreply, commit_create(socket, attrs)}

      {:ok, %{scenario: scenario, titles: titles, ids: flip_ids}} ->
        # Optimism (§8.20, parity with a held move): the task must SHOW UP before
        # the confirm decides. Splice a preview row into the tree at the target,
        # marked maybe-write (pink) via pending_saving_ids; confirm → real create
        # + load_tree replaces it, cancel → reload drops it.
        preview = preview_task(title)

        {:noreply,
         socket
         |> assign(
           :tree,
           splice_preview(
             socket.assigns.tree,
             initiative.root_task_id,
             attrs["parent_id"],
             attrs["position"],
             preview
           )
         )
         |> assign_pending(%{
           kind: :create,
           attrs: attrs,
           scenario: scenario,
           titles: titles,
           flip_ids: flip_ids,
           preview_id: preview.id
         })}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, "Couldn't create task: #{summarize_errors(cs)}.")}
    end
  end

  defp commit_create(socket, attrs) do
    case Tasks.create_task(socket.assigns.current_user, attrs) do
      {:ok, _task} ->
        socket
        |> assign_pending(nil)
        |> put_flash(:info, "Task added.")
        |> load_tree()

      {:error, cs} ->
        socket
        |> assign_pending(nil)
        |> put_flash(:error, "Couldn't create task: #{summarize_errors(cs)}.")
    end
  end

  # An optimistic, un-persisted leaf for the create-confirm hold. Sentinel id
  # 0 (no real task collides); renders as a plain 0% leaf via task_node.
  defp preview_task(title) do
    %Task{
      id: 0,
      title: title,
      description: nil,
      status: "open",
      priority: "normal",
      manual_progress: 0,
      computed_progress: 0,
      sort_order: 0,
      sort_mode: nil,
      sort_reverse: false,
      assignee_id: nil,
      assignee: nil,
      children: []
    }
  end

  # Splice the preview leaf into the rendered tree at the create's target.
  # parent == the system root means top level; otherwise find the parent
  # branch anywhere in the tree and insert among its children.
  defp splice_preview(tree, root_task_id, root_task_id, position, preview),
    do: List.insert_at(tree, position || -1, preview)

  defp splice_preview(tree, _root_task_id, parent_id, position, preview) do
    Enum.map(tree, fn node ->
      if node.id == parent_id do
        %{node | children: List.insert_at(node.children, position || -1, preview)}
      else
        %{node | children: splice_preview(node.children, nil, parent_id, position, preview)}
      end
    end)
  end

  defp commit_cascade_sort(socket, task) do
    user = socket.assigns.current_user

    case Tasks.cascade_sort(task, user) do
      {:ok, %{branch_count: n}} ->
        socket
        |> assign_pending(nil)
        |> put_flash(:info, "#{n} descendant branch(es) now inherit this sort.")
        |> load_tree()
        |> refresh_selected()

      {:error, _reason} ->
        socket
        |> assign_pending(nil)
        |> put_flash(:error, "Couldn't update descendants.")
    end
  end

  # Branch checkbox: the "complete / reopen this branch and all subtasks?"
  # confirm now opens CLIENT-SIDE (app.js #cascade-confirm, UX_GUARDRAILS
  # 6.5/6.6) — its content (task title + verb) is client-known, so it never
  # waits on the network, and the client holds the optimistic flip while it
  # decides. This event arrives only when the cascade should COMMIT (skip
  # suppressed, or the user Proceeded); we just write it. Permission is the
  # authoritative backstop. Reply mirrors move_task: ok:true + committed:true
  # releases the held flip; ok:false reverts it.
  # `id` is nil for a bad/absent client id (parse_id rejected it) — reply ok:false
  # so the held optimistic flip reverts, never crash.
  defp request_cascade(socket, nil, _kind), do: {:reply, %{ok: false}, socket}

  defp request_cascade(socket, id, kind) do
    if not can_progress?(socket, id) do
      {:reply, %{ok: false}, socket |> put_flash(:error, "You don't have permission.") |> bonk()}
    else
      case commit_cascade(socket, id, kind) do
        {:ok, socket} -> {:reply, %{ok: true, committed: true}, socket}
        {:error, socket} -> {:reply, %{ok: false}, socket}
      end
    end
  end

  defp commit_cascade(socket, id, kind) do
    user = socket.assigns.current_user

    result =
      case Tasks.get_task(id) do
        # Just-deleted under us (real-time collab) — nothing to cascade.
        nil -> {:error, :not_found}
        task when kind == :cascade_complete -> Tasks.cascade_complete(task, user)
        task -> Tasks.cascade_incomplete(task, user)
      end

    case result do
      {:error, :not_found} ->
        {:error, assign_pending(socket, nil)}

      {:ok, _} ->
        {:ok, socket |> assign_pending(nil) |> load_tree() |> refresh_selected()}

      {:error, cs} ->
        # The {:error, socket} reply carries ok:false — the client reverts the
        # held optimistic flip from there (revertPendingToggle). No event needed.
        {:error,
         socket
         |> assign_pending(nil)
         |> put_flash(:error, "Couldn't cascade: #{summarize_errors(cs)}.")}
    end
  end

  # A bad/absent id, or one whose task a collaborator already deleted, is a no-op
  # (the row was optimistically removed client-side; the tree reload reconciles).
  defp commit_delete_task(socket, nil), do: socket

  defp commit_delete_task(socket, id) do
    case Tasks.get_task(id) do
      nil ->
        socket

      task ->
        case Tasks.delete_task(task, socket.assigns.current_user) do
          {:ok, _} ->
            socket
            |> assign_pending(nil)
            |> assign(:selected_task_id, nil)
            |> assign(:selected_task, nil)
            |> put_flash(:info, "Task deleted.")
            |> load_tree()

          {:error, cs} ->
            socket
            |> assign_pending(nil)
            |> put_flash(:error, "Couldn't delete task: #{summarize_errors(cs)}.")
        end
    end
  end

  defp commit_delete_initiative(socket) do
    # Trash, not hard-delete (m02.06 item 10): the owner can restore it from the
    # Trash on the index, or purge it permanently there.
    {:ok, _} = Initiatives.trash_initiative(socket.assigns.initiative)

    socket
    |> put_flash(:info, "Initiative moved to Trash.")
    |> push_navigate(to: ~p"/initiatives")
  end

  # Per-user archive (m02.08 worklist 4): set archived_at on the caller's own
  # membership row, then send them to the index where it now sits in their
  # Archived list (restorable). Resolves any pending confirm first.
  defp commit_archive(socket) do
    {:ok, _} =
      Initiatives.archive_initiative(socket.assigns.current_user, socket.assigns.initiative)

    socket
    |> assign_pending(nil)
    |> put_flash(:info, "Initiative archived. Restore it anytime from your Archived list.")
    |> push_navigate(to: ~p"/initiatives")
  end

  # If "Don't show this again" was checked, remember the class server-side and
  # tell the client to persist it to localStorage.
  defp maybe_suppress(socket, pending, params) do
    class = pending && confirm_class(pending)

    if class && params["dont_show"] in ["true", "on"] do
      socket
      |> assign(:confirm_skips, MapSet.put(socket.assigns.confirm_skips, class))
      |> push_event("persist-confirm-skip", %{class: class})
    else
      socket
    end
  end

  # Re-attach the rail's member-avatar data. @initiatives drives the left rail in
  # both list and detail modes (rail_initiatives={@initiatives}), and each entry
  # carries its members for the WL3.5 avatar row. A membership change on the open
  # Initiative — a local add/remove/role change OR a :members_changed broadcast —
  # must refresh this so the left-column avatars reflect the change live, without
  # a manual refresh. One re-query re-attaches every entry's avatars (no N+1).
  defp refresh_rail_initiatives(socket) do
    assign(
      socket,
      :initiatives,
      Initiatives.list_visible_initiatives(socket.assigns.current_user)
    )
  end

  defp commit_remove_member(socket, user_id) do
    initiative = socket.assigns.initiative
    member = Enum.find(socket.assigns.members, &(&1.user_id == user_id))
    {_count, _} = Initiatives.remove_member(initiative.id, user_id, socket.assigns.current_user)

    socket
    |> assign_pending(nil)
    |> put_flash(:info, "Removed #{(member && member.user.name) || "member"}.")
    |> assign(:members, Initiatives.list_members(initiative.id))
    |> refresh_rail_initiatives()
  end

  defp commit_move(socket, task, attrs) do
    user = socket.assigns.current_user

    case Tasks.move_task(task, user, attrs) do
      {:ok, _moved} ->
        {:ok,
         socket
         |> assign_pending(nil)
         |> load_tree()
         |> refresh_selected()}

      {:error, reason} ->
        {:error, reason,
         socket
         |> assign_pending(nil)
         # A client may be holding the optimistic placement from a confirmed
         # drag — the move died, so revert it.
         |> push_event("confirm-cancelled", %{})
         |> put_flash(:error, "Couldn't move task: #{format_move_error(reason)}.")}
    end
  end

  # --- PubSub ---------------------------------------------------------------

  # Deferred non-critical loads (see mount): the tree already painted and the
  # page is interactive, so fill in the undo/redo toolbar labels and the
  # cross-Initiative Collaborators rail now. Cheap, idempotent, and safe to run
  # after any number of intervening renders — it touches only these assigns and
  # never the tree or the client-owned selection / editor view state.
  @impl true
  def handle_info(:after_mount, socket) do
    # Guard the undo/redo labels on still being in a detail: the user may have
    # patched back to the list (clearing @initiative) before this deferred load
    # ran. The collaborators rail is shell-level, so always refresh it.
    socket = if socket.assigns.initiative, do: assign_undo_state(socket), else: socket

    {:noreply,
     assign(
       socket,
       :rail_collaborators,
       Initiatives.list_collaborators(socket.assigns.current_user)
     )}
  end

  # A global presence join/leave (item 8): just refresh the Collaborators
  # pane's online set. Matched first (topic is DoItWeb.Presence.global_topic/0;
  # literal here since guards can't call it) so the per-initiative head below
  # only handles the initiative topic.
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: "presence:online"},
        socket
      ) do
    {:noreply, assign(socket, :collaborator_online_ids, DoItWeb.Presence.global_online_ids())}
  end

  # A presence join/leave/move anywhere in the initiative: push the full
  # selection list to this client (the PresenceBadges hook redraws rows) and
  # refresh who's-here for the server-rendered online dots. Guarded against a
  # stray in-flight diff arriving after we left the detail (@initiative nil).
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    if socket.assigns.initiative do
      {:noreply,
       socket
       |> assign(:online_ids, online_ids(socket.assigns.initiative.id))
       |> push_presence()}
    else
      {:noreply, socket}
    end
  end

  # Membership changed somewhere in this initiative: re-check OUR role —
  # removed means ejected on the spot, not at the next refresh; a role change
  # (e.g. an ownership transfer) re-renders the right controls live. A stray
  # in-flight message after leaving the detail (@initiative nil) is ignored.
  def handle_info({:members_changed, _initiative_id}, socket) do
    cond do
      is_nil(socket.assigns.initiative) ->
        {:noreply, socket}

      true ->
        initiative = Initiatives.get_initiative(socket.assigns.initiative.id)
        role = initiative && Initiatives.get_role(initiative.id, socket.assigns.current_user.id)

        if role do
          {:noreply,
           socket
           |> assign(:initiative, initiative)
           |> assign(:role, role)
           |> assign(:can_edit, Initiatives.can_edit?(role))
           |> assign(:can_admin, Initiatives.can_admin?(role))
           |> assign(:members, Initiatives.list_members(initiative.id))
           # Another user's add/remove/role change on this Initiative: refresh the
           # rail entry's member-avatar row so the left-column avatars update live.
           |> refresh_rail_initiatives()
           # A removal here may drop the last Initiative shared with someone, so
           # refresh the Collaborators pane too (item 9).
           |> assign(
             :rail_collaborators,
             Initiatives.list_collaborators(socket.assigns.current_user)
           )}
        else
          {:noreply,
           socket
           |> put_flash(:info, "You're no longer a member of that Initiative.")
           |> push_navigate(to: ~p"/initiatives")}
        end
    end
  end

  # Task-tree broadcasts are guarded against a stray in-flight delivery after we
  # unsubscribed on leave/switch: @initiative nil → ignore (the list isn't a
  # tree), AND a message whose task belongs to a DIFFERENT Initiative is dropped.
  # PubSub delivery is async, so a broadcast for the just-left Initiative A can
  # already be enqueued before teardown_detail unsubscribed and still arrive after
  # we switched to B — patching A's lineage into B's tree. own_task_broadcast?/2
  # confirms the task is ours before we touch the tree (see its note for why a
  # gone task falls through to the harmless reload path).
  def handle_info({:task_created, id}, socket),
    do: {:noreply, if(own_task_broadcast?(socket, id), do: load_tree(socket), else: socket)}

  def handle_info({:task_updated, id}, socket),
    do: {:noreply, if(own_task_broadcast?(socket, id), do: patch_task(socket, id), else: socket)}

  def handle_info({:task_deleted, id}, socket),
    do:
      {:noreply,
       if(own_task_broadcast?(socket, id),
         do: socket |> load_tree() |> refresh_selected(),
         else: socket
       )}

  # A comment landed in the Initiative (item 14.3): refresh the pane only for a
  # viewer who has that task open, so the comment appears live for them without
  # every other viewer needlessly reloading their own selected pane. In list mode
  # selected_task_id is nil, so this is a safe no-op there.
  def handle_info({:comment_added, task_id}, socket) do
    if socket.assigns.selected_task_id == task_id,
      do: {:noreply, refresh_selected(socket)},
      else: {:noreply, socket}
  end

  # An author edited or deleted a comment (m02.08 worklist 3 item 2.2/2.3):
  # refresh the pane live for any viewer who has that task open, like a new
  # comment landing.
  def handle_info({:comment_changed, task_id}, socket) do
    if socket.assigns.selected_task_id == task_id,
      do: {:noreply, refresh_selected(socket)},
      else: {:noreply, socket}
  end

  # Live chat (item 3.1): a message arrived for this Initiative. Append to the
  # capped in-socket list (oldest dropped past @chat_cap) and bump a monotonic
  # id the template uses as a stable key + autoscroll trigger. Ephemeral — only
  # ever held here, never written. Ignored when not in a detail (stray delivery).
  def handle_info({:chat_message, msg}, socket) do
    case socket.assigns[:initiative] do
      %{id: iid} ->
        # PubSub delivery is async: a chat broadcast for the just-left Initiative A
        # can already be enqueued before teardown_detail unsubscribed and still
        # arrive after we switched to B (own_task_broadcast?/2 covers the task
        # topics; this is the chat-topic equivalent). Drop a message not stamped for
        # the open Initiative — and any message while in list mode (@initiative nil)
        # — so A's chat can't leak into B.
        if Map.get(msg, :initiative_id) == iid,
          do: {:noreply, append_chat(socket, msg)},
          else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:task_moved, id}, socket),
    do:
      {:noreply,
       if(own_task_broadcast?(socket, id),
         do: socket |> load_tree() |> refresh_selected(),
         else: socket
       )}

  # True only when a task-tree broadcast's task belongs to the Initiative now
  # open. @initiative nil (list mode) is always false. A task that POSITIVELY
  # belongs to another Initiative is dropped; a task we can't find (nil — e.g. a
  # create immediately undone) falls through to true so the existing reload path
  # still runs, which is harmless (load_tree always loads the CURRENT tree). The
  # task row is fetched even when soft-deleted (Repo.get ignores deleted_at), so
  # a {:task_deleted} for a foreign Initiative is still correctly rejected.
  defp own_task_broadcast?(socket, task_id) do
    case socket.assigns[:initiative] do
      %{id: iid} ->
        case Tasks.get_task(task_id) do
          %Task{initiative_id: other} when other != iid -> false
          _ -> true
        end

      _ ->
        false
    end
  end

  # Whether the sender is the only viewer of this Initiative right now. The
  # per-Initiative presence set (@online_ids, kept fresh on every presence_diff)
  # minus the sender — empty means there's no one to read a chat message.
  defp alone?(socket),
    do: MapSet.delete(socket.assigns.online_ids, socket.assigns.current_user.id) |> Enum.empty?()

  # Append one message to this viewer's own ephemeral log (capped), bumping the
  # monotonic chat-log id the template keys on. Shared by the broadcast path
  # (handle_info) and the alone-case system line.
  defp append_chat(socket, msg) do
    next_id = socket.assigns.chat_log_id + 1
    entry = Map.put(msg, :id, next_id)
    messages = Enum.take([entry | socket.assigns.chat_messages], @chat_cap)

    socket
    |> assign(:chat_messages, messages)
    |> assign(:chat_log_id, next_id)
  end

  # --- Index (list) helpers --------------------------------------------------

  # The saved manual order as an id list, derived from the membership rows'
  # sort_order — feeds the same order-list sorting the drag push uses.
  defp stored_order(initiatives) do
    initiatives
    |> Enum.filter(& &1.my_sort_order)
    |> Enum.sort_by(& &1.my_sort_order)
    |> Enum.map(&to_string(&1.id))
  end

  # Keep the in-memory my_sort_order in step with a freshly pushed order, so
  # re-renders (and the cards' data-my-order) reflect what was just saved.
  defp reindex_order(initiatives, []), do: initiatives

  defp reindex_order(initiatives, order) do
    idx = order |> Enum.with_index() |> Map.new(fn {id, i} -> {to_string(id), i} end)

    Enum.map(initiatives, fn it ->
      %{it | my_sort_order: Map.get(idx, to_string(it.id), it.my_sort_order)}
    end)
  end

  defp restream_sorted(socket) do
    sorted = sort_initiatives(socket.assigns.initiatives, socket.assigns.sort_state)
    stream(socket, :initiatives, sorted, reset: true)
  end

  defp normalize_mode(mode) when mode in @sort_modes, do: mode
  defp normalize_mode(_), do: nil

  defp sort_initiatives(list, %{mode: nil, reverse: reverse}), do: maybe_reverse(list, reverse)

  defp sort_initiatives(list, %{mode: "manual", order: order, reverse: reverse}) do
    idx = order |> Enum.with_index() |> Map.new(fn {id, i} -> {to_string(id), i} end)

    list
    |> Enum.sort_by(fn it -> Map.get(idx, to_string(it.id), length(order)) end)
    |> maybe_reverse(reverse)
  end

  defp sort_initiatives(list, %{mode: mode, reverse: reverse}) do
    list |> Enum.sort_by(&index_sort_key(&1, mode), index_sorter(mode)) |> maybe_reverse(reverse)
  end

  defp index_sort_key(i, "name"), do: String.downcase(i.name || "")
  defp index_sort_key(i, "progress"), do: i.progress || 0
  defp index_sort_key(i, "created"), do: i.inserted_at
  defp index_sort_key(i, "updated"), do: i.updated_at

  defp index_sorter(mode) when mode in ~w(created updated), do: DateTime
  defp index_sorter(_), do: :asc

  defp maybe_reverse(list, true), do: Enum.reverse(list)
  defp maybe_reverse(list, _), do: list

  # The Initiative's subtitle (root task title) for the card, or nil when blank
  # (stored as a single space). nil hides the row via `:if`.
  defp subtitle_text(%{subtitle: s}) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp subtitle_text(_), do: nil

  defp build_empty_form do
    to_form(Initiatives.change_initiative(%DoIt.Initiatives.Initiative{}))
  end

  # The Archived-list rows to show (m02.08 item 4.3): archived items always; a
  # purely-hidden item only when Show-hidden is checked.
  defp visible_archived(archived, show_hidden) do
    Enum.filter(archived, fn a -> a.archived? or (a.hidden? and show_hidden) end)
  end

  # The merged Archive/Trash drawer's summary title (m03.01 item 5.3): each
  # bucket contributes its own "Name (count)" segment, only when non-empty —
  # "Trash" never appears in the title while there's nothing trashed. The
  # Archived count still reacts to Show-hidden; Trash's count is the honest
  # total regardless of show_trash — only the detail rows are gated behind it.
  defp archive_drawer_title(archived, show_hidden, trashed) do
    [
      archived != [] && "Archived (#{length(visible_archived(archived, show_hidden))})",
      trashed != [] && "Trash (#{length(trashed)})"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # Owner-gated Trash action (m02.06 item 10): apply `fun` to the named trashed
  # Initiative the current user owns, then refresh both the Trash list and the
  # live index stream (a restore reappears there).
  defp with_owned_trashed(socket, id, fun, msg) do
    user = socket.assigns.current_user
    initiative = fetch_initiative(id)

    if initiative && initiative.owner_id == user.id && initiative.trashed_at do
      {:ok, _} = fun.(initiative)
      visible = Initiatives.list_visible_initiatives(user)

      socket
      |> assign(:trashed, Initiatives.list_trashed_initiatives(user))
      |> assign(:initiatives, visible)
      |> assign(:initiative_count, length(visible))
      |> stream(:initiatives, sort_initiatives(visible, socket.assigns.sort_state), reset: true)
      |> put_flash(:info, msg)
    else
      put_flash(socket, :error, "Couldn't find that Initiative in your Trash.")
    end
  end

  # Per-user restore/unhide (m02.08 worklist 4): apply `fun` to the named
  # Initiative the current user is a member of, then refresh the active index
  # stream and the Archived list. Scoped to the caller's own membership row.
  defp with_member_initiative(socket, id, fun, msg) do
    user = socket.assigns.current_user
    initiative = fetch_initiative(id)

    if initiative && Initiatives.get_role(initiative.id, user.id) do
      {:ok, _} = fun.(user, initiative)
      visible = Initiatives.list_visible_initiatives(user)

      socket
      |> assign(:initiatives, visible)
      |> assign(:initiative_count, length(visible))
      |> assign(:archived, Initiatives.list_archived_initiatives(user))
      |> stream(:initiatives, sort_initiatives(visible, socket.assigns.sort_state), reset: true)
      |> put_flash(:info, msg)
    else
      put_flash(socket, :error, "Couldn't find that Initiative.")
    end
  end

  # --- Render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      width={:wide}
      rail_initiatives={@initiatives}
      rail_current_id={@initiative && @initiative.id}
      rail_current_name={@initiative && @initiative.name}
      rail_collaborators={@rail_collaborators}
      rail_online_ids={@collaborator_online_ids}
      rail_member_ids={MapSet.new(@members, & &1.user_id)}
    >
      <%!-- Shell root hook (M02.09 WL5.4): ALWAYS present in both list and detail
           modes. It owns the §6.8 dead-window livePush registration — registered
           once at first connect and NEVER unregistered on a list<->detail hop, so
           the dead window exists only at first connect (today's per-hop
           registration/presence churn is gone). The detail-specific .TaskKeys
           duties live on a hook mounted only in detail mode (below). --%>
      <div id="workspace-root" phx-hook=".Workspace">
        <script :type={Phoenix.LiveView.ColocatedHook} name=".Workspace">
          export default {
            mounted() {
              this._livePush = (ev, payload, cb) => this.pushEvent(ev, payload, cb);
              window.DoitRegisterLivePush(this._livePush);
            },
            destroyed() {
              window.DoitUnregisterLivePush(this._livePush);
            },
          }
        </script>
      </div>

      <%= if @live_action == :show do %>
        <div id={"initiative-detail-#{@initiative.id}"}>
          <div
            id={"initiative-show-root-#{@initiative.id}"}
            data-initiative-id={@initiative.id}
            phx-hook=".TaskKeys"
          >
            <script :type={Phoenix.LiveView.ColocatedHook} name=".TaskKeys">
              export default {
                mounted() {
                  this._h = (e) => this.handle(e);
                  window.addEventListener("keydown", this._h);
                  // M02.09 WL5 defect fix: this hook's element now carries the
                  // per-Initiative id, so an A->B rail switch truly DESTROYS this hook
                  // and MOUNTS a fresh one (morphdom can no longer move a static-id
                  // node into the new wrapper). But LiveView fires destroyed() in its
                  // post-patch removal pass — AFTER the new Initiative's subtree is
                  // morphed and this mounted() runs — so the leaving hook's cleanup is
                  // too late to stop B painting with A's client state. Detect the
                  // switch HERE (the prior Initiative still owns DoitDetailInitiativeId,
                  // since its destroyed() hasn't run yet) and clear the leaked
                  // detail-scoped state BEFORE B's data-keep appliers settle. Re-assert
                  // the keeps on the moved stable-id elements (editor pane, mobile rail,
                  // edit signifiers) that morphdom relocated with A's DoitState still
                  // set — all synchronous, so the corrected state is what the browser
                  // paints (no flash of A's editor/flyout on B). The query is scoped to
                  // the per-Initiative detail WRAPPER (#initiative-detail-<id>), NOT this
                  // hook's own element (#initiative-show-root-<id>): show-root holds only
                  // the tree column (#tree-scroll, the mobile members panel and the
                  // archive-prompt banner), while the right-rail flyout (#details-rail,
                  // carrying the initiative/task editor panes and the desktop members
                  // panel) is a SIBLING of show-root inside the wrapper. A this.el-scoped
                  // (show-root) query would skip those rail/editor keeps and leave A's
                  // editor/flyout state stuck on B, so we scope to the wrapper to
                  // re-assert every detail keep.
                  this._iid = this.el.dataset.initiativeId;
                  if (window.DoitDetailInitiativeId &&
                      window.DoitDetailInitiativeId !== this._iid) {
                    this.clearDetailState();
                    const detail =
                      document.getElementById("initiative-detail-" + this._iid) || this.el;
                    detail.querySelectorAll("[data-keep]").forEach((el) => {
                      if (window.DoitApplyKeep) window.DoitApplyKeep(el);
                    });
                  }
                  window.DoitDetailInitiativeId = this._iid;
                  // M02.09 WL5.4: the dead-window livePush registration moved to the
                  // always-present .Workspace shell hook, so a list<->detail hop never
                  // unregisters it (the dead window exists only at first connect). This
                  // detail hook mounts on detail-enter and is destroyed on leave/switch
                  // (its element rides the per-Initiative keyed wrapper), so it owns the
                  // detail-only duties: the keydown handler, undo/redo clicks, the
                  // selection replay, and the deep-link / comment-saved / viewer-plus /
                  // bonk handleEvents.
                  // Expose the bonk so delegated listeners in app.js (e.g. the
                  // transfer-confirm in-flight latch, item 15.16) can sound it too.
                  window.DoitBonk = () => this.bonk();
                  // Server-pushed bonk: a permission denial (a viewer / viewer+
                  // attempting a disallowed action) sounds the same rejection thud,
                  // however the attempt arrived — key, form, click, or drop.
                  this.handleEvent("bonk", () => this.bonk());
                  // Saved-tick acks (WL3 item 3.7, §6.7): a debounced subtitle write
                  // and the viewer+ flip have no reply callback (they ride phx-change
                  // forms), so the server pushes these one-shot events; reveal the
                  // brief "✓ Saved" span. viewer-plus additionally re-enables its
                  // checkbox here (the in-flight signifier disabled it client-side) —
                  // that re-enable IS the success ack.
                  this.handleEvent("subtitle-saved", () => {
                    if (window.DoitSavedTick) window.DoitSavedTick("subtitle-saved-tick");
                  });
                  this.handleEvent("viewer-plus-saved", () => {
                    const box = document.querySelector("input[name='viewer_plus']");
                    if (box) { clearTimeout(box._vpTimer); box.disabled = false; }
                    if (window.DoitSavedTick) window.DoitSavedTick("viewer-plus-saved-tick");
                  });
                  // Comment-edit save (WL3 3.3, §6.5): the editor's open/close is
                  // client-owned (DoitState.commentEditId), but SAVE is server-gated.
                  // The server pushes this ONLY on a granted save (an :ok, or a
                  // :not_found that's already terminal) — never on a refusal — so it
                  // can clear the client open state honestly. Re-apply the row's
                  // "comment-edit" keep at once so the editor closes immediately,
                  // ahead of the reconciling patch.
                  this.handleEvent("comment-saved", ({id}) => {
                    if (String(window.DoitState.commentEditId) === String(id)) {
                      window.DoitState.commentEditId = null;
                    }
                    const li = document.getElementById("comment-" + id);
                    if (li && window.DoitApplyKeep) window.DoitApplyKeep(li);
                  });
                  // A selection can land before we connect (DoitSelection is
                  // client-only; slow longpoll connect). Replay it now so the server
                  // loads the pane's comments / activity / co-assignees for it. This
                  // is ALSO the §6.8 de-confliction (WL4.2.2): the dead-window queue
                  // deliberately SKIPS select_task/close_task, leaving this one push
                  // of the FINAL selection (DoitSelection.id is the selection slot's
                  // single source of truth — it captures pill-click selections that
                  // never call DoitPush, which the queue would miss). One push, no
                  // double-fire.
                  if (window.DoitSelection && window.DoitSelection.id) {
                    this.pushEvent("select_task", {id: window.DoitSelection.id});
                  }
                  // After an undo/redo, select + scroll the affected task into view
                  // (m02.06 item 13). Guarded: an undone create removes the task, so
                  // there's nothing to show — skip rather than stall the pane.
                  this.handleEvent("select-task", ({id}) => {
                    if (!document.getElementById("task-" + id)) return;
                    if (window.DoitSelection) window.DoitSelection.set(id, {scroll: true});
                    if (window.DoitPush) window.DoitPush("select_task", {id});
                  });
                  // Deep-link from Assigned-to-Me (m02.08 item 1.7): expand any
                  // collapsed ancestors so the target is visible, then select +
                  // scroll it into view. Expansion clears each ancestor's collapse
                  // state the same way the toggle does (localStorage + class +
                  // aria), so it sticks across the post-load collapse-guard pass.
                  this.handleEvent("deep-link-task", ({id, ancestors}) => {
                    (ancestors || []).forEach((aid) => {
                      // The children <ul> + toggle button carry the initiative id;
                      // mirror the toggle's localStorage key off it so the expand
                      // survives the post-load collapse-guard re-apply.
                      const ul = document.getElementById("children-" + aid);
                      const btn = document.getElementById("collapse-" + aid);
                      const init = (ul && ul.dataset.initiativeId) ||
                                   (btn && btn.dataset.initiativeId);
                      if (init) localStorage.setItem(`phx:collapse:${init}:${aid}`, "0");
                      if (ul) ul.classList.remove("collapsed-peek");
                      if (btn) btn.setAttribute("aria-expanded", "true");
                    });
                    // Defer the select/scroll a frame so the just-expanded rows are
                    // laid out before scrollIntoView measures (no layout jank).
                    requestAnimationFrame(() => {
                      if (!document.getElementById("task-" + id)) return;
                      if (window.DoitSelection) window.DoitSelection.set(id, {scroll: true});
                      if (window.DoitPush) window.DoitPush("select_task", {id});
                    });
                  });
                  // Toolbar Undo/Redo clicks route through the same latch + feedback
                  // as the keyboard (item 15.9), so a repeat while one's in flight is
                  // dropped (with a bonk), never queued.
                  this._undoBtn = (e) => {
                    const b = e.target.closest("#undo-button, #redo-button");
                    if (!b || b.disabled) return;
                    e.preventDefault();
                    this.triggerUndoRedo(b.id === "redo-button" ? "redo" : "undo");
                  };
                  window.addEventListener("click", this._undoBtn);
                },
                destroyed() {
                  window.removeEventListener("keydown", this._h);
                  window.removeEventListener("click", this._undoBtn);
                  clearTimeout(this._paneT);
                  // M02.09 WL5.4 + defect fix: leaving the detail (patch to the list)
                  // must clear ALL detail-scoped client state, or it leaks into the
                  // next detail — e.g. a stale selection replayed against another
                  // Initiative's tree, or an editor/comment editor re-opening. On an
                  // Initiative SWITCH this destroyed() runs AFTER the next
                  // Initiative's hook has already mounted and reset the state
                  // (LiveView mounts on add, destroys on the later removal pass), so
                  // guard on the tracked id: only clear when WE are still the active
                  // detail (the leave-to-list case). On a switch the newer mount owns
                  // DoitDetailInitiativeId — skip, or we'd wipe B's freshly-set state
                  // and break detection of the next switch. The livePush stays
                  // registered (owned by the always-present .Workspace shell hook), so
                  // the dead-window funnel is untouched here.
                  if (window.DoitDetailInitiativeId === this._iid) {
                    window.DoitDetailInitiativeId = null;
                    this.clearDetailState();
                  }
                },
                // Reset every detail-scoped client store to its default. Shared by the
                // leave path (destroyed) and the switch path (mounted) so the two stay
                // in lock-step.
                clearDetailState() {
                  // editorOpen must be cleared BEFORE the selection: DoitSelection.clear()
                  // runs syncRail (via apply -> syncPaneSkeleton), and syncRail computes
                  // the mobile rail/backdrop open state from BOTH the selection AND
                  // DoitInitiativeEditor.open. Clearing the editor flag first means that
                  // syncRail pass already sees the editor closed, so a switch-with-editor-
                  // open doesn't leave the rail/backdrop stuck open (nothing re-runs
                  // syncRail after clear()).
                  if (window.DoitState) {
                    window.DoitState.editorOpen = false;
                    window.DoitState.commentEditId = null;
                    window.DoitState.commentVersionsId = null;
                    window.DoitState.pending = {toggle: null, move: null, initiativeOrder: null};
                    window.DoitState.presence = {selections: [], online: []};
                    // Tree scroll is detail-scoped: the only data-keep="scroll" box is
                    // the per-Initiative #tree-scroll, so reset it wholesale — B's tree
                    // must open at the top, not inherit A's scrollTop.
                    window.DoitState.scroll = {};
                    // <details data-keep="open"> open-state is keyed by STABLE element
                    // id, and the detail disclosures (initiative-settings, task-activity,
                    // members-*-form) reuse the same ids across Initiatives — so A's open
                    // state would re-assert on B. Clear every detailsOpen entry EXCEPT the
                    // genuinely non-detail ones: the app-shell menus (notif/account/mobile
                    // -menu, cross-page) and the index-mode disclosures (new-initiative,
                    // archived, list-scoped). Everything else is a detail disclosure and
                    // must reset to its server default. (Keeping this an allow-list of the
                    // few stable non-detail ids means a NEW detail disclosure is cleared by
                    // default — failing safe against the very leak this closes.)
                    const KEEP_OPEN = new Set([
                      "notif-menu", "account-menu", "mobile-menu", "new-initiative", "archived"
                    ]);
                    Object.keys(window.DoitState.detailsOpen).forEach((id) => {
                      if (!KEEP_OPEN.has(id)) delete window.DoitState.detailsOpen[id];
                    });
                    // The archive-on-completion banner dismissal is detail-scoped
                    // (#archive-prompt renders per-Initiative); clear it so a fresh detail
                    // re-evaluates from the server's show_archive_prompt instead of
                    // inheriting A's dismissal.
                    window.DoitState.archivePromptDismissed = false;
                  }
                  if (window.DoitSelection) window.DoitSelection.clear();
                },
                inField() {
                  const a = document.activeElement;
                  return !!(a && (a.tagName === "INPUT" || a.tagName === "TEXTAREA" ||
                                  a.tagName === "SELECT" || a.isContentEditable));
                },
                selectedId() {
                  const S = window.DoitSelection;
                  return S ? S.id : null;
                },
                // The pane load trails rapid keyboard navigation: the highlight is
                // client-instant, the server round-trip settles after the pause.
                schedulePaneLoad(id) {
                  clearTimeout(this._paneT);
                  this._paneT = setTimeout(() => this.pushEvent("select_task", {id: id}), 150);
                },
                handle(e) {
                  // Suppression: a text-accepting element has focus — fall through
                  // (so native field-level undo still works).
                  if (this.inField()) return;
                  // Undo / redo (m02.06 item 4): Ctrl/Cmd+Z = undo; +Shift or Ctrl+Y
                  // = redo. Handled before the idclip letter-buffer so "z" isn't
                  // swallowed. No selection required.
                  if ((e.ctrlKey || e.metaKey) && /^[zy]$/i.test(e.key)) {
                    e.preventDefault();
                    const redo = /^y$/i.test(e.key) || e.shiftKey;
                    this.triggerUndoRedo(redo ? "redo" : "undo");
                    return;
                  }
                  const k = e.key;
                  // Easter egg (idclip — Doom's noclip): "see through" to each row's
                  // task/parent IDs as a debug pill. Type the code outside any field.
                  if (k.length === 1 && /[a-z]/i.test(k)) {
                    this._idbuf = ((this._idbuf || "") + k.toLowerCase()).slice(-6);
                    if (this._idbuf === "idclip") {
                      this._idbuf = "";
                      document.documentElement.classList.toggle("debug-task-ids");
                      return;
                    }
                  }
                  if (k === "?") {
                    e.preventDefault();
                    const o = document.getElementById("shortcuts-overlay");
                    if (o) o.dispatchEvent(new CustomEvent("doit:shortcuts-toggle"));
                    return;
                  }
                  if (k === "Enter") {
                    e.preventDefault();
                    const S = window.DoitSelection;
                    if (!S) return;
                    if (S.id) {
                      S.clear();
                      this.pushEvent("close_task", {});
                    } else {
                      const first = document.querySelector("li[data-task-id]");
                      const id = S.lastId || (first && first.dataset.taskId);
                      if (id) { S.set(id, {scroll: true}); this.pushEvent("select_task", {id: id}); }
                    }
                    return;
                  }
                  // Down arrow while the Initiative (not a task) is the thing
                  // selected: the mirror of the top-of-list Up-arrow escape below —
                  // reverse back into the first visible task. DoitSelection.set
                  // already closes the editor pane (syncPaneSkeleton), so this stays
                  // pure client view-state, no round trip.
                  if (k === "ArrowDown" && !this.selectedId() &&
                      window.DoitInitiativeEditor && window.DoitInitiativeEditor.open) {
                    e.preventDefault();
                    const first = this.visibleRows()[0];
                    if (first) {
                      const id = first.dataset.taskId;
                      window.DoitSelection.set(id, {scroll: true});
                      this.schedulePaneLoad(id);
                    }
                    return;
                  }
                  const sel = this.selectedId();
                  if (!sel) return; // every other shortcut needs a selected task
                  if (k === " ") {
                    e.preventDefault();
                    const btn = document.getElementById("collapse-" + sel);
                    if (btn) btn.click();
                    return;
                  }
                  if (k === "ArrowUp" || k === "ArrowDown" || k === "ArrowLeft" || k === "ArrowRight") {
                    e.preventDefault();
                    if (e.altKey) {
                      const li = document.querySelector(`li[data-task-id="${sel}"]`);
                      if (li && this.blockedMove(li, k)) { this.bonk(); return; }
                      const S = window.DoitSaving;
                      if (S && li) {
                        const rows = this.movePinkRows(S, li, k);
                        S.markSaving(rows);
                        // Reparents move the row between parents — both parents'
                        // % is in flight (.03.07.23): indeterminate bars.
                        if (k === "ArrowLeft" || k === "ArrowRight") S.markRecomputing(rows.slice(1));
                      }
                      this.pushEvent("kbd_move", {key: k, altKey: true, id: sel});
                      return;
                    }
                    const id = this.navTarget(sel, k);
                    if (id) {
                      window.DoitSelection.set(id, {scroll: true});
                      this.schedulePaneLoad(id);
                    } else if (k === "ArrowUp" && window.DoitInitiativeEditor) {
                      // Top of the visible list: Up escapes into the Initiative
                      // itself (the mirror of the ArrowDown reversal above).
                      window.DoitInitiativeEditor.show();
                    }
                    return;
                  }
                  if (k === "n" || k === "N") { e.preventDefault(); window.DoitAddForm.openChild(sel); return; }
                  if (k === "s" || k === "S") { e.preventDefault(); window.DoitAddForm.openSibling(sel); return; }
                  // Del clicks the delete button so its confirm dialog still fires.
                  if (k === "Delete") {
                    e.preventDefault();
                    const btn = document.getElementById("delete-task-btn");
                    if (btn) btn.click();
                    return;
                  }
                  // P / A: Alt focuses the field for precise editing; plain steps
                  // the value up, Shift steps it down.
                  const field = k.length === 1 && {p: "priority", a: "assignee"}[k.toLowerCase()];
                  if (field) {
                    e.preventDefault();
                    // Alt+P/A: focusing a pane field is pure view state — no
                    // server (.03.07.17). The field exists whenever a task is
                    // selected (persistent pane) and is disabled for viewers.
                    if (e.altKey) {
                      const el = document.getElementById("task-field-" + field);
                      if (el && !el.disabled) { el.focus(); el.scrollIntoView({block: "nearest"}); }
                      return;
                    }
                    const S = window.DoitSaving, li = S && S.selectedLi();
                    if (li) S.markSaving([S.savingRowOf(li)]);
                    // Optimistic value echo (§6.2): step the pane <select> the
                    // same way the server will, then recolor/relabel the row pill
                    // through the shared echo — directly, NOT via a synthetic
                    // input event (which would also fire the form's phx-change
                    // and double-push update_task). The server's patch reconciles
                    // (and reverts a refused write — MUST NOT LIE). Priority:
                    // low→normal→high clamped; assignee: [Unassigned|members] wrap
                    // — both mirror step_priority/step_assignee, and the option
                    // order matches the server's because the template renders from
                    // the same source lists.
                    const fieldEl = document.getElementById("task-field-" + field);
                    if (fieldEl && !fieldEl.disabled && fieldEl.options && fieldEl.options.length) {
                      const step = e.shiftKey ? -1 : 1;
                      if (field === "priority") {
                        fieldEl.selectedIndex =
                          Math.max(0, Math.min(fieldEl.selectedIndex + step, fieldEl.options.length - 1));
                      } else {
                        const n = fieldEl.options.length;
                        fieldEl.selectedIndex = (fieldEl.selectedIndex + step + n) % n;
                      }
                      if (window.DoitRowEcho) window.DoitRowEcho(fieldEl);
                    }
                    this.pushEvent("kbd_adjust", {field: field, dir: e.shiftKey ? "down" : "up", id: sel});
                    return;
                  }
                },
                visibleRows() {
                  return [...document.querySelectorAll("li[data-task-id]")]
                    .filter((li) => !li.closest("ul.collapsed-peek"));
                },
                navTarget(sel, key) {
                  const cur = document.querySelector(`li[data-task-id="${sel}"]`);
                  if (!cur) return null;
                  if (key === "ArrowUp" || key === "ArrowDown") {
                    const rows = this.visibleRows();
                    const j = rows.indexOf(cur) + (key === "ArrowUp" ? -1 : 1);
                    return rows[j] ? rows[j].dataset.taskId : null;
                  }
                  if (key === "ArrowLeft") {
                    const p = cur.parentElement && cur.parentElement.closest("li[data-task-id]");
                    return p ? p.dataset.taskId : null;
                  }
                  const ul = cur.querySelector(":scope > ul[id^='children-']");
                  if (!ul || ul.classList.contains("collapsed-peek")) return null;
                  const first = ul.querySelector(":scope > li[data-task-id]");
                  return first ? first.dataset.taskId : null;
                },
                taskSibling(li, dir) {
                  let el = dir < 0 ? li.previousElementSibling : li.nextElementSibling;
                  while (el && !el.matches("li[data-task-id]")) {
                    el = dir < 0 ? el.previousElementSibling : el.nextElementSibling;
                  }
                  return el;
                },
                // The four impossible reorgs (.03.07.02.12): first child up, last
                // child down, top-level dedent, indent with no previous sibling.
                blockedMove(li, key) {
                  if (key === "ArrowUp" || key === "ArrowRight") return !this.taskSibling(li, -1);
                  if (key === "ArrowDown") return !this.taskSibling(li, 1);
                  return !li.parentElement.closest("li[data-task-id]");
                },
                // Pink only rows that certainly get a DB write. Moves write the
                // moved row (parent_id / sort_order), the swapped sibling, and the
                // parent when the reorder flips it from auto-sort to manual.
                // Reparents (dedent / indent) also pink BOTH immediate parents —
                // their % moves in almost every case. Chains above stay quiet:
                // value-dependent.
                movePinkRows(S, li, key) {
                  if (key === "ArrowLeft" || key === "ArrowRight") {
                    const rows = [S.savingRowOf(li)];
                    const parentLi = li.parentElement.closest("li[data-task-id]");
                    if (parentLi) rows.push(S.savingRowOf(parentLi));
                    const dest = key === "ArrowRight"
                      ? this.taskSibling(li, -1)
                      : parentLi && parentLi.parentElement.closest("li[data-task-id]");
                    if (dest) rows.push(S.savingRowOf(dest));
                    return rows;
                  }
                  const swap = this.taskSibling(li, key === "ArrowUp" ? -1 : 1);
                  const rows = [S.savingRowOf(li), S.savingRowOf(swap)];
                  const parentLi = li.parentElement.closest("li[data-task-id]");
                  if (parentLi && li.parentElement.dataset.sortMode !== "manual") {
                    rows.push(S.savingRowOf(parentLi));
                  }
                  return rows;
                },
                // Short descending thud for a rejected move. Audio is a nicety —
                // never let it break the keyboard path.
                bonk() {
                  try {
                    const Ctx = window.AudioContext || window.webkitAudioContext;
                    this._audio = this._audio || new Ctx();
                    const ctx = this._audio;
                    if (ctx.state === "suspended") ctx.resume();
                    const osc = ctx.createOscillator(), gain = ctx.createGain();
                    // Triangle + ~220 Hz: pure sine below ~100 Hz is inaudible on
                    // laptop speakers (tab showed the speaker icon, nobody heard it).
                    osc.type = "triangle";
                    osc.frequency.setValueAtTime(220, ctx.currentTime);
                    osc.frequency.exponentialRampToValueAtTime(110, ctx.currentTime + 0.2);
                    gain.gain.setValueAtTime(0.3, ctx.currentTime);
                    gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.25);
                    osc.connect(gain).connect(ctx.destination);
                    osc.start();
                    osc.stop(ctx.currentTime + 0.3);
                  } catch (_e) { /* no audio, no problem */ }
                },
                // In-flight undo/redo feedback (item 15.9): the first trigger latches
                // and shows a working state instantly (no round trip); a repeat while
                // it's in flight is DROPPED with a bonk, not queued. The server reply
                // (handlers return {:reply,…}) clears the latch + working state.
                triggerUndoRedo(dir) {
                  if (this._undoInFlight) { this.bonk(); return; }
                  this._undoInFlight = dir;
                  this.setUndoBusy(dir, true);
                  this.pushEvent(dir, {}, () => {
                    this._undoInFlight = null;
                    this.setUndoBusy(dir, false);
                  });
                },
                setUndoBusy(dir, on) {
                  const btn = document.getElementById(dir === "redo" ? "redo-button" : "undo-button");
                  if (btn) {
                    btn.classList.toggle("animate-pulse", on);
                    btn.classList.toggle("pointer-events-none", on);
                  }
                  const toast = document.getElementById("undo-toast");
                  if (toast) {
                    if (on) {
                      toast.textContent = dir === "redo" ? "Redoing…" : "Undoing…";
                      toast.hidden = false;
                    } else {
                      toast.hidden = true;
                    }
                  }
                },
              }
            </script>
            <%!-- Instant "we heard you" toast for undo/redo (item 15.9), shown
             client-side before the round trip and hidden when the server reply
             settles the latch; the result then shows as the normal flash. --%>
            <div
              id="undo-toast"
              hidden
              aria-live="polite"
              class="fixed top-4 left-1/2 -translate-x-1/2 z-50 rounded-lg bg-zinc-900/90 px-3 py-1.5 text-sm font-medium text-white shadow-lg dark:bg-zinc-100/90 dark:text-zinc-900"
            >
            </div>
            <%!-- Below lg: New List + a Show/Hide Members toggle, kept together as
             one row (the pinned Members panel is lg:+ only, so the toggle is
             needed up to lg). The title-row New List takes over at lg:+, so it's
             hidden below lg and this pair carries New List everywhere else. --%>
            <div class="lg:hidden mb-6">
              <div class="flex justify-center items-center gap-2">
                <button
                  :if={@can_edit}
                  type="button"
                  data-add-root
                  class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-sm font-bold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
                  aria-label="New list"
                  title="New list"
                >
                  <.icon name="hero-plus" class="w-4 h-4" />
                  <span>New List</span>
                </button>
                <button
                  type="button"
                  phx-click={
                    Phoenix.LiveView.JS.toggle(to: "#mobile-members")
                    |> Phoenix.LiveView.JS.toggle(to: "#members-show-label")
                    |> Phoenix.LiveView.JS.toggle(to: "#members-hide-label")
                  }
                  aria-controls="mobile-members"
                  class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-sm font-bold border border-zinc-300 dark:border-zinc-600 text-zinc-700 dark:text-zinc-200 hover:bg-zinc-50 dark:hover:bg-zinc-800"
                >
                  <.icon name="hero-users" class="w-4 h-4" />
                  <span id="members-show-label">Show Members</span>
                  <span id="members-hide-label" class="hidden">Hide Members</span>
                </button>
              </div>
              <div id="mobile-members" class="hidden mt-2">
                <.members_panel
                  id="members-mobile"
                  members={@members}
                  can_admin={@can_admin}
                  online_ids={@online_ids}
                  owner_id={@initiative.owner_id}
                  me={@current_user.id}
                  assignee_ids={@direct_assignee_ids}
                  viewer_plus_on={@initiative.viewer_plus}
                  can_assign={@can_edit or MapSet.size(@led_task_ids) > 0}
                />
              </div>
            </div>

            <%!-- App-shell (m02.07 item 1.1): at lg:+ the grid is a viewport-height
             shell — the page stops scrolling and each column owns its own
             vertical scroll. Below lg: it's a plain grid and the page scrolls,
             unchanged. The calc trims the top header (~2.8rem) and the
             container's top padding (pt-8 = 2rem); bottom padding is dropped at
             lg: (lg:pb-0), so the shell fits flush to the viewport bottom. The
             close/role row now lives inside the center column (it used to sit
             full-width above the shell), so it no longer subtracts here. --%>
            <div class="grid grid-cols-1 lg:grid-cols-[1fr_360px] xl:grid-cols-[1fr_400px] 2xl:grid-cols-[1fr_440px] gap-6 lg:h-[calc(100dvh-5rem)] lg:items-stretch lg:overflow-hidden">
              <%!-- Center column. At lg:+ it's a flex column: the close/role row and
               header are flex-none siblings above the tree's own scroll box
               (item 1.2), so the tree scrolls beneath chrome that never moves.
               Below lg: it's a normal block and the page scrolls. min-w-0 keeps
               the column from expanding to fit deep rows. --%>
              <div class="min-w-0 lg:flex lg:flex-col lg:min-h-0 lg:overflow-hidden">
                <%!-- Close (back to the index) + role on the same row, scoped to the
                 center column so it aligns with the header beneath it rather
                 than spanning the right pane. The little red X (item 12.7) reads
                 as "close this Initiative" rather than a plain back arrow —
                 matching the task pane's close affordance. --%>
                <div class="mb-4 flex items-center justify-between gap-2">
                  <.link
                    patch={~p"/initiatives"}
                    data-nav-spinner
                    title="Close this Initiative — back to all Initiatives"
                    class="group inline-flex items-center gap-1.5 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:text-red-700 dark:hover:text-red-300"
                  >
                    <span class="inline-flex items-center justify-center w-5 h-5 rounded bg-red-500/20 text-red-600 dark:text-red-400 group-hover:bg-red-500/40 transition">
                      <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                    </span>
                    Close Initiative
                  </.link>
                  <div class="flex items-center gap-3">
                    <%!-- Undo / Redo (m02.06 item 5). Disabled when the stack is empty
                     that way; the tooltip names the action. Ctrl+Z / Ctrl+Shift+Z
                     drive the same handlers (KbdNav hook). --%>
                    <div class="flex items-center gap-1">
                      <button
                        type="button"
                        id="undo-button"
                        disabled={is_nil(@undo_label)}
                        title={(@undo_label && "Undo: #{@undo_label}") || "Nothing to undo"}
                        aria-label={
                          (@undo_label && "Undo #{@undo_label}") || "Undo (nothing to undo)"
                        }
                        class="inline-flex items-center justify-center w-7 h-7 rounded text-zinc-500 hover:text-zinc-800 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:text-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-30 disabled:pointer-events-none transition"
                      >
                        <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
                      </button>
                      <button
                        type="button"
                        id="redo-button"
                        disabled={is_nil(@redo_label)}
                        title={(@redo_label && "Redo: #{@redo_label}") || "Nothing to redo"}
                        aria-label={
                          (@redo_label && "Redo #{@redo_label}") || "Redo (nothing to redo)"
                        }
                        class="inline-flex items-center justify-center w-7 h-7 rounded text-zinc-500 hover:text-zinc-800 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:text-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-30 disabled:pointer-events-none transition"
                      >
                        <.icon name="hero-arrow-uturn-right" class="w-4 h-4" />
                      </button>
                    </div>
                    <div class="text-xs text-zinc-500 dark:text-zinc-400 whitespace-nowrap">
                      Your role:
                      <span class="font-medium text-zinc-700 dark:text-zinc-200">{@role}</span>
                    </div>
                  </div>
                </div>

                <.initiative_header
                  initiative={@initiative}
                  subtitle={@subtitle}
                  initiative_progress={@initiative_progress}
                  can_edit={@can_edit}
                />

                <%!-- Archive-on-completion prompt (m02.08 item 4.1): a dismissible
                 nudge when the roll-up hits 100%. It only OFFERS to archive —
                 Archive runs the same per-user archive (with its own 4.2
                 confirm); Dismiss just closes the banner. Never auto-archives. --%>
                <div
                  :if={@show_archive_prompt}
                  id="archive-prompt"
                  data-keep="archive-prompt"
                  class="mb-4 flex flex-wrap items-center justify-between gap-3 rounded border border-emerald-300 dark:border-emerald-700 bg-emerald-50 dark:bg-emerald-950/40 px-4 py-2.5"
                >
                  <p class="flex items-center gap-2 text-sm text-emerald-800 dark:text-emerald-200">
                    <.icon name="hero-check-circle" class="w-5 h-5 flex-none" />
                    All done! Archive this Initiative to clear it from your active list?
                  </p>
                  <div class="flex items-center gap-2 flex-none">
                    <button
                      type="button"
                      data-archive-btn
                      data-am-owner={to_string(@current_user.id == @initiative.owner_id)}
                      class="inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-semibold text-white bg-emerald-600 hover:bg-emerald-700 active:scale-95 transition"
                    >
                      <.icon name="hero-archive-box" class="w-3.5 h-3.5" /> Archive
                    </button>
                    <button
                      type="button"
                      phx-click="dismiss_archive_prompt"
                      data-archive-dismiss
                      aria-label="Dismiss"
                      class="inline-flex items-center justify-center w-6 h-6 rounded text-emerald-700 dark:text-emerald-300 hover:bg-emerald-100 dark:hover:bg-emerald-900/50"
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>
                </div>

                <%!-- Scroll-fade signifier (item 1.3): a relative frame holding the
                 tree's own scroll box. The two theme-matched gradient overlays
                 live INSIDE the scroll box as sticky elements, so the scrollport
                 bounds them past the scrollbars with no measurement (see below).
                 The TreeScrollFade hook flips data-scrolled / data-at-end on the
                 frame; the overlays show/hide off those. lg:+ only — below it the
                 page scrolls so there's nothing to fade. --%>
                <div class="relative lg:flex-1 lg:min-h-0 group/treescroll" data-at-end>
                  <%!-- min-w-0 + overflow-x-auto: deep indentation scrolls
                   horizontally inside the column. At lg:+ overflow-y-auto adds
                   the column's own vertical scroll; below lg: the page scrolls.
                   The hook lives on this scroll box but flips data-scrolled /
                   data-at-end on its parent frame, so the fade overlays (sticky
                   descendants of the frame) read them as group-data-* variants. --%>
                  <div
                    id="tree-scroll"
                    phx-hook="TreeScrollFade"
                    data-keep="scroll"
                    class="min-w-0 overflow-x-auto lg:h-full lg:overflow-y-auto"
                  >
                    <%!-- Top fade: a sticky overlay pinned to the scrollport's
                     top-left edge, so the scrollport — which excludes both
                     scrollbars by definition — bounds it on every platform with
                     ZERO scrollbar measurement. -mb-24 cancels its h-24 so it
                     adds no scrollable height. Visible only while scrolled down
                     (data-scrolled on the frame). pointer-events-none so it
                     never intercepts a click/drag on the rows beneath (item 1.3
                     hard requirement); aria-hidden as it's purely decorative.
                     The gradient stop is the column's exact bg token (white /
                     zinc-950), with a dark-mode variant. --%>
                    <div
                      aria-hidden="true"
                      class="hidden lg:block pointer-events-none sticky top-0 left-0 -mb-24 w-full h-24 z-10 bg-gradient-to-b from-white dark:from-zinc-950 to-transparent opacity-0 transition-opacity duration-150 group-data-scrolled/treescroll:opacity-100"
                    >
                    </div>

                    <%!-- The one add-task form (parked in #add-task-home below) gets
                     client-teleported into these phx-update="ignore" slots —
                     opening a form never phones home (UX_GUARDRAILS 6.5). --%>
                    <div id="add-slot-root" phx-update="ignore" class="mb-3 empty:hidden"></div>

                    <div :if={@tree == []} class="text-zinc-500 dark:text-zinc-400 text-sm">
                      <%= if @can_edit do %>
                        No lists yet. Use the New List button above to start tracking work.
                      <% else %>
                        No lists yet.
                      <% end %>
                    </div>

                    <ul
                      id="task-tree"
                      phx-hook="TreeWidth"
                      data-sort-mode={@root_sort_mode}
                      data-progress-calc={@initiative.progress_calc}
                      class="space-y-2"
                    >
                      <%= for {t, i} <- Enum.with_index(@tree) do %>
                        <.task_node
                          task={t}
                          depth={0}
                          index_positions={[i]}
                          index_style={@initiative.index_style}
                          can_edit={@can_edit}
                          initiative_id={@initiative.id}
                          saving_ids={@pending_saving_ids}
                          recompute_ids={@pending_recompute_ids}
                          inherited_sort={@root_sort_mode}
                          progress_calc={@initiative.progress_calc}
                          display={@display}
                          member_ids={MapSet.new(@members, & &1.user_id)}
                          led_ids={@led_task_ids}
                        />
                        <li id={"add-after-#{t.id}"} phx-update="ignore" class="empty:hidden"></li>
                      <% end %>
                    </ul>

                    <%!-- Bottom fade: a sticky overlay pinned to the scrollport's
                     bottom-left edge, so it sits ABOVE the horizontal scrollbar
                     and its scrollport width stops short of the vertical
                     scrollbar — both automatically, on every platform, with ZERO
                     scrollbar measurement. -mt-24 cancels its h-24 so it adds no
                     scrollable height. Visible while more content sits below
                     (i.e. NOT at the end — group-data-at-end on the frame). Same
                     click-through + theme-match rules as the top fade. --%>
                    <div
                      aria-hidden="true"
                      class="hidden lg:block pointer-events-none sticky bottom-0 left-0 -mt-24 w-full h-24 z-10 bg-gradient-to-t from-white dark:from-zinc-950 to-transparent opacity-100 transition-opacity duration-150 group-data-at-end/treescroll:opacity-0"
                    >
                    </div>
                  </div>
                </div>
                <%!-- Live chat (m02.08 worklist 3 item 3.1): at lg:+ an in-flow row
                 beneath the tree's scroll box (a flex-none sibling below #tree-scroll,
                 so the collapsed bar never overlaps the scrollport); below lg: a fixed
                 lower-left overlay. For everyone currently viewing this Initiative.
                 Fully ephemeral —
                 the message log lives only in socket assigns (broadcast, never
                 persisted), so a fresh viewer sees no history and it clears once the
                 last viewer leaves. Open/closed is client view state (the .Chat hook,
                 localStorage), so toggling never round-trips. The input sits in a
                 phx-update="ignore" wrapper so typing survives a message arriving. --%>
                <div
                  id="initiative-chat"
                  phx-hook=".Chat"
                  data-chat-log-id={@chat_log_id}
                  data-me={@current_user.id}
                  data-my-name={@current_user.name}
                  data-my-initials={initials(@current_user)}
                  data-my-bg={avatar_bg(@current_user)}
                  data-my-fg={avatar_fg(@current_user)}
                  class="fixed bottom-3 left-3 z-40 w-72 max-w-[calc(100vw-1.5rem)] lg:static lg:bottom-auto lg:left-auto lg:z-auto lg:mt-3 lg:max-w-none lg:flex-none"
                >
                  <button
                    type="button"
                    data-chat-toggle
                    class="flex w-full items-center justify-between gap-2 rounded-t-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 px-3 py-2 text-xs font-semibold text-zinc-700 dark:text-zinc-200 shadow-lg"
                  >
                    <span class="flex flex-none items-center gap-1.5">
                      <.icon name="hero-chat-bubble-left-right" class="w-4 h-4" /> Chat
                    </span>
                    <%!-- Peek of the latest message when collapsed (3.1 follow-up): the
                     .Chat hook fills + shows this on a new message while closed, and
                     clears it on open. Dimmed italic, single-line ellipsis. --%>
                    <span
                      data-chat-preview
                      hidden
                      class="min-w-0 flex-1 truncate text-left font-normal italic text-zinc-400 dark:text-zinc-500"
                    >
                    </span>
                    <span data-chat-chevron class="inline-flex flex-none transition-transform">
                      <.icon name="hero-chevron-up" class="w-4 h-4" />
                    </span>
                  </button>

                  <div
                    data-chat-panel
                    hidden
                    class="flex flex-col rounded-b-lg border border-t-0 border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 shadow-lg"
                  >
                    <div
                      id="chat-log"
                      data-chat-log
                      class="flex flex-col gap-2 overflow-y-auto px-3 py-2 h-56 text-sm"
                    >
                      <p class="hidden only:block text-xs italic text-zinc-400 dark:text-zinc-500">
                        No messages yet — say hello to anyone else viewing this Initiative.
                      </p>
                      <%!-- A system line (e.g. "nobody's here to read that") is the
                       sender's own local notice: dimmed italic, no avatar, and
                       marked data-chat-system so the .Chat hook never treats it as a
                       message from another viewer (no pop / flash / preview). It has
                       no user_id, so no data-chat-uid. --%>
                      <%= for m <- Enum.reverse(@chat_messages) do %>
                        <%= if Map.get(m, :system) do %>
                          <div
                            id={"chat-msg-#{m.id}"}
                            data-chat-system
                            class="text-xs italic text-zinc-400 dark:text-zinc-500"
                          >
                            {m.body}
                          </div>
                        <% else %>
                          <div
                            id={"chat-msg-#{m.id}"}
                            data-chat-uid={m.user_id}
                            data-chat-echo={Map.get(m, :echo_id)}
                            class="flex gap-2"
                          >
                            <span
                              class="avatar-emboss relative inline-flex flex-none items-center justify-center rounded-full font-semibold select-none w-5 h-5 text-[10px]"
                              style={"background-image: #{m.bg}; color: #{m.fg};"}
                            >
                              {m.initials}
                            </span>
                            <div class="min-w-0">
                              <div class="text-xs text-zinc-500 dark:text-zinc-400">{m.name}</div>
                              <div
                                data-chat-body
                                class="break-words whitespace-pre-wrap text-zinc-800 dark:text-zinc-100"
                              >
                                {m.body}
                              </div>
                            </div>
                          </div>
                        <% end %>
                      <% end %>
                    </div>

                    <div
                      id="chat-input-wrap"
                      phx-update="ignore"
                      class="border-t border-zinc-200 dark:border-zinc-700 p-2"
                    >
                      <form data-chat-form class="flex gap-2">
                        <input
                          type="text"
                          data-chat-input
                          maxlength="2000"
                          placeholder="Message viewers…"
                          aria-label="Chat message"
                          autocomplete="off"
                          class="flex-1 input input-bordered input-sm"
                        />
                        <button
                          type="submit"
                          class="text-xs px-3 py-1 rounded bg-zinc-700 text-white hover:bg-zinc-800"
                        >
                          Send
                        </button>
                      </form>
                    </div>
                  </div>

                  <script :type={Phoenix.LiveView.ColocatedHook} name=".Chat">
                    export default {
                      mounted() {
                        this.toggle = this.el.querySelector("[data-chat-toggle]");
                        this.panel = this.el.querySelector("[data-chat-panel]");
                        this.chevron = this.el.querySelector("[data-chat-chevron]");
                        this.preview = this.el.querySelector("[data-chat-preview]");
                        this.log = this.el.querySelector("[data-chat-log]");
                        this.form = this.el.querySelector("[data-chat-form]");
                        this.input = this.el.querySelector("[data-chat-input]");
                        // Track the server's monotonic chat counter to spot NEW messages
                        // in updated() (vs. unrelated re-renders).
                        this._lastLogId = parseInt(this.el.dataset.chatLogId || "0", 10);

                        // Open/closed is in-memory view state, default CLOSED on every
                        // mount (refresh / initiative open) — not persisted, so the chat
                        // never greets you open.
                        this._open = false;
                        this.setOpen(false);

                        this.toggle.addEventListener("click", () => this.setOpen(this.panel.hidden));

                        this.form.addEventListener("submit", (e) => {
                          e.preventDefault();
                          const raw = this.input.value.trim();
                          if (!raw) return;
                          // Resolve `%label` refs to their `%⟨id⟩` token form before the
                          // echo + broadcast (Wave 3): the token rides the EPHEMERAL
                          // broadcast body; each receiver renders it against its OWN tree
                          // (an off-tree ref falls back to %?). Nothing is persisted.
                          const body = window.DoitRefTransformForSave
                            ? window.DoitRefTransformForSave(raw)
                            : raw;
                          // Optimistic own-line echo (§6.7): show the sent bubble at submit
                          // instead of waiting for the PubSub broadcast to round-trip back.
                          // A client nonce ties the pending node to the real line so we can
                          // dedupe it in updated() (and pull it on alone/empty/failure — a
                          // sent bubble must never stand if no reader got it).
                          const echoId = "e" + Date.now() + "-" + Math.random().toString(36).slice(2, 8);
                          this.appendEcho(echoId, body);
                          this.pushEvent("send_chat", { body, echo_id: echoId }, (reply) => {
                            if (!reply || reply.ok === false) {
                              const n = this.log && this.log.querySelector(`[data-chat-echo="${echoId}"][data-chat-pending]`);
                              if (n) n.remove();
                            }
                          });
                          this.input.value = "";
                          this.input.focus();
                        });

                        // Render tokens -> links in any server-rendered message bodies
                        // present at mount (Wave 3). Chat starts empty, so this is
                        // usually a no-op; received lines render via updated() below.
                        if (window.DoitRenderRefs) window.DoitRenderRefs(document);
                      },
                      // Build + append a pending own-message node matching the server's
                      // own-message markup (avatar from data-my-*), dimmed while pending.
                      // Lives in the morphdom-owned log; updated() reconciles it once the
                      // real (broadcast) line arrives carrying the same echo id.
                      appendEcho(echoId, body) {
                        if (!this.log) return;
                        const d = this.el.dataset;
                        const row = document.createElement("div");
                        row.className = "flex gap-2 opacity-60";
                        row.setAttribute("data-chat-uid", d.me || "");
                        row.setAttribute("data-chat-echo", echoId);
                        row.setAttribute("data-chat-pending", "");
                        const av = document.createElement("span");
                        av.className = "avatar-emboss relative inline-flex flex-none items-center justify-center rounded-full font-semibold select-none w-5 h-5 text-[10px]";
                        av.style.backgroundImage = d.myBg || "";
                        av.style.color = d.myFg || "";
                        av.textContent = d.myInitials || "";
                        const wrap = document.createElement("div");
                        wrap.className = "min-w-0";
                        const name = document.createElement("div");
                        name.className = "text-xs text-zinc-500 dark:text-zinc-400";
                        name.textContent = d.myName || "";
                        const bodyEl = document.createElement("div");
                        bodyEl.setAttribute("data-chat-body", "");
                        bodyEl.className = "break-words whitespace-pre-wrap text-zinc-800 dark:text-zinc-100";
                        bodyEl.textContent = body;
                        wrap.appendChild(name);
                        wrap.appendChild(bodyEl);
                        row.appendChild(av);
                        row.appendChild(wrap);
                        this.log.appendChild(row);
                        // Render the token -> link in the optimistic bubble at once
                        // (Wave 3): a direct DOM append fires no LiveView patch, so
                        // updated()'s renderAllRefs wouldn't otherwise catch it.
                        if (window.DoitRenderRefs) window.DoitRenderRefs(row);
                        this.scrollToBottom();
                      },
                      // Remove any pending echo whose nonce now appears on a real
                      // (server-rendered, non-pending) message node — the broadcast line
                      // has landed and supersedes the optimistic bubble.
                      reconcileEchoes() {
                        if (!this.log) return;
                        const pending = this.log.querySelectorAll("[data-chat-pending][data-chat-echo]");
                        pending.forEach((p) => {
                          const id = p.getAttribute("data-chat-echo");
                          if (!id) return;
                          const real = this.log.querySelector(`[data-chat-echo="${id}"]:not([data-chat-pending])`);
                          if (real) p.remove();
                        });
                      },
                      setOpen(open) {
                        this.panel.hidden = !open;
                        // Bottom-docked panel opens upward: chevron points up when closed
                        // ("open me"), down when open ("minimize"). Base icon is up, so
                        // rotate only when open.
                        if (this.chevron) this.chevron.classList.toggle("rotate-180", open);
                        this._open = open;
                        if (open) {
                          this.hidePreview(); // reading them now — clear the collapsed peek
                          this.scrollToBottom();
                          this.input.focus();
                        }
                      },
                      hidePreview() {
                        if (this.preview) {
                          this.preview.hidden = true;
                          this.preview.textContent = "";
                        }
                      },
                      showLatestPreview() {
                        if (!this.preview || !this.log) return;
                        const bodies = this.log.querySelectorAll("[data-chat-body]");
                        const last = bodies[bodies.length - 1];
                        if (!last) return;
                        this.preview.textContent = last.textContent.trim();
                        this.preview.hidden = false;
                      },
                      scrollToBottom() {
                        if (this.log) this.log.scrollTop = this.log.scrollHeight;
                      },
                      updated() {
                        // A server re-render (e.g. your own sent message broadcasting
                        // back) re-applies the template's `hidden` on the panel via
                        // morphdom, which would snap an open chat shut. Re-assert the open
                        // state from localStorage (the source of truth) before anything
                        // else, so sending never closes the window.
                        const reopen = this._open;
                        this.panel.hidden = !reopen;
                        if (this.chevron) this.chevron.classList.toggle("rotate-180", reopen);
                        // Reconcile optimistic echoes: when the real (broadcast) own-line
                        // arrives it carries the same client nonce on a NON-pending node.
                        // Drop the dimmed pending bubble so the canonical line supersedes
                        // it — no duplicate, and the dimmed "pending" look clears.
                        this.reconcileEchoes();
                        // Render tokens -> links on any newly-arrived (broadcast) message
                        // bodies (Wave 3). Idempotent + document-wide, so it also
                        // re-resolves chat labels after a tree re-number while shown.
                        if (window.DoitRenderRefs) window.DoitRenderRefs(document);
                        // A new message bumps the server's monotonic chat-log id. A
                        // system line (the alone-case "nobody's here" notice) also bumps
                        // it, but it's the sender's own local notice — never pop / flash /
                        // preview for it (the rejection bonk already fired server-side).
                        const id = parseInt(this.el.dataset.chatLogId || "0", 10);
                        if (id > this._lastLogId) {
                          this._lastLogId = id;
                          if (!this.latestIsSystem() && this.fromOther()) {
                            this.pop(); // a quick blip — distinct from the rejection bonk
                            if (this.panel.hidden) {
                              this.showLatestPreview();
                              this.flash();
                            }
                          }
                        }
                        if (this.panel && !this.panel.hidden) this.scrollToBottom();
                      },
                      // Is the newest log entry a system notice (data-chat-system)?
                      latestIsSystem() {
                        if (!this.log) return false;
                        const last = this.log.lastElementChild;
                        return !!last && last.hasAttribute("data-chat-system");
                      },
                      // Was the latest message from someone else? No pop / flash for your
                      // own message echoing back over the broadcast.
                      fromOther() {
                        if (!this.log) return false;
                        const msgs = this.log.querySelectorAll("[data-chat-uid]");
                        const last = msgs[msgs.length - 1];
                        return !!last && last.dataset.chatUid !== (this.el.dataset.me || "");
                      },
                      // Brief green pulse on the collapsed bar (reflow to retrigger on
                      // rapid messages).
                      flash() {
                        const t = this.toggle;
                        if (!t) return;
                        t.classList.remove("chat-flash");
                        void t.offsetWidth;
                        t.classList.add("chat-flash");
                      },
                      // A short rising blip — deliberately unlike the descending bonk thud.
                      pop() {
                        try {
                          const Ctx = window.AudioContext || window.webkitAudioContext;
                          this._ac = this._ac || new Ctx();
                          const ctx = this._ac;
                          if (ctx.state === "suspended") ctx.resume();
                          const osc = ctx.createOscillator(), gain = ctx.createGain();
                          osc.type = "sine";
                          osc.frequency.setValueAtTime(420, ctx.currentTime);
                          osc.frequency.exponentialRampToValueAtTime(720, ctx.currentTime + 0.06);
                          gain.gain.setValueAtTime(0.0001, ctx.currentTime);
                          gain.gain.exponentialRampToValueAtTime(0.22, ctx.currentTime + 0.012);
                          gain.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + 0.13);
                          osc.connect(gain).connect(ctx.destination);
                          osc.start();
                          osc.stop(ctx.currentTime + 0.14);
                        } catch (_e) {}
                      },
                    }
                  </script>
                </div>
              </div>

              <%!-- Backdrop on mobile when right-rail flyout is open. Always
               rendered; the client flips `hidden` with the rail (.03.07.20). --%>
              <div
                id="pane-backdrop"
                hidden={is_nil(@selected_task_id)}
                class="lg:hidden fixed inset-0 z-20 bg-black/50"
                data-close-panel
                aria-hidden="true"
              >
              </div>

              <%!-- Right pane (m02.07 item 1.4). At lg:+ it's a persistent column —
               always shown, full grid-cell height, a flex column whose Members
               panel is pinned at the top (flex-none, own capped overflow) while
               the Details / initiative-editor content scrolls independently
               beneath it, so Members stays reachable to drag onto a task no
               matter how far Details has scrolled. The pane scrolls
               independently of the center tree.

               Below lg:, the data-open flyout mechanism is unchanged
               (.03.07.20): client flips data-open at the tap and the variants
               make it a fixed overlay over the backdrop. The shell layout
               (flex column, pinned Members) is lg:+ only. --%>
              <aside
                id="details-rail"
                data-open={@selected_task_id && "true"}
                data-keep="rail"
                class={[
                  "not-data-open:hidden lg:not-data-open:block",
                  "data-open:block lg:data-open:flex data-open:fixed lg:data-open:static data-open:top-0 data-open:bottom-0 data-open:right-0 data-open:z-30",
                  "data-open:w-full sm:data-open:w-96 lg:data-open:w-auto",
                  "data-open:bg-zinc-50 lg:data-open:bg-transparent dark:data-open:bg-zinc-950 lg:dark:data-open:bg-transparent",
                  "data-open:shadow-xl lg:data-open:shadow-none data-open:p-4 lg:data-open:p-0",
                  "data-open:overflow-y-auto lg:data-open:overflow-hidden data-open:[scrollbar-gutter:stable]",
                  "space-y-4 lg:space-y-0 lg:flex lg:flex-col lg:h-full lg:min-h-0 lg:overflow-hidden"
                ]}
              >
                <div class="lg:hidden flex justify-end">
                  <button
                    type="button"
                    data-close-panel
                    aria-label="Close details panel"
                    title="Close"
                    class="inline-flex items-center justify-center w-8 h-8 rounded bg-red-500/30 hover:bg-red-500/50 text-white font-bold"
                  >
                    <.icon name="hero-x-mark" class="w-5 h-5" />
                  </button>
                </div>
                <%!-- Members — pinned at the top of the pane (lg:flex-none) with its
                 own capped height + overflow when the list is long (item 1.4),
                 so it never scrolls away beneath the Details content. On phone
                 it's hidden in favor of the header's collapsible toggle
                 (.05.04.1). --%>
                <div class="hidden sm:block lg:flex-none lg:max-h-[45%] lg:overflow-y-auto lg:[scrollbar-gutter:stable] lg:mb-4">
                  <.members_panel
                    id="members-desktop"
                    members={@members}
                    can_admin={@can_admin}
                    online_ids={@online_ids}
                    owner_id={@initiative.owner_id}
                    me={@current_user.id}
                    assignee_ids={@direct_assignee_ids}
                    viewer_plus_on={@initiative.viewer_plus}
                    can_assign={@can_edit or MapSet.size(@led_task_ids) > 0}
                  />
                </div>

                <%!-- Content region: Details / initiative-editor, scrolling
                 independently beneath the pinned Members (item 1.4). At lg:+
                 it's flex-1 with its own overflow; below lg: a normal block
                 (the whole flyout scrolls). space-y restores the gap the
                 aside-level one drops at lg. --%>
                <div class="space-y-4 lg:flex-1 lg:min-h-0 lg:overflow-y-auto lg:[scrollbar-gutter:stable]">
                  <%!-- Persistent like the task pane (.03.07.08): always rendered,
                   the editor's #initiative-form pre-populated from the
                   initiative. Visibility is CLIENT-OWNED view state (UX_GUARDRAILS
                   6.5): always rendered `hidden` here, and DoitInitiativeEditor
                   reveals it instantly on the title click — no round trip. The
                   guard observer re-asserts the open flag across patches. --%>
                  <div
                    id="initiative-editor-pane"
                    data-keep="editor"
                    hidden
                    class="rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 p-4"
                  >
                    <.initiative_editor
                      form={@initiative_form}
                      can_edit={@can_edit}
                      can_admin={@can_admin}
                      initiative={@initiative}
                      root_task={@root_task}
                      subtitle={@subtitle}
                      am_owner={@current_user.id == @initiative.owner_id}
                    />
                  </div>

                  <%!-- ONE pane, pre-mounted and never swapped (.03.07.06, item 15.8):
                   the shell renders from the start — a blank task when nothing is
                   selected — so the FIRST selection fills client-side with no
                   round trip, exactly like every later switch. Deselecting hides
                   it (selected_task keeps the last pane data, only selected_task_id
                   nils). On a selection the client writes the row-known values
                   (title / priority / assignee) into these real fields immediately
                   and swaps the async lists to "Loading…"; the server patch then
                   reconciles the same elements in place (and fills the editable
                   co-assignee list, comments, activity) — LiveView never clobbers
                   the focused field, so in-progress typing survives the patch. --%>
                  <div
                    id="task-editor-pane"
                    data-task-id={@selected_task_id}
                    data-keep="pane"
                    hidden={is_nil(@selected_task_id)}
                    class="rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 p-4"
                  >
                    <.task_editor
                      task={@selected_task || blank_task()}
                      comments={@comments}
                      current_user={@current_user}
                      activity={@activity}
                      members={@members}
                      can_edit={@can_edit}
                      can_progress={@can_edit or MapSet.member?(@led_task_ids, @selected_task_id)}
                      can_staff={@selected_staff_pool != nil}
                      staff_pool={@selected_staff_pool}
                      show_activity={@show_task_activity}
                      online_ids={@online_ids}
                    />
                  </div>
                </div>
              </aside>
            </div>
          </div>

          <div id="confirm-skips" phx-hook="ConfirmSkips" hidden></div>

          <%!-- The single add-task form. Lives here (hidden) until the client
           teleports it into a slot; all containers are phx-update="ignore",
           so no patch can disturb it mid-typing. create_task reads the two
           hidden inputs — opening/closing never touches the server. --%>
          <div id="add-task-home" phx-update="ignore" hidden>
            <form
              id="add-task-form"
              phx-submit="create_task"
              class="flex items-center gap-2 rounded border border-emerald-500/40 bg-white dark:bg-zinc-900 px-3 py-2"
            >
              <input type="hidden" name="parent_id" value="" />
              <input type="hidden" name="after_id" value="" />
              <input
                type="text"
                name="title"
                required
                placeholder="New task..."
                class="flex-1 input input-bordered input-sm"
              />
              <.ref_picker_button target="#add-task-form input[name='title']" class="flex-none" />
              <button
                type="submit"
                phx-disable-with="Adding..."
                class="text-sm px-3 py-1.5 rounded bg-emerald-600 text-white hover:bg-emerald-700 active:bg-emerald-800 active:scale-95 transition"
              >
                Add
              </button>
              <%!-- "Done", not "Cancel": the adder stays open across submits so
               you can add several tasks; this button just closes it and
               discards nothing already added. --%>
              <button
                type="button"
                data-add-cancel
                class="text-sm px-2 py-1.5 text-zinc-500 hover:text-zinc-800 dark:text-zinc-100 dark:hover:text-white"
              >
                Done
              </button>
            </form>
          </div>
          <.completion_confirm pending={@pending_action} verb={pending_verb(@pending_action)} />
          <.move_flip_confirm :if={@can_edit} />
          <.cascade_confirm />
          <.cascade_sort_confirm :if={@can_edit} />
          <.delete_task_confirm :if={@can_edit} />
          <.delete_initiative_confirm :if={@can_admin} name={@initiative.name} />
          <.leave_confirm :if={@current_user.id != @initiative.owner_id} />
          <.archive_confirm />
          <.remove_member_confirm :if={@can_admin} />
          <%!-- Member-removal assignment hand-off (m02.05 item 13.5). --%>
          <div
            :if={@pending_handoff}
            id="handoff-confirm"
            class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
          >
            <form
              :if={@pending_handoff}
              id="handoff-form"
              phx-submit="confirm_handoff"
              class="w-full max-w-md rounded-lg bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-700 p-5 shadow-xl"
            >
              <h3 class="text-base font-semibold text-zinc-800 dark:text-zinc-100">
                Remove {@pending_handoff.name}
              </h3>
              <p class="mt-2 text-sm text-zinc-600 dark:text-zinc-300">
                They hold {@pending_handoff.count} assignment(s) here. Choose what happens to those,
                then they'll be removed.
              </p>

              <label class="mt-3 flex items-center gap-2 text-sm text-zinc-700 dark:text-zinc-200 select-none">
                <input
                  type="checkbox"
                  name="promote_co"
                  value="true"
                  checked={@pending_handoff.promote_default}
                  class="checkbox checkbox-sm"
                /> Promote the next co-assignee in line where one exists
              </label>

              <label class="mt-3 block text-xs text-zinc-500 dark:text-zinc-400">
                Otherwise hand their tasks to
              </label>
              <select name="takeover" class="mt-1 w-full select select-bordered select-sm">
                <option value="">No one — leave those tasks unassigned</option>
                <option
                  :for={m <- @members}
                  :if={m.user_id != @pending_handoff.user_id}
                  value={m.user_id}
                >
                  {m.user.name} (@{m.user.username})
                </option>
              </select>

              <div class="mt-5 flex justify-end gap-2">
                <button
                  type="button"
                  data-handoff-cancel
                  class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 active:scale-95 transition dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  phx-disable-with="Removing..."
                  class="rounded px-3 py-1.5 text-sm font-medium text-white active:scale-95 transition bg-red-600 hover:bg-red-700"
                >
                  Remove &amp; hand off
                </button>
              </div>
            </form>
          </div>
          <%!-- Transfer-ownership confirm is client-side (UX_GUARDRAILS 6.5, like
           the delete confirms): everything it shows — the target's name, the
           demotion copy — is client-known, so it opens at the click with no
           round trip. app.js fills [data-transfer-name] + stashes the user-id;
           only Proceed touches the server (confirm_transfer). phx-update="ignore"
           keeps the server out of it (a rename mid-session leaves the initiative
           name stale — display-only and rare). --%>
          <div
            id="transfer-confirm"
            hidden
            phx-update="ignore"
            class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
          >
            <div class="w-full max-w-md rounded-lg bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-700 p-5 shadow-xl">
              <h3 class="text-base font-semibold text-zinc-800 dark:text-zinc-100">
                Transfer ownership
              </h3>
              <p data-transfer-body class="mt-2 text-sm text-zinc-600 dark:text-zinc-300">
                Make <span class="font-semibold" data-transfer-name></span>
                the owner of <span class="font-semibold">{@initiative.name}</span>?
                This is a transfer — you'll be demoted to <span class="font-semibold">editor</span>
                and lose owner controls.
              </p>
              <div class="mt-5 flex justify-end gap-2">
                <button
                  type="button"
                  data-transfer-cancel
                  class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200 active:scale-95 transition dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:active:bg-zinc-700"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  id="transfer-confirm-proceed"
                  data-transfer-proceed
                  class="rounded px-3 py-1.5 text-sm font-medium text-white active:scale-95 transition bg-amber-600 hover:bg-amber-700 active:bg-amber-800"
                >
                  Transfer ownership
                </button>
              </div>
            </div>
          </div>
          <.shortcuts_overlay />
          <%!-- Anchor for the selection-presence channel (.04.01.12): receives
           presence-selections pushes and paints row badges client-side. --%>
          <div
            id="presence-badges"
            phx-hook="PresenceBadges"
            data-keep="presence"
            phx-update="ignore"
            hidden
          >
          </div>
        </div>
      <% else %>
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-6">
          <div>
            <h1 class="text-2xl font-semibold text-zinc-800 dark:text-zinc-100">My Initiatives</h1>
            <p class="text-sm text-zinc-500 dark:text-zinc-400">
              An Initiative holds multiple Lists. Each List is a tree of nested tasks.
            </p>
          </div>
          <button
            type="button"
            data-details-toggle="new-initiative"
            class="w-fit self-center inline-flex items-center gap-1 px-2 py-0.5 rounded text-sm font-bold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
          >
            <.icon name="hero-plus" class="w-4 h-4" />
            <span>New Initiative</span>
          </button>
        </div>

        <%!-- Client-toggled (no round trip before typing); data-keep="open"
             preserves the open state across patches, e.g. a validation error re-render. --%>
        <details id="new-initiative" data-keep="open" class="mb-6">
          <summary class="hidden"></summary>
          <div class="rounded border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4">
            <.form :let={f} for={@form} phx-submit="create" class="space-y-3">
              <.input field={f[:name]} type="text" label="Name" required />
              <.input field={f[:description]} type="textarea" label="Description (optional)" />
              <div class="flex justify-end gap-2">
                <button
                  type="button"
                  data-details-close="new-initiative"
                  class="px-3 py-1.5 rounded border border-zinc-300 dark:border-zinc-700 text-sm text-zinc-700 dark:text-zinc-200 hover:bg-zinc-50 dark:hover:bg-zinc-800"
                >
                  Cancel
                </button>
                <.button type="submit" data-latch="Creating…">Create initiative</.button>
              </div>
            </.form>
          </div>
        </details>

        <%!-- Sort control (.06.2, server-persisted by m02.04 §2.6). The server
             renders the saved state (initial values survive phx-update="ignore");
             the hook owns it from there and pushes apply_sort on change. --%>
        <form
          :if={@initiative_count > 0}
          id="initiative-sort"
          phx-hook="InitiativeSort"
          phx-update="ignore"
          data-reverse-by-mode={Jason.encode!(@reverse_by_mode)}
          class="flex items-center justify-end gap-2 mb-3 text-zinc-600 dark:text-zinc-300 3xl:hidden"
        >
          <label for="initiative-sort-mode" class="text-xs">Sort</label>
          <select id="initiative-sort-mode" name="mode" class="select select-bordered select-sm">
            <option value="" selected={is_nil(@sort_state.mode)}>Recent</option>
            <option value="manual" selected={@sort_state.mode == "manual"}>Manual</option>
            <option value="name" selected={@sort_state.mode == "name"}>Name</option>
            <option value="progress" selected={@sort_state.mode == "progress"}>Progress</option>
            <option value="created" selected={@sort_state.mode == "created"}>Created</option>
            <option value="updated" selected={@sort_state.mode == "updated"}>Updated</option>
          </select>
          <%!-- In-flight slot (§6.7): explicit modes reorder client-side at the
               change (instant), but "Recent" (and Reverse-while-Recent) is
               server-derived — spin this reserved slot while .doit-busy is held
               on the select so the server re-sort isn't silent. --%>
          <span
            class="doit-busy-slot inline-flex w-3.5 flex-none items-center justify-center"
            aria-hidden="true"
          >
            <.icon
              name="hero-arrow-path"
              class="doit-busy-spinner size-3.5 animate-spin text-emerald-600 dark:text-emerald-400"
            />
          </span>
          <label class="flex items-center gap-1 text-xs select-none">
            <input
              type="checkbox"
              name="reverse"
              value="true"
              checked={@sort_state.reverse}
              class="checkbox checkbox-xs"
            /> Reverse
          </label>
        </form>

        <%!-- Card list: full-width below 3xl. At 3xl the left rail (Layouts
             chrome) covers it, so it hides and the center shows a "pick an
             Initiative" prompt; the "Assigned to Me" pane rides the layout's
             right pane (a sibling of the left rail, via <:rail_right> below). --%>
        <div id="initiatives" phx-update="stream" class="space-y-2 3xl:hidden">
          <div
            :for={{dom_id, initiative} <- @streams.initiatives}
            id={dom_id}
            data-initiative-id={initiative.id}
            data-name={initiative.name}
            data-progress={initiative.progress || 0}
            data-created={to_string(initiative.inserted_at)}
            data-updated={to_string(initiative.updated_at)}
            data-my-order={initiative.my_sort_order}
            class="rounded border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 hover:shadow-sm transition motion-reduce:transition-none"
          >
            <%!-- list<->detail is a same-module push_patch (no remount): use
                 patch, not navigate, so the kept-mounted shell stays intact. --%>
            <.link
              patch={~p"/initiatives/#{initiative.id}"}
              data-nav-spinner
              draggable="false"
              class="block p-4"
            >
              <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-1 sm:gap-3">
                <span class="font-medium text-zinc-800 dark:text-zinc-100 inline-flex items-center gap-2 min-w-0">
                  <span
                    id={"init-drag-#{initiative.id}"}
                    phx-hook="InitiativeDrag"
                    data-id={initiative.id}
                    aria-hidden="true"
                    title="Drag to reorder"
                    class="flex-none inline-flex items-center gap-0.5 text-emerald-600 dark:text-emerald-400 cursor-grab active:cursor-grabbing touch-none select-none"
                  >
                    <.icon
                      name="hero-ellipsis-vertical"
                      class="w-3 h-3 text-zinc-600 dark:text-zinc-500"
                    />
                    <.botanical_icon kind={:grove} class="w-5 h-5" />
                    <.icon
                      name="hero-ellipsis-vertical"
                      class="w-3 h-3 text-zinc-600 dark:text-zinc-500"
                    />
                  </span>
                  <span class="truncate">{initiative.name}</span>
                </span>
                <div class="flex items-center gap-2 flex-none">
                  <span
                    :if={initiative.my_role}
                    class={[
                      "text-[10px] uppercase tracking-wide font-semibold px-1.5 py-0.5 rounded",
                      role_badge_class(initiative.my_role)
                    ]}
                    title={"Your role: #{initiative.my_role}"}
                  >
                    {initiative.my_role}
                  </span>
                  <span class="text-xs text-zinc-500 dark:text-zinc-400">
                    Updated <.local_time value={initiative.updated_at} format="%b %-d, %Y" />
                  </span>
                </div>
              </div>
              <p
                :if={subtitle_text(initiative)}
                data-initiative-card-field
                class="mt-1 text-sm text-zinc-600 dark:text-zinc-300 line-clamp-1"
              >
                {subtitle_text(initiative)}
              </p>
              <p
                :if={initiative.description}
                data-initiative-card-field
                class="mt-1 text-sm text-zinc-500 dark:text-zinc-400 line-clamp-2"
              >
                {initiative.description}
              </p>

              <div
                class="relative mt-2 h-4 bg-zinc-100 dark:bg-zinc-800 rounded-full overflow-hidden"
                role="progressbar"
                aria-valuenow={initiative.progress || 0}
                aria-valuemin="0"
                aria-valuemax="100"
                aria-label={"Progress: #{initiative.progress || 0}%"}
                style={"--progress: #{initiative.progress || 0}%"}
              >
                <div
                  class="absolute inset-y-0 left-0 bg-emerald-400 rounded-full"
                  style="width: var(--progress)"
                >
                </div>
                <span class="absolute inset-0 flex items-center justify-center text-xs font-semibold text-zinc-900 dark:text-zinc-50 progress-bar-text">
                  {initiative.progress || 0}%
                </span>
              </div>
            </.link>
          </div>
        </div>

        <%!-- Center prompt at 3xl: the rail covers the list, so this column
             just asks the user to pick one. --%>
        <div class="hidden 3xl:flex flex-col items-center justify-center text-center py-24 text-zinc-500 dark:text-zinc-400">
          <.botanical_icon kind={:grove} class="w-12 h-12 mb-3 text-zinc-300 dark:text-zinc-600" />
          <p class="text-lg font-medium text-zinc-600 dark:text-zinc-300">Pick an Initiative</p>
          <p class="text-sm">Choose one from the list on the left to open it.</p>
        </div>

        <p :if={@initiative_count == 0} class="text-zinc-500 dark:text-zinc-400 mt-4">
          No initiatives yet. Create one to get started.
        </p>

        <%!-- Desktop-only entry to the keyboard-shortcuts help (.07.2.1). --%>
        <div class="hidden sm:flex justify-center mt-10 mb-16">
          <button
            type="button"
            phx-click={
              Phoenix.LiveView.JS.dispatch("doit:shortcuts-toggle", to: "#shortcuts-overlay")
            }
            class="inline-flex items-center gap-1 text-xs text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100"
          >
            <.icon name="hero-command-line" class="w-4 h-4" /> Keyboard shortcuts
          </button>
        </div>

        <.shortcuts_overlay />

        <%!-- Archived + Trash (m02.08 worklist 4 / m03.01 item 5.3): the caller's
             per-user Archived list merged with the owner-level Trash into one
             drawer. data-keep="open" pins the open state across LiveView
             patches. --%>
        <details
          :if={@trashed != [] or @archived != []}
          id="archived"
          data-keep="open"
          aria-label={archive_drawer_title(@archived, @show_hidden, @trashed)}
          class="group fixed bottom-0 z-30 border-t border-zinc-200 dark:border-zinc-800 bg-white/95 dark:bg-zinc-900/95 backdrop-blur supports-[backdrop-filter]:bg-white/80 dark:supports-[backdrop-filter]:bg-zinc-900/80 shadow-[0_-1px_3px_rgba(0,0,0,0.06)] 3xl:rounded-t-lg 3xl:border-x 3xl:shadow-[0_-1px_3px_rgba(0,0,0,0.1)]"
        >
          <summary class="flex cursor-pointer list-none select-none items-center gap-2 px-4 sm:px-6 3xl:px-3 py-2.5 text-sm font-semibold text-zinc-600 dark:text-zinc-300 [&::-webkit-details-marker]:hidden hover:bg-zinc-50 dark:hover:bg-zinc-800/50">
            <.icon :if={@archived != []} name="hero-archive-box" class="w-4 h-4 flex-none" />
            <span :if={@archived != []}>
              Archived ({length(visible_archived(@archived, @show_hidden))})
            </span>
            <span :if={@archived != [] and @trashed != []} class="text-zinc-400 dark:text-zinc-500">
              ·
            </span>
            <.icon :if={@trashed != []} name="hero-trash" class="w-4 h-4 flex-none" />
            <span :if={@trashed != []}>Trash ({length(@trashed)})</span>
            <.icon
              name="hero-chevron-up"
              class="ml-auto w-4 h-4 flex-none transition-transform group-open:rotate-180"
            />
          </summary>
          <div class="px-4 sm:px-6 3xl:px-3 pb-3">
            <div class="flex items-center justify-end gap-2">
              <label
                :if={Enum.any?(@archived, & &1.hidden?)}
                class="flex items-center gap-1.5 text-xs text-zinc-500 dark:text-zinc-400 select-none"
              >
                <input
                  type="checkbox"
                  id="show-hidden"
                  phx-click="toggle_show_hidden"
                  checked={@show_hidden}
                  data-keep="reveal-toggle"
                  class="checkbox checkbox-xs"
                /> Show hidden
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
              <label
                :if={@trashed != []}
                class="flex items-center gap-1.5 text-xs text-zinc-500 dark:text-zinc-400 select-none"
              >
                <input
                  type="checkbox"
                  id="show-trash"
                  phx-click="toggle_show_trash"
                  checked={@show_trash}
                  data-keep="reveal-toggle"
                  class="checkbox checkbox-xs"
                /> Show trash
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
            </div>
            <ul class="mt-2 space-y-1 max-h-[40vh] overflow-y-auto">
              <%= for a <- visible_archived(@archived, @show_hidden) do %>
                <li
                  id={"archived-#{a.id}"}
                  class="flex items-start sm:items-center justify-between gap-2 rounded border border-zinc-200 dark:border-zinc-800 bg-zinc-50/60 dark:bg-zinc-900 px-3 py-2"
                >
                  <div class="flex flex-col sm:flex-row sm:items-center gap-0.5 sm:gap-2 min-w-0 text-sm text-zinc-600 dark:text-zinc-300">
                    <span class="flex items-center gap-2 min-w-0">
                      <.botanical_icon
                        kind={:grove}
                        class="w-4 h-4 text-zinc-400 dark:text-zinc-500"
                      />
                      <span class="truncate">{a.name}</span>
                    </span>
                    <span
                      :if={a.hidden? and not a.archived?}
                      class="text-[10px] uppercase tracking-wide font-semibold px-1.5 py-0.5 rounded bg-zinc-200 text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300"
                    >
                      hidden
                    </span>
                  </div>
                  <span class="flex flex-col sm:flex-row items-end sm:items-center gap-1 flex-none">
                    <button
                      :if={a.archived?}
                      type="button"
                      phx-click="unarchive_initiative"
                      phx-value-id={a.id}
                      data-latch="Restoring…"
                      class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-semibold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
                    >
                      <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" /> Restore
                    </button>
                    <button
                      :if={a.hidden?}
                      type="button"
                      phx-click="unhide_initiative"
                      phx-value-id={a.id}
                      data-latch="Unhiding…"
                      class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-semibold border border-zinc-400 dark:border-zinc-600 text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800"
                    >
                      <.icon name="hero-eye" class="w-3.5 h-3.5" /> Unhide
                    </button>
                  </span>
                </li>
              <% end %>
            </ul>
            <div
              :if={@trashed != [] and @show_trash}
              class="mt-4 pt-3 border-t border-zinc-200 dark:border-zinc-800"
            >
              <h3 class="flex items-center gap-1.5 text-xs font-semibold text-zinc-500 dark:text-zinc-400 uppercase tracking-wide">
                <.icon name="hero-trash" class="w-3.5 h-3.5" /> Trash
                <span class="font-normal normal-case text-zinc-400 dark:text-zinc-500">
                  · auto-deletes after {Initiatives.trash_retention_days()} days
                </span>
              </h3>
              <ul class="mt-2 space-y-1 max-h-[40vh] overflow-y-auto">
                <li
                  :for={t <- @trashed}
                  id={"trashed-#{t.id}"}
                  class="flex items-start sm:items-center justify-between gap-2 rounded border border-zinc-200 dark:border-zinc-800 bg-zinc-50/60 dark:bg-zinc-900 px-3 py-2"
                >
                  <div class="flex flex-col sm:flex-row sm:items-center gap-0.5 sm:gap-2 min-w-0 text-sm text-zinc-600 dark:text-zinc-300">
                    <span class="flex items-center gap-2 min-w-0">
                      <.botanical_icon
                        kind={:grove}
                        class="w-4 h-4 text-zinc-400 dark:text-zinc-500"
                      />
                      <span class="truncate">{t.name}</span>
                    </span>
                    <span class="text-xs text-zinc-400 dark:text-zinc-500 whitespace-nowrap">
                      trashed <.local_time value={t.trashed_at} format="%b %-d" />
                    </span>
                  </div>
                  <span class="flex flex-col sm:flex-row items-end sm:items-center gap-1 flex-none">
                    <button
                      type="button"
                      phx-click="restore_initiative"
                      phx-value-id={t.id}
                      data-latch="Restoring…"
                      class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-semibold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
                    >
                      <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" /> Restore
                    </button>
                    <button
                      type="button"
                      phx-click="purge_initiative"
                      phx-value-id={t.id}
                      data-latch="Deleting…"
                      data-confirm={"Permanently delete \"#{t.name}\"? This can't be undone."}
                      class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-semibold border border-red-500 text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950/40"
                    >
                      <.icon name="hero-x-mark" class="w-3.5 h-3.5" /> Delete
                    </button>
                  </span>
                </li>
              </ul>
            </div>
          </div>
        </details>
      <% end %>

      <%!-- Right (third) pane (item 6): the "Assigned to Me" home, list mode
           only — a sibling of the left rail at 3xl. --%>
      <:rail_right :if={@live_action == :index}>
        <div class="min-h-[calc(100dvh-9rem)]">
          <h2 class="mb-3 flex items-center gap-1.5 text-lg font-semibold text-zinc-700 dark:text-zinc-200">
            <.botanical_icon
              kind={:leaf}
              class="w-5 h-5 text-emerald-500/70 dark:text-emerald-400/70"
            /> Assigned to Me
          </h2>
          <.assigned_list
            id="assigned-pane"
            rows={@streams.assigned_tasks}
            empty?={@assigned_empty?}
            show_completed={@show_completed}
            show_archived_hidden={@show_archived_hidden}
            group_by_initiative={@group_by_initiative}
            variant={:pane}
          />
        </div>
      </:rail_right>
    </Layouts.app>
    """
  end

  # The pane's update_task forms carry no task id, so natively the server applies
  # them to the loaded selection (selected_task). A dead-window edit (WL4.2.2),
  # though, flushes on connect BEFORE the selection replay lands — so the client
  # captures the task the edit was made against (DoitState.selectedId) into the
  # payload. Honor an explicit id when present so the edit ALWAYS lands on its own
  # task (never the wrong one, never a silent drop); guard it to this initiative's
  # tree and fall back to the current selection for a stale/absent id.
  # A "Linked <label> — <title>, ..." info flash when a save's resolved
  # `%`-reference set CHANGED and is non-empty, else nil (m03.03 item 3.5 —
  # optimistic, never blocking). Labels + titles resolve off the already-loaded
  # `:tree` assign (no query); a dead / foreign / dropped id contributes nothing.
  defp ref_link_message(socket, old_text, new_text) do
    new_ids = Tasks.reference_ids(new_text)

    if new_ids != [] and Enum.sort(new_ids) != Enum.sort(Tasks.reference_ids(old_text)) do
      index = Tasks.label_index(socket.assigns.tree, socket.assigns.initiative.index_style)

      parts =
        new_ids
        |> Enum.map(&Map.get(index, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn %{index: label, title: title} ->
          "#{label} — #{Tasks.strip_reference_tokens(title)}"
        end)

      if parts != [], do: "Linked " <> Enum.join(parts, ", ")
    end
  end

  defp maybe_flash_links(socket, nil), do: socket
  defp maybe_flash_links(socket, msg), do: put_flash(socket, :info, msg)

  defp update_task_target(socket, payload) do
    with id when not is_nil(id) <- parse_id(payload["id"]),
         %Task{} = task <- Tasks.get_task(id),
         true <- task.initiative_id == socket.assigns.initiative.id do
      task
    else
      _ -> socket.assigns.selected_task
    end
  end

  # The sort controls name their own target (the form's hidden task_id /
  # the cascade button's phx-value-id); fall back to the pane task.
  defp sort_target(socket, params) do
    case parse_id(params["task_id"] || params["id"]) do
      # No / malformed named target → the pane task; a valid-but-just-deleted id
      # also falls back to the pane task instead of crashing.
      nil -> socket.assigns.selected_task
      id -> Tasks.get_task(id) || socket.assigns.selected_task
    end
  end

  # Resolve a keyboard shortcut's target: the client sends its selected id
  # (the DOM-owned selection); fall back to the server's pane task. Guarded
  # to this initiative and to editors.
  defp kbd_target(socket, params) do
    # An explicit (but malformed) id no-ops via the is_nil check below rather than
    # falling back to the selection; an absent id targets the pane task.
    id =
      case params["id"] do
        nil -> socket.assigns.selected_task_id
        raw -> parse_id(raw)
      end

    with true <- socket.assigns.can_edit,
         false <- is_nil(id),
         %Task{} = task <- Tasks.get_task(id),
         true <- task.initiative_id == socket.assigns.initiative.id do
      task
    else
      _ -> nil
    end
  end

  # Whitelist the field so a client can't push an arbitrary DOM id to focus.

  # Persist a single-field keyboard step (P/A), then patch the affected rows.
  defp apply_kbd_adjust(socket, task, field, dir) do
    params = adjust_params(field, dir, task, socket.assigns.members)

    case Tasks.update_task(task, socket.assigns.current_user, params) do
      {:ok, _updated} ->
        {:noreply, patch_task(socket, task.id)}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, "Couldn't update task: #{summarize_errors(cs)}.")}
    end
  end

  defp adjust_params("priority", dir, task, _members),
    do: %{"priority" => step_priority(task.priority, dir)}

  defp adjust_params("assignee", dir, task, members),
    do: %{"assignee_id" => step_assignee(task.assignee_id, dir, members)}

  # Priority order is low → normal → high; "up" moves toward high, clamped at
  # both ends (no wrap).
  defp step_priority(current, dir) do
    order = DoIt.Tasks.Task.priorities()
    i = Enum.find_index(order, &(&1 == current)) || 0
    next = if dir == "up", do: i + 1, else: i - 1
    Enum.at(order, max(0, min(next, length(order) - 1)))
  end

  # Assignee cycles [Unassigned | members…] with wrap in both directions; an
  # empty string is the "unassigned" param value for the changeset.
  defp step_assignee(current, dir, members) do
    ids = [nil | Enum.map(members, & &1.user.id)]
    i = Enum.find_index(ids, &(&1 == current)) || 0
    n = length(ids)
    next = if dir == "up", do: rem(i + 1, n), else: rem(i - 1 + n, n)

    case Enum.at(ids, next) do
      nil -> ""
      id -> to_string(id)
    end
  end

  defp pending_verb(%{kind: :create}), do: "new task"
  defp pending_verb(%{kind: :move}), do: "move"
  defp pending_verb(_), do: "change"

  # Confirmation classes (.03.01.11). A suppressible pending action maps to a
  # class with its own localStorage skip key + checkbox label; deletes → nil
  # (a destructive action always confirms).
  defp confirm_class(%{kind: kind}) when kind in [:move, :create], do: "completion-flip"
  defp confirm_class(%{kind: :cascade_sort}), do: "cascade-sort"
  defp confirm_class(_), do: nil

  defp confirm_class_label("completion-flip"), do: "completion changes"
  defp confirm_class_label("cascade-sort"), do: "large branch reorgs"

  defp skip_confirm?(socket, class),
    do: not is_nil(class) and MapSet.member?(socket.assigns.confirm_skips, class)

  # Pink = "maybe write" (.03.03.08): while a confirm modal is pending, the
  # rows its write would touch hold the saving hue — rendered server-side so
  # it survives re-renders and the user sees what's at stake while deciding.
  # Cancel clears it; Proceed keeps it through the write.
  defp assign_pending(socket, nil) do
    socket
    |> assign(:pending_action, nil)
    |> assign(:pending_saving_ids, MapSet.new())
    |> assign(:pending_recompute_ids, MapSet.new())
  end

  defp assign_pending(socket, pending) do
    saving = pending_saving_ids(pending)

    socket
    |> assign(:pending_action, pending)
    |> assign(:pending_saving_ids, saving)
    |> assign(:pending_recompute_ids, pending_recompute_ids(pending, saving))
  end

  defp pending_saving_ids(%{kind: :cascade_sort, task_id: id}),
    do: MapSet.new(Tasks.subtree_ids(id))

  defp pending_saving_ids(%{kind: :move, task_id: id, flip_ids: flip_ids}),
    do: MapSet.new([id | flip_ids])

  defp pending_saving_ids(%{kind: :create, flip_ids: flip_ids, preview_id: preview_id}),
    do: MapSet.new([preview_id | flip_ids])

  defp pending_saving_ids(_), do: MapSet.new()

  # The held-modal era's indeterminate bars (.03.07.23): every maybe-write row
  # whose % is genuinely unknown — i.e. all of them EXCEPT the operated row
  # (its values are client-held optimistically). Sort-only confirms move no %.
  defp pending_recompute_ids(%{kind: :cascade_sort}, _saving), do: MapSet.new()

  # The preview row's % is known (a new 0% leaf) — only the flipping ancestors
  # are genuinely indeterminate.
  defp pending_recompute_ids(%{kind: :create, preview_id: preview_id}, saving),
    do: MapSet.delete(saving, preview_id)

  defp pending_recompute_ids(%{task_id: id}, saving), do: MapSet.delete(saving, id)
  defp pending_recompute_ids(_, saving), do: saving

  # The instant completion-flip confirm for drags (UX_GUARDRAILS 6.5/6.6). The
  # client predicts (from the DOM, at drop time) when a reorganizing drag would
  # silently flip an ancestor's completion (§6.3 sanctions this confirm) and
  # opens THIS dialog immediately — no round trip — keeping the optimistic
  # placement up while the user decides. app.js fills the scenario message +
  # flipping titles, then Proceed re-sends move_task with confirmed:true and
  # Cancel reverts the placement. phx-update="ignore": the server never patches
  # it. The server's #completion-confirm stays the authoritative backstop for
  # any flip the client doesn't predict; this dialog never touches it.
  #
  # Copy matches the server confirm (confirm_title fallback +
  # completion_confirm_message) so the instant and backstop paths read the same.
  defp move_flip_confirm(assigns) do
    ~H"""
    <div
      id="move-flip-confirm"
      hidden
      phx-update="ignore"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
    >
      <div class="w-full max-w-md rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900">
        <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-100">
          Confirm completion change
        </h2>
        <p class="mt-2 text-sm text-zinc-700 dark:text-zinc-300" data-flip-message></p>
        <ul
          data-flip-titles
          hidden
          class="mt-3 max-h-40 overflow-y-auto rounded border border-zinc-200 bg-zinc-50 p-2 text-sm text-zinc-700 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-200"
        >
        </ul>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            data-flip-cancel
            class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200 active:scale-95 transition dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:active:bg-zinc-700"
          >
            Cancel
          </button>
          <button
            type="button"
            data-flip-proceed
            class="rounded px-3 py-1.5 text-sm font-medium text-white active:scale-95 transition bg-emerald-600 hover:bg-emerald-700 active:bg-emerald-800"
          >
            Proceed
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Branch-cascade confirm — client-opened (app.js #cascade-confirm,
  # UX_GUARDRAILS 6.5/6.6). Checking a branch's box flips the row optimistically
  # and, unless suppressed, opens THIS dialog instantly (title + verb are
  # client-known) while holding the flip. app.js fills the heading/body for the
  # complete-vs-reopen case, Proceed commits (cascade_complete / cascade_incomplete,
  # optionally persisting the "don't ask again" skip to localStorage), and
  # Cancel / backdrop / Esc revert the held flip. phx-update="ignore": the
  # server never patches it.
  defp cascade_confirm(assigns) do
    ~H"""
    <div
      id="cascade-confirm"
      hidden
      phx-update="ignore"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
    >
      <div class="w-full max-w-md rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900">
        <h2 data-cascade-title class="text-base font-semibold text-zinc-900 dark:text-zinc-100">
          Complete this branch?
        </h2>
        <p data-cascade-body class="mt-2 text-sm text-zinc-700 dark:text-zinc-300"></p>
        <label class="mt-4 flex items-center gap-2 text-sm text-zinc-600 dark:text-zinc-300 select-none">
          <input type="checkbox" data-cascade-dont-show class="checkbox checkbox-sm" />
          Don't show this again for branch completion changes
        </label>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            data-cascade-cancel
            class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200 active:scale-95 transition dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:active:bg-zinc-700"
          >
            Cancel
          </button>
          <button
            type="button"
            data-cascade-proceed
            class="rounded px-3 py-1.5 text-sm font-medium text-white active:scale-95 transition bg-emerald-600 hover:bg-emerald-700 active:bg-emerald-800"
          >
            Proceed
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Large-branch-reorg confirm — client-opened (app.js #cascade-sort-confirm,
  # UX_GUARDRAILS 6.5). "Make descendants inherit" predicts the descendant-branch
  # count from the DOM (the whole tree is rendered regardless of collapse); when
  # it exceeds 10 and isn't suppressed, app.js opens THIS dialog instantly (the
  # count is client-derivable) while holding the maybe-write hue on the subtree.
  # app.js fills the body's affected count, Proceed commits (cascade_sort with
  # confirmed: true, optionally persisting the "don't ask again" skip), and
  # Cancel / backdrop / Esc strip the hue with no server touch. phx-update="ignore":
  # the server never patches it. The server count gate (handle_event) stays as the
  # authoritative backstop for a client that didn't predict.
  defp cascade_sort_confirm(assigns) do
    ~H"""
    <div
      id="cascade-sort-confirm"
      hidden
      phx-update="ignore"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
    >
      <div class="w-full max-w-md rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900">
        <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-100">
          Large branch reorg
        </h2>
        <p data-cascade-sort-body class="mt-2 text-sm text-zinc-700 dark:text-zinc-300"></p>
        <label class="mt-4 flex items-center gap-2 text-sm text-zinc-600 dark:text-zinc-300 select-none">
          <input type="checkbox" data-cascade-sort-dont-show class="checkbox checkbox-sm" />
          Don't show this again for large branch reorgs
        </label>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            data-cascade-sort-cancel
            class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200 active:scale-95 transition dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:active:bg-zinc-700"
          >
            Cancel
          </button>
          <button
            type="button"
            data-cascade-sort-proceed
            class="rounded px-3 py-1.5 text-sm font-medium text-white active:scale-95 transition bg-emerald-600 hover:bg-emerald-700 active:bg-emerald-800"
          >
            Proceed
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Task deletion's confirm is fully client-side (.03.07.15, UX_GUARDRAILS
  # 6.5): everything the dialog shows — the task title, the irreversibility
  # copy — is already in the DOM, so opening it costs no round trip. app.js
  # fills the title, holds the maybe-write hue on the subtree, and only the
  # Delete button touches the server (the `delete_task` event, alongside the
  # optimistic row removal). phx-update="ignore": the server never patches it.
  defp delete_task_confirm(assigns) do
    ~H"""
    <div
      id="delete-confirm"
      hidden
      phx-update="ignore"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
    >
      <div class="w-full max-w-md rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900">
        <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-100">Delete task</h2>
        <p class="mt-2 text-sm text-zinc-700 dark:text-zinc-300">
          Delete "<span data-delete-title></span>" and all its subtasks? This can't be undone.
        </p>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            data-delete-cancel
            class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200 active:scale-95 transition dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:active:bg-zinc-700"
          >
            Cancel
          </button>
          <button
            type="button"
            data-delete-proceed
            class="rounded px-3 py-1.5 text-sm font-medium text-white active:scale-95 transition bg-red-600 hover:bg-red-700 active:bg-red-800"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Initiative deletion's confirm is client-side like the task one
  # (.03.07.18); the name is known at render, so not even a client fill is
  # needed. Proceed pushes `delete_initiative`. phx-update="ignore" keeps it
  # out of patches (a rename mid-session leaves the dialog's copy stale —
  # display-only and rare).
  attr :name, :string, required: true

  defp delete_initiative_confirm(assigns) do
    ~H"""
    <div
      id="delete-initiative-confirm"
      hidden
      phx-update="ignore"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
    >
      <div class="w-full max-w-md rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900">
        <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-100">Delete initiative</h2>
        <p class="mt-2 text-sm text-zinc-700 dark:text-zinc-300">
          Delete "{@name}" and everything in it? This can't be undone.
        </p>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            data-delete-cancel
            class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200 active:scale-95 transition dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:active:bg-zinc-700"
          >
            Cancel
          </button>
          <button
            type="button"
            data-delete-proceed
            class="rounded px-3 py-1.5 text-sm font-medium text-white active:scale-95 transition bg-red-600 hover:bg-red-700 active:bg-red-800"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Remove-member confirm — client-opened (UX_GUARDRAILS 6.5; the name is
  # client-known). app.js fills the name and opens it; only Proceed pushes
  # remove_member, which commits or escalates to the server hand-off modal for
  # a member holding assignments.
  defp remove_member_confirm(assigns) do
    ~H"""
    <div
      id="remove-member-confirm"
      hidden
      phx-update="ignore"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
    >
      <div class="w-full max-w-md rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900">
        <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-100">Remove member</h2>
        <p class="mt-2 text-sm text-zinc-700 dark:text-zinc-300">
          Remove <span data-remove-name class="font-medium">this member</span>
          from this Initiative? They can be re-added anytime.
        </p>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            data-remove-cancel
            class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200 active:scale-95 transition dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:active:bg-zinc-700"
          >
            Cancel
          </button>
          <button
            type="button"
            data-remove-proceed
            class="rounded px-3 py-1.5 text-sm font-medium text-white active:scale-95 transition bg-red-600 hover:bg-red-700 active:bg-red-800"
          >
            Remove
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Archive confirm — client-opened (UX_GUARDRAILS 6.5). app.js decides whether
  # it's needed without a round trip: the owner case predicts from the DOM (any
  # incomplete task), the member case is caught by the server backstop, which
  # replies needs_confirm to pop this. Proceed re-sends archive with
  # confirmed:true. One body covers both (owner / member) cases.
  defp archive_confirm(assigns) do
    ~H"""
    <div
      id="archive-confirm"
      hidden
      phx-update="ignore"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
    >
      <div class="w-full max-w-md rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900">
        <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-100">
          Archive this Initiative?
        </h2>
        <p class="mt-2 text-sm text-zinc-700 dark:text-zinc-300">
          There's still unfinished work here. Archive it anyway? It moves to your Archived list,
          where you can restore it anytime.
        </p>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            data-archive-cancel
            class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200 active:scale-95 transition dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:active:bg-zinc-700"
          >
            Cancel
          </button>
          <button
            type="button"
            data-archive-proceed
            class="rounded px-3 py-1.5 text-sm font-medium text-white active:scale-95 transition bg-emerald-600 hover:bg-emerald-700 active:bg-emerald-800"
          >
            Archive
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Leave-Initiative confirm — client-opened (app.js), so the dialog never waits
  # on the server (UX_GUARDRAILS 6.5). Its own title (the generic completion
  # modal read "Confirm completion change", the wrong heading for a leave).
  defp leave_confirm(assigns) do
    ~H"""
    <div
      id="leave-confirm"
      hidden
      phx-update="ignore"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
    >
      <div class="w-full max-w-md rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900">
        <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-100">Leave Initiative</h2>
        <p class="mt-2 text-sm text-zinc-700 dark:text-zinc-300">
          Leave this Initiative? Only the owner can add you back.
        </p>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            data-leave-cancel
            class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200 active:scale-95 transition dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:active:bg-zinc-700"
          >
            Cancel
          </button>
          <button
            type="button"
            data-leave-proceed
            class="rounded px-3 py-1.5 text-sm font-medium text-white active:scale-95 transition bg-red-600 hover:bg-red-700 active:bg-red-800"
          >
            Leave
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :pending, :map, default: nil
  attr :verb, :string, default: "change"

  defp completion_confirm(assigns) do
    pending = assigns.pending

    assigns =
      assigns
      |> assign(:class, pending && confirm_class(pending))

    ~H"""
    <div
      :if={@pending}
      id="completion-confirm"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
    >
      <%!-- The modal hides optimistically (6.1/6.2): JS.hide runs at click time,
           the push commits; the maybe-write hue carries the in-flight signal,
           and the server render reconciles (incl. failures, via flash). --%>
      <form
        id="confirm-form"
        phx-submit={
          Phoenix.LiveView.JS.hide(to: "#completion-confirm")
          |> Phoenix.LiveView.JS.push("confirm_pending")
        }
        phx-click-away={
          Phoenix.LiveView.JS.hide(to: "#completion-confirm")
          |> Phoenix.LiveView.JS.push("cancel_pending")
        }
        class="w-full max-w-md rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900"
      >
        <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-100">
          {confirm_title(@pending)}
        </h2>
        <p class="mt-2 text-sm text-zinc-700 dark:text-zinc-300">
          {confirm_body(@pending, @verb)}
        </p>
        <ul
          :if={Map.get(@pending, :titles, []) != []}
          class="mt-3 max-h-40 overflow-y-auto rounded border border-zinc-200 bg-zinc-50 p-2 text-sm text-zinc-700 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-200"
        >
          <li :for={title <- @pending.titles} class="truncate">{title}</li>
        </ul>
        <label
          :if={@class}
          class="mt-4 flex items-center gap-2 text-sm text-zinc-600 dark:text-zinc-300 select-none"
        >
          <input type="checkbox" name="dont_show" value="true" class="checkbox checkbox-sm" />
          Don't show this again for {confirm_class_label(@class)}
        </label>
        <div class="mt-5 flex justify-end gap-2">
          <%!-- data-confirm-cancel: app.js reverts held optimism + strips the
               maybe-write hue at the click (.03.07.16) — the cancel_pending
               round trip reconciles the same state behind it. --%>
          <button
            type="button"
            data-confirm-cancel
            phx-click={
              Phoenix.LiveView.JS.hide(to: "#completion-confirm")
              |> Phoenix.LiveView.JS.push("cancel_pending")
            }
            class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200 active:scale-95 transition dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:active:bg-zinc-700"
          >
            Cancel
          </button>
          <button
            type="submit"
            phx-disable-with="Working…"
            class="rounded px-3 py-1.5 text-sm font-medium text-white active:scale-95 transition bg-emerald-600 hover:bg-emerald-700 active:bg-emerald-800"
          >
            Proceed
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp confirm_title(%{kind: :cascade_sort}), do: "Large branch reorg"
  defp confirm_title(_), do: "Confirm completion change"

  defp confirm_body(%{kind: :cascade_sort, affected: n}, _verb) do
    "This is a large branch reorg affecting #{n} task(s). Every descendant branch " <>
      "switches to Inherit — their own sort settings are overwritten and they follow " <>
      "this branch from now on; reversible only via Undo (Arc 5)."
  end

  defp confirm_body(%{scenario: scenario}, verb) when is_integer(scenario),
    do: completion_confirm_message(scenario, verb)

  defp confirm_body(_, _), do: ""

  defp completion_confirm_message(1, verb),
    do: "This #{verb} will mark previously completed task(s) as incomplete."

  defp completion_confirm_message(2, verb),
    do: "This #{verb} will mark previously incomplete task(s) as complete."

  defp completion_confirm_message(3, verb),
    do: "This #{verb} will mark some tasks complete and others incomplete."

  # --- Components -----------------------------------------------------------

  attr :initiative, :map, required: true
  attr :subtitle, :string, required: true
  attr :initiative_progress, :integer, required: true
  attr :can_edit, :boolean, required: true

  @doc """
  The initiative header — grove icon + name, subtitle/description, roll-up
  progress bar, and the desktop "New List" button (m02.07 item 1.2). On the
  shell it's the center column's flex-none top: a fixed sibling above the
  tree's scroll box (never sticky inside it), so the tree scrolls beneath while
  the header stays put.
  """
  def initiative_header(assigns) do
    ~H"""
    <div class="relative pb-6">
      <%!-- Title row (dedicated): grove icon + name. New List inline on desktop only. --%>
      <div class="flex items-start gap-2">
        <%!-- The grove icon + title are one click/tap-to-edit affordance, styled as a
             subtle button (persistent soft border, hover tint, pressed state) so the
             edit cue reads without hover (mobile). An <h1> can't live in a real
             <button>, so this is a role="button" wrapper with keyboard support; the
             delegated [data-edit-initiative] click + the editor-signifier preserve
             path ride on the wrapper. Gated on @can_edit — viewers see a plain title. --%>
        <%= if @can_edit do %>
          <span
            data-edit-initiative
            data-keep="editor-signifier"
            role="button"
            tabindex="0"
            aria-label="Edit initiative name"
            title="Edit name"
            class="group flex items-start gap-2 px-2 py-1 rounded-lg cursor-pointer border border-zinc-400 dark:border-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:bg-zinc-200 dark:active:bg-zinc-700 transition"
          >
            <span class="mt-1 text-emerald-600 dark:text-emerald-400" aria-hidden="true">
              <.botanical_icon kind={:grove} class="w-6 h-6" />
            </span>
            <h1 class="text-2xl font-semibold text-zinc-800 dark:text-zinc-100 group-hover:text-zinc-900 dark:group-hover:text-white">
              {@initiative.name}
            </h1>
          </span>
        <% else %>
          <span class="flex items-start gap-2">
            <span class="mt-1 text-emerald-600 dark:text-emerald-400" aria-hidden="true">
              <.botanical_icon kind={:grove} class="w-6 h-6" />
            </span>
            <h1 class="text-2xl font-semibold text-zinc-800 dark:text-zinc-100">
              {@initiative.name}
            </h1>
          </span>
        <% end %>
        <button
          :if={@can_edit}
          type="button"
          data-add-root
          class="mt-1 ml-auto hidden lg:inline-flex items-center gap-1 px-2 py-0.5 rounded text-sm font-bold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
          aria-label="New list"
          title="New list"
        >
          <.icon name="hero-plus" class="w-4 h-4" />
          <span>New List</span>
        </button>
      </div>

      <p
        :if={@subtitle != ""}
        data-initiative-subtitle-body
        data-edit-initiative
        data-keep="editor-signifier"
        title="Click to edit"
        class="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5 cursor-pointer hover:text-zinc-700 dark:hover:text-zinc-200"
      >
        {@subtitle}
      </p>

      <p
        :if={@initiative.description}
        data-initiative-description-body
        class="text-sm text-zinc-500 dark:text-zinc-400 mt-1"
      >
        {@initiative.description}
      </p>

      <div
        class="absolute bottom-1 left-0 right-0 h-4 bg-zinc-100 dark:bg-zinc-800 rounded-full overflow-hidden"
        role="progressbar"
        aria-valuenow={@initiative_progress}
        aria-valuemin="0"
        aria-valuemax="100"
        aria-label={"Initiative progress: #{@initiative_progress}%"}
        style={"--progress: #{@initiative_progress}%"}
      >
        <div
          class="absolute inset-y-0 left-0 bg-emerald-400 rounded-full"
          style="width: var(--progress)"
        >
        </div>
        <span class="absolute inset-0 flex items-center justify-center text-xs font-semibold text-zinc-900 dark:text-zinc-50 progress-bar-text">
          {@initiative_progress}%
        </span>
      </div>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :depth, :integer, required: true
  # Positional index chain (item 1.7): this node's zero-based sibling positions
  # from the root down, e.g. [0, 2] = first list → its third child. Threaded so
  # the label is derived from sort order at render — correct on reorder/move.
  attr :index_positions, :list, required: true
  attr :index_style, :string, required: true
  attr :can_edit, :boolean, required: true
  attr :initiative_id, :integer, required: true
  attr :saving_ids, :any, required: true
  attr :recompute_ids, :any, required: true
  attr :inherited_sort, :string, required: true
  attr :progress_calc, :string, required: true
  attr :display, :map, required: true
  attr :member_ids, :any, required: true
  attr :led_ids, :any, default: %MapSet{}

  def task_node(assigns) do
    assigns = assign(assigns, :resolved_sort, assigns.task.sort_mode || assigns.inherited_sort)

    assigns =
      assign(
        assigns,
        :index_label,
        DoIt.Tasks.Index.label(assigns.index_positions, assigns.index_style)
      )

    # Viewer+ (item 12.6): a viewer who leads this task may flip its progress,
    # even without can_edit. Other affordances stay can_edit only.
    assigns =
      assign(
        assigns,
        :can_progress,
        assigns.can_edit or MapSet.member?(assigns.led_ids, assigns.task.id)
      )

    ~H"""
    <%!-- Selection is client-owned (UX_GUARDRAILS 6.5): the data-selected attr
         is set by the client and the highlight comes from app.css rules under
         li[data-selected], so selection never re-renders the tree. Row clicks
         are handled by the delegated listener in app.js. --%>
    <li
      id={"task-#{@task.id}"}
      data-task-id={@task.id}
      data-keep="selected"
      data-depth={@depth}
      data-sort={@task.sort_mode || ""}
      data-sort-reverse={to_string(@task.sort_reverse)}
      class="rounded border border-zinc-400 dark:border-zinc-700 bg-white dark:bg-zinc-900 first:border-t-2 first:border-t-zinc-500 dark:first:border-t-zinc-500"
    >
      <%!-- data-done drives the done styling (title strikethrough via
           group-data-done variants) so the optimistic toggle (.03.07.22)
           flips one attribute; group/row scopes it. --%>
      <div
        data-task-row
        data-keep="pending-toggle"
        data-done={@task.status == "done"}
        data-task-progress={progress_value(@task)}
        data-can-progress={to_string(@can_progress)}
        class={[
          "group/row relative flex flex-wrap items-center gap-x-2 xl:gap-x-3 gap-y-1 px-3 xl:px-5 2xl:px-6 pt-2 pb-6 min-w-[240px] cursor-pointer",
          MapSet.member?(@saving_ids, @task.id) && "is-saving",
          MapSet.member?(@recompute_ids, @task.id) && "is-recomputing",
          "hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
        ]}
      >
        <span
          :if={@can_edit}
          id={"drag-#{@task.id}"}
          phx-hook="DragReorder"
          aria-hidden="true"
          data-task-id={@task.id}
          data-parent-id={@task.parent_id}
          data-depth={@depth}
          data-initiative-id={@initiative_id}
          class="flex-none -my-2 w-11 h-11 flex items-center justify-center gap-0.5 text-zinc-600 dark:text-zinc-600 hover:text-zinc-800 dark:hover:text-zinc-400 cursor-grab active:cursor-grabbing touch-none"
        >
          <.icon name="hero-ellipsis-vertical" class="w-3 h-3" />
          <span class={botanical_color(@task, @depth)}>
            <.botanical_icon kind={botanical_kind(@task, @depth)} />
          </span>
          <.icon name="hero-ellipsis-vertical" class="w-3 h-3" />
        </span>
        <%!-- Viewers (no drag handle): the type icon alone. --%>
        <span
          :if={not @can_edit}
          class={["flex-none", botanical_color(@task, @depth)]}
          aria-hidden="true"
        >
          <.botanical_icon kind={botanical_kind(@task, @depth)} />
        </span>
        <%!-- Positional task index (item 1.7): a display-only label between the
             botanical icon and the pills, derived from sibling position at every
             level. Rendered only when the Initiative's index style isn't "none"
             (empty label = no element). The copy button (delegated handler in
             app.js, data-copy-index) writes the label to the clipboard; it's
             revealed on row hover / keyboard focus, and always shown on touch
             devices (no hover) so it stays tappable. --%>
        <span
          :if={@index_label != ""}
          data-task-index
          class="group/idx flex-none inline-flex items-center gap-1 font-mono text-xs font-medium text-zinc-500 dark:text-zinc-400 tabular-nums select-none"
        >
          {@index_label}
          <button
            type="button"
            data-copy-index={@index_label}
            aria-label={"Copy index #{@index_label}"}
            title="Copy index"
            class="flex-none inline-flex items-center justify-center w-4 h-4 rounded text-zinc-400 hover:text-zinc-700 dark:text-zinc-500 dark:hover:text-zinc-200 opacity-0 group-hover/row:opacity-100 focus-visible:opacity-100 [@media(hover:none)]:opacity-100 transition-opacity"
          >
            <span data-copy-icon class="inline-flex">
              <.icon name="hero-clipboard-document" class="w-3 h-3" />
            </span>
            <span data-copied-icon class="hidden text-emerald-600 dark:text-emerald-400">
              <.icon name="hero-check" class="w-3 h-3" />
            </span>
          </button>
        </span>
        <%!-- Row 1: attribute chips. Priority + assignee always occupy
             a slot; defaults render as an empty dashed placeholder of the same
             size so customized values stand out and stay column-aligned. Each
             chip taps through to its Details field (item: select + focus). They
             live in a min-w-0 overflow-hidden group so they clip together
             (rightmost first) instead of wrapping Row 1 when depth narrows it. --%>
        <div class="flex flex-1 items-center gap-2 min-w-0 overflow-hidden">
          <%!-- Debug-only ID pill (idclip easter egg). Hidden unless the
               `debug-task-ids` class is toggled on; shows this task's id and,
               on hover, its parent id — for diagnosing drag/drop placement. --%>
          <span
            class="task-id-pill items-center justify-center h-5 px-1.5 rounded-full text-xs flex-none font-mono bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300"
            title={"parent #{@task.parent_id}"}
          >
            {"#" <> Integer.to_string(@task.id)}
          </span>
          <%!-- Pills carry their customized/default state as `data-pill-set`
               (styled via Tailwind data-variants), so the optimistic row echo
               in app.js flips one attribute instead of juggling class lists.
               A pill tap selects + focuses its Details field client-side
               (data-pill names the field); the phx-click only loads pane
               data when the task wasn't selected yet (.03.07.17). --%>
          <%!-- Priority always has a value, so the pill is always "set". Its
               color is a chip accent (item 1.6): a colored border + text over a
               soft tint, keyed off data-priority via app.css rules (light/dark).
               Driving the color off one attribute lets the optimistic echo
               recolor by flipping data-priority — and the label always stays,
               so it reads without relying on hue alone (colorblind-safe). --%>
          <button
            :if={@display.priority}
            type="button"
            phx-click="select_task"
            phx-value-id={@task.id}
            data-pill="priority"
            data-pill-set
            data-priority={@task.priority}
            class="priority-pill inline-flex items-center justify-center h-5 min-w-9 px-1.5 rounded-full text-xs flex-none cursor-pointer border"
            title={"Priority: #{@task.priority}"}
          >
            {@task.priority}
          </button>
          <button
            :if={@display.assignee}
            type="button"
            phx-click="select_task"
            phx-value-id={@task.id}
            data-pill="assignee"
            data-pill-set={
              (not is_nil(@task.assignee_id) and not is_nil(@task.assignee)) or
                @task.co_assignee_count > 0
            }
            class={[
              "inline-flex items-center justify-center h-5 min-w-9 max-w-[45%] px-1.5 rounded-full text-xs flex-none cursor-pointer",
              "border border-dashed border-zinc-300 dark:border-zinc-600",
              "data-pill-set:border-solid data-pill-set:border-zinc-400 dark:data-pill-set:border-zinc-500 data-pill-set:bg-zinc-100 dark:data-pill-set:bg-zinc-800 data-pill-set:text-zinc-600 dark:data-pill-set:text-zinc-300"
            ]}
            title={assignee_title(@task, @member_ids)}
          >
            <%!-- Avatar is always in the DOM (hidden when unassigned) so the
                 optimistic echo can fill it from the pane select's data attrs. --%>
            <span
              data-pill-avatar
              data-assignee-id={@task.assignee_id}
              hidden={!(@task.assignee_id && @task.assignee)}
              class="avatar-emboss relative inline-flex flex-none items-center justify-center w-3.5 h-3.5 mr-1 rounded-full text-[8px] font-semibold select-none"
              style={
                @task.assignee &&
                  "background-image: #{avatar_bg(@task.assignee)}; color: #{avatar_fg(@task.assignee)}"
              }
              aria-hidden="true"
            >
              {@task.assignee && initials(@task.assignee)}
            </span>
            <%!-- Struck through when the assignee is no longer a member —
                 a member who leaves voluntarily keeps their assignments
                 (owner-initiated removal hands them off instead), and the
                 strike says so at a glance. --%>
            <span
              class={["truncate", ex_member?(@task, @member_ids) && "line-through"]}
              data-pill-text
            >
              {if @task.assignee_id && @task.assignee, do: "@#{@task.assignee.username}"}
            </span>
            <%!-- Co-assignees (m02.05 item 16): "+" then their overlapping
                 avatars (capped server-side), with a "+N" tail for any
                 overflow. Corrects on the server patch after an optimistic
                 primary change (the echo can't synthesize co's). --%>
            <span
              :if={@task.co_assignee_count > 0}
              data-co-count
              title={"#{@task.co_assignee_count} co-assignee(s)"}
              class="ml-0.5 flex-none inline-flex items-center"
            >
              <span class="text-[10px] font-semibold opacity-80">+</span>
              <span class="inline-flex items-center -space-x-1 ml-0.5">
                <.avatar
                  :for={u <- @task.co_assignee_users}
                  user={u}
                  class="w-3.5 h-3.5 text-[7px] ring-1 ring-white dark:ring-zinc-900"
                />
              </span>
              <span
                :if={@task.co_assignee_count > length(@task.co_assignee_users)}
                class="ml-0.5 text-[10px] font-semibold opacity-80"
              >
                +{@task.co_assignee_count - length(@task.co_assignee_users)}
              </span>
            </span>
          </button>

          <%!-- Other members' selection-presence avatars (.04.01.12). The
               server renders the slot empty; the PresenceBadges hook fills
               it and the patch-guard re-applies after morphdom passes. --%>
          <span
            data-presence-slot={@task.id}
            class="inline-flex items-center gap-0.5 flex-none"
            aria-hidden="true"
          >
          </span>

          <%!-- Co-assignee seed (item 15.11): hidden, machine-readable copy of
               the chip above, so selecting this task fills the pane's optimistic
               co-list instantly — before the server reply. Capped like the chip
               (co_assignee_users); the full interactive list reconciles on the
               reply. --%>
          <span
            :for={u <- @task.co_assignee_users}
            hidden
            data-co-seed
            data-user-id={u.id}
            data-name={u.username}
            data-initials={initials(u)}
            data-avatar-bg={avatar_bg(u)}
            data-avatar-fg={avatar_fg(u)}
          >
          </span>
        </div>

        <%!-- Row 1, pinned right: the new-task button. --%>
        <div :if={@can_edit} class="relative flex-none ml-auto">
          <div class="inline-flex rounded border border-emerald-600 dark:border-emerald-500 overflow-hidden">
            <button
              type="button"
              data-add-child={@task.id}
              class="inline-flex items-center justify-center gap-1 w-8 h-8 sm:w-auto sm:h-auto sm:min-w-11 sm:px-2 sm:py-0.5 text-xs font-bold text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
              aria-label={if(@depth == 0, do: "New task", else: "New subtask")}
              title={if(@depth == 0, do: "New task", else: "New subtask")}
            >
              <.icon name="hero-plus" class="w-4 h-4" />
              <span class="hidden sm:inline">
                <span class="kbd-key">N</span>{if(@depth == 0,
                  do: "ew Task",
                  else: "ew Subtask"
                )}
              </span>
            </button>
            <button
              type="button"
              id={"add-menu-#{@task.id}"}
              phx-click={Phoenix.LiveView.JS.toggle(to: "#add-menu-panel-#{@task.id}")}
              aria-label="More add options"
              title="More add options"
              class="hidden sm:inline-flex items-center px-1 text-emerald-700 dark:text-emerald-400 border-l border-emerald-600 dark:border-emerald-500 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
            >
              <.icon name="hero-chevron-down" class="w-3.5 h-3.5" />
            </button>
          </div>
          <div
            id={"add-menu-panel-#{@task.id}"}
            class="hidden absolute right-0 top-full mt-1 z-10 bg-white dark:bg-zinc-900 border border-zinc-300 dark:border-zinc-700 rounded shadow-lg"
          >
            <button
              type="button"
              data-add-sibling={@task.id}
              phx-click={Phoenix.LiveView.JS.hide(to: "#add-menu-panel-#{@task.id}")}
              class="block w-full text-left whitespace-nowrap px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800"
            >
              + Add <span class="kbd-key">S</span>ibling
            </button>
          </div>
        </div>

        <%!-- Row 2: title with its glued chevron. --%>
        <div class="w-full flex items-baseline gap-1 min-w-0">
          <button
            :if={@task.children != []}
            type="button"
            id={"collapse-#{@task.id}"}
            phx-hook="CollapseToggle"
            phx-update="ignore"
            data-task-id={@task.id}
            data-initiative-id={@initiative_id}
            aria-controls={"children-#{@task.id}"}
            aria-label="Toggle children"
            class="group flex-none inline-flex items-center justify-center w-5 h-5 rounded-full text-black bg-emerald-400 hover:bg-emerald-300 group-data-done/row:bg-emerald-500 group-data-done/row:hover:bg-emerald-400 transition-colors motion-reduce:transition-none"
          >
            <.icon
              name="hero-chevron-down-solid"
              class="w-4 h-4 transition-transform motion-reduce:transition-none group-aria-[expanded=false]:-rotate-90"
            />
          </button>

          <%!-- Leaf count lives OUTSIDE the phx-update="ignore" button so the
               server keeps it live — inside, it froze at its mount-time value. --%>
          <span
            :if={@task.children != [] && @display.count}
            title={branch_unit_title(@progress_calc)}
            class="flex-none relative top-[-0.4em] inline-flex items-center gap-0.5 text-sm font-bold tabular-nums text-emerald-400 group-data-done/row:text-emerald-500"
          >
            <%!-- The unit's icon: green leaf (leaf_average) / amber branch
                 (single_level) — mode tellable at a glance. Leaf inherits
                 the count's emerald via currentColor. --%>
            <.botanical_icon
              kind={badge_icon(@progress_calc)}
              class={badge_icon_class(@progress_calc)}
            />
            {branch_unit_count(@task, @progress_calc)}
          </span>

          <%!-- No phx-click: app.js owns the click (.03.07.22) — it flips the
               operated row optimistically (aria-pressed, data-done, bar) and
               pushes data-toggle-event with a reply, so a confirm-gated
               cascade can HOLD the flip while the modal decides (6.6). --%>
          <button
            :if={@can_progress && @display.progress}
            type="button"
            data-toggle-event={
              cond do
                @task.children == [] -> "toggle_complete"
                @task.status == "done" -> "cascade_incomplete"
                true -> "cascade_complete"
              end
            }
            data-complete-toggle
            aria-label={if @task.status == "done", do: "Reopen task", else: "Mark task completed"}
            aria-pressed={to_string(@task.status == "done")}
            class={[
              "group/check absolute bottom-0.5 left-3 z-10 w-5 h-5 rounded border-2 flex items-center justify-center transition-colors motion-reduce:transition-none",
              "border-emerald-500 bg-transparent text-emerald-500 hover:border-emerald-400",
              "drop-shadow-[0_1px_1px_rgba(0,0,0,0.65)]"
            ]}
          >
            <%!-- Check visibility keys off aria-pressed (not server-conditional
                 classes) so the optimistic leaf flip in app.js is one attribute
                 write. Micro variant (tightest glyph padding) stretched to the
                 box's full w-5 — mask-size pinned so the vendor plugin's
                 per-variant size can't shrink it. The box's transparent middle
                 rules out box-shadow; the button's drop-shadow filter above
                 shadows the border ring and this glyph together. --%>
            <.icon
              name="hero-check-micro"
              class="w-5 h-5 [mask-size:100%_100%] [-webkit-mask-size:100%_100%] hidden group-aria-pressed/check:inline-block"
            />
          </button>

          <span
            data-task-title
            class={[
              "flex-1 min-w-0",
              @depth == 0 && "text-xl 2xl:text-2xl font-bold",
              @depth > 0 && "text-sm font-medium",
              "group-data-done/row:line-through group-data-done/row:text-zinc-400 dark:group-data-done/row:text-zinc-500"
            ]}
          >
            {@task.title}
          </span>
        </div>

        <%!-- Row 3: description. Single-line truncate on narrow; once there's
             room (xl:) it relaxes to a two-line clamp so wide rows show more
             without letting heights vary unbounded. Always in the DOM (hidden
             when empty) so the optimistic row echo can fill it. --%>
        <span
          data-task-description
          hidden={is_nil(@task.description) or @task.description == ""}
          class="w-full min-w-0 text-sm text-zinc-400 dark:text-zinc-500 truncate xl:whitespace-normal xl:line-clamp-2"
        >
          {@task.description}
        </span>

        <div
          :if={@display.progress}
          class={[
            "absolute bottom-1 right-2 h-4 bg-zinc-100 dark:bg-zinc-800 rounded-full overflow-hidden",
            if(@can_edit, do: "left-9", else: "left-2")
          ]}
          role="progressbar"
          aria-valuenow={progress_value(@task)}
          aria-valuemin="0"
          aria-valuemax="100"
          aria-label={"Progress: #{progress_value(@task)}%"}
          style={"--progress: #{progress_value(@task)}%"}
        >
          <div
            class="absolute inset-y-0 left-0 rounded-full bg-emerald-400 group-data-done/row:bg-emerald-500"
            style="width: var(--progress)"
          >
          </div>
          <span class="absolute inset-0 flex items-center justify-center text-xs font-semibold text-zinc-900 dark:text-zinc-50 progress-bar-text">
            {progress_value(@task)}%
          </span>
        </div>
      </div>

      <div id={"add-slot-#{@task.id}"} phx-update="ignore" class="px-3 pb-3 empty:hidden"></div>

      <ul
        :if={@task.children != []}
        id={"children-#{@task.id}"}
        data-keep="collapse"
        data-task-id={@task.id}
        data-initiative-id={@initiative_id}
        data-sort-mode={@resolved_sort}
        class="pl-1.5 sm:pl-6 space-y-1"
      >
        <%= for {c, i} <- Enum.with_index(@task.children) do %>
          <.task_node
            task={c}
            depth={@depth + 1}
            index_positions={@index_positions ++ [i]}
            index_style={@index_style}
            can_edit={@can_edit}
            initiative_id={@initiative_id}
            saving_ids={@saving_ids}
            recompute_ids={@recompute_ids}
            inherited_sort={@resolved_sort}
            progress_calc={@progress_calc}
            display={@display}
            member_ids={@member_ids}
            led_ids={@led_ids}
          />
          <li id={"add-after-#{c.id}"} phx-update="ignore" class="empty:hidden"></li>
        <% end %>
        <%!-- Item 21: tail drop-zone — "last child of this branch." Sits at the
             child indent (inside this <ul>), so nested tails stack into a
             leftward staircase. Clipped away when the branch is collapsed. --%>
        <li :if={@can_edit} class="drop-tail" data-tail-for={@task.id} aria-hidden="true"></li>
      </ul>
    </li>
    """
  end

  attr :form, :map, required: true
  attr :can_edit, :boolean, required: true
  attr :can_admin, :boolean, required: true
  attr :initiative, :map, required: true
  attr :root_task, :map, required: true
  attr :subtitle, :string, required: true
  attr :am_owner, :boolean, required: true

  def initiative_editor(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-start justify-between gap-2">
        <h3 class="font-medium text-zinc-800 dark:text-zinc-100">Initiative details</h3>
        <button
          type="button"
          data-close-initiative
          aria-label="Close"
          title="Close"
          class="hidden lg:inline-flex items-center justify-center w-7 h-7 rounded bg-red-500/30 hover:bg-red-500/50 text-white font-bold"
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>
      </div>

      <.form
        for={@form}
        id="initiative-form"
        phx-change="update_initiative"
        phx-submit="update_initiative"
        class="space-y-3"
      >
        <%!-- Name takes no %-ref: it renders inside the header's click-to-edit
             button, where a nested ref link fights the edit affordance (WL3
             item 3.6 reversal). Subtitle/Description keep refs. --%>
        <.input
          field={@form[:name]}
          type="text"
          label="Name"
          required
          disabled={not @can_edit}
          phx-debounce="600"
        />

        <%!-- Subtitle is stored in the root task's title (.05.03), so it has its
             own write path rather than riding the Initiative changeset. --%>
        <div>
          <div class="flex items-center gap-2">
            <label for="initiative-subtitle" class="text-xs text-zinc-500 dark:text-zinc-400">
              Subtitle
            </label>
            <%!-- Saved-tick (WL3 item 3.7, §6.7): server-rendered hidden, revealed
                 for ~1.2s by the TaskKeys hook on the "subtitle-saved" push_event,
                 then re-hidden. Transient + self-clearing like flashCopied, so it
                 rides the preserve path with no data-keep (the server always
                 renders it hidden, so any patch can only re-hide it). --%>
            <span
              id="subtitle-saved-tick"
              hidden
              class="inline-flex items-center gap-0.5 text-[11px] font-medium text-emerald-600 dark:text-emerald-400"
            >
              <.icon name="hero-check" class="w-3 h-3" /> Saved
            </span>
            <.ref_picker_button
              :if={@can_edit}
              target="#initiative-subtitle"
              class="ml-auto"
            />
          </div>
          <%!-- RefField + save-on-blur (WL3 item 3.6), same as Name; keeps its own
               update_subtitle write path (root-task title, bypasses edge-sync). --%>
          <input
            id="initiative-subtitle"
            type="text"
            name="subtitle"
            value={@subtitle}
            placeholder="a short tagline for this initiative"
            class="w-full input input-bordered input-sm"
            disabled={not @can_edit}
            phx-change="update_subtitle"
            phx-debounce="blur"
            phx-hook="RefField"
          />
        </div>

        <%!-- %-ref support (WL3 item 3.6): RefField + picker + save-on-blur, as Name. --%>
        <div class="relative">
          <.input
            field={@form[:description]}
            type="textarea"
            label="Description"
            disabled={not @can_edit}
            phx-debounce="blur"
            phx-hook="RefField"
          />
          <.ref_picker_button
            :if={@can_edit}
            target="#initiative_description"
            class="absolute top-0 right-0"
          />
        </div>
      </.form>

      <%!-- Per-user Archive + Hide (m02.08 worklist 4): part of the Initiative
           details, available to ANY member (per-user, never affects others).
           Archive → the restorable Archived list; Hide → the lighter "off my
           dashboard" move. Archive may confirm first (item 4.2, server-decided
           on unfinished work), so it's a plain phx-click, not a client dialog. --%>
      <div class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          id="archive-initiative-btn"
          data-archive-btn
          data-am-owner={to_string(@am_owner)}
          title="Archive for yourself — restorable from your Archived list"
          class="inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-semibold border border-zinc-300 dark:border-zinc-600 text-zinc-700 dark:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:scale-95 transition"
        >
          <.icon name="hero-archive-box" class="w-3.5 h-3.5" /> Archive
        </button>
        <button
          type="button"
          id="hide-initiative-btn"
          phx-click="hide_initiative"
          data-latch="Hiding…"
          title="Hide from your dashboard — unhide from your Archived list"
          class="inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-semibold border border-zinc-300 dark:border-zinc-600 text-zinc-700 dark:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:scale-95 transition"
        >
          <.icon name="hero-eye-slash" class="w-3.5 h-3.5" /> Hide
        </button>
      </div>

      <div class={[
        "text-xs text-zinc-500 dark:text-zinc-400 italic",
        leaf?(@root_task) && "invisible"
      ]}>
        Computed from children: {@root_task.computed_progress}%
      </div>

      <.sort_menu task={@root_task} can_edit={@can_edit} label="Sort lists by" scope="init" />

      <%!-- Settings (.03.07.07): collapsed by default; initiative-wide
           behavior that isn't day-to-day editing. data-keep="open" preserves
           the open/closed state across LiveView patches. --%>
      <details
        id="initiative-settings"
        data-keep="open"
        class="border-t border-zinc-200 dark:border-zinc-700 pt-3"
      >
        <summary class="cursor-pointer select-none font-medium text-zinc-800 dark:text-zinc-100">
          Settings
        </summary>
        <div class="mt-3 space-y-3">
          <div>
            <div class="flex items-center gap-1">
              <label for="progress-calc" class="text-xs text-zinc-500 dark:text-zinc-400">
                Progress calculation
              </label>
              <.info_hint id="calc-hint" label="How do the methods differ?">
                <dl class="space-y-2">
                  <div>
                    <dt class="font-medium text-zinc-700 dark:text-zinc-200">
                      Leaf average <span class="font-normal text-zinc-400">(default)</span>
                    </dt>
                    <dd>
                      Every leaf counts equally, however deep it sits. Breaking a
                      branch into more leaves makes it count for more.
                    </dd>
                  </div>
                  <div>
                    <dt class="font-medium text-zinc-700 dark:text-zinc-200">
                      Single-level average
                    </dt>
                    <dd>
                      Each direct child counts as one unit, no matter how many leaves
                      it holds.
                    </dd>
                  </div>
                  <div class="pt-1 border-t border-zinc-100 dark:border-zinc-700 text-zinc-500 dark:text-zinc-400 space-y-1">
                    <p>Example: a List contains</p>
                    <ul class="list-disc pl-4 space-y-0.5">
                      <li>✓ one completed Task</li>
                      <li>one unfinished Task with 40 unfinished Tasks inside it</li>
                    </ul>
                    <p>
                      Leaf average →
                      <span class="font-medium text-zinc-700 dark:text-zinc-200">2%</span>
                      (1 of 41 Tasks complete)
                    </p>
                    <p>
                      Single-level average →
                      <span class="font-medium text-zinc-700 dark:text-zinc-200">50%</span>
                      (1 of the List's 2 Tasks complete)
                    </p>
                  </div>
                </dl>
              </.info_hint>
            </div>
            <form phx-change="set_progress_calc">
              <select
                id="progress-calc"
                name="calc"
                class="w-full select select-bordered select-sm"
                disabled={not @can_edit}
              >
                <option value="leaf_average" selected={@initiative.progress_calc == "leaf_average"}>
                  Leaf average — every leaf counts equally
                </option>
                <option
                  value="single_level"
                  selected={@initiative.progress_calc == "single_level"}
                >
                  Single-level average — each child one unit
                </option>
              </select>
            </form>
          </div>

          <%!-- m02.07 item 1.7.2: positional task-index style. A property of the
               tree (per-Initiative), so it lives with the Initiative settings,
               not the account. None is the default. --%>
          <div>
            <label for="index-style" class="text-xs text-zinc-500 dark:text-zinc-400">
              Task numbering
            </label>
            <form phx-change="set_index_style">
              <select
                id="index-style"
                name="index_style"
                class="w-full select select-bordered select-sm"
                disabled={not @can_edit}
              >
                <option value="none" selected={@initiative.index_style == "none"}>
                  None — no index shown
                </option>
                <option value="outline" selected={@initiative.index_style == "outline"}>
                  Outline — I.A.1.a.i
                </option>
                <option value="numerical" selected={@initiative.index_style == "numerical"}>
                  Numerical — 1.1.2
                </option>
                <option value="roman" selected={@initiative.index_style == "roman"}>
                  Roman — I.II.III
                </option>
                <option value="alphabetical" selected={@initiative.index_style == "alphabetical"}>
                  Alphabetical — A.B.C
                </option>
              </select>
            </form>
          </div>

          <%!-- m02.05 item 12.6: owner-only, since it's a permission policy. --%>
          <div :if={@can_admin}>
            <form phx-change="set_viewer_plus">
              <label class="flex items-center gap-2 text-xs text-zinc-600 dark:text-zinc-300 select-none">
                <input
                  type="checkbox"
                  name="viewer_plus"
                  value="true"
                  checked={@initiative.viewer_plus}
                  class="checkbox checkbox-sm"
                /> Viewer+ — an assigned viewer leads their subtree
                <%!-- Saved-tick (WL3 item 3.7, §6.7): the success ack for the
                     in-flight signifier; revealed for ~1.2s by the TaskKeys hook
                     on "viewer-plus-saved", then re-hidden (same as subtitle). --%>
                <span
                  id="viewer-plus-saved-tick"
                  hidden
                  class="inline-flex items-center gap-0.5 text-[11px] font-medium text-emerald-600 dark:text-emerald-400"
                >
                  <.icon name="hero-check" class="w-3 h-3" /> Saved
                </span>
              </label>
              <p class="mt-0.5 text-[11px] text-zinc-400 dark:text-zinc-500">
                A viewer who is a task's assignee can update its progress and comments (and
                everything below it), and staff descendants from that task's co-assignees.
              </p>
            </form>
          </div>
        </div>
      </details>

      <%!-- Delete (owner-only): irreversible, so it stays in the destructive
           cluster below Settings — apart from the per-user Archive/Hide that now
           live up in the details. No phx-click: the confirm opens client-side
           (.03.07.18). --%>
      <div
        :if={@can_admin}
        class="border-t border-zinc-100 dark:border-zinc-700 pt-3 flex flex-wrap items-center gap-2"
      >
        <button
          type="button"
          id="delete-initiative-btn"
          class="inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-semibold text-white bg-red-600 hover:bg-red-700 dark:bg-red-700 dark:hover:bg-red-600 active:scale-95 transition"
        >
          <.icon name="hero-trash" class="w-3.5 h-3.5" /> Delete initiative
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :members, :list, required: true
  attr :can_admin, :boolean, required: true
  attr :online_ids, :any, required: true
  attr :owner_id, :integer, required: true
  attr :me, :integer, required: true
  # Viewer+ label (item 12.6.5): user ids that are a direct assignee somewhere,
  # and whether the Initiative's viewer_plus setting is on — a viewer in both
  # reads "viewer+".
  attr :assignee_ids, :any, default: %MapSet{}
  attr :viewer_plus_on, :boolean, default: false
  # Item 12.8.1: show the drag handle (and arm member→task drag) only when the
  # current user can assign anyone (editor/owner, or a viewer+ who leads a task).
  attr :can_assign, :boolean, default: false

  @doc """
  The Initiative's Members list + add-member form. Shared by the aside panel
  (desktop/tablet) and the mobile header collapsible (.05.04.1). The form
  opens client-side (native <details>, UX_GUARDRAILS 6.5); data-keep="open"
  carries its state across patches.
  """
  def members_panel(assigns) do
    ~H"""
    <div
      id={@id}
      class="rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 p-4"
    >
      <div class="flex items-center justify-between mb-2">
        <h3 class="font-medium text-zinc-800 dark:text-zinc-100">Members</h3>
        <button
          :if={@can_admin}
          type="button"
          data-details-toggle={"#{@id}-form"}
          class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-bold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
        >
          <.icon name="hero-plus" class="w-3.5 h-3.5" />
          <span>Add Member</span>
        </button>
      </div>

      <%!-- Client-opened (UX_GUARDRAILS 6.5): the button flips this <details>
           and data-keep="open" carries the state across patches. --%>
      <details :if={@can_admin} id={"#{@id}-form"} data-keep="open" class="mb-3">
        <summary class="hidden"></summary>
        <div>
          <form phx-submit="add_member" class="flex flex-col gap-2">
            <input
              type="text"
              name="member"
              placeholder="email or @username"
              aria-label="Member email or username"
              required
              phx-mounted={Phoenix.LiveView.JS.focus()}
              class="w-full input input-bordered input-sm"
            />
            <select
              name="role"
              aria-label="Member role"
              class="w-full select select-bordered select-sm"
            >
              <option value="editor">Editor</option>
              <option value="viewer">Viewer</option>
              <option value="owner">Owner</option>
            </select>
            <div class="flex justify-end gap-2">
              <button
                type="button"
                data-details-close={"#{@id}-form"}
                class="text-xs text-zinc-500 hover:text-zinc-800 dark:text-zinc-100 dark:hover:text-white"
              >
                Cancel
              </button>
              <button
                type="submit"
                data-latch="Adding…"
                class="text-xs px-2 py-1 rounded bg-emerald-600 text-white hover:bg-emerald-700"
              >
                Add
              </button>
            </div>
          </form>
        </div>
      </details>

      <ul data-members-list class="space-y-1 text-sm">
        <li
          :for={m <- @members}
          data-member-row
          data-user-id={m.user_id}
          class="flex items-center justify-between"
        >
          <span class="flex items-center gap-1 min-w-0 text-zinc-700 dark:text-zinc-200">
            <%!-- Drag handle (item 12.8.1): grab a member and drop them on a
                 task to assign. Shown only when this user can assign; desktop
                 pointer drag, with the assignee select / co-list as the a11y
                 + touch path. --%>
            <span
              :if={@can_assign}
              id={"member-drag-#{@id}-#{m.user_id}"}
              phx-hook="MemberDrag"
              data-user-id={m.user_id}
              data-username={m.user.username}
              data-initials={initials(m.user)}
              data-avatar-bg={avatar_bg(m.user)}
              data-avatar-fg={avatar_fg(m.user)}
              title={"Drag #{m.user.name} onto a task to assign"}
              aria-hidden="true"
              class="flex-none -ml-1 cursor-grab touch-none text-zinc-600 hover:text-zinc-700 dark:text-zinc-600 dark:hover:text-zinc-400"
            >
              <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
            </span>
            <.avatar
              user={m.user}
              online={MapSet.member?(@online_ids, m.user.id)}
              class="w-6 h-6 text-xs"
            />
            <span class="truncate">{m.user.name}</span>
            <span class="text-xs text-zinc-400 dark:text-zinc-500 truncate">@{m.user.username}</span>
          </span>
          <span class="flex items-center gap-1 flex-none">
            <%!-- Change role (m02.05 item 14): owner-only, non-owner rows,
                 editor ↔ viewer. update_member_role broadcasts members_changed
                 so open views re-role live. --%>
            <form
              :if={@can_admin and m.user_id != @owner_id}
              phx-change="update_member_role"
              class="flex-none inline-flex items-center gap-1"
            >
              <input type="hidden" name="user_id" value={m.user_id} />
              <%!-- Item 12.6.5: the effective role shows IN the dropdown — a
                   viewer who holds an assignment reads "viewer+" (its value is
                   still "viewer", so leaving it set is a no-op; the DB role
                   stays viewer). --%>
              <select
                name="role"
                data-member-role-select
                aria-label={"Role for #{m.user.name}"}
                class="select select-bordered select-xs"
              >
                <option value="editor" selected={m.role == "editor"}>editor</option>
                <%= if viewer_plus?(m, @assignee_ids, @viewer_plus_on) do %>
                  <option value="viewer" selected>viewer+</option>
                <% else %>
                  <option value="viewer" selected={m.role == "viewer"}>viewer</option>
                <% end %>
              </select>
              <%!-- In-flight slot (§6.7): the role change is server-gated
                   (applies only after members_changed re-renders), so spin a
                   reserved slot beside the select while .doit-busy is held. --%>
              <span
                class="doit-busy-slot inline-flex w-3.5 flex-none items-center justify-center"
                aria-hidden="true"
              >
                <.icon
                  name="hero-arrow-path"
                  class="doit-busy-spinner size-3.5 animate-spin text-emerald-600 dark:text-emerald-400"
                />
              </span>
            </form>
            <span
              :if={not (@can_admin and m.user_id != @owner_id)}
              class="text-xs text-zinc-500 dark:text-zinc-400"
            >
              {role_label(m, @assignee_ids, @viewer_plus_on)}
            </span>
            <%!-- Leave (own row, non-owners): always confirmed — only the
                 owner can add you back. The confirm opens client-side
                 (#leave-confirm); only Proceed pushes leave_initiative, whose
                 members_changed broadcast ejects this very view. --%>
            <button
              :if={m.user_id == @me && @me != @owner_id}
              type="button"
              data-leave-initiative
              title="Leave this Initiative"
              aria-label="Leave this Initiative"
              class="inline-flex items-center justify-center w-5 h-5 rounded text-zinc-400 hover:text-red-600 hover:bg-red-50 dark:text-zinc-500 dark:hover:text-red-400 dark:hover:bg-red-950/40"
            >
              <.icon name="hero-arrow-right-start-on-rectangle" class="w-3.5 h-3.5" />
            </button>
            <%!-- Transfer ownership: always confirmed (the modal spells out
                 the demotion-to-editor consequence). The confirm opens
                 client-side (app.js) so it pops at the click with no round
                 trip — the member's name + id ride on the button. Only Proceed
                 touches the server. --%>
            <button
              :if={@can_admin && m.user_id != @owner_id}
              type="button"
              data-transfer-open
              data-user-id={m.user_id}
              data-user-name={m.user.name}
              title={"Transfer ownership to #{m.user.name}"}
              aria-label={"Transfer ownership to #{m.user.name}"}
              class="inline-flex items-center justify-center w-5 h-5 rounded text-zinc-400 hover:text-amber-600 hover:bg-amber-50 dark:text-zinc-500 dark:hover:text-amber-400 dark:hover:bg-amber-950/40"
            >
              <.icon name="hero-key" class="w-3.5 h-3.5" />
            </button>
            <%!-- The initiative's owner row is never removable. The "Remove X?"
                 confirm opens client-side (#remove-member-confirm, app.js); only
                 Proceed pushes remove_member, which commits or — for a member
                 holding assignments — escalates to the server hand-off modal. --%>
            <button
              :if={@can_admin && m.user_id != @owner_id}
              type="button"
              data-remove-member
              data-user-id={m.user_id}
              data-user-name={m.user.name}
              title={"Remove #{m.user.name} from this Initiative"}
              aria-label={"Remove #{m.user.name}"}
              class="inline-flex items-center justify-center w-5 h-5 rounded text-zinc-400 hover:text-red-600 hover:bg-red-50 dark:text-zinc-500 dark:hover:text-red-400 dark:hover:bg-red-950/40"
            >
              <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
            </button>
          </span>
        </li>
      </ul>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :can_edit, :boolean, required: true
  attr :label, :string, default: "Sort children by"
  # Stable element ids (item 15.17): the form / select / checkbox are keyed by
  # this pane scope, not the task id, so morphdom updates them in place across
  # selections (the optimistic value survives + reconciles) instead of tearing
  # the node down. The component is shared by two panes, so each passes its own
  # scope to keep the ids unique. The task id rides on `data-task-id` + the
  # hidden `task_id` (what SortRecall + set_sort actually key on).
  attr :scope, :string, required: true

  @doc """
  The "sort by" control for a branch task: criterion dropdown + Reverse +
  "Make descendants inherit". Shared by the Task and Initiative Details panes
  (the Initiative's is its root task, labeled "Sort lists by"). Targets the
  selected task server-side via `set_sort` / `cascade_sort`.
  """
  def sort_menu(assigns) do
    ~H"""
    <%!-- invisible (not removed) on leaves so leaf↔branch selection switches
         don't shift the layout below (UX_GUARDRAILS 1.1). --%>
    <div data-sort-block class={["space-y-1", leaf?(@task) && "invisible"]}>
      <label for={"sort-mode-#{@scope}"} class="text-xs text-zinc-500 dark:text-zinc-400">
        {@label}
      </label>
      <form
        id={"sort-form-#{@scope}"}
        phx-hook="SortRecall"
        data-task-id={@task.id}
        data-saving-children
        phx-change="set_sort"
        class="flex items-center gap-2"
      >
        <input type="hidden" name="task_id" value={@task.id} />
        <select
          id={"sort-mode-#{@scope}"}
          name="mode"
          class="flex-1 select select-bordered select-sm"
          disabled={not @can_edit}
        >
          <option value="" selected={is_nil(@task.sort_mode)}>
            {sort_mode_inherit_label(@task)}
          </option>
          <option :for={m <- sort_mode_options()} value={m} selected={@task.sort_mode == m}>
            {sort_mode_label(m)}
          </option>
        </select>
        <label
          for={"sort-reverse-#{@scope}"}
          class={[
            "flex items-center gap-1 text-xs select-none",
            reverse_disabled?(@task) && "text-zinc-400 dark:text-zinc-500",
            not reverse_disabled?(@task) && "text-zinc-600 dark:text-zinc-300"
          ]}
          title="Reverse the sort direction"
        >
          <input
            id={"sort-reverse-#{@scope}"}
            type="checkbox"
            name="reverse"
            value="true"
            checked={@task.sort_reverse}
            disabled={not @can_edit or reverse_disabled?(@task)}
            class="checkbox checkbox-xs"
          /> Reverse
        </label>
      </form>
      <button
        :if={@can_edit}
        type="button"
        data-cascade-sort
        data-task-id={@task.id}
        data-saving-subtree
        class="inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30 active:scale-95 transition"
        title="Force every descendant branch to inherit this branch's sort"
      >
        Make descendants inherit
      </button>
    </div>
    """
  end

  # Author-only edit/delete controls (m02.08 worklist 3 item 2.4). The view
  # guard is convenience; Tasks.edit_comment / delete_comment re-check.
  defp comment_author?(comment, %{id: user_id}), do: comment.user_id == user_id
  defp comment_author?(_comment, _user), do: false

  # "Link task" picker button (m03.03 worklist 3 item 3.2): opens the client-only
  # %-reference picker (app.js) anchored to `target` (a CSS selector for one of
  # the three eligible ref fields). The button only opens the popover; all
  # list-building + insertion is client-side.
  attr :target, :string, required: true
  attr :class, :any, default: nil

  defp ref_picker_button(assigns) do
    ~H"""
    <button
      type="button"
      data-ref-picker={@target}
      aria-label="Link a task by number"
      title="Link a task by number"
      class={[
        "inline-flex items-center justify-center w-6 h-6 rounded text-zinc-400 hover:text-emerald-600 dark:hover:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30 active:scale-95 transition",
        @class
      ]}
    >
      <.icon name="hero-link" class="w-4 h-4" />
    </button>
    """
  end

  attr :task, :map, required: true
  attr :comments, :list, required: true
  attr :current_user, :map, required: true
  # Comment lifecycle (m02.08 worklist 3 item 2): the inline edit editor and the
  # prior-versions popup are now CLIENT-OWNED (m02.09 WL3 3.3, §6.5) — both render
  # statically (hidden by default) and DoitState.commentEditId / commentVersionsId
  # toggle visibility at click on the client; the server no longer holds an
  # editing/versions assign. Versions render inline from the preloaded
  # `c.versions` association (ordered newest-first in list_comments/1).
  attr :activity, :list, required: true
  attr :show_activity, :boolean, default: true
  attr :online_ids, :any, required: true
  attr :members, :list, required: true
  attr :can_edit, :boolean, required: true
  # Viewer+ (item 12.6): edit progress + comments on a led task without the
  # full can_edit (title / priority stay can_edit).
  attr :can_progress, :boolean, default: false
  # Viewer+ staffing (item 12.6.3/12.6.4): may this user set this task's primary
  # / co-assignees, and from which pool (:all for an editor, a MapSet for a
  # viewer+, nil when they can't staff it).
  attr :can_staff, :boolean, default: false
  attr :staff_pool, :any, default: nil

  def task_editor(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-start justify-between gap-2">
        <h3 class="font-medium text-zinc-800 dark:text-zinc-100">Task details</h3>
        <button
          type="button"
          data-close-task
          aria-label="Close"
          title="Close"
          class="hidden lg:inline-flex items-center justify-center w-7 h-7 rounded bg-red-500/30 hover:bg-red-500/50 text-white font-bold"
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>
      </div>

      <%!-- Pane field order (m02.05 item 15): title, description, progress,
           sorting, priority, assignee — so Assignee sits directly against the
           Co-assignees block below. sort_menu + co-assignees have their own
           forms, so the update_task form splits around them (the echo keys off
           element IDs, so the split is harmless). --%>
      <form phx-change="update_task" phx-submit="update_task" class="space-y-3">
        <div>
          <div class="flex items-center justify-between gap-2">
            <label for="task-field-title" class="text-xs text-zinc-500 dark:text-zinc-400">
              Title
            </label>
            <.ref_picker_button :if={@can_edit} target="#task-field-title" />
          </div>
          <input
            id="task-field-title"
            type="text"
            name="task[title]"
            value={@task.title}
            class="w-full input input-bordered input-sm"
            disabled={not @can_edit}
            phx-debounce="blur"
            phx-hook="RefField"
          />
        </div>

        <div>
          <div class="flex items-center justify-between gap-2">
            <label for="task-field-description" class="text-xs text-zinc-500 dark:text-zinc-400">
              Description
            </label>
            <.ref_picker_button :if={@can_edit} target="#task-field-description" />
          </div>
          <textarea
            id="task-field-description"
            name="task[description]"
            class="w-full textarea textarea-bordered textarea-sm"
            rows="3"
            disabled={not @can_edit}
            phx-debounce="blur"
            phx-hook="RefField"
          >{@task.description}</textarea>
        </div>

        <%!-- One progress block for leaf and branch alike — the branch-only
             copy keeps its space when invisible, so leaf↔branch selection
             switches never shift the layout (UX_GUARDRAILS 1.1). --%>
        <div class="space-y-1">
          <div class="flex items-center gap-1">
            <label for="task-field-progress" class="text-xs text-zinc-500 dark:text-zinc-400">
              Manual progress: <span data-progress-readout>{if leaf?(@task), do: @task.manual_progress, else: @task.computed_progress}</span>%
            </label>
            <span data-mp-hint class={["inline-flex", leaf?(@task) && "invisible"]}>
              <.info_hint id={"mp-hint-#{@task.id}"} label="Why is this disabled?">
                Progress on a task with subtasks is calculated from its subtasks instead of
                being set manually. Your manual value is kept and will start being used again
                if you remove all subtasks.
              </.info_hint>
            </span>
          </div>
          <input
            id="task-field-progress"
            data-keep="pending-toggle-slider"
            type="range"
            name="task[manual_progress]"
            min="0"
            max="100"
            step="5"
            value={if leaf?(@task), do: @task.manual_progress, else: @task.computed_progress}
            class="w-full"
            disabled={not @can_progress or not leaf?(@task)}
            phx-debounce="200"
            aria-label={
              if leaf?(@task),
                do: "Manual progress",
                else: "Manual progress (disabled — computed from subtasks)"
            }
          />
          <p
            data-branch-note
            class={[
              "text-xs text-zinc-400 dark:text-zinc-500 italic",
              leaf?(@task) && "invisible"
            ]}
          >
            Ignored — this task has subtasks.
          </p>
          <div
            data-computed-note
            class={[
              "text-xs text-zinc-500 dark:text-zinc-400 italic",
              leaf?(@task) && "invisible"
            ]}
          >
            Computed from children: <span data-computed-readout>{@task.computed_progress}</span>%
          </div>
        </div>
      </form>

      <%!-- Always rendered (item 15.17): blank task renders it invisible (leaf),
           so it's present on a first selection and fillPaneFields fills it. --%>
      <.sort_menu task={@task} can_edit={@can_edit} label="Sort children by" scope="task" />

      <form phx-change="update_task" phx-submit="update_task" class="grid grid-cols-2 gap-3">
        <div>
          <label for="task-field-priority" class="text-xs text-zinc-500 dark:text-zinc-400">
            <span class={@can_edit && "underline"}>P</span>riority
          </label>
          <select
            id="task-field-priority"
            name="task[priority]"
            class="w-full select select-bordered select-sm"
            disabled={not @can_edit}
          >
            <option
              :for={p <- DoIt.Tasks.Task.priorities()}
              value={p}
              selected={@task.priority == p}
            >
              {p}
            </option>
          </select>
        </div>
        <div>
          <label for="task-field-assignee" class="text-xs text-zinc-500 dark:text-zinc-400">
            <span class={@can_edit && "underline"}>A</span>ssignee
          </label>
          <select
            id="task-field-assignee"
            name="task[assignee_id]"
            class="w-full select select-bordered select-sm"
            disabled={not (@can_edit or @can_staff)}
          >
            <%!-- Option text is the bare username: the optimistic echo in
                 app.js builds the chip's "@username" from it, and the
                 pane-skeleton sync matches it back. Display name rides
                 the option title. A viewer+ sees only their handed pool
                 (item 12.6.4) plus the current assignee so it reads true. --%>
            <option value="">Unassigned</option>
            <option
              :for={m <- assignable_members(@members, @task, @can_edit, @staff_pool)}
              value={m.user.id}
              title={m.user.name}
              data-initials={initials(m.user)}
              data-avatar-bg={avatar_bg(m.user)}
              data-avatar-fg={avatar_fg(m.user)}
              selected={@task.assignee_id == m.user.id}
            >
              {m.user.username}
            </option>
          </select>
        </div>
      </form>

      <%!-- Optimistic co-assignees (item 15.11): a read-only mirror of the
           selected row's co-chip, shown the instant a selection switch is in
           flight so co's appear pronto — before the server reply fills the
           real interactive list below. fillPaneFields builds it from the row's
           hidden [data-co-seed] spans; syncPaneSkeleton shows it only while the
           switch is in flight and hides it once the real list arrives. Always
           present (not gated on @task.id) so a first selection has it too. --%>
      <div id="co-optimistic" hidden>
        <span class="text-xs text-zinc-500 dark:text-zinc-400">Co-assignees</span>
        <ul data-co-opt-list class="mt-1 space-y-1"></ul>
      </div>

      <%!-- Co-assignees (m02.05 item 13): ordered, manual — position is
           promotion order. The primary stays the assignee select above.
           MUST live OUTSIDE the update_task form — its own add-form can't be
           nested in another form (the browser drops nested forms). --%>
      <div
        :if={@task.id && (@can_edit or @can_staff or @task.co_assignee_links != [])}
        id="co-assignees"
        data-async-list
        phx-hook="CoAssignees"
      >
        <span class="text-xs text-zinc-500 dark:text-zinc-400">Co-assignees</span>
        <%!-- Item 12.5: the list is hook-owned (phx-update="ignore") so optimistic
             add/remove/reorder apply at the gesture without morphdom fighting
             them; the hook reverts from the server's reply (or a timeout) when a
             write doesn't land — never sticking a change the server refused.
             Keyed by task id so selecting another task re-renders from the
             server. The chip + dropdown stay server-driven (truthful). During a
             selection switch the whole block hides (data-async-list above) and
             the optimistic mirror stands in. --%>
        <ul id={"co-list-#{@task.id}"} phx-update="ignore" class="mt-1 space-y-1">
          <li
            :for={{link, idx} <- Enum.with_index(@task.co_assignee_links)}
            id={"co-row-#{link.user_id}"}
            data-co-row
            data-user-id={link.user_id}
            data-name={link.user.username}
            data-initials={initials(link.user)}
            data-avatar-bg={avatar_bg(link.user)}
            data-avatar-fg={avatar_fg(link.user)}
            class="flex items-center gap-2 text-sm"
          >
            <.avatar
              user={link.user}
              online={MapSet.member?(@online_ids, link.user_id)}
              class="w-5 h-5 text-[10px]"
            />
            <span class={[
              "flex-1 min-w-0 truncate text-zinc-700 dark:text-zinc-200",
              not member_user?(@members, link.user_id) && "line-through"
            ]}>
              @{link.user.username}
            </span>
            <button
              :if={@can_edit or @can_staff}
              type="button"
              data-co-move
              data-dir="up"
              data-user-id={link.user_id}
              disabled={idx == 0}
              aria-label="Move up"
              class="px-1 text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 disabled:opacity-30"
            >
              <.icon name="hero-chevron-up" class="w-3.5 h-3.5" />
            </button>
            <button
              :if={@can_edit or @can_staff}
              type="button"
              data-co-move
              data-dir="down"
              data-user-id={link.user_id}
              disabled={idx == length(@task.co_assignee_links) - 1}
              aria-label="Move down"
              class="px-1 text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 disabled:opacity-30"
            >
              <.icon name="hero-chevron-down" class="w-3.5 h-3.5" />
            </button>
            <button
              :if={@can_edit or @can_staff}
              type="button"
              data-co-remove
              data-user-id={link.user_id}
              aria-label={"Remove co-assignee @#{link.user.username}"}
              class="px-1 text-zinc-400 hover:text-red-600 dark:hover:text-red-400"
            >
              <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
            </button>
          </li>
          <li
            :if={@task.co_assignee_links == []}
            data-co-empty
            class="text-xs text-zinc-400 dark:text-zinc-500 italic"
          >
            None yet.
          </li>
        </ul>
        <form :if={@can_edit or @can_staff} id="add-co-assignee-form" class="mt-1">
          <select name="user_id" data-co-add class="w-full select select-bordered select-sm">
            <option value="">+ Add co-assignee…</option>
            <option
              :for={m <- eligible_co_members(@members, @task, @can_edit, @staff_pool)}
              value={m.user.id}
              data-name={m.user.username}
              data-initials={initials(m.user)}
              data-avatar-bg={avatar_bg(m.user)}
              data-avatar-fg={avatar_fg(m.user)}
            >
              {m.user.username}
            </option>
          </select>
        </form>
      </div>

      <div
        :if={@task.id}
        class="flex items-center justify-between gap-2 border-t border-zinc-100 dark:border-zinc-700 pt-3"
      >
        <div class="text-xs text-zinc-500 dark:text-zinc-400">
          <%= if @task.updated_by do %>
            Last updated by
            <span class="font-medium text-zinc-700 dark:text-zinc-200 inline-flex items-center gap-1 align-bottom">
              <.avatar
                user={@task.updated_by}
                online={MapSet.member?(@online_ids, @task.updated_by.id)}
                class="w-4 h-4 text-[8px]"
              />{@task.updated_by.name}
            </span>
            <span title={LocalTime.from_utc(@task.updated_at)}>
              (<.local_time value={@task.updated_at} format="%b %-d %H:%M" />)
            </span>
          <% else %>
            Updated <.local_time value={@task.updated_at} format="%b %-d %H:%M" />
          <% end %>
        </div>
        <div class="flex items-center gap-2">
          <%!-- No phx-click: the delete confirm opens client-side (.03.07.15);
               app.js owns this button. --%>
          <button
            :if={@can_edit}
            id="delete-task-btn"
            type="button"
            class="inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-semibold text-white bg-red-600 hover:bg-red-700 dark:bg-red-700 dark:hover:bg-red-600"
          >
            <.icon name="hero-trash" class="w-3.5 h-3.5" /> Delete
          </button>
        </div>
      </div>

      <div class="border-t border-zinc-100 dark:border-zinc-700 pt-3">
        <h4 class="text-xs font-medium text-zinc-700 dark:text-zinc-200 mb-2">Comments</h4>
        <p data-async-loading hidden class="text-xs text-zinc-400 dark:text-zinc-500 italic mb-2">
          Loading…
        </p>
        <ul
          id="comment-list"
          phx-hook="CommentRefs"
          data-async-list
          data-comment-list
          class="space-y-2 mb-2"
        >
          <%!-- Open/close of the inline editor is CLIENT-OWNED (m02.09 WL3 3.3,
               §6.5): the <li> carries data-keep="comment-edit" so a list-refresh
               patch can't snap an open editor shut, and the "comment-edit"
               applier reads DoitState.commentEditId to show the display block or
               the author's form. Both render statically; the form is hidden by
               default and revealed at click with no round trip. --%>
          <li
            :for={c <- @comments}
            id={"comment-#{c.id}"}
            data-keep="comment-edit"
            class="group/comment text-sm"
          >
            <div class="text-xs text-zinc-500 dark:text-zinc-400 flex items-center gap-1">
              <.avatar
                :if={c.user}
                user={c.user}
                online={c.user && MapSet.member?(@online_ids, c.user.id)}
                class="w-4 h-4 text-[8px]"
              />
              {c.user && c.user.name} · <.local_time value={c.inserted_at} format="%b %-d %H:%M" />
            </div>

            <%= cond do %>
              <% Tasks.comment_deleted?(c) -> %>
                <%!-- Tombstone (item 2.3): the row survives so thread shape +
                     references hold, shown as deleted. --%>
                <div class="italic text-zinc-400 dark:text-zinc-500">comment deleted</div>
              <% true -> %>
                <%!-- Display block — shown when NOT editing (the applier toggles
                     `hidden` against DoitState.commentEditId). --%>
                <div data-comment-display>
                  <div
                    data-comment-body
                    class="text-zinc-800 dark:text-zinc-100 whitespace-pre-wrap"
                  >
                    {c.body}
                  </div>
                  <div class="mt-0.5 flex items-center gap-2 text-xs">
                    <button
                      :if={c.versions != []}
                      type="button"
                      data-comment-versions-open
                      phx-value-id={c.id}
                      class="text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300 italic"
                    >
                      edited · history
                    </button>
                    <%= if comment_author?(c, @current_user) do %>
                      <button
                        type="button"
                        id={"edit-comment-btn-#{c.id}"}
                        data-comment-edit-open
                        phx-value-id={c.id}
                        class="opacity-0 group-hover/comment:opacity-100 focus:opacity-100 text-zinc-400 dark:text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-200"
                      >
                        Edit
                      </button>
                      <button
                        type="button"
                        id={"delete-comment-btn-#{c.id}"}
                        data-comment-delete
                        phx-click="delete_comment"
                        phx-value-id={c.id}
                        data-confirm="Delete this comment? It will be marked as deleted."
                        class="opacity-0 group-hover/comment:opacity-100 focus:opacity-100 text-red-400 dark:text-red-500 hover:text-red-600 dark:hover:text-red-400"
                      >
                        Delete
                      </button>
                    <% end %>
                  </div>
                </div>
                <%!-- Inline editor (item 2.2) — author-only, rendered hidden;
                     the "comment-edit" applier reveals it when this comment is
                     the client-owned commentEditId. Save stays server-owned; the
                     context re-checks authorship. The Edit button seeds + focuses
                     the textarea at click (app.js), so a stale value never shows. --%>
                <form
                  :if={comment_author?(c, @current_user)}
                  id={"edit-comment-form-#{c.id}"}
                  data-comment-edit-form
                  hidden
                  phx-submit="save_comment"
                  phx-value-id={c.id}
                  class="mt-1 flex flex-col gap-1"
                >
                  <textarea
                    id={"edit-comment-textarea-#{c.id}"}
                    phx-hook="CommentEditRef"
                    name="comment[body]"
                    aria-label="Edit comment"
                    rows="2"
                    class="w-full textarea textarea-bordered textarea-sm"
                  ><%= c.body %></textarea>
                  <div class="flex items-center gap-2">
                    <button
                      type="submit"
                      data-latch="Saving…"
                      class="text-xs px-2.5 py-1 rounded bg-zinc-700 text-white hover:bg-zinc-800"
                    >
                      Save
                    </button>
                    <button
                      type="button"
                      data-comment-edit-cancel
                      class="text-xs px-2.5 py-1 rounded border border-zinc-300 dark:border-zinc-600 text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800"
                    >
                      Cancel
                    </button>
                  </div>
                </form>
            <% end %>

            <%!-- Prior-versions popup (item 2.2): a minimal inline panel listing
                 earlier bodies, NEWEST FIRST (the `versions` preload is ordered
                 desc in list_comments/1). Open/close is CLIENT-OWNED (m02.09 WL3
                 3.3, §6.5): rendered statically + hidden, carries
                 data-keep="comment-versions" so a patch can't snap it shut, and
                 the "comment-versions" applier reveals it when this comment is the
                 client-owned commentVersionsId — no round trip on open or close. --%>
            <div
              :if={not Tasks.comment_deleted?(c) and c.versions != []}
              id={"comment-versions-#{c.id}"}
              data-keep="comment-versions"
              hidden
              class="mt-1 rounded border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-800/60 p-2"
            >
              <div class="flex items-center justify-between mb-1">
                <span class="text-xs font-medium text-zinc-600 dark:text-zinc-300">
                  Edit history
                </span>
                <button
                  type="button"
                  data-comment-versions-cancel
                  aria-label="Close history"
                  class="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-200"
                >
                  <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                </button>
              </div>
              <ul class="space-y-1">
                <%!-- Forward-compatible lazy-load hook: a future fetch-on-open
                     can reveal this while versions stream in. Hidden today —
                     versions render inline from the preload. --%>
                <li
                  data-versions-loading
                  hidden
                  class="text-xs italic text-zinc-400 dark:text-zinc-500"
                >
                  Loading…
                </li>
                <li
                  :for={v <- c.versions}
                  class="text-xs text-zinc-600 dark:text-zinc-300"
                >
                  <span class="text-zinc-400 dark:text-zinc-500">
                    <.local_time value={v.inserted_at} format="%b %-d %H:%M" />
                  </span>
                  <div data-comment-body class="whitespace-pre-wrap">{v.body}</div>
                </li>
              </ul>
            </div>
          </li>
        </ul>
        <form
          :if={@can_progress}
          phx-submit="add_comment"
          data-add-comment-form
          data-my-name={@current_user.name}
          data-my-initials={initials(@current_user)}
          data-my-bg={avatar_bg(@current_user)}
          data-my-fg={avatar_fg(@current_user)}
          class="flex gap-2"
        >
          <input
            type="text"
            name="comment[body]"
            placeholder="Write a comment..."
            aria-label="Comment text"
            class="flex-1 input input-bordered input-sm"
          />
          <button
            type="submit"
            phx-disable-with="Posting..."
            class="text-xs px-3 py-1 rounded bg-zinc-700 text-white hover:bg-zinc-800"
          >
            Post
          </button>
        </form>
      </div>

      <%!-- Hideable per user preference (m02.04 §2.4); collapsed by default,
           expandable. data-keep="open" persists the user's open/closed choice
           across pane patches. --%>
      <details
        :if={@show_activity}
        id="task-activity"
        data-keep="open"
        class="group border-t border-zinc-100 dark:border-zinc-700 pt-3"
      >
        <summary class="cursor-pointer list-none [&::-webkit-details-marker]:hidden flex items-center gap-1 text-xs font-medium text-zinc-700 dark:text-zinc-200 mb-2">
          <.icon
            name="hero-chevron-right"
            class="w-3.5 h-3.5 transition-transform group-open:rotate-90"
          /> Activity
        </summary>
        <p data-async-loading hidden class="text-xs text-zinc-400 dark:text-zinc-500 italic">
          Loading…
        </p>
        <ul data-async-list class="space-y-1 text-xs text-zinc-600 dark:text-zinc-300">
          <li :for={e <- @activity} :if={e.kind != "status_changed"}>
            <span class="text-zinc-500 dark:text-zinc-400">
              <.local_time value={e.inserted_at} format="%b %-d %H:%M" />
            </span>
            ·
            <span class="font-medium inline-flex items-center gap-1 align-bottom">
              <.avatar
                :if={e.user}
                user={e.user}
                online={e.user && MapSet.member?(@online_ids, e.user.id)}
                class="w-4 h-4 text-[8px]"
              />{(e.user && e.user.name) || "system"}
            </span>
            · {event_label(e, @members)}
            <span
              :if={Map.get(e.data, "from") || Map.get(e.data, "to")}
              class="text-zinc-500 dark:text-zinc-400"
            >
              ({inspect(Map.get(e.data, "from"))} → {inspect(Map.get(e.data, "to"))})
            </span>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  # Botanical type icon for a task row: tree at the root (Lists), branch for
  # parents, leaf for childless tasks. Tree/leaf are green, branch amber.
  defp botanical_kind(_task, 0), do: :tree

  defp botanical_kind(%{children: children}, _depth) when is_list(children) and children != [],
    do: :branch

  defp botanical_kind(_task, _depth), do: :leaf

  defp botanical_color(task, depth) do
    if botanical_kind(task, depth) == :branch,
      do: "text-amber-700 dark:text-amber-600",
      else: "text-emerald-600 dark:text-emerald-400"
  end

  # Collapsed-badge count: leaf tasks in the whole subtree, not direct
  # children — "(12)" tells you how much work is folded away, not how many
  # immediate branches happen to wrap it.
  # Run a co-assignee mutation against the selected task (edit-gated), then
  # patch the tree for the actor (updates the row's "+N"); patch_task also
  # refreshes the pane. Other clients update via the Tasks fn's broadcast.
  # Co-assignee mutation, edit-gated. Replies `%{ok: bool}` so the optimistic
  # CoAssignees hook (item 12.5) can keep the change or revert it — a write
  # that didn't land (or wasn't allowed) snaps the list back, never sticks.
  defp with_co(socket, fun) do
    task = socket.assigns.selected_task

    # Editors/owners anywhere; a viewer+ only on a staffable descendant within
    # their pool (item 12.6.3). The reply drives the optimistic hook: a refused
    # or failed write returns ok: false so the change reverts instead of lying.
    if task && can_staff?(socket) do
      case fun.(task, socket.assigns.current_user) do
        {:error, _} -> {:reply, %{ok: false}, socket}
        _ -> {:reply, %{ok: true}, patch_task(socket, task.id)}
      end
    else
      {:reply, %{ok: false}, socket}
    end
  end

  # Move `id` one slot up/down within the ordered id list.
  defp shift(ids, id, dir) do
    case Enum.find_index(ids, &(&1 == id)) do
      nil ->
        ids

      i ->
        j = if dir == "up", do: i - 1, else: i + 1

        if j in 0..(length(ids) - 1) do
          a = Enum.at(ids, i)
          b = Enum.at(ids, j)
          ids |> List.replace_at(i, b) |> List.replace_at(j, a)
        else
          ids
        end
    end
  end

  defp member_user?(members, user_id), do: Enum.any?(members, &(&1.user_id == user_id))

  # A member reads "viewer+" when the Initiative setting is on, their role is
  # viewer, and they're the direct assignee of at least one task (item 12.6.5).
  defp viewer_plus?(member, assignee_ids, viewer_plus_on),
    do:
      viewer_plus_on and member.role == "viewer" and MapSet.member?(assignee_ids, member.user_id)

  defp role_label(member, assignee_ids, viewer_plus_on) do
    if viewer_plus?(member, assignee_ids, viewer_plus_on), do: "viewer+", else: member.role
  end

  # Readable activity labels for the co-assignee event kinds (m02.05 .13.7);
  # everything else keeps its raw kind, as before.
  defp event_label(%{kind: "co_assignee_added", data: d}, members),
    do: "added co-assignee #{event_username(d, members)}"

  defp event_label(%{kind: "co_assignee_removed", data: d}, members),
    do: "removed co-assignee #{event_username(d, members)}"

  defp event_label(%{kind: "co_assignee_promoted", data: d}, members),
    do: "promoted #{event_username(d, members)} to assignee"

  defp event_label(%{kind: "co_assignees_reordered"}, _members), do: "reordered co-assignees"
  # Undo / redo feed entries (m02.06 item 8) — labeled, never hiding the round-trip.
  defp event_label(%{kind: "undid", data: d}, _members), do: "undid #{d["of"] || "a change"}"
  defp event_label(%{kind: "redid", data: d}, _members), do: "redid #{d["of"] || "a change"}"
  defp event_label(%{kind: kind}, _members), do: kind

  defp event_username(%{"user_id" => uid}, members) do
    case Enum.find(members, &(&1.user_id == uid)) do
      nil -> "a member"
      m -> "@#{m.user.username}"
    end
  end

  defp event_username(_, _), do: "a member"

  # Members eligible to ADD as a co-assignee: not the primary, not already on
  # the co-list.
  defp eligible_co_members(members, task) do
    co_ids = MapSet.new(task.co_assignee_links, & &1.user_id)

    Enum.reject(members, fn m ->
      m.user_id == task.assignee_id or MapSet.member?(co_ids, m.user_id)
    end)
  end

  # Same, narrowed to the staffer's pool: an editor (can_edit) draws from all
  # members; a viewer+ only from their handed pool (item 12.6.4).
  defp eligible_co_members(members, task, can_edit, staff_pool) do
    members
    |> within_pool(can_edit, staff_pool)
    |> eligible_co_members(task)
  end

  # Members a staffer may set as the task's PRIMARY: an editor sees everyone; a
  # viewer+ sees their pool, plus the current assignee so the select reads true
  # even if that person sits outside the pool (item 12.6.4).
  defp assignable_members(members, _task, true, _staff_pool), do: members

  defp assignable_members(members, task, false, staff_pool) do
    pool = within_pool(members, false, staff_pool)

    if task.assignee_id && not Enum.any?(pool, &(&1.user_id == task.assignee_id)) do
      pool ++ Enum.filter(members, &(&1.user_id == task.assignee_id))
    else
      pool
    end
  end

  defp within_pool(members, true, _staff_pool), do: members
  defp within_pool(_members, _can_edit, nil), do: []
  defp within_pool(members, _can_edit, :all), do: members

  defp within_pool(members, _can_edit, %MapSet{} = pool),
    do: Enum.filter(members, &MapSet.member?(pool, &1.user_id))

  defp ex_member?(%{assignee_id: id, assignee: %{}}, member_ids) when not is_nil(id),
    do: not MapSet.member?(member_ids, id)

  defp ex_member?(_task, _member_ids), do: false

  defp assignee_title(%{assignee_id: id, assignee: %{username: username}} = task, member_ids)
       when not is_nil(id) do
    if ex_member?(task, member_ids),
      do: "Assignee: @#{username} (no longer a member)",
      else: "Assignee: @#{username}"
  end

  defp assignee_title(_task, _member_ids), do: "Unassigned"

  defp leaf_count(%{children: []}), do: 1
  defp leaf_count(%{children: children}), do: Enum.sum(Enum.map(children, &leaf_count/1))

  # The chevron badge counts what the progress mode counts: every descendant
  # leaf (leaf_average), or each direct child as one unit (single_level).
  defp branch_unit_count(task, "single_level"), do: length(task.children)
  defp branch_unit_count(task, _calc), do: leaf_count(task)

  defp branch_unit_title("single_level"), do: "Direct children — each counts equally"
  defp branch_unit_title(_calc), do: "Leaves in this branch"

  defp badge_icon("single_level"), do: :branch
  defp badge_icon(_calc), do: :leaf

  defp badge_icon_class("single_level"),
    do: "w-3 h-3 flex-none text-amber-700 dark:text-amber-600"

  defp badge_icon_class(_calc), do: "w-3 h-3 flex-none"

  # An empty placeholder so the Details pane shell can pre-mount before any task
  # is selected (item 15.8) — the client fills the editable fields from the row
  # on the first selection. children: [] keeps leaf?/sort safe; the task-keyed
  # sections (sort, co-assignees, "last updated") gate on @task.id and stay out
  # until the real task arrives on the reply.
  defp blank_task, do: %Task{children: [], co_assignee_links: []}

  defp leaf?(%Task{} = task) do
    case Map.get(task, :children) do
      children when is_list(children) ->
        children == []

      _ ->
        Repo.one(
          from t in Task,
            where: t.parent_id == ^task.id and is_nil(t.deleted_at),
            select: count(t.id)
        ) == 0
    end
  end

  # Dropdown ordering: criteria first, then Manual at the bottom.
  @sort_mode_options ~w(alphabetical completion priority created updated manual)

  defp sort_mode_options, do: @sort_mode_options

  defp sort_mode_label("manual"), do: "Manual"
  defp sort_mode_label("alphabetical"), do: "Alphabetical"
  defp sort_mode_label("completion"), do: "Completion %"
  defp sort_mode_label("priority"), do: "Priority"
  defp sort_mode_label("created"), do: "First Created"
  defp sort_mode_label("updated"), do: "Last Updated"

  # Always name what Inherit currently means — resolved from the parent
  # chain, ignoring the task's own explicit mode ("Inherit (Manual)" when
  # nothing above sets one). Direction is folded into the wording since the
  # Reverse checkbox is disabled on Inherit.
  defp sort_mode_inherit_label(%Task{} = task) do
    {mode, reverse} = Tasks.resolve_sort(task.parent_id)
    "Inherit (#{sort_direction_label(mode, reverse)})"
  end

  defp sort_direction_label("alphabetical", false), do: "Alphabetical A–Z"
  defp sort_direction_label("alphabetical", true), do: "Alphabetical Z–A"
  defp sort_direction_label("priority", false), do: "highest priority"
  defp sort_direction_label("priority", true), do: "lowest priority"
  defp sort_direction_label("completion", false), do: "least complete"
  defp sort_direction_label("completion", true), do: "most complete"
  defp sort_direction_label("created", false), do: "oldest 1st"
  defp sort_direction_label("created", true), do: "newest 1st"
  defp sort_direction_label("updated", false), do: "recently updated"
  defp sort_direction_label("updated", true), do: "stalest"
  defp sort_direction_label(mode, _reverse), do: sort_mode_label(mode)

  defp reverse_disabled?(%Task{sort_mode: mode}), do: mode in [nil, "manual"]

  defp progress_value(%{children: children, computed_progress: cp})
       when is_list(children) and children != [],
       do: cp

  defp progress_value(%{status: "done"}), do: 100
  defp progress_value(%{manual_progress: mp}), do: mp || 0

  # New-task placement (item 18): the inline form sits in a slot, so the
  # created task lands there. Root/child "add" forms render at the top of
  # their list → index 0; an "add sibling after X" form → just after X. For an
  defp sibling_after_position(after_id) do
    # after_id is a client-supplied anchor; if it was just deleted, fall back to
    # the top (nil position) instead of crashing.
    case Tasks.get_task(after_id) do
      nil ->
        nil

      anchor ->
        case Enum.find_index(sibling_ids(anchor), &(&1 == anchor.id)) do
          nil -> nil
          idx -> idx + 1
        end
    end
  end

  # --- Keyboard move helpers ------------------------------------------------

  # Compute and execute the right move_task call for the selected task given
  # an Alt+Arrow key. Goes through the same preview → confirm path as a drag,
  # so a move that would flip ancestor completion raises the styled modal
  # (and honors the "completion changes" suppression class) instead of
  # committing silently. Returns {:noreply, socket}.
  defp do_kbd_move(key, task, socket) do
    user = socket.assigns.current_user
    siblings = sibling_ids(task)
    idx = Enum.find_index(siblings, &(&1 == task.id)) || 0

    move_attrs =
      case key do
        "ArrowUp" -> kbd_move_up(siblings, idx, task)
        "ArrowDown" -> kbd_move_down(siblings, idx, task)
        "ArrowRight" -> kbd_indent(siblings, idx, task)
        "ArrowLeft" -> kbd_dedent(task)
      end

    case move_attrs do
      :noop ->
        {:noreply, socket}

      attrs ->
        case Tasks.preview_move(task, user, attrs) do
          {:ok, %{scenario: nil}} ->
            kbd_commit_move(socket, task, attrs)

          {:ok, %{scenario: scenario, titles: titles, ids: flip_ids}} ->
            if skip_confirm?(socket, "completion-flip") do
              kbd_commit_move(socket, task, attrs)
            else
              {:noreply,
               assign_pending(socket, %{
                 kind: :move,
                 task_id: task.id,
                 attrs: attrs,
                 scenario: scenario,
                 titles: titles,
                 flip_ids: flip_ids
               })}
            end

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Couldn't move task: #{format_move_error(reason)}.")}
        end
    end
  end

  defp kbd_commit_move(socket, task, attrs) do
    case commit_move(socket, task, attrs) do
      {:ok, socket} -> {:noreply, socket}
      {:error, _reason, socket} -> {:noreply, socket}
    end
  end

  # Sibling task IDs (same parent_id, same initiative) ordered by sort_order.
  defp sibling_ids(%Task{} = task) do
    base =
      from(t in Task,
        where: t.initiative_id == ^task.initiative_id,
        order_by: [asc: t.sort_order, asc: t.inserted_at],
        select: t.id
      )

    query =
      case task.parent_id do
        nil -> from(t in base, where: is_nil(t.parent_id))
        pid -> from(t in base, where: t.parent_id == ^pid)
      end

    Repo.all(query)
  end

  # Alt+↑: swap with previous sibling. No-op at index 0.
  defp kbd_move_up(_siblings, 0, _task), do: :noop

  defp kbd_move_up(_siblings, idx, %Task{} = task) do
    %{"parent_id" => task.parent_id, "position" => idx - 1, "reorder" => true}
  end

  # Alt+↓: swap with next sibling. No-op at last index.
  defp kbd_move_down(siblings, idx, %Task{} = task) do
    if idx >= length(siblings) - 1 do
      :noop
    else
      %{"parent_id" => task.parent_id, "position" => idx + 1, "reorder" => true}
    end
  end

  # Alt+→: become first child of previous sibling (move-in defaults to the top
  # of the new parent, item 18). No-op if no previous sibling.
  defp kbd_indent(_siblings, 0, _task), do: :noop

  defp kbd_indent(siblings, idx, _task) do
    new_parent_id = Enum.at(siblings, idx - 1)
    %{"parent_id" => new_parent_id, "position" => nil}
  end

  # Alt+←: become a sibling of the parent, inserted right after the parent
  # within the grandparent's children. No-op at the top level — i.e. when the
  # parent is the Initiative's root task (grandparent is nil), or the root task
  # itself (defensive).
  defp kbd_dedent(%Task{parent_id: nil}), do: :noop

  defp kbd_dedent(%Task{parent_id: parent_id} = task) do
    parent = Tasks.get_task!(parent_id)
    grandparent_id = parent.parent_id

    if is_nil(grandparent_id) do
      # Parent is the root task → the task is already top-level; can't dedent.
      :noop
    else
      grand_sibling_ids =
        sibling_ids(%Task{parent_id: grandparent_id, initiative_id: task.initiative_id})

      parent_idx = Enum.find_index(grand_sibling_ids, &(&1 == parent.id)) || 0

      # Inserting "right after the parent" — among grand-siblings excluding the
      # moved task itself, that's parent_idx + 1.
      %{"parent_id" => grandparent_id, "position" => parent_idx + 1}
    end
  end

  defp format_move_error(:cycle), do: "would create a cycle"
  defp format_move_error(:cross_initiative), do: "can't move across initiatives"
  defp format_move_error(%Ecto.Changeset{} = cs), do: summarize_errors(cs)
  defp format_move_error(other), do: inspect(other)

  defp summarize_errors(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, "; ", fn {field, {msg, _}} ->
      "#{humanize(field)} #{msg}"
    end)
  end

  defp humanize(field), do: field |> to_string() |> String.replace("_", " ")
end
