defmodule DoItWeb.InitiativeShowLive do
  use DoItWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Tasks.Task
  alias DoIt.Tasks.Tree

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user
    initiative = Initiatives.get_initiative(id)
    role = initiative && Initiatives.get_role(initiative.id, user.id)

    cond do
      is_nil(initiative) ->
        {:ok,
         socket
         |> put_flash(:error, "Initiative not found.")
         |> push_navigate(to: ~p"/initiatives")}

      is_nil(role) ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to that initiative.")
         |> push_navigate(to: ~p"/initiatives")}

      true ->
        if connected?(socket) do
          Tasks.subscribe(initiative.id)

          # Selection presence (.04.01.12): subscribe first, then track — our
          # own join diff arrives as the initial push to this client, and it
          # already includes everyone who was here before us.
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

          # Global presence (m02.05 item 8): the Collaborators pane lights up
          # avatars for anyone online anywhere. on_mount already tracks us;
          # subscribe to follow others. Distinct from the per-initiative topic
          # above — the presence_diff handler tells them apart by topic.
          Phoenix.PubSub.subscribe(DoIt.PubSub, DoItWeb.Presence.global_topic())
        end

        {:ok,
         socket
         |> assign(:page_title, initiative.name)
         |> assign(:initiative, initiative)
         |> assign(:rail_initiatives, Initiatives.list_visible_initiatives(user))
         |> assign(:rail_collaborators, Initiatives.list_collaborators(user))
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
         |> assign_display_prefs(Accounts.get_preferences(user))
         |> assign(
           :online_ids,
           if(connected?(socket), do: online_ids(initiative.id), else: MapSet.new())
         )
         |> assign(
           :collaborator_online_ids,
           if(connected?(socket), do: DoItWeb.Presence.global_online_ids(), else: MapSet.new())
         )
         |> assign(:editing_initiative?, false)
         |> assign(:initiative_form, to_form(Initiatives.change_initiative(initiative)))
         |> assign_pending(nil)
         |> assign(:pending_transfer, nil)
         |> assign(:pending_handoff, nil)
         |> assign(:confirm_skips, MapSet.new())
         |> load_tree()}
    end
  end

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

  defp load_tree(socket) do
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

    socket
    |> assign(:tree, tree)
    |> assign(:root_task, root)
    |> assign(:root_sort_mode, elem(Tasks.resolve_sort(root), 0))
    |> assign(:initiative_progress, (root && root.computed_progress) || 0)
    |> assign(:led_task_ids, viewer_led_ids(socket))
    |> assign(:direct_assignee_ids, tree_assignee_ids(tree))
    |> assign_undo_state()
  end

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
  defp to_int(s) when is_binary(s), do: String.to_integer(s)

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
    case Tasks.lineage(task_id) do
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
              |> assign(:initiative_progress, root.computed_progress || 0)
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

  @impl true
  # Confirmation suppression (.03.01.11): the ConfirmSkips hook reads the
  # per-class skip flags from localStorage on mount and pushes them here.
  def handle_event("confirm_skips_loaded", %{"classes" => classes}, socket) do
    {:noreply, assign(socket, :confirm_skips, MapSet.new(classes))}
  end

  def handle_event("create_task", %{"title" => title} = params, socket) do
    user = socket.assigns.current_user
    initiative = socket.assigns.initiative

    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission to add tasks.")}
    else
      # The form carries its own target (client-positioned, UX_GUARDRAILS
      # 6.5): empty parent_id = top level (a child of the system root);
      # after_id places the new task just after that sibling, else at top.
      parent_id =
        case params["parent_id"] do
          id when is_binary(id) and id != "" -> String.to_integer(id)
          _ -> initiative.root_task_id
        end

      position =
        case params["after_id"] do
          id when is_binary(id) and id != "" -> sibling_after_position(String.to_integer(id))
          _ -> 0
        end

      attrs = %{
        "initiative_id" => initiative.id,
        "parent_id" => parent_id,
        "title" => title,
        "position" => position
      }

      case Tasks.preview_create(user, attrs) do
        {:ok, %{scenario: nil}} ->
          {:noreply, commit_create(socket, attrs)}

        {:ok, %{scenario: scenario, titles: titles, ids: flip_ids}} ->
          if skip_confirm?(socket, "completion-flip") do
            {:noreply, commit_create(socket, attrs)}
          else
            # Optimism (§8.20, parity with a held move): the task must SHOW UP
            # before the confirm decides. Splice a preview row into the tree at
            # the target, marked maybe-write (pink) via pending_saving_ids;
            # confirm → real create + load_tree replaces it, cancel → reload
            # drops it.
            preview = preview_task(title)

            {:noreply,
             socket
             |> assign(
               :tree,
               splice_preview(
                 socket.assigns.tree,
                 initiative.root_task_id,
                 parent_id,
                 position,
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
          end

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't create task: #{summarize_errors(cs)}.")}
      end
    end
  end

  # Selection is client-first (UX_GUARDRAILS 6.5): the highlight lives in the
  # DOM, this event only loads the Details pane.
  # Field focus (pill taps, Alt+P/W/A) is pure view state and happens
  # client-side — this event only loads pane data (.03.07.17).
  def handle_event("select_task", %{"id" => id}, socket) do
    id = String.to_integer(id)

    cond do
      # Pane already shows this task — nothing to load.
      socket.assigns.selected_task_id == id ->
        {:noreply, socket}

      true ->
        case Tasks.get_task_with_relations(id) do
          nil ->
            {:noreply, socket}

          task ->
            {:noreply,
             socket
             |> assign(:editing_initiative?, false)
             |> assign(:selected_task_id, id)
             |> assign_selected(task)
             |> assign(:comments, Tasks.list_comments(id))
             |> assign(:activity, Tasks.list_task_activity(id))
             |> update_presence(id)}
        end
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

  def handle_event("edit_initiative", _params, socket) do
    initiative = socket.assigns.initiative
    form = to_form(Initiatives.change_initiative(initiative))

    # The editor reads @root_task (kept fresh by load_tree / patch_task); the
    # sort controls carry their own task id, so the task selection is left
    # alone — its pane just hides while the editor is open.
    {:noreply,
     socket
     |> assign(:selected_task_id, nil)
     |> assign(:editing_initiative?, true)
     |> assign(:initiative_form, form)
     |> assign(:subtitle, Initiatives.subtitle(initiative))}
  end

  def handle_event("close_initiative", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_initiative?, false)
     |> assign(:selected_task_id, nil)}
  end

  def handle_event("update_subtitle", %{"subtitle" => subtitle}, socket) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission to edit this initiative.")}
    else
      case Initiatives.update_subtitle(socket.assigns.initiative, subtitle) do
        {:ok, _root} ->
          {:noreply, assign(socket, :subtitle, Initiatives.subtitle(socket.assigns.initiative))}

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

  def handle_event("close_panel", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_initiative?, false)
     |> assign(:selected_task_id, nil)}
  end

  # Initiative Settings (.03.07.07): switch the progress calc, recompute the
  # whole initiative under the new mode, and tell members to full-reload.
  def handle_event("set_progress_calc", %{"calc" => calc}, socket)
      when calc in ~w(leaf_average single_level) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
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

  def handle_event("update_initiative", %{"initiative" => params}, socket) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission to edit this initiative.")}
    else
      initiative = socket.assigns.initiative

      case Initiatives.update_initiative(initiative, params) do
        {:ok, updated} ->
          form = to_form(Initiatives.change_initiative(updated))

          {:noreply,
           socket
           |> assign(:initiative, updated)
           |> assign(:initiative_form, form)
           |> assign(:page_title, updated.name)}

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
      if staff_pool_allows?(socket, uid),
        do: Tasks.add_co_assignee(task, user, String.to_integer(uid)),
        else: {:error, :not_in_pool}
    end)
  end

  def handle_event("add_co_assignee", _params, socket), do: {:noreply, socket}

  def handle_event("remove_co_assignee", %{"user-id" => uid}, socket) do
    with_co(socket, fn task, user ->
      Tasks.remove_co_assignee(task, user, String.to_integer(uid))
    end)
  end

  def handle_event("move_co_assignee", %{"user-id" => uid, "dir" => dir}, socket)
      when dir in ~w(up down) do
    with_co(socket, fn task, user ->
      ids = Enum.map(Tasks.list_co_assignees(task.id), & &1.user_id)
      Tasks.reorder_co_assignees(task, user, shift(ids, String.to_integer(uid), dir))
    end)
  end

  # Drag a member from the Members panel onto any task row (item 12.8): assign
  # them as PRIMARY when the task has none, else stack them as a CO-assignee —
  # never clobbering an existing primary. Validated per the *dropped* task:
  # editor/owner anywhere; a viewer+ only within a led subtree, from its pool.
  # Replies ok:bool so the drag's optimistic row settles (item 12.5).
  def handle_event("assign_member", %{"user-id" => uid, "task-id" => tid}, socket) do
    uid = String.to_integer(uid)
    task = Tasks.get_task(String.to_integer(tid))
    user = socket.assigns.current_user

    cond do
      is_nil(task) or task.initiative_id != socket.assigns.initiative.id ->
        {:reply, %{ok: false}, socket}

      not member_id?(socket, uid) ->
        {:reply, %{ok: false}, socket}

      not assign_allowed?(socket, task, uid) ->
        {:reply, %{ok: false},
         put_flash(socket, :error, assign_denied_message(socket, task, uid))}

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

  def handle_event("update_task", %{"task" => params}, socket) do
    task = socket.assigns.selected_task
    user = socket.assigns.current_user

    cond do
      socket.assigns.can_edit ->
        case Tasks.update_task(task, user, params) do
          {:ok, _updated} ->
            {:noreply, socket |> put_flash(:info, "Saved.") |> patch_task(task.id)}

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
        {:noreply, put_flash(socket, :error, "You don't have permission.")}
    end
  end

  def handle_event("cascade_sort", params, socket) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    else
      task = sort_target(socket, params)
      branch_count = Tasks.count_descendant_branches(task.id)

      if branch_count > 10 and not skip_confirm?(socket, "cascade-sort") do
        {:noreply,
         assign_pending(socket, %{
           kind: :cascade_sort,
           task_id: task.id,
           branch_count: branch_count,
           affected: Tasks.count_descendants(task.id)
         })}
      else
        {:noreply, commit_cascade_sort(socket, task)}
      end
    end
  end

  def handle_event("set_sort", params, socket) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    else
      task = sort_target(socket, params)
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
          {:noreply, put_flash(socket, :error, "Couldn't change sort: #{summarize_errors(cs)}.")}
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
    if not can_progress?(socket, String.to_integer(id)) do
      {:reply, %{ok: false}, put_flash(socket, :error, "You don't have permission.")}
    else
      task = Tasks.get_task!(String.to_integer(id))
      user = socket.assigns.current_user

      case Tasks.toggle_complete(task, user) do
        {:ok, _} ->
          {:reply, %{ok: true, committed: true}, patch_task(socket, task.id)}

        {:error, cs} ->
          {:reply, %{ok: false},
           put_flash(socket, :error, "Couldn't toggle: #{summarize_errors(cs)}.")}
      end
    end
  end

  # Branch checkbox (.03.01.11): confirm via the styled modal unless the
  # "branch completion changes" class is suppressed, in which case cascade now.
  def handle_event("cascade_complete", %{"id" => id}, socket),
    do: request_cascade(socket, String.to_integer(id), :cascade_complete)

  def handle_event("cascade_incomplete", %{"id" => id}, socket),
    do: request_cascade(socket, String.to_integer(id), :cascade_incomplete)

  def handle_event("add_comment", %{"comment" => %{"body" => body}}, socket) do
    task = socket.assigns.selected_task

    if not (task && can_progress?(socket, task.id)) do
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    else
      user = socket.assigns.current_user

      case Tasks.add_comment(task, user, body) do
        {:ok, _comment} -> {:noreply, refresh_selected(socket)}
        {:error, _cs} -> {:noreply, put_flash(socket, :error, "Comment cannot be empty.")}
      end
    end
  end

  # Delete (.03.01.11, .03.07.15): the styled confirm is client-rendered and
  # client-decided — opening a dialog whose content is already in the DOM is
  # view state (UX_GUARDRAILS 6.5). This event arrives only after the user
  # confirmed; the row was already optimistically removed client-side.
  def handle_event("delete_task", %{"id" => id}, socket) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    else
      {:noreply, commit_delete_task(socket, String.to_integer(id))}
    end
  end

  def handle_event("move_task", %{"task_id" => task_id} = params, socket) do
    if not socket.assigns.can_edit do
      {:reply, %{ok: false, error: "forbidden"},
       put_flash(socket, :error, "You don't have permission to move tasks.")}
    else
      task = Tasks.get_task!(task_id)
      user = socket.assigns.current_user

      attrs = %{
        # A root-zone drop (promotion) carries no parent → it lands under the
        # Initiative's root task, the new meaning of "root level".
        "parent_id" => Map.get(params, "parent_id") || socket.assigns.initiative.root_task_id,
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
          if skip_confirm?(socket, "completion-flip") do
            # Suppressed: commit straight through, no modal.
            case commit_move(socket, task, attrs) do
              {:ok, socket} ->
                {:reply, %{ok: true, committed: true}, socket}

              {:error, reason, socket} ->
                {:reply, %{ok: false, error: format_move_error(reason)}, socket}
            end
          else
            # A completion-flip confirmation is required: the move is NOT yet
            # persisted, but the client KEEPS its optimistic placement while
            # the modal decides (§8.20 — confirmations must not undo optimism).
            # committed: false tells it to hold a revert handle: Cancel / a
            # failed Proceed reverts via "confirm-cancelled"; a Proceed commit
            # re-renders the same placement.
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
  end

  def handle_event("confirm_pending", params, socket) do
    pending = socket.assigns.pending_action
    socket = maybe_suppress(socket, pending, params)

    socket =
      case pending do
        %{kind: :move, task_id: task_id, attrs: attrs} ->
          case commit_move(socket, Tasks.get_task!(task_id), attrs) do
            {:ok, socket} -> socket
            {:error, _reason, socket} -> socket
          end

        %{kind: :create, attrs: attrs} ->
          commit_create(socket, attrs)

        %{kind: :cascade_sort, task_id: task_id} ->
          commit_cascade_sort(socket, Tasks.get_task!(task_id))

        %{kind: :remove_member, user_id: user_id} ->
          commit_remove_member(socket, user_id)

        %{kind: :leave_initiative} ->
          # The broadcast this triggers ejects our own view via
          # {:members_changed} — no navigation needed here.
          if socket.assigns.current_user.id != socket.assigns.initiative.owner_id do
            {_count, _} =
              Initiatives.remove_member(
                socket.assigns.initiative.id,
                socket.assigns.current_user.id
              )
          end

          assign_pending(socket, nil)

        %{kind: kind, task_id: id} when kind in [:cascade_complete, :cascade_incomplete] ->
          # Failure pushed "confirm-cancelled" inside — the held flip reverts.
          case commit_cascade(socket, id, kind) do
            {:ok, socket} -> socket
            {:error, socket} -> socket
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
  # Opening sets the pending target; the modal's confirm commits it. Not
  # suppressible — transferring ownership always asks.
  def handle_event("transfer_ownership", %{"user-id" => user_id}, socket) do
    user_id = String.to_integer(user_id)
    member = Enum.find(socket.assigns.members, &(&1.user_id == user_id))

    if socket.assigns.can_admin and member do
      {:noreply, assign(socket, :pending_transfer, %{user_id: user_id, name: member.user.name})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_transfer", _params, socket) do
    {:noreply, assign(socket, :pending_transfer, nil)}
  end

  def handle_event("confirm_transfer", _params, socket) do
    initiative = socket.assigns.initiative
    pending = socket.assigns.pending_transfer

    with true <- socket.assigns.can_admin and not is_nil(pending),
         {:ok, updated} <- Initiatives.transfer_ownership(initiative, pending.user_id) do
      role = Initiatives.get_role(updated.id, socket.assigns.current_user.id)

      {:noreply,
       socket
       |> assign(:initiative, updated)
       |> assign(:role, role)
       |> assign(:can_edit, Initiatives.can_edit?(role))
       |> assign(:can_admin, Initiatives.can_admin?(role))
       |> assign(:members, Initiatives.list_members(updated.id))
       |> assign(:pending_transfer, nil)
       |> put_flash(:info, "Ownership transferred to #{pending.name}. You're now an editor.")}
    else
      _ ->
        {:noreply,
         socket
         |> assign(:pending_transfer, nil)
         |> put_flash(:error, "Couldn't transfer ownership.")}
    end
  end

  # Leave (m02.04-era pull-forward of BACKLOG's "Leave an initiative"):
  # remove your own membership. Always confirmed — only the owner can add
  # you back. The commit's members_changed broadcast ejects this view.
  def handle_event("leave_initiative", _params, socket) do
    me = socket.assigns.current_user.id

    if me == socket.assigns.initiative.owner_id do
      {:noreply, put_flash(socket, :error, "Owners transfer ownership before leaving.")}
    else
      {:noreply, assign_pending(socket, %{kind: :leave_initiative})}
    end
  end

  def handle_event("remove_member", %{"user-id" => user_id}, socket) do
    initiative = socket.assigns.initiative
    user_id = String.to_integer(user_id)

    member = Enum.find(socket.assigns.members, &(&1.user_id == user_id))
    name = (member && member.user.name) || "this member"

    cond do
      not socket.assigns.can_admin ->
        {:noreply, put_flash(socket, :error, "Only the owner can remove members.")}

      user_id == initiative.owner_id ->
        {:noreply, put_flash(socket, :error, "The Initiative's owner can't be removed.")}

      # Holds assignments → the hand-off modal (13.5), so removal leaves no
      # struck residue. Always asks (it needs decisions), even if the plain
      # remove confirm was suppressed.
      Tasks.member_assignment_count(initiative.id, user_id) > 0 ->
        {:noreply,
         assign(socket, :pending_handoff, %{
           user_id: user_id,
           name: name,
           count: Tasks.member_assignment_count(initiative.id, user_id),
           promote_default: initiative.auto_promote_co_assignees
         })}

      skip_confirm?(socket, "remove-member") ->
        {:noreply, commit_remove_member(socket, user_id)}

      true ->
        {:noreply, assign_pending(socket, %{kind: :remove_member, user_id: user_id, name: name})}
    end
  end

  def handle_event("cancel_handoff", _params, socket) do
    {:noreply, assign(socket, :pending_handoff, nil)}
  end

  def handle_event("confirm_handoff", params, socket) do
    initiative = socket.assigns.initiative
    pending = socket.assigns.pending_handoff

    takeover_id =
      case params["takeover"] do
        id when is_binary(id) and id != "" -> String.to_integer(id)
        _ -> nil
      end

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

      {_n, _} = Initiatives.remove_member(initiative.id, pending.user_id)

      {:noreply,
       socket
       |> assign(:pending_handoff, nil)
       |> assign(:members, Initiatives.list_members(initiative.id))
       |> put_flash(:info, "Removed #{pending.name}; their assignments were handed off.")
       |> load_tree()
       |> refresh_selected()}
    else
      {:noreply, assign(socket, :pending_handoff, nil)}
    end
  end

  def handle_event("update_member_role", %{"user_id" => uid, "role" => role}, socket) do
    initiative = socket.assigns.initiative
    uid = String.to_integer(uid)

    if socket.assigns.can_admin and uid != initiative.owner_id and role in ~w(editor viewer) do
      {:ok, _} = Initiatives.update_member_role(initiative.id, uid, role)

      {:noreply,
       socket
       |> assign(:members, Initiatives.list_members(initiative.id))
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
          case Initiatives.add_member(initiative.id, user.id, role) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Added #{user.name}.")
               |> assign(:members, Initiatives.list_members(initiative.id))}

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
    iid = String.to_integer(iid)
    uid = String.to_integer(uid)

    socket =
      case Initiatives.add_collaborator_as_viewer(user, iid, uid) do
        {:ok, added} ->
          put_flash(socket, :info, "Added #{added.name} as a viewer.")

        {:error, :already_member} ->
          put_flash(socket, :info, "They're already a member there.")

        {:error, :forbidden} ->
          put_flash(socket, :error, "Only that Initiative's owner can add members.")

        {:error, :failed} ->
          put_flash(socket, :error, "Couldn't add them.")
      end

    socket = assign(socket, :rail_collaborators, Initiatives.list_collaborators(user))

    socket =
      if iid == socket.assigns.initiative.id,
        do: assign(socket, :members, Initiatives.list_members(iid)),
        else: socket

    {:noreply, socket}
  end

  # Prune a past collaborator from My Collaborators (m02.05 item 12.11). Only
  # offered for someone with no current shared Initiative; the context re-guards
  # that and removes just this user's own edge.
  def handle_event("remove_collaborator", %{"user-id" => uid}, socket) do
    user = socket.assigns.current_user

    socket =
      case Initiatives.remove_collaborator(user, String.to_integer(uid)) do
        {:ok, _} ->
          assign(socket, :rail_collaborators, Initiatives.list_collaborators(user))

        {:error, :still_collaborating} ->
          put_flash(socket, :error, "You still share an Initiative with them.")
      end

    {:noreply, socket}
  end

  # --- Pending-action commits -----------------------------------------------

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

  # Branch checkbox: open the modal unless suppressed, else cascade now.
  # Replies mirror move_task's contract — the client flipped the branch's own
  # checkbox optimistically (.03.07.22): committed: false holds the flip while
  # the modal decides (6.6); committed: true releases it; ok: false reverts.
  defp request_cascade(socket, id, kind) do
    cond do
      not can_progress?(socket, id) ->
        {:reply, %{ok: false}, put_flash(socket, :error, "You don't have permission.")}

      skip_confirm?(socket, "cascade-complete") ->
        case commit_cascade(socket, id, kind) do
          {:ok, socket} -> {:reply, %{ok: true, committed: true}, socket}
          {:error, socket} -> {:reply, %{ok: false}, socket}
        end

      true ->
        task = Tasks.get_task!(id)

        {:reply, %{ok: true, committed: false},
         assign_pending(socket, %{kind: kind, task_id: id, title: task.title})}
    end
  end

  defp commit_cascade(socket, id, kind) do
    task = Tasks.get_task!(id)
    user = socket.assigns.current_user

    result =
      case kind do
        :cascade_complete -> Tasks.cascade_complete(task, user)
        :cascade_incomplete -> Tasks.cascade_incomplete(task, user)
      end

    case result do
      {:ok, _} ->
        {:ok, socket |> assign_pending(nil) |> load_tree() |> refresh_selected()}

      {:error, cs} ->
        {:error,
         socket
         |> assign_pending(nil)
         # A client may hold the optimistic flip from a confirmed cascade —
         # the write died, so revert it.
         |> push_event("confirm-cancelled", %{})
         |> put_flash(:error, "Couldn't cascade: #{summarize_errors(cs)}.")}
    end
  end

  defp commit_delete_task(socket, id) do
    case Tasks.delete_task(Tasks.get_task!(id), socket.assigns.current_user) do
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

  defp commit_delete_initiative(socket) do
    # Trash, not hard-delete (m02.06 item 10): the owner can restore it from the
    # Trash on the index, or purge it permanently there.
    {:ok, _} = Initiatives.trash_initiative(socket.assigns.initiative)

    socket
    |> put_flash(:info, "Initiative moved to Trash.")
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

  defp commit_remove_member(socket, user_id) do
    initiative = socket.assigns.initiative
    member = Enum.find(socket.assigns.members, &(&1.user_id == user_id))
    {_count, _} = Initiatives.remove_member(initiative.id, user_id)

    socket
    |> assign_pending(nil)
    |> put_flash(:info, "Removed #{(member && member.user.name) || "member"}.")
    |> assign(:members, Initiatives.list_members(initiative.id))
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

  @impl true
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
  # refresh who's-here for the server-rendered online dots.
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply,
     socket
     |> assign(:online_ids, online_ids(socket.assigns.initiative.id))
     |> push_presence()}
  end

  # Membership changed somewhere in this initiative: re-check OUR role —
  # removed means ejected on the spot, not at the next refresh; a role change
  # (e.g. an ownership transfer) re-renders the right controls live.
  def handle_info({:members_changed, _initiative_id}, socket) do
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
       # A removal here may drop the last Initiative shared with someone, so
       # refresh the Collaborators pane too (item 9).
       |> assign(:rail_collaborators, Initiatives.list_collaborators(socket.assigns.current_user))}
    else
      {:noreply,
       socket
       |> put_flash(:info, "You're no longer a member of that Initiative.")
       |> push_navigate(to: ~p"/initiatives")}
    end
  end

  def handle_info({:task_created, _id}, socket), do: {:noreply, load_tree(socket)}

  def handle_info({:task_updated, id}, socket), do: {:noreply, patch_task(socket, id)}

  def handle_info({:task_deleted, _id}, socket),
    do: {:noreply, socket |> load_tree() |> refresh_selected()}

  # A comment landed in the Initiative (item 14.3): refresh the pane only for a
  # viewer who has that task open, so the comment appears live for them without
  # every other viewer needlessly reloading their own selected pane.
  def handle_info({:comment_added, task_id}, socket) do
    if socket.assigns.selected_task_id == task_id,
      do: {:noreply, refresh_selected(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:task_moved, _id}, socket),
    do: {:noreply, socket |> load_tree() |> refresh_selected()}

  # --- Render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      width={:wide}
      rail_initiatives={@rail_initiatives}
      rail_current_id={@initiative.id}
      rail_current_name={@initiative.name}
      rail_collaborators={@rail_collaborators}
      rail_online_ids={@collaborator_online_ids}
      rail_member_ids={MapSet.new(@members, & &1.user_id)}
    >
      <div id="initiative-show-root" phx-hook=".TaskKeys">
        <script :type={Phoenix.LiveView.ColocatedHook} name=".TaskKeys">
          export default {
            mounted() {
              this._h = (e) => this.handle(e);
              window.addEventListener("keydown", this._h);
              // Row clicks are handled by a delegated listener in app.js (no
              // hook of its own) — give it a push channel into this LiveView.
              window.DoitPush = (ev, payload, cb) => this.pushEvent(ev, payload, cb);
              // After an undo/redo, select + scroll the affected task into view
              // (m02.06 item 13). Guarded: an undone create removes the task, so
              // there's nothing to show — skip rather than stall the pane.
              this.handleEvent("select-task", ({id}) => {
                if (!document.getElementById("task-" + id)) return;
                if (window.DoitSelection) window.DoitSelection.set(id, {scroll: true});
                if (window.DoitPush) window.DoitPush("select_task", {id});
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
              if (window.DoitPush) delete window.DoitPush;
              clearTimeout(this._paneT);
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
        <div class="relative mb-6 pb-6">
          <%!-- Close (back to the index) + role on the same row. The little red
               X (item 12.7) reads as "close this Initiative" rather than a plain
               back arrow — matching the task pane's close affordance. --%>
          <div class="flex items-center justify-between gap-2">
            <.link
              navigate={~p"/initiatives"}
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
                  aria-label={(@undo_label && "Undo #{@undo_label}") || "Undo (nothing to undo)"}
                  class="inline-flex items-center justify-center w-7 h-7 rounded text-zinc-500 hover:text-zinc-800 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:text-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-30 disabled:pointer-events-none transition"
                >
                  <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
                </button>
                <button
                  type="button"
                  id="redo-button"
                  disabled={is_nil(@redo_label)}
                  title={(@redo_label && "Redo: #{@redo_label}") || "Nothing to redo"}
                  aria-label={(@redo_label && "Redo #{@redo_label}") || "Redo (nothing to redo)"}
                  class="inline-flex items-center justify-center w-7 h-7 rounded text-zinc-500 hover:text-zinc-800 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:text-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-30 disabled:pointer-events-none transition"
                >
                  <.icon name="hero-arrow-uturn-right" class="w-4 h-4" />
                </button>
              </div>
              <div class="text-xs text-zinc-500 dark:text-zinc-400 whitespace-nowrap">
                Your role: <span class="font-medium text-zinc-700 dark:text-zinc-200">{@role}</span>
              </div>
            </div>
          </div>

          <%!-- Title row (dedicated): grove icon + name. New List inline on desktop only. --%>
          <div class="flex items-start gap-2 mt-2">
            <span class="mt-1 text-emerald-600 dark:text-emerald-400" aria-hidden="true">
              <.botanical_icon kind={:grove} class="w-6 h-6" />
            </span>
            <h1
              phx-click="edit_initiative"
              title="Click to edit"
              class={[
                "text-2xl font-semibold text-zinc-800 dark:text-zinc-100 cursor-pointer hover:text-zinc-900 dark:hover:text-white",
                !@editing_initiative? &&
                  "underline decoration-dotted decoration-2 underline-offset-4 decoration-zinc-400 dark:decoration-zinc-500"
              ]}
            >
              {@initiative.name}
            </h1>
            <button
              :if={@can_edit}
              type="button"
              data-add-root
              class="mt-1 ml-auto hidden sm:inline-flex items-center gap-1 px-2 py-0.5 rounded text-sm font-bold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
              aria-label="New list"
              title="New list"
            >
              <.icon name="hero-plus" class="w-4 h-4" />
              <span>New List</span>
            </button>
          </div>

          <p
            :if={@subtitle != ""}
            phx-click="edit_initiative"
            title="Click to edit"
            class="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5 cursor-pointer hover:text-zinc-700 dark:hover:text-zinc-200"
          >
            {@subtitle}
          </p>

          <p :if={@initiative.description} class="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
            {@initiative.description}
          </p>

          <div
            class="absolute bottom-0 left-0 right-0 h-4 bg-zinc-100 dark:bg-zinc-800 rounded-full overflow-hidden"
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

        <%!-- Mobile only (.05.04): New List + a Show/Hide Members toggle on one
             row under the progress bar; the members section collapses inline,
             client-side. Desktop uses the title-row New List + aside panel. --%>
        <div class="sm:hidden mb-6">
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

        <div class="grid grid-cols-1 lg:grid-cols-[1fr_360px] xl:grid-cols-[1fr_400px] 2xl:grid-cols-[1fr_440px] gap-6">
          <%!-- min-w-0 keeps this grid column from expanding to fit deep rows;
               overflow-x-auto lets the tree scroll horizontally inside it when
               indentation + the row's min width exceed the column. --%>
          <div class="min-w-0 overflow-x-auto">
            <%!-- The one add-task form (parked in #add-task-home below) gets
                 client-teleported into these phx-update="ignore" slots —
                 opening a form never phones home (UX_GUARDRAILS 6.5). --%>
            <div id="add-slot-root" phx-update="ignore" class="mb-3 empty:hidden"></div>

            <div :if={@tree == []} class="text-zinc-500 dark:text-zinc-400 text-sm">
              No lists yet. Create one to start tracking work.
            </div>

            <ul id="task-tree" phx-hook="TreeWidth" data-sort-mode={@root_sort_mode} class="space-y-2">
              <%= for t <- @tree do %>
                <.task_node
                  task={t}
                  depth={0}
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
          </div>

          <%!-- Backdrop on mobile when right-rail flyout is open. Always
               rendered; the client flips `hidden` with the rail (.03.07.20). --%>
          <div
            id="pane-backdrop"
            hidden={!(@selected_task_id || @editing_initiative?)}
            class="lg:hidden fixed inset-0 z-20 bg-black/50"
            phx-click="close_panel"
            aria-hidden="true"
          >
          </div>

          <%!-- The open/closed state rides ONE data-open attribute (flipped
               client-side at the tap, .03.07.20); all class differences hang
               off it as Tailwind data-variants. Mobile open: flyout overlay.
               Desktop open: sticky to the top of <main>, scrolls its own
               contents (.03.07.01) — self-start + max-h give sticky room. --%>
          <aside
            id="details-rail"
            data-open={(@selected_task_id || @editing_initiative?) && "true"}
            class={[
              "space-y-4",
              "not-data-open:hidden lg:not-data-open:block",
              "data-open:block data-open:fixed lg:data-open:sticky data-open:top-0 data-open:bottom-0 lg:data-open:bottom-auto data-open:right-0 data-open:z-30",
              "data-open:w-full sm:data-open:w-96 lg:data-open:w-auto lg:data-open:self-start lg:data-open:max-h-[calc(100dvh-4rem)]",
              "data-open:bg-zinc-50 lg:data-open:bg-transparent dark:data-open:bg-zinc-950 lg:dark:data-open:bg-transparent",
              "data-open:shadow-xl lg:data-open:shadow-none data-open:p-4 lg:data-open:p-0",
              "data-open:overflow-y-auto data-open:[scrollbar-gutter:stable]"
            ]}
          >
            <div class="lg:hidden flex justify-end">
              <button
                type="button"
                phx-click="close_panel"
                aria-label="Close details panel"
                title="Close"
                class="inline-flex items-center justify-center w-8 h-8 rounded bg-red-500/30 hover:bg-red-500/50 text-white font-bold"
              >
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>
            <%!-- Desktop/tablet: standalone Members panel. On phone it's hidden
                 in favor of the header's collapsible toggle (.05.04.1). --%>
            <div class="hidden sm:block">
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

            <%!-- Persistent like the task pane (.03.07.08): always rendered,
                 hidden toggled — the client flips it instantly on the
                 initiative title click and the server patch confirms. --%>
            <div
              id="initiative-editor-pane"
              hidden={not @editing_initiative?}
              class="rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 p-4"
            >
              <.initiative_editor
                form={@initiative_form}
                can_edit={@can_edit}
                can_admin={@can_admin}
                initiative={@initiative}
                root_task={@root_task}
                subtitle={@subtitle}
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
              hidden={is_nil(@selected_task_id) or @editing_initiative?}
              class="rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 p-4"
            >
              <.task_editor
                task={@selected_task || blank_task()}
                comments={@comments}
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
      <.delete_task_confirm :if={@can_edit} />
      <.delete_initiative_confirm :if={@can_admin} name={@initiative.name} />
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
          phx-click-away="cancel_handoff"
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
              phx-click="cancel_handoff"
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
      <div
        :if={@pending_transfer}
        id="transfer-confirm"
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
      >
        <div
          phx-click-away="cancel_transfer"
          class="w-full max-w-md rounded-lg bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-700 p-5 shadow-xl"
        >
          <h3 class="text-base font-semibold text-zinc-800 dark:text-zinc-100">
            Transfer ownership
          </h3>
          <p class="mt-2 text-sm text-zinc-600 dark:text-zinc-300">
            Make <span class="font-semibold">{@pending_transfer.name}</span>
            the owner of <span class="font-semibold">{@initiative.name}</span>?
            This is a transfer — you'll be demoted to <span class="font-semibold">editor</span>
            and lose owner controls.
          </p>
          <div class="mt-5 flex justify-end gap-2">
            <button
              type="button"
              phx-click="cancel_transfer"
              class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200 active:scale-95 transition dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:active:bg-zinc-700"
            >
              Cancel
            </button>
            <button
              type="button"
              id="transfer-confirm-proceed"
              phx-click="confirm_transfer"
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
      <div id="presence-badges" phx-hook="PresenceBadges" phx-update="ignore" hidden></div>
    </Layouts.app>
    """
  end

  # The sort controls name their own target (the form's hidden task_id /
  # the cascade button's phx-value-id); fall back to the pane task.
  defp sort_target(socket, params) do
    case params["task_id"] || params["id"] do
      id when is_binary(id) -> Tasks.get_task!(String.to_integer(id))
      _ -> socket.assigns.selected_task
    end
  end

  # Resolve a keyboard shortcut's target: the client sends its selected id
  # (the DOM-owned selection); fall back to the server's pane task. Guarded
  # to this initiative and to editors.
  defp kbd_target(socket, params) do
    id =
      case params["id"] do
        id when is_binary(id) -> String.to_integer(id)
        _ -> socket.assigns.selected_task_id
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
  defp confirm_class(%{kind: :remove_member}), do: "remove-member"

  defp confirm_class(%{kind: kind}) when kind in [:cascade_complete, :cascade_incomplete],
    do: "cascade-complete"

  defp confirm_class(_), do: nil

  defp confirm_class_label("completion-flip"), do: "completion changes"
  defp confirm_class_label("cascade-sort"), do: "large branch reorgs"
  defp confirm_class_label("cascade-complete"), do: "branch completion changes"
  defp confirm_class_label("remove-member"), do: "member removals"

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

  defp pending_saving_ids(%{kind: kind, task_id: id})
       when kind in [:cascade_complete, :cascade_incomplete],
       do: MapSet.new(Tasks.subtree_ids(id) ++ Tasks.ancestor_ids(id))

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
  defp confirm_title(%{kind: :cascade_complete}), do: "Complete this branch?"
  defp confirm_title(%{kind: :cascade_incomplete}), do: "Reopen this branch?"
  defp confirm_title(_), do: "Confirm completion change"

  defp confirm_body(%{kind: :cascade_sort, affected: n}, _verb) do
    "This is a large branch reorg affecting #{n} task(s). Every descendant branch " <>
      "switches to Inherit — their own sort settings are overwritten and they follow " <>
      "this branch from now on; reversible only via Undo (Arc 5)."
  end

  defp confirm_body(%{kind: :cascade_complete, title: t}, _verb),
    do: "Mark \"#{t}\" and all its subtasks complete?"

  defp confirm_body(%{kind: :cascade_incomplete, title: t}, _verb),
    do: "Reopen \"#{t}\" and all its subtasks?"

  defp confirm_body(%{kind: :remove_member, name: name}, _verb),
    do: "Remove #{name} from this Initiative? They can be re-added anytime."

  defp confirm_body(%{kind: :leave_initiative}, _verb),
    do: "Leave this Initiative? Only the owner can add you back."

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

  attr :task, :map, required: true
  attr :depth, :integer, required: true
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
        data-done={@task.status == "done"}
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
          <%!-- Priority always has a value, so the pill is always "set"
               (solid border) and shows "normal" too. --%>
          <button
            :if={@display.priority}
            type="button"
            phx-click="select_task"
            phx-value-id={@task.id}
            data-pill="priority"
            data-pill-set
            class={[
              "inline-flex items-center justify-center h-5 min-w-9 px-1.5 rounded-full text-xs flex-none cursor-pointer",
              "border border-dashed border-zinc-300 dark:border-zinc-600",
              "data-pill-set:border-solid data-pill-set:border-zinc-400 dark:data-pill-set:border-zinc-500 data-pill-set:bg-zinc-100 dark:data-pill-set:bg-zinc-800 data-pill-set:text-zinc-600 dark:data-pill-set:text-zinc-300"
            ]}
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
              "border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-900 hover:border-emerald-500",
              "aria-pressed:border-emerald-500 aria-pressed:bg-emerald-500 aria-pressed:text-white"
            ]}
          >
            <%!-- Styling keys off aria-pressed (not server-conditional classes)
                 so the optimistic leaf flip in app.js is one attribute write. --%>
            <.icon name="hero-check" class="w-3 h-3 hidden group-aria-pressed/check:inline-block" />
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
        phx-hook="CollapseChildren"
        data-task-id={@task.id}
        data-initiative-id={@initiative_id}
        data-sort-mode={@resolved_sort}
        class="pl-1.5 sm:pl-6 space-y-1"
      >
        <%= for c <- @task.children do %>
          <.task_node
            task={c}
            depth={@depth + 1}
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

  def initiative_editor(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-start justify-between gap-2">
        <h3 class="font-medium text-zinc-800 dark:text-zinc-100">Initiative details</h3>
        <button
          type="button"
          phx-click="close_initiative"
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
          <label for="initiative-subtitle" class="text-xs text-zinc-500 dark:text-zinc-400">
            Subtitle
          </label>
          <input
            id="initiative-subtitle"
            type="text"
            name="subtitle"
            value={@subtitle}
            placeholder="a short tagline for this initiative"
            class="w-full input input-bordered input-sm"
            disabled={not @can_edit}
            phx-change="update_subtitle"
            phx-debounce="600"
          />
        </div>

        <.input
          field={@form[:description]}
          type="textarea"
          label="Description"
          disabled={not @can_edit}
          phx-debounce="600"
        />
      </.form>

      <div class={[
        "text-xs text-zinc-500 dark:text-zinc-400 italic",
        leaf?(@root_task) && "invisible"
      ]}>
        Computed from children: {@root_task.computed_progress}%
      </div>

      <.sort_menu task={@root_task} can_edit={@can_edit} label="Sort lists by" />

      <%!-- Settings (.03.07.07): collapsed by default; initiative-wide
           behavior that isn't day-to-day editing. KeepOpen preserves the
           open/closed state across LiveView patches. --%>
      <details
        id="initiative-settings"
        phx-hook="KeepOpen"
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
              </label>
              <p class="mt-0.5 text-[11px] text-zinc-400 dark:text-zinc-500">
                A viewer who is a task's assignee can update its progress and comments (and
                everything below it), and staff descendants from that task's co-assignees.
              </p>
            </form>
          </div>
        </div>
      </details>

      <div :if={@can_admin} class="border-t border-zinc-100 dark:border-zinc-700 pt-3">
        <%!-- No phx-click: the confirm opens client-side (.03.07.18). --%>
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
  opens client-side (native <details>, UX_GUARDRAILS 6.5); KeepOpen carries
  its state across patches.
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
           and KeepOpen carries the state across patches. --%>
      <details :if={@can_admin} id={"#{@id}-form"} phx-hook="KeepOpen" class="mb-3">
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
                phx-disable-with="Adding..."
                class="text-xs px-2 py-1 rounded bg-emerald-600 text-white hover:bg-emerald-700"
              >
                Add
              </button>
            </div>
          </form>
        </div>
      </details>

      <ul class="space-y-1 text-sm">
        <li :for={m <- @members} class="flex items-center justify-between">
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
              class="flex-none"
            >
              <input type="hidden" name="user_id" value={m.user_id} />
              <%!-- Item 12.6.5: the effective role shows IN the dropdown — a
                   viewer who holds an assignment reads "viewer+" (its value is
                   still "viewer", so leaving it set is a no-op; the DB role
                   stays viewer). --%>
              <select
                name="role"
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
            </form>
            <span
              :if={not (@can_admin and m.user_id != @owner_id)}
              class="text-xs text-zinc-500 dark:text-zinc-400"
            >
              {role_label(m, @assignee_ids, @viewer_plus_on)}
            </span>
            <%!-- Leave (own row, non-owners): always confirmed — only the
                 owner can add you back. The members_changed broadcast ejects
                 this very view on commit. --%>
            <button
              :if={m.user_id == @me && @me != @owner_id}
              type="button"
              phx-click="leave_initiative"
              title="Leave this Initiative"
              aria-label="Leave this Initiative"
              class="inline-flex items-center justify-center w-5 h-5 rounded text-zinc-400 hover:text-red-600 hover:bg-red-50 dark:text-zinc-500 dark:hover:text-red-400 dark:hover:bg-red-950/40"
            >
              <.icon name="hero-arrow-right-start-on-rectangle" class="w-3.5 h-3.5" />
            </button>
            <%!-- Transfer ownership: always confirmed (the modal spells out
                 the demotion-to-editor consequence). --%>
            <button
              :if={@can_admin && m.user_id != @owner_id}
              type="button"
              phx-click="transfer_ownership"
              phx-value-user-id={m.user_id}
              title={"Transfer ownership to #{m.user.name}"}
              aria-label={"Transfer ownership to #{m.user.name}"}
              class="inline-flex items-center justify-center w-5 h-5 rounded text-zinc-400 hover:text-amber-600 hover:bg-amber-50 dark:text-zinc-500 dark:hover:text-amber-400 dark:hover:bg-amber-950/40"
            >
              <.icon name="hero-key" class="w-3.5 h-3.5" />
            </button>
            <%!-- The initiative's owner row is never removable. Removal runs
                 through the suppressible confirm (.03.01.11, class
                 "remove-member") — re-addable, so "don't ask again" is fine. --%>
            <button
              :if={@can_admin && m.user_id != @owner_id}
              type="button"
              phx-click="remove_member"
              phx-value-user-id={m.user_id}
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
      <label for={"sort-mode-#{@task.id}"} class="text-xs text-zinc-500 dark:text-zinc-400">
        {@label}
      </label>
      <form
        id={"sort-form-#{@task.id}"}
        phx-hook="SortRecall"
        data-task-id={@task.id}
        data-saving-children
        phx-change="set_sort"
        class="flex items-center gap-2"
      >
        <input type="hidden" name="task_id" value={@task.id} />
        <select
          id={"sort-mode-#{@task.id}"}
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
          for={"sort-reverse-#{@task.id}"}
          class={[
            "flex items-center gap-1 text-xs select-none",
            reverse_disabled?(@task) && "text-zinc-400 dark:text-zinc-500",
            not reverse_disabled?(@task) && "text-zinc-600 dark:text-zinc-300"
          ]}
          title="Reverse the sort direction"
        >
          <input
            id={"sort-reverse-#{@task.id}"}
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
        phx-click="cascade_sort"
        phx-value-id={@task.id}
        data-saving-subtree
        class="inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30 active:scale-95 transition"
        title="Force every descendant branch to inherit this branch's sort"
      >
        Make descendants inherit
      </button>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :comments, :list, required: true
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
          phx-click="close_task"
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
          <label for="task-field-title" class="text-xs text-zinc-500 dark:text-zinc-400">
            Title
          </label>
          <input
            id="task-field-title"
            type="text"
            name="task[title]"
            value={@task.title}
            class="w-full input input-bordered input-sm"
            disabled={not @can_edit}
            phx-debounce="blur"
          />
        </div>

        <div>
          <label for="task-field-description" class="text-xs text-zinc-500 dark:text-zinc-400">
            Description
          </label>
          <textarea
            id="task-field-description"
            name="task[description]"
            class="w-full textarea textarea-bordered textarea-sm"
            rows="3"
            disabled={not @can_edit}
            phx-debounce="blur"
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
            <.info_hint
              :if={not leaf?(@task)}
              id={"mp-hint-#{@task.id}"}
              label="Why is this disabled?"
            >
              Progress on a task with subtasks is calculated from its subtasks instead of
              being set manually. Your manual value is kept and will start being used again
              if you remove all subtasks.
            </.info_hint>
          </div>
          <input
            id="task-field-progress"
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
          <p class={[
            "text-xs text-zinc-400 dark:text-zinc-500 italic",
            leaf?(@task) && "invisible"
          ]}>
            Ignored — this task has subtasks.
          </p>
          <div class={[
            "text-xs text-zinc-500 dark:text-zinc-400 italic",
            leaf?(@task) && "invisible"
          ]}>
            Computed from children: {@task.computed_progress}%
          </div>
        </div>
      </form>

      <.sort_menu :if={@task.id} task={@task} can_edit={@can_edit} label="Sort children by" />

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

      <%!-- Co-assignees (m02.05 item 13): ordered, manual — position is
           promotion order. The primary stays the assignee select above.
           MUST live OUTSIDE the update_task form — its own add-form can't be
           nested in another form (the browser drops nested forms). --%>
      <div
        :if={@task.id && (@can_edit or @can_staff or @task.co_assignee_links != [])}
        id="co-assignees"
        phx-hook="CoAssignees"
      >
        <span class="text-xs text-zinc-500 dark:text-zinc-400">Co-assignees</span>
        <%!-- Item 12.5: the list is hook-owned (phx-update="ignore") so optimistic
             add/remove/reorder apply at the gesture without morphdom fighting
             them; the hook reverts from the server's reply (or a timeout) when a
             write doesn't land — never sticking a change the server refused.
             Keyed by task id so selecting another task re-renders from the
             server. The chip + dropdown stay server-driven (truthful). --%>
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
            <span title={@task.updated_at}>
              ({Calendar.strftime(@task.updated_at, "%b %-d %H:%M")})
            </span>
          <% else %>
            Updated {Calendar.strftime(@task.updated_at, "%b %-d %H:%M")}
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
        <ul data-async-list class="space-y-2 mb-2">
          <li :for={c <- @comments} class="text-sm">
            <div class="text-xs text-zinc-500 dark:text-zinc-400 flex items-center gap-1">
              <.avatar
                :if={c.user}
                user={c.user}
                online={c.user && MapSet.member?(@online_ids, c.user.id)}
                class="w-4 h-4 text-[8px]"
              />
              {c.user && c.user.name} · {Calendar.strftime(c.inserted_at, "%b %-d %H:%M")}
            </div>
            <div class="text-zinc-800 dark:text-zinc-100 whitespace-pre-wrap">{c.body}</div>
          </li>
        </ul>
        <form :if={@can_progress} phx-submit="add_comment" class="flex gap-2">
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
           expandable. KeepOpen persists the user's open/closed choice across
           pane patches. --%>
      <details
        :if={@show_activity}
        id="task-activity"
        phx-hook="KeepOpen"
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
              {Calendar.strftime(e.inserted_at, "%b %-d %H:%M")}
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
    anchor = Tasks.get_task!(after_id)
    sibs = sibling_ids(anchor)

    case Enum.find_index(sibs, &(&1 == anchor.id)) do
      nil -> nil
      idx -> idx + 1
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
