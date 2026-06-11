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
        if connected?(socket), do: Tasks.subscribe(initiative.id)

        {:ok,
         socket
         |> assign(:page_title, initiative.name)
         |> assign(:initiative, initiative)
         |> assign(:subtitle, Initiatives.subtitle(initiative))
         |> assign(:role, role)
         |> assign(:can_edit, Initiatives.can_edit?(role))
         |> assign(:can_admin, Initiatives.can_admin?(role))
         |> assign(:members, Initiatives.list_members(initiative.id))
         |> assign(:show_member_form, false)
         |> assign(:member_email, "")
         |> assign(:selected_task_id, nil)
         |> assign(:editing_initiative?, false)
         |> assign(:initiative_form, to_form(Initiatives.change_initiative(initiative)))
         |> assign(:add_task_for, nil)
         |> assign(:add_task_after, nil)
         |> assign(:new_task_title, "")
         |> assign_pending(nil)
         |> assign(:confirm_skips, MapSet.new())
         |> load_tree()}
    end
  end

  defp load_tree(socket) do
    initiative_id = socket.assigns.initiative.id
    tree = Tasks.initiative_task_tree(initiative_id)
    root = Tasks.get_task(socket.assigns.initiative.root_task_id)

    # Resolved once here; task_node threads it down (child = own mode ||
    # parent's resolved), so rendering never walks the DB per branch. The
    # header bar shows the system root's roll-up — same leaf-average math as
    # every branch (ProductSpec § Roll-up Progress).
    socket
    |> assign(:tree, tree)
    |> assign(:root_sort_mode, elem(Tasks.resolve_sort(root), 0))
    |> assign(:initiative_progress, (root && root.computed_progress) || 0)
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

        socket =
          socket
          |> assign(:tree, patched_tree(socket, task, lineage))
          |> maybe_refresh_root_sort(task, root_id)

        # Any in-tree lineage tops out at the system root — its fresh roll-up
        # drives the header bar.
        socket =
          case Enum.find(lineage, &(&1.id == root_id)) do
            nil -> socket
            root -> assign(socket, :initiative_progress, root.computed_progress || 0)
          end

        if socket.assigns.selected_task_id in Enum.map(lineage, & &1.id),
          do: refresh_selected(socket),
          else: socket
    end
  end

  defp patched_tree(socket, task, lineage) do
    root_id = socket.assigns.initiative.root_task_id
    tree = Tree.merge(socket.assigns.tree, lineage)

    # The write may have re-keyed two display orders: the task among its
    # siblings (auto-sorted parents resort on update), and the task's own
    # children (a sort-mode change resorts them — §8.11 finding: collaborators
    # never saw a resort because only the sibling level was re-keyed).
    tree =
      case task.parent_id do
        # The system root has no sibling order of its own to re-key.
        nil -> tree
        parent_id -> reorder_level(tree, parent_id, root_id)
      end

    reorder_level(tree, task.id, root_id)
  end

  defp reorder_level(tree, parent_id, root_id) do
    key = if parent_id == root_id, do: :root, else: parent_id
    Tree.reorder_children(tree, key, Tasks.ordered_child_ids(parent_id))
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
            |> assign(:selected_task, task)
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

  def handle_event("show_add_root", _params, socket) do
    {:noreply,
     socket
     |> assign(:add_task_for, :root)
     |> assign(:add_task_after, nil)
     |> assign(:new_task_title, "")}
  end

  def handle_event("show_add_child", %{"parent" => parent_id}, socket) do
    parent_id = String.to_integer(parent_id)

    {:noreply,
     socket
     |> assign(:add_task_for, parent_id)
     |> assign(:add_task_after, parent_id)
     |> assign(:new_task_title, "")}
  end

  def handle_event("show_add_sibling", %{"task" => task_id}, socket) do
    task = Tasks.get_task!(String.to_integer(task_id))
    add_for = task.parent_id || :root

    {:noreply,
     socket
     |> assign(:add_task_for, add_for)
     |> assign(:add_task_after, task.id)
     |> assign(:new_task_title, "")}
  end

  def handle_event("cancel_add", _params, socket) do
    {:noreply,
     socket
     |> assign(:add_task_for, nil)
     |> assign(:add_task_after, nil)}
  end

  def handle_event("create_task", %{"title" => title} = params, socket) do
    user = socket.assigns.current_user
    initiative = socket.assigns.initiative

    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission to add tasks.")}
    else
      parent_id =
        case socket.assigns.add_task_for do
          # "Root level" now means a child of the Initiative's root task.
          :root -> initiative.root_task_id
          id when is_integer(id) -> id
        end

      attrs = %{
        "initiative_id" => initiative.id,
        "parent_id" => parent_id,
        "title" => title,
        "weight" => Map.get(params, "weight", "1.0"),
        "position" => new_task_position(socket.assigns)
      }

      case Tasks.preview_create(user, attrs) do
        {:ok, %{scenario: nil}} ->
          {:noreply, commit_create(socket, attrs)}

        {:ok, %{scenario: scenario, titles: titles, ids: flip_ids}} ->
          if skip_confirm?(socket, "completion-flip") do
            {:noreply, commit_create(socket, attrs)}
          else
            {:noreply,
             assign_pending(socket, %{
               kind: :create,
               attrs: attrs,
               scenario: scenario,
               titles: titles,
               flip_ids: flip_ids
             })}
          end

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't create task: #{summarize_errors(cs)}.")}
      end
    end
  end

  # Selection is client-first (UX_GUARDRAILS 6.5): the highlight lives in the
  # DOM, this event only loads the Details pane.
  def handle_event("select_task", %{"id" => id} = params, socket) do
    id = String.to_integer(id)
    focus = params["focus"]

    cond do
      # A pill tap on the already-open task: just jump to the field.
      focus && socket.assigns.selected_task_id == id ->
        {:noreply, push_focus(socket, focus)}

      # Pane already shows this task — nothing to load.
      socket.assigns.selected_task_id == id ->
        {:noreply, socket}

      true ->
        case Tasks.get_task_with_relations(id) do
          nil ->
            {:noreply, socket}

          task ->
            socket =
              socket
              |> assign(:editing_initiative?, false)
              |> assign(:selected_task_id, id)
              |> assign(:selected_task, task)
              |> assign(:comments, Tasks.list_comments(id))
              |> assign(:activity, Tasks.list_task_activity(id))

            {:noreply, push_focus(socket, focus)}
        end
    end
  end

  # Keyboard: N — open the New Subtask form under the client's selected task.
  def handle_event("kbd_new_subtask", params, socket) do
    case kbd_target(socket, params) do
      nil -> {:noreply, socket}
      task -> {:noreply, show_add_for(socket, task.id)}
    end
  end

  # Keyboard: S — open the New Sibling form for the selected task (same parent).
  def handle_event("kbd_new_sibling", params, socket) do
    case kbd_target(socket, params) do
      nil ->
        {:noreply, socket}

      task ->
        {:noreply,
         socket
         |> assign(:add_task_for, task.parent_id || :root)
         |> assign(:add_task_after, task.id)
         |> assign(:new_task_title, "")}
    end
  end

  # Keyboard: P / W / A — step priority / weight / assignee of the selected task.
  def handle_event("kbd_adjust", %{"field" => field, "dir" => dir} = params, socket)
      when field in ~w(priority weight assignee) and dir in ~w(up down) do
    case kbd_target(socket, params) do
      nil -> {:noreply, socket}
      task -> apply_kbd_adjust(socket, task, field, dir)
    end
  end

  # Keyboard: Alt+P / Alt+W / Alt+A — focus that Details field for precise editing.
  def handle_event("kbd_focus_field", %{"field" => field}, socket) do
    cond do
      is_nil(socket.assigns.selected_task_id) -> {:noreply, socket}
      not socket.assigns.can_edit -> {:noreply, socket}
      true -> {:noreply, push_focus(socket, field)}
    end
  end

  def handle_event("edit_initiative", _params, socket) do
    initiative = socket.assigns.initiative
    form = to_form(Initiatives.change_initiative(initiative))

    # The Initiative IS its root task: select the root so the shared sort menu +
    # computed-from-children line operate on it, while the pane wraps the
    # Initiative-only fields (name / subtitle / description / members / delete).
    root = Tasks.get_task_with_relations(initiative.root_task_id)

    {:noreply,
     socket
     |> assign(:selected_task_id, initiative.root_task_id)
     |> assign(:selected_task, root)
     |> assign(:editing_initiative?, true)
     |> assign(:initiative_form, form)
     |> assign(:subtitle, Initiatives.subtitle(initiative))}
  end

  def handle_event("close_initiative", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_initiative?, false)
     |> assign(:selected_task_id, nil)
     |> assign(:selected_task, nil)}
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

  def handle_event("request_delete_initiative", _params, socket) do
    if not socket.assigns.can_admin do
      {:noreply, put_flash(socket, :error, "Only the owner can delete this initiative.")}
    else
      {:noreply,
       assign_pending(socket, %{
         kind: :delete_initiative,
         title: socket.assigns.initiative.name
       })}
    end
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_initiative?, false)
     |> assign(:selected_task_id, nil)}
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
    {:noreply, assign(socket, :selected_task_id, nil)}
  end

  def handle_event("update_task", %{"task" => params}, socket) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    else
      task = socket.assigns.selected_task
      user = socket.assigns.current_user

      case Tasks.update_task(task, user, params) do
        {:ok, _updated} ->
          {:noreply, socket |> put_flash(:info, "Saved.") |> patch_task(task.id)}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't save task: #{summarize_errors(cs)}.")}
      end
    end
  end

  def handle_event("cascade_sort", _params, socket) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    else
      task = socket.assigns.selected_task
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
      task = socket.assigns.selected_task
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
    if not socket.assigns.can_edit do
      {:noreply, socket}
    else
      task = socket.assigns.selected_task
      user = socket.assigns.current_user

      case Tasks.update_task(task, user, %{"manual_progress" => value}) do
        {:ok, _} ->
          {:noreply, patch_task(socket, task.id)}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Invalid progress: #{summarize_errors(cs)}.")}
      end
    end
  end

  def handle_event("toggle_complete", %{"id" => id}, socket) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    else
      task = Tasks.get_task!(String.to_integer(id))
      user = socket.assigns.current_user

      case Tasks.toggle_complete(task, user) do
        {:ok, _} ->
          {:noreply, patch_task(socket, task.id)}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't toggle: #{summarize_errors(cs)}.")}
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
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    else
      task = socket.assigns.selected_task
      user = socket.assigns.current_user

      case Tasks.add_comment(task, user, body) do
        {:ok, _comment} -> {:noreply, refresh_selected(socket)}
        {:error, _cs} -> {:noreply, put_flash(socket, :error, "Comment cannot be empty.")}
      end
    end
  end

  # Delete (.03.01.11): always confirm via the styled modal (not suppressible).
  def handle_event("request_delete_task", _params, socket) do
    cond do
      not socket.assigns.can_edit ->
        {:noreply, put_flash(socket, :error, "You don't have permission.")}

      is_nil(socket.assigns.selected_task_id) ->
        {:noreply, socket}

      true ->
        task = socket.assigns.selected_task

        {:noreply,
         assign_pending(socket, %{
           kind: :delete_task,
           task_id: task.id,
           title: task.title
         })}
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
            # persisted, so tell the client not to keep its optimistic placement
            # (the confirm modal drives the real move). committed: false.
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

        %{kind: kind, task_id: id} when kind in [:cascade_complete, :cascade_incomplete] ->
          commit_cascade(socket, id, kind)

        %{kind: :delete_task, task_id: id} ->
          commit_delete_task(socket, id)

        %{kind: :delete_initiative} ->
          commit_delete_initiative(socket)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("cancel_pending", _params, socket) do
    {:noreply, assign_pending(socket, nil)}
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

  def handle_event("show_member_form", _params, socket) do
    {:noreply, socket |> assign(:show_member_form, true) |> assign(:member_email, "")}
  end

  def handle_event("cancel_member", _params, socket) do
    {:noreply, assign(socket, :show_member_form, false)}
  end

  def handle_event("add_member", %{"email" => email, "role" => role}, socket) do
    if not socket.assigns.can_admin do
      {:noreply, put_flash(socket, :error, "Only the owner can add members.")}
    else
      initiative = socket.assigns.initiative

      case Accounts.get_user_by_email(email) do
        nil ->
          {:noreply, put_flash(socket, :error, "No user with that email.")}

        user ->
          case Initiatives.add_member(initiative.id, user.id, role) do
            {:ok, _} ->
              {:noreply,
               socket
               |> assign(:show_member_form, false)
               |> put_flash(:info, "Added #{user.name}.")
               |> assign(:members, Initiatives.list_members(initiative.id))}

            {:error, cs} ->
              {:noreply,
               put_flash(socket, :error, "Couldn't add member: #{summarize_errors(cs)}.")}
          end
      end
    end
  end

  # --- Pending-action commits -----------------------------------------------

  defp commit_create(socket, attrs) do
    case Tasks.create_task(socket.assigns.current_user, attrs) do
      {:ok, _task} ->
        socket
        |> assign(:add_task_for, nil)
        |> assign(:add_task_after, nil)
        |> assign(:new_task_title, "")
        |> assign_pending(nil)
        |> put_flash(:info, "Task added.")
        |> load_tree()

      {:error, cs} ->
        socket
        |> assign_pending(nil)
        |> put_flash(:error, "Couldn't create task: #{summarize_errors(cs)}.")
    end
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
  defp request_cascade(socket, id, kind) do
    cond do
      not socket.assigns.can_edit ->
        {:noreply, put_flash(socket, :error, "You don't have permission.")}

      skip_confirm?(socket, "cascade-complete") ->
        {:noreply, commit_cascade(socket, id, kind)}

      true ->
        task = Tasks.get_task!(id)
        {:noreply, assign_pending(socket, %{kind: kind, task_id: id, title: task.title})}
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
        socket |> assign_pending(nil) |> load_tree() |> refresh_selected()

      {:error, cs} ->
        socket
        |> assign_pending(nil)
        |> put_flash(:error, "Couldn't cascade: #{summarize_errors(cs)}.")
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
    {:ok, _} = Initiatives.delete_initiative(socket.assigns.initiative)

    socket
    |> put_flash(:info, "Initiative deleted.")
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
         |> put_flash(:error, "Couldn't move task: #{format_move_error(reason)}.")}
    end
  end

  # --- PubSub ---------------------------------------------------------------

  @impl true
  def handle_info({:task_created, _id}, socket), do: {:noreply, load_tree(socket)}

  def handle_info({:task_updated, id}, socket), do: {:noreply, patch_task(socket, id)}

  def handle_info({:task_deleted, _id}, socket),
    do: {:noreply, socket |> load_tree() |> refresh_selected()}

  def handle_info({:comment_added, _id}, socket), do: {:noreply, refresh_selected(socket)}

  def handle_info({:task_moved, _id}, socket),
    do: {:noreply, socket |> load_tree() |> refresh_selected()}

  # --- Render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div id="initiative-show-root" phx-hook=".TaskKeys">
        <script :type={Phoenix.LiveView.ColocatedHook} name=".TaskKeys">
          export default {
            mounted() {
              this._h = (e) => this.handle(e);
              window.addEventListener("keydown", this._h);
              // Row clicks are handled by a delegated listener in app.js (no
              // hook of its own) — give it a push channel into this LiveView.
              window.DoitPush = (ev, payload) => this.pushEvent(ev, payload);
            },
            destroyed() {
              window.removeEventListener("keydown", this._h);
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
              // Suppression: a text-accepting element has focus — fall through.
              if (this.inField()) return;
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
                  if (S && li) S.markSaving(this.movePinkRows(S, li, k));
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
              if (k === "n" || k === "N") { e.preventDefault(); this.pushEvent("kbd_new_subtask", {id: sel}); return; }
              if (k === "s" || k === "S") { e.preventDefault(); this.pushEvent("kbd_new_sibling", {id: sel}); return; }
              // Del clicks the delete button so its confirm dialog still fires.
              if (k === "Delete") {
                e.preventDefault();
                const btn = document.getElementById("delete-task-btn");
                if (btn) btn.click();
                return;
              }
              // P / W / A: Alt focuses the field for precise editing; plain steps
              // the value up, Shift steps it down.
              const field = k.length === 1 && {p: "priority", w: "weight", a: "assignee"}[k.toLowerCase()];
              if (field) {
                e.preventDefault();
                if (e.altKey) { this.pushEvent("kbd_focus_field", {field: field}); return; }
                const S = window.DoitSaving, li = S && S.selectedLi();
                if (li) {
                  S.markSaving(field === "weight"
                    ? [S.savingRowOf(li), ...S.savingAncestors(li)]
                    : [S.savingRowOf(li)]);
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
          }
        </script>
        <div class="relative mb-6 pb-6">
          <%!-- Back link + role on the same row. --%>
          <div class="flex items-center justify-between gap-2">
            <.link
              navigate={~p"/initiatives"}
              class="text-sm text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100"
            >
              ← All initiatives
            </.link>
            <div class="text-xs text-zinc-500 dark:text-zinc-400 whitespace-nowrap">
              Your role: <span class="font-medium text-zinc-700 dark:text-zinc-200">{@role}</span>
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
              phx-click="show_add_root"
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
              phx-click="show_add_root"
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
              members={@members}
              can_admin={@can_admin}
              show_member_form={@show_member_form}
            />
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-[1fr_360px] gap-6">
          <%!-- min-w-0 keeps this grid column from expanding to fit deep rows;
               overflow-x-auto lets the tree scroll horizontally inside it when
               indentation + the row's min width exceed the column. --%>
          <div class="min-w-0 overflow-x-auto">
            <div :if={@add_task_for == :root} class="mb-3">
              <.task_form parent_id={nil} />
            </div>

            <div :if={@tree == []} class="text-zinc-500 dark:text-zinc-400 text-sm">
              No lists yet. Create one to start tracking work.
            </div>

            <ul id="task-tree" phx-hook="TreeWidth" data-sort-mode={@root_sort_mode} class="space-y-2">
              <%= for t <- @tree do %>
                <.task_node
                  task={t}
                  depth={0}
                  add_task_for={@add_task_for}
                  add_task_after={@add_task_after}
                  can_edit={@can_edit}
                  initiative_id={@initiative.id}
                  saving_ids={@pending_saving_ids}
                  inherited_sort={@root_sort_mode}
                />
                <%= if @add_task_after == t.id and @add_task_for != t.id do %>
                  <li class="rounded border border-emerald-500/40 bg-white dark:bg-zinc-900 px-3 py-2">
                    <.task_form parent_id={if(@add_task_for == :root, do: nil, else: @add_task_for)} />
                  </li>
                <% end %>
              <% end %>
            </ul>
          </div>

          <%!-- Backdrop on mobile when right-rail flyout is open --%>
          <div
            :if={@selected_task_id || @editing_initiative?}
            class="lg:hidden fixed inset-0 z-20 bg-black/50"
            phx-click="close_panel"
            aria-hidden="true"
          >
          </div>

          <aside class={
            [
              "space-y-4",
              # Mobile: flyout overlay. Desktop: sticky to the top of <main>, scrolls
              # its own contents (.03.07.01) — self-start + max-h give sticky room.
              (@selected_task_id || @editing_initiative?) &&
                "fixed lg:sticky top-0 bottom-0 lg:bottom-auto right-0 z-30 w-full sm:w-96 lg:w-auto lg:self-start lg:max-h-[calc(100dvh-4rem)] bg-zinc-50 lg:bg-transparent dark:bg-zinc-950 lg:dark:bg-transparent shadow-xl lg:shadow-none p-4 lg:p-0 overflow-y-auto",
              !(@selected_task_id || @editing_initiative?) && "hidden lg:block"
            ]
          }>
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
                members={@members}
                can_admin={@can_admin}
                show_member_form={@show_member_form}
              />
            </div>

            <div
              :if={@editing_initiative?}
              class="rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 p-4"
            >
              <.initiative_editor
                form={@initiative_form}
                can_edit={@can_edit}
                can_admin={@can_admin}
                initiative={@initiative}
                root_task={@selected_task}
                subtitle={@subtitle}
              />
            </div>

            <%!-- Instant pane shell (.03.07.04): shown client-side the moment a
                 task is selected, replaced by the real pane when the server
                 render lands. The client compares data-task-id below against
                 its selection to know when to hide this. --%>
            <div
              id="pane-skeleton"
              hidden
              aria-hidden="true"
              class="rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 p-4 space-y-3"
            >
              <h3 class="font-medium text-zinc-800 dark:text-zinc-100">Task details</h3>
              <div data-skeleton-title class="text-sm font-medium text-zinc-700 dark:text-zinc-200">
              </div>
              <div class="space-y-2 animate-pulse motion-reduce:animate-none">
                <div class="h-8 rounded bg-zinc-100 dark:bg-zinc-800"></div>
                <div class="h-8 rounded bg-zinc-100 dark:bg-zinc-800"></div>
                <div class="h-24 rounded bg-zinc-100 dark:bg-zinc-800"></div>
              </div>
            </div>

            <div
              :if={@selected_task_id && not @editing_initiative?}
              id="task-editor-pane"
              phx-hook="FocusField"
              data-task-id={@selected_task_id}
              class="rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 p-4"
            >
              <.task_editor
                task={@selected_task}
                comments={@comments}
                activity={@activity}
                members={@members}
                can_edit={@can_edit}
              />
            </div>
          </aside>
        </div>
      </div>

      <div id="confirm-skips" phx-hook="ConfirmSkips" hidden></div>
      <.completion_confirm pending={@pending_action} verb={pending_verb(@pending_action)} />
      <.shortcuts_overlay />
    </Layouts.app>
    """
  end

  defp show_add_for(socket, parent_id) do
    socket
    |> assign(:add_task_for, parent_id)
    |> assign(:add_task_after, parent_id)
    |> assign(:new_task_title, "")
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
  defp push_focus(socket, field) when field in ~w(priority weight assignee) do
    push_event(socket, "focus-field", %{id: "task-field-#{field}"})
  end

  defp push_focus(socket, _field), do: socket

  # Persist a single-field keyboard step (P/W/A), then patch the affected rows.
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

  defp adjust_params("weight", dir, task, _members),
    do: %{"weight" => Decimal.to_string(step_weight(task.weight, dir))}

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

  # Weight steps by whole units; no upper wrap, floored at 1 on the way down.
  defp step_weight(weight, "up"), do: Decimal.add(weight, 1)
  defp step_weight(weight, "down"), do: Decimal.max(Decimal.new(1), Decimal.sub(weight, 1))

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

  defp confirm_class(%{kind: kind}) when kind in [:cascade_complete, :cascade_incomplete],
    do: "cascade-complete"

  defp confirm_class(_), do: nil

  defp confirm_class_label("completion-flip"), do: "completion changes"
  defp confirm_class_label("cascade-sort"), do: "large branch reorgs"
  defp confirm_class_label("cascade-complete"), do: "branch completion changes"

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
  end

  defp assign_pending(socket, pending) do
    socket
    |> assign(:pending_action, pending)
    |> assign(:pending_saving_ids, pending_saving_ids(pending))
  end

  defp pending_saving_ids(%{kind: kind, task_id: id})
       when kind in [:cascade_complete, :cascade_incomplete],
       do: MapSet.new(Tasks.subtree_ids(id) ++ Tasks.ancestor_ids(id))

  defp pending_saving_ids(%{kind: kind, task_id: id}) when kind in [:cascade_sort, :delete_task],
    do: MapSet.new(Tasks.subtree_ids(id))

  defp pending_saving_ids(%{kind: :move, task_id: id, flip_ids: flip_ids}),
    do: MapSet.new([id | flip_ids])

  defp pending_saving_ids(%{kind: :create, flip_ids: flip_ids}), do: MapSet.new(flip_ids)
  defp pending_saving_ids(_), do: MapSet.new()

  attr :pending, :map, default: nil
  attr :verb, :string, default: "change"

  defp completion_confirm(assigns) do
    pending = assigns.pending

    assigns =
      assigns
      |> assign(:class, pending && confirm_class(pending))
      |> assign(
        :destructive,
        pending && Map.get(pending, :kind) in [:delete_task, :delete_initiative]
      )
      |> assign(
        :optimistic_remove,
        pending && Map.get(pending, :kind) == :delete_task && Map.get(pending, :task_id)
      )

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
          <button
            type="button"
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
            data-optimistic-remove={@optimistic_remove}
            phx-disable-with={if @destructive, do: "Deleting…", else: "Working…"}
            class={[
              "rounded px-3 py-1.5 text-sm font-medium text-white active:scale-95 transition",
              @destructive && "bg-red-600 hover:bg-red-700 active:bg-red-800",
              !@destructive && "bg-emerald-600 hover:bg-emerald-700 active:bg-emerald-800"
            ]}
          >
            {if @destructive, do: "Delete", else: "Proceed"}
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp confirm_title(%{kind: :cascade_sort}), do: "Large branch reorg"
  defp confirm_title(%{kind: :cascade_complete}), do: "Complete this branch?"
  defp confirm_title(%{kind: :cascade_incomplete}), do: "Reopen this branch?"
  defp confirm_title(%{kind: :delete_task}), do: "Delete task"
  defp confirm_title(%{kind: :delete_initiative}), do: "Delete initiative"
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

  defp confirm_body(%{kind: :delete_task, title: t}, _verb),
    do: "Delete \"#{t}\" and all its subtasks? This can't be undone."

  defp confirm_body(%{kind: :delete_initiative, title: t}, _verb),
    do: "Delete \"#{t}\" and everything in it? This can't be undone."

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
  attr :add_task_for, :any, required: true
  attr :add_task_after, :any, required: true
  attr :can_edit, :boolean, required: true
  attr :initiative_id, :integer, required: true
  attr :saving_ids, :any, required: true
  attr :inherited_sort, :string, required: true

  def task_node(assigns) do
    assigns = assign(assigns, :resolved_sort, assigns.task.sort_mode || assigns.inherited_sort)

    ~H"""
    <%!-- Selection is client-owned (UX_GUARDRAILS 6.5): the data-selected attr
         is set by the client and the highlight comes from app.css rules under
         li[data-selected], so selection never re-renders the tree. Row clicks
         are handled by the delegated listener in app.js. --%>
    <li
      id={"task-#{@task.id}"}
      data-task-id={@task.id}
      data-depth={@depth}
      class="rounded border border-zinc-400 dark:border-zinc-700 bg-white dark:bg-zinc-900 first:border-t-2 first:border-t-zinc-500 dark:first:border-t-zinc-500"
    >
      <div
        data-task-row
        class={[
          "relative flex flex-wrap items-center gap-x-2 gap-y-1 px-3 pt-2 pb-6 min-w-[240px] cursor-pointer",
          MapSet.member?(@saving_ids, @task.id) && "is-saving",
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
          class="flex-none -my-2 w-11 h-11 flex items-center justify-center gap-0.5 text-zinc-500 dark:text-zinc-600 hover:text-zinc-700 dark:hover:text-zinc-400 cursor-grab active:cursor-grabbing touch-none"
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
        <%!-- Row 1: attribute chips. Priority + weight + assignee always occupy
             a slot; defaults render as an empty dashed placeholder of the same
             size so customized values stand out and stay column-aligned. Each
             chip taps through to its Details field (item: select + focus). The
             three live in a min-w-0 overflow-hidden group so they clip together
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
          <button
            type="button"
            phx-click="select_task"
            phx-value-id={@task.id}
            phx-value-focus="priority"
            class={[
              "inline-flex items-center justify-center h-5 min-w-9 px-1.5 rounded-full text-xs flex-none cursor-pointer",
              if(@task.priority == "normal",
                do: "border border-dashed border-zinc-300 dark:border-zinc-600",
                else: "bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300"
              )
            ]}
            title={"Priority: #{@task.priority}"}
          >
            {if @task.priority != "normal", do: @task.priority}
          </button>
          <button
            type="button"
            phx-click="select_task"
            phx-value-id={@task.id}
            phx-value-focus="weight"
            class={[
              "inline-flex items-center justify-center h-5 min-w-9 px-1.5 rounded-full text-xs flex-none cursor-pointer",
              if(Decimal.equal?(@task.weight, Decimal.new(1)),
                do: "border border-dashed border-zinc-300 dark:border-zinc-600",
                else: "bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300"
              )
            ]}
            title={"Weight #{Decimal.to_string(@task.weight)}"}
          >
            {if not Decimal.equal?(@task.weight, Decimal.new(1)),
              do: "w=" <> Decimal.to_string(@task.weight)}
          </button>
          <button
            type="button"
            phx-click="select_task"
            phx-value-id={@task.id}
            phx-value-focus="assignee"
            class={[
              "inline-flex items-center justify-center h-5 min-w-9 max-w-[45%] px-1.5 rounded-full text-xs flex-none cursor-pointer",
              if(@task.assignee_id && @task.assignee,
                do: "bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300",
                else: "border border-dashed border-zinc-300 dark:border-zinc-600"
              )
            ]}
            title={
              if(@task.assignee_id && @task.assignee,
                do: "Assignee: #{@task.assignee.name}",
                else: "Unassigned"
              )
            }
          >
            <span :if={@task.assignee_id && @task.assignee} class="truncate">
              @{@task.assignee.name}
            </span>
          </button>
        </div>

        <%!-- Row 1, pinned right: the new-task button. --%>
        <div :if={@can_edit} class="relative flex-none ml-auto">
          <div class="inline-flex rounded border border-emerald-600 dark:border-emerald-500 overflow-hidden">
            <button
              type="button"
              phx-click="show_add_child"
              phx-value-parent={@task.id}
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
              phx-click={
                Phoenix.LiveView.JS.push("show_add_sibling")
                |> Phoenix.LiveView.JS.hide(to: "#add-menu-panel-#{@task.id}")
              }
              phx-value-task={@task.id}
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
            class="group flex-none inline-flex items-center gap-0.5 px-0.5 h-5 rounded text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-zinc-800"
          >
            <.icon
              name="hero-chevron-down"
              class="w-4 h-4 transition-transform motion-reduce:transition-none group-aria-[expanded=false]:-rotate-90"
            />
            <span class="hidden group-aria-[expanded=false]:inline text-xs tabular-nums">
              ({length(@task.children)})
            </span>
          </button>

          <button
            :if={@can_edit}
            type="button"
            phx-click={
              cond do
                @task.children == [] -> "toggle_complete"
                @task.status == "done" -> "cascade_incomplete"
                true -> "cascade_complete"
              end
            }
            phx-value-id={@task.id}
            data-complete-toggle
            aria-label={if @task.status == "done", do: "Reopen task", else: "Mark task completed"}
            aria-pressed={to_string(@task.status == "done")}
            class={[
              "absolute bottom-0.5 left-3 z-10 w-5 h-5 rounded border-2 flex items-center justify-center transition-colors motion-reduce:transition-none",
              @task.status == "done" && "border-emerald-500 bg-emerald-500 text-white",
              @task.status != "done" &&
                "border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-900 hover:border-emerald-500"
            ]}
          >
            <.icon :if={@task.status == "done"} name="hero-check" class="w-3 h-3" />
          </button>

          <span
            data-task-title
            class={[
              "flex-1 min-w-0",
              @depth == 0 && "text-xl font-bold",
              @depth > 0 && "text-sm font-medium",
              @task.status == "done" && "line-through text-zinc-400 dark:text-zinc-500"
            ]}
          >
            {@task.title}
          </span>
        </div>

        <%!-- Row 3: description, its own truncated line. --%>
        <span
          :if={@task.description && @task.description != ""}
          class="w-full min-w-0 text-sm text-zinc-400 dark:text-zinc-500 truncate"
        >
          {@task.description}
        </span>

        <div
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
            class={[
              "absolute inset-y-0 left-0 rounded-full",
              @task.status == "done" && "bg-emerald-500",
              @task.status != "done" && "bg-emerald-400"
            ]}
            style="width: var(--progress)"
          >
          </div>
          <span class="absolute inset-0 flex items-center justify-center text-xs font-semibold text-zinc-900 dark:text-zinc-50 progress-bar-text">
            {progress_value(@task)}%
          </span>
        </div>
      </div>

      <div :if={@add_task_for == @task.id and @add_task_after == @task.id} class="px-3 pb-3">
        <.task_form parent_id={@task.id} />
      </div>

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
            add_task_for={@add_task_for}
            add_task_after={@add_task_after}
            can_edit={@can_edit}
            initiative_id={@initiative_id}
            saving_ids={@saving_ids}
            inherited_sort={@resolved_sort}
          />
          <%= if @add_task_after == c.id and @add_task_for != c.id do %>
            <li class="rounded border border-emerald-500/40 bg-white dark:bg-zinc-900 px-3 py-2">
              <.task_form parent_id={@add_task_for} />
            </li>
          <% end %>
        <% end %>
        <%!-- Item 21: tail drop-zone — "last child of this branch." Sits at the
             child indent (inside this <ul>), so nested tails stack into a
             leftward staircase. Clipped away when the branch is collapsed. --%>
        <li :if={@can_edit} class="drop-tail" data-tail-for={@task.id} aria-hidden="true"></li>
      </ul>
    </li>
    """
  end

  attr :parent_id, :any, required: true

  def task_form(assigns) do
    ~H"""
    <form phx-submit="create_task" class="flex items-center gap-2">
      <input
        type="text"
        name="title"
        required
        phx-mounted={Phoenix.LiveView.JS.focus()}
        placeholder={if(@parent_id, do: "New subtask...", else: "New list / root task...")}
        class="flex-1 input input-bordered input-sm"
      />
      <button
        type="submit"
        phx-disable-with="Adding..."
        class="text-sm px-3 py-1.5 rounded bg-emerald-600 text-white hover:bg-emerald-700"
      >
        Add
      </button>
      <button
        type="button"
        phx-click="cancel_add"
        class="text-sm px-2 py-1.5 text-zinc-500 hover:text-zinc-800 dark:text-zinc-100 dark:hover:text-white"
      >
        Cancel
      </button>
    </form>
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
          <label class="text-xs text-zinc-500 dark:text-zinc-400">Subtitle</label>
          <input
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

      <div :if={not leaf?(@root_task)} class="text-xs text-zinc-500 dark:text-zinc-400 italic">
        Computed from children: {@root_task.computed_progress}%
      </div>

      <.sort_menu task={@root_task} can_edit={@can_edit} label="Sort lists by" />

      <div :if={@can_admin} class="border-t border-zinc-100 dark:border-zinc-700 pt-3">
        <button
          type="button"
          phx-click="request_delete_initiative"
          class="inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-semibold text-white bg-red-600 hover:bg-red-700 dark:bg-red-700 dark:hover:bg-red-600"
        >
          <.icon name="hero-trash" class="w-3.5 h-3.5" /> Delete initiative
        </button>
      </div>
    </div>
    """
  end

  attr :members, :list, required: true
  attr :can_admin, :boolean, required: true
  attr :show_member_form, :boolean, required: true

  @doc """
  The Initiative's Members list + add-member form. Shared by the aside panel
  (desktop/tablet) and the mobile header collapsible (.05.04.1).
  """
  def members_panel(assigns) do
    ~H"""
    <div class="rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 p-4">
      <div class="flex items-center justify-between mb-2">
        <h3 class="font-medium text-zinc-800 dark:text-zinc-100">Members</h3>
        <button
          :if={@can_admin}
          type="button"
          phx-click="show_member_form"
          class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-bold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
        >
          <.icon name="hero-plus" class="w-3.5 h-3.5" />
          <span>Add Member</span>
        </button>
      </div>

      <div :if={@show_member_form} class="mb-3">
        <form phx-submit="add_member" class="flex flex-col gap-2">
          <input
            type="email"
            name="email"
            placeholder="email@example.com"
            aria-label="Member email"
            required
            phx-mounted={Phoenix.LiveView.JS.focus()}
            class="w-full input input-bordered input-sm"
          />
          <select name="role" aria-label="Member role" class="w-full select select-bordered select-sm">
            <option value="editor">Editor</option>
            <option value="viewer">Viewer</option>
            <option value="owner">Owner</option>
          </select>
          <div class="flex justify-end gap-2">
            <button
              type="button"
              phx-click="cancel_member"
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

      <ul class="space-y-1 text-sm">
        <li :for={m <- @members} class="flex items-center justify-between">
          <span class="text-zinc-700 dark:text-zinc-200">{m.user.name}</span>
          <span class="text-xs text-zinc-500 dark:text-zinc-400">{m.role}</span>
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
    <div :if={not leaf?(@task)} class="space-y-1">
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
  attr :members, :list, required: true
  attr :can_edit, :boolean, required: true

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

      <form phx-change="update_task" phx-submit="update_task" class="space-y-3">
        <div>
          <label class="text-xs text-zinc-500 dark:text-zinc-400">Title</label>
          <input
            type="text"
            name="task[title]"
            value={@task.title}
            class="w-full input input-bordered input-sm"
            disabled={not @can_edit}
            phx-debounce="600"
          />
        </div>

        <div>
          <label class="text-xs text-zinc-500 dark:text-zinc-400">Description</label>
          <textarea
            name="task[description]"
            class="w-full textarea textarea-bordered textarea-sm"
            rows="3"
            disabled={not @can_edit}
            phx-debounce="600"
          >{@task.description}</textarea>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <div>
            <label class="text-xs text-zinc-500 dark:text-zinc-400">
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
            <label class="text-xs text-zinc-500 dark:text-zinc-400">
              <span class={@can_edit && "underline"}>W</span>eight
            </label>
            <input
              id="task-field-weight"
              type="number"
              name="task[weight]"
              value={Decimal.to_string(@task.weight)}
              min="0.01"
              step="0.01"
              class="w-full input input-bordered input-sm"
              disabled={not @can_edit}
              phx-debounce="500"
            />
          </div>
          <div>
            <label class="text-xs text-zinc-500 dark:text-zinc-400">
              <span class={@can_edit && "underline"}>A</span>ssignee
            </label>
            <select
              id="task-field-assignee"
              name="task[assignee_id]"
              class="w-full select select-bordered select-sm"
              disabled={not @can_edit}
            >
              <option value="">Unassigned</option>
              <option
                :for={m <- @members}
                value={m.user.id}
                selected={@task.assignee_id == m.user.id}
              >
                {m.user.name}
              </option>
            </select>
          </div>
        </div>

        <div :if={leaf?(@task)}>
          <label class="text-xs text-zinc-500 dark:text-zinc-400">
            Manual progress: {@task.manual_progress}%
          </label>
          <input
            type="range"
            name="task[manual_progress]"
            min="0"
            max="100"
            step="5"
            value={@task.manual_progress}
            class="w-full"
            disabled={not @can_edit}
            phx-debounce="200"
          />
        </div>

        <div :if={not leaf?(@task)} class="space-y-1">
          <div class="flex items-center gap-1">
            <label class="text-xs text-zinc-500 dark:text-zinc-400">
              Manual progress: {@task.manual_progress}%
            </label>
            <.info_hint id={"mp-hint-#{@task.id}"} label="Why is this disabled?">
              Progress on a task with subtasks is calculated from its subtasks instead of
              being set manually. Your manual value is kept and will start being used again
              if you remove all subtasks.
            </.info_hint>
          </div>
          <input
            type="range"
            min="0"
            max="100"
            step="5"
            value={@task.manual_progress}
            class="w-full"
            disabled
            aria-label="Manual progress (disabled — computed from subtasks)"
          />
          <p class="text-xs text-zinc-400 dark:text-zinc-500 italic">
            Ignored — this task has subtasks.
          </p>
          <div class="text-xs text-zinc-500 dark:text-zinc-400 italic">
            Computed from children: {@task.computed_progress}%
          </div>
        </div>
      </form>

      <.sort_menu task={@task} can_edit={@can_edit} label="Sort children by" />

      <div class="flex items-center justify-between gap-2 border-t border-zinc-100 dark:border-zinc-700 pt-3">
        <div class="text-xs text-zinc-500 dark:text-zinc-400">
          <%= if @task.updated_by do %>
            Last updated by
            <span class="font-medium text-zinc-700 dark:text-zinc-200">{@task.updated_by.name}</span>
            <span title={@task.updated_at}>
              ({Calendar.strftime(@task.updated_at, "%b %-d %H:%M")})
            </span>
          <% else %>
            Updated {Calendar.strftime(@task.updated_at, "%b %-d %H:%M")}
          <% end %>
        </div>
        <div class="flex items-center gap-2">
          <button
            :if={@can_edit}
            id="delete-task-btn"
            type="button"
            phx-click="request_delete_task"
            class="inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-semibold text-white bg-red-600 hover:bg-red-700 dark:bg-red-700 dark:hover:bg-red-600"
          >
            <.icon name="hero-trash" class="w-3.5 h-3.5" /> Delete
          </button>
        </div>
      </div>

      <div class="border-t border-zinc-100 dark:border-zinc-700 pt-3">
        <h4 class="text-xs font-medium text-zinc-700 dark:text-zinc-200 mb-2">Comments</h4>
        <ul class="space-y-2 mb-2">
          <li :for={c <- @comments} class="text-sm">
            <div class="text-xs text-zinc-500 dark:text-zinc-400">
              {c.user && c.user.name} · {Calendar.strftime(c.inserted_at, "%b %-d %H:%M")}
            </div>
            <div class="text-zinc-800 dark:text-zinc-100 whitespace-pre-wrap">{c.body}</div>
          </li>
        </ul>
        <form :if={@can_edit} phx-submit="add_comment" class="flex gap-2">
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

      <div class="border-t border-zinc-100 dark:border-zinc-700 pt-3">
        <h4 class="text-xs font-medium text-zinc-700 dark:text-zinc-200 mb-2">Activity</h4>
        <ul class="space-y-1 text-xs text-zinc-600 dark:text-zinc-300">
          <li :for={e <- @activity} :if={e.kind != "status_changed"}>
            <span class="text-zinc-500 dark:text-zinc-400">
              {Calendar.strftime(e.inserted_at, "%b %-d %H:%M")}
            </span>
            · <span class="font-medium">{(e.user && e.user.name) || "system"}</span>
            · {e.kind}
            <span
              :if={Map.get(e.data, "from") || Map.get(e.data, "to")}
              class="text-zinc-500 dark:text-zinc-400"
            >
              ({inspect(Map.get(e.data, "from"))} → {inspect(Map.get(e.data, "to"))})
            </span>
          </li>
        </ul>
      </div>
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

  defp leaf?(%Task{} = task) do
    case Map.get(task, :children) do
      children when is_list(children) ->
        children == []

      _ ->
        Repo.one(from t in Task, where: t.parent_id == ^task.id, select: count(t.id)) == 0
    end
  end

  # Dropdown ordering: criteria first, then Manual at the bottom. "weight"
  # is intentionally absent from the menu but still supported by the engine
  # for a possible future re-enable.
  @sort_mode_options ~w(alphabetical completion computed_progress priority created updated manual)

  defp sort_mode_options, do: @sort_mode_options

  defp sort_mode_label("manual"), do: "Manual"
  defp sort_mode_label("alphabetical"), do: "Alphabetical"
  defp sort_mode_label("completion"), do: "Completion"
  defp sort_mode_label("computed_progress"), do: "Progress"
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
  defp sort_direction_label("computed_progress", false), do: "most progress"
  defp sort_direction_label("computed_progress", true), do: "least progress"
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
  # auto-sorted parent the backend re-sorts afterward, overriding this.
  defp new_task_position(%{add_task_for: add_for, add_task_after: after_id}) do
    cond do
      is_nil(after_id) -> 0
      after_id == add_for -> 0
      true -> sibling_after_position(after_id)
    end
  end

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
