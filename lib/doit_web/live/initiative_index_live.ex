defmodule DoItWeb.InitiativeIndexLive do
  use DoItWeb, :live_view

  import DoItWeb.AssignedComponents

  alias DoIt.Accounts
  alias DoIt.Initiatives
  alias DoItWeb.AssignedActions

  @impl true
  # Sort modes the index understands. `nil` = the server's default order
  # (owner-first, recently-updated); "manual" = the user's drag order, stored
  # on their membership rows (m02.04 §2.6).
  @sort_modes ~w(name progress created updated manual)

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    # Lazy retention sweep (m02.06 item 11): purge anything past the window on
    # the way in, so the Trash never shows stale, already-expired entries.
    Initiatives.purge_expired_trash()
    initiatives = Initiatives.list_visible_initiatives(user)

    # Global presence (m02.05 item 8): light up Collaborators avatars for
    # anyone connected to the app. The on_mount hook already tracks us here;
    # we just subscribe to learn when others come and go.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(DoIt.PubSub, DoItWeb.Presence.global_topic())
    end

    # Sort preference follows the account (m02.04 §2.6): mode + per-mode
    # reverse on the prefs record, manual order on the membership rows.
    prefs = Accounts.get_preferences(user)
    mode = normalize_mode(prefs.index_sort_mode)
    reverse_by_mode = prefs.index_sort_reverse_by_mode || %{}

    sort_state = %{
      mode: mode,
      reverse: !!Map.get(reverse_by_mode, mode || ""),
      order: stored_order(initiatives)
    }

    {:ok,
     socket
     |> assign(:page_title, "Initiatives")
     |> assign(:initiative_count, length(initiatives))
     |> assign(:initiatives, initiatives)
     |> assign(:rail_collaborators, Initiatives.list_collaborators(user))
     |> assign(:collaborator_online_ids, online_ids(socket))
     |> assign(:sort_state, sort_state)
     |> assign(:reverse_by_mode, reverse_by_mode)
     |> assign(:form, build_empty_form())
     |> assign(:trashed, Initiatives.list_trashed_initiatives(user))
     # Per-user Archived list (m02.08 worklist 4). `show_hidden` is plain assign
     # state — deliberately NON-persistent: it resets to false on every mount,
     # so hidden Initiatives stay out of sight by default each visit (unlike the
     # account-persisted sort/group-by toggles).
     |> assign(:archived, Initiatives.list_archived_initiatives(user))
     |> assign(:show_hidden, false)
     |> stream(:initiatives, sort_initiatives(initiatives, sort_state))
     # Assigned-to-Me pane (m02.08 item 1.3): the ultrawide right pane reuses
     # the A2M list. Seed its stream + toggle state here.
     |> AssignedActions.assign_initial(user)}
  end

  # The saved manual order as an id list, derived from the membership rows'
  # sort_order — feeds the same order-list sorting the drag push uses.
  defp stored_order(initiatives) do
    initiatives
    |> Enum.filter(& &1.my_sort_order)
    |> Enum.sort_by(& &1.my_sort_order)
    |> Enum.map(&to_string(&1.id))
  end

  # The New Initiative form opens/closes client-side (UX_GUARDRAILS 6.5 —
  # typing must never wait on a round trip): a <details> + KeepOpen, driven by
  # the data-details-toggle/-close handlers in app.js. Only a successful
  # create closes it from here.
  @impl true
  def handle_event("create", %{"initiative" => params}, socket) do
    user = socket.assigns.current_user

    case Initiatives.create_initiative(user, params) do
      {:ok, initiative} ->
        initiative = %{initiative | my_role: "owner"}

        {:noreply,
         socket
         |> assign(:form, build_empty_form())
         |> update(:initiative_count, &(&1 + 1))
         |> update(:initiatives, &[initiative | &1])
         |> put_flash(:info, "Initiative created.")
         |> push_event("close-details", %{id: "new-initiative"})
         |> restream_sorted()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # Sort changes persist server-side (m02.04 §2.6): mode + per-mode reverse
  # onto the prefs record, a pushed manual order onto the membership rows.
  # The control pushes no order; only a drag does — absent, the session's
  # existing order stands.
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

    {:noreply,
     socket
     |> assign(:initiatives, reindex_order(socket.assigns.initiatives, pushed_order))
     |> assign(:sort_state, sort_state)
     |> assign(:reverse_by_mode, reverse_by_mode)
     |> restream_sorted()}
  end

  # Drag-drop add from the Collaborators pane onto a rail Initiative entry
  # (m02.05 item 10). Same permission-checked context call as the show page;
  # refresh the pane so shared counts stay current.
  def handle_event("add_collaborator_to", %{"user-id" => uid, "initiative-id" => iid}, socket) do
    user = socket.assigns.current_user

    socket =
      case Initiatives.add_collaborator_as_viewer(
             user,
             String.to_integer(iid),
             String.to_integer(uid)
           ) do
        {:ok, added} ->
          put_flash(socket, :info, "Added #{added.name} as a viewer.")

        {:error, :already_member} ->
          put_flash(socket, :info, "They're already a member there.")

        {:error, :forbidden} ->
          put_flash(socket, :error, "Only that Initiative's owner can add members.")

        {:error, :failed} ->
          put_flash(socket, :error, "Couldn't add them.")
      end

    {:noreply, assign(socket, :rail_collaborators, Initiatives.list_collaborators(user))}
  end

  # Prune a past collaborator from My Collaborators (m02.05 item 12.11). The
  # index has no open Initiative, so this is the only collaborator action here.
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

  # Trash (m02.06 item 10): owner-only restore / permanent delete. Both refresh
  # the live index too — a restored Initiative reappears there.
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
  # unhide clears `hidden_at` — both on the caller's own membership row only, so
  # the Initiative reappears in *their* active index and drops from the Archived
  # list. Both refresh both lists.
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

  # Show-hidden toggle: a plain, NON-persistent assign (m02.08 item 4.3). It
  # resets to false on every mount, so hidden items stay off by default each
  # visit. Deliberately unlike the persisted Group-by/sort toggles.
  def handle_event("toggle_show_hidden", _params, socket) do
    {:noreply, assign(socket, :show_hidden, !socket.assigns.show_hidden)}
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

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :collaborator_online_ids, DoItWeb.Presence.global_online_ids())}
  end

  # Owner-gated Trash action (m02.06 item 10): apply `fun` to the named trashed
  # Initiative the current user owns, then refresh both the Trash list and the
  # live index stream (a restore reappears there).
  defp with_owned_trashed(socket, id, fun, msg) do
    user = socket.assigns.current_user
    initiative = Initiatives.get_initiative(String.to_integer(id))

    if initiative && initiative.owner_id == user.id && initiative.trashed_at do
      {:ok, _} = fun.(initiative)
      visible = Initiatives.list_visible_initiatives(user)

      socket
      |> assign(:trashed, Initiatives.list_trashed_initiatives(user))
      |> assign(:initiative_count, length(visible))
      |> stream(:initiatives, sort_initiatives(visible, socket.assigns.sort_state), reset: true)
      |> put_flash(:info, msg)
    else
      put_flash(socket, :error, "Couldn't find that Initiative in your Trash.")
    end
  end

  # Per-user restore/unhide (m02.08 worklist 4): apply `fun` to the named
  # Initiative the current user is a member of, then refresh the active index
  # stream (the restored/unhidden one reappears) and the Archived list. Scoped
  # to the caller's own membership row inside the context fun, so it never
  # touches anyone else.
  defp with_member_initiative(socket, id, fun, msg) do
    user = socket.assigns.current_user
    initiative = Initiatives.get_initiative(String.to_integer(id))

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

  # Global online set for the Collaborators avatars — empty until connected.
  defp online_ids(socket) do
    if connected?(socket), do: DoItWeb.Presence.global_online_ids(), else: MapSet.new()
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
    # Items in the saved order come first by their index; the rest keep their
    # current (server) order after, via a stable sort on a tied key. Reverse
    # flips the resulting manual sequence.
    list
    |> Enum.sort_by(fn it -> Map.get(idx, to_string(it.id), length(order)) end)
    |> maybe_reverse(reverse)
  end

  defp sort_initiatives(list, %{mode: mode, reverse: reverse}) do
    list |> Enum.sort_by(&sort_key(&1, mode), sorter(mode)) |> maybe_reverse(reverse)
  end

  defp sort_key(i, "name"), do: String.downcase(i.name || "")
  defp sort_key(i, "progress"), do: i.progress || 0
  defp sort_key(i, "created"), do: i.inserted_at
  defp sort_key(i, "updated"), do: i.updated_at

  defp sorter(mode) when mode in ~w(created updated), do: DateTime
  defp sorter(_), do: :asc

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
  # purely-hidden item only when Show-hidden is checked. An item that is both
  # archived and hidden counts as archived (shown by default).
  defp visible_archived(archived, show_hidden) do
    Enum.filter(archived, fn a -> a.archived? or (a.hidden? and show_hidden) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      width={:wide}
      rail_initiatives={@initiatives}
      rail_current_id={nil}
      rail_collaborators={@rail_collaborators}
      rail_online_ids={@collaborator_online_ids}
    >
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

      <%!-- Client-toggled (no round trip before typing); KeepOpen preserves
           the open state across patches, e.g. a validation error re-render. --%>
      <details id="new-initiative" phx-hook="KeepOpen" class="mb-6">
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
              <.button type="submit" phx-disable-with="Creating...">Create initiative</.button>
            </div>
          </.form>
        </div>
      </details>

      <%!-- Sort control (.06.2, server-persisted by m02.04 §2.6). The server
           renders the saved state (initial values survive phx-update="ignore");
           the hook owns it from there and pushes apply_sort on change. The
           per-mode reverse memory rides the data attribute. --%>
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
           right pane (a sibling of the left rail, via <:rail_right> below),
           not this column. --%>
      <div id="initiatives" phx-update="stream" class="space-y-2 3xl:hidden">
        <%!-- Sort keys ride the card as data attributes so the sort control
             reorders the list client-side at the change (UX_GUARDRAILS 6.5);
             the server re-stream confirms the same order. --%>
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
          <.link navigate={~p"/initiatives/#{initiative.id}"} draggable="false" class="block p-4">
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
                  Updated {Calendar.strftime(initiative.updated_at, "%b %-d, %Y")}
                </span>
              </div>
            </div>
            <p
              :if={subtitle_text(initiative)}
              class="mt-1 text-sm text-zinc-600 dark:text-zinc-300 line-clamp-1"
            >
              {subtitle_text(initiative)}
            </p>
            <p
              :if={initiative.description}
              class="mt-1 text-sm text-zinc-500 dark:text-zinc-400 line-clamp-2"
            >
              {initiative.description}
            </p>

            <%!-- Rolled-up progress (the root task's computed progress), with the
                 percentage centered inside the bar like the Initiative page. --%>
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

      <%!-- Trash (m02.06 item 10): the owner's soft-deleted Initiatives, with
           Restore and permanent delete. Hidden when empty. Auto-purges after
           the retention window. --%>
      <section
        :if={@trashed != []}
        id="trash"
        class="mt-10 border-t border-zinc-200 dark:border-zinc-800 pt-4"
      >
        <h2 class="flex items-center gap-1.5 text-sm font-semibold text-zinc-600 dark:text-zinc-300">
          <.icon name="hero-trash" class="w-4 h-4" /> Trash
          <span class="font-normal text-xs text-zinc-400 dark:text-zinc-500">
            · auto-deletes after {Initiatives.trash_retention_days()} days
          </span>
        </h2>
        <ul class="mt-2 space-y-1">
          <li
            :for={t <- @trashed}
            id={"trashed-#{t.id}"}
            class="flex items-center justify-between gap-2 rounded border border-zinc-200 dark:border-zinc-800 bg-zinc-50/60 dark:bg-zinc-900 px-3 py-2"
          >
            <span class="flex items-center gap-2 min-w-0 text-sm text-zinc-600 dark:text-zinc-300">
              <.botanical_icon kind={:grove} class="w-4 h-4 text-zinc-400 dark:text-zinc-500" />
              <span class="truncate">{t.name}</span>
              <span class="text-xs text-zinc-400 dark:text-zinc-500 whitespace-nowrap">
                trashed {Calendar.strftime(t.trashed_at, "%b %-d")}
              </span>
            </span>
            <span class="flex items-center gap-1 flex-none">
              <button
                type="button"
                phx-click="restore_initiative"
                phx-value-id={t.id}
                class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-semibold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
              >
                <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" /> Restore
              </button>
              <button
                type="button"
                phx-click="purge_initiative"
                phx-value-id={t.id}
                data-confirm={"Permanently delete \"#{t.name}\"? This can't be undone."}
                class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-semibold border border-red-500 text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950/40"
              >
                <.icon name="hero-x-mark" class="w-3.5 h-3.5" /> Delete
              </button>
            </span>
          </li>
        </ul>
      </section>

      <%!-- Archived (m02.08 worklist 4): the caller's per-user Archived list,
           distinct from the owner-level Trash above. Archived items show by
           default; hidden items stay behind the Show-hidden checkbox, which is
           NON-persistent (resets each visit). Restore clears archived_at,
           unhide clears hidden_at — both on the caller's own membership row. --%>
      <section
        :if={@archived != []}
        id="archived"
        class="mt-10 border-t border-zinc-200 dark:border-zinc-800 pt-4"
      >
        <div class="flex items-center justify-between gap-2">
          <h2 class="flex items-center gap-1.5 text-sm font-semibold text-zinc-600 dark:text-zinc-300">
            <.icon name="hero-archive-box" class="w-4 h-4" /> Archived
          </h2>
          <label
            :if={Enum.any?(@archived, & &1.hidden?)}
            class="flex items-center gap-1.5 text-xs text-zinc-500 dark:text-zinc-400 select-none"
          >
            <input
              type="checkbox"
              id="show-hidden"
              phx-click="toggle_show_hidden"
              checked={@show_hidden}
              class="checkbox checkbox-xs"
            /> Show hidden
          </label>
        </div>
        <ul class="mt-2 space-y-1">
          <%= for a <- visible_archived(@archived, @show_hidden) do %>
            <li
              id={"archived-#{a.id}"}
              class="flex items-center justify-between gap-2 rounded border border-zinc-200 dark:border-zinc-800 bg-zinc-50/60 dark:bg-zinc-900 px-3 py-2"
            >
              <span class="flex items-center gap-2 min-w-0 text-sm text-zinc-600 dark:text-zinc-300">
                <.botanical_icon kind={:grove} class="w-4 h-4 text-zinc-400 dark:text-zinc-500" />
                <span class="truncate">{a.name}</span>
                <span
                  :if={a.hidden? and not a.archived?}
                  class="text-[10px] uppercase tracking-wide font-semibold px-1.5 py-0.5 rounded bg-zinc-200 text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300"
                >
                  hidden
                </span>
              </span>
              <span class="flex items-center gap-1 flex-none">
                <button
                  :if={a.archived?}
                  type="button"
                  phx-click="unarchive_initiative"
                  phx-value-id={a.id}
                  class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-semibold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
                >
                  <.icon name="hero-arrow-uturn-left" class="w-3.5 h-3.5" /> Restore
                </button>
                <button
                  :if={a.hidden?}
                  type="button"
                  phx-click="unhide_initiative"
                  phx-value-id={a.id}
                  class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-semibold border border-zinc-400 dark:border-zinc-600 text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800"
                >
                  <.icon name="hero-eye" class="w-3.5 h-3.5" /> Unhide
                </button>
              </span>
            </li>
          <% end %>
        </ul>
      </section>

      <%!-- Desktop-only entry to the keyboard-shortcuts help (.07.2.1); hidden on
           mobile, which won't use shortcuts. --%>
      <div class="hidden sm:flex justify-center mt-10">
        <button
          type="button"
          phx-click={Phoenix.LiveView.JS.dispatch("doit:shortcuts-toggle", to: "#shortcuts-overlay")}
          class="inline-flex items-center gap-1 text-xs text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100"
        >
          <.icon name="hero-command-line" class="w-4 h-4" /> Keyboard shortcuts
        </button>
      </div>

      <.shortcuts_overlay />

      <%!-- Right (third) pane, a sibling of the left rail (item 6): the
           "Assigned to Me" home, filled by Arc 8 (m02.08 item 1.3) with the
           cross-Initiative list — the same reusable component as /assigned. --%>
      <:rail_right>
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
end
