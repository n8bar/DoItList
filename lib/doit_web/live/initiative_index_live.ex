defmodule DoItWeb.InitiativeIndexLive do
  use DoItWeb, :live_view

  alias DoIt.Initiatives

  @impl true
  # Sort modes the index understands. `nil` = the server's default order
  # (owner-first, recently-updated); "manual" = the user's localStorage drag order.
  @sort_modes ~w(name progress created updated manual)

  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    initiatives = Initiatives.list_visible_initiatives(user)

    {:ok,
     socket
     |> assign(:page_title, "Initiatives")
     |> assign(:show_form, false)
     |> assign(:initiative_count, length(initiatives))
     |> assign(:initiatives, initiatives)
     |> assign(:sort_state, %{mode: nil, reverse: false, order: []})
     |> assign(:form, build_empty_form())
     |> stream(:initiatives, initiatives)}
  end

  @impl true
  def handle_event("show_new", _params, socket) do
    {:noreply, assign(socket, :show_form, true) |> assign(:form, build_empty_form())}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, :show_form, false)}
  end

  def handle_event("create", %{"initiative" => params}, socket) do
    user = socket.assigns.current_user

    case Initiatives.create_initiative(user, params) do
      {:ok, initiative} ->
        initiative = %{initiative | my_role: "owner"}

        {:noreply,
         socket
         |> assign(:show_form, false)
         |> update(:initiative_count, &(&1 + 1))
         |> update(:initiatives, &[initiative | &1])
         |> put_flash(:info, "Initiative created.")
         |> restream_sorted()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # Sort preference (and manual drag order) live in the browser's localStorage;
  # a hook pushes them here on mount and on change, and we re-stream sorted.
  # Keeps the preference per-user without a schema (see worklist 6 / BACKLOG).
  def handle_event("apply_sort", params, socket) do
    sort_state = %{
      mode: normalize_mode(params["mode"]),
      reverse: params["reverse"] in [true, "true"],
      order: params["order"] || []
    }

    {:noreply, socket |> assign(:sort_state, sort_state) |> restream_sorted()}
  end

  defp restream_sorted(socket) do
    sorted = sort_initiatives(socket.assigns.initiatives, socket.assigns.sort_state)
    stream(socket, :initiatives, sorted, reset: true)
  end

  defp normalize_mode(mode) when mode in @sort_modes, do: mode
  defp normalize_mode(_), do: nil

  defp sort_initiatives(list, %{mode: nil}), do: list

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

  defp role_badge_class("owner"),
    do: "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-300"

  defp role_badge_class("editor"),
    do: "bg-blue-100 text-blue-800 dark:bg-blue-900/40 dark:text-blue-300"

  defp role_badge_class("viewer"),
    do: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

  defp role_badge_class(_), do: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-semibold text-zinc-800 dark:text-zinc-100">Your initiatives</h1>
          <p class="text-sm text-zinc-500 dark:text-zinc-400">
            An Initiative holds multiple Lists. Each List is a tree of nested tasks.
          </p>
        </div>
        <button
          type="button"
          phx-click="show_new"
          class="px-3 py-2 rounded bg-emerald-600 text-white text-sm hover:bg-emerald-700"
        >
          New initiative
        </button>
      </div>

      <%= if @show_form do %>
        <div class="rounded border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4 mb-6">
          <.form :let={f} for={@form} phx-submit="create" class="space-y-3">
            <.input field={f[:name]} type="text" label="Name" required />
            <.input field={f[:description]} type="textarea" label="Description (optional)" />
            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="cancel_new"
                class="px-3 py-1.5 rounded border border-zinc-300 dark:border-zinc-700 text-sm text-zinc-700 dark:text-zinc-200 hover:bg-zinc-50 dark:hover:bg-zinc-800"
              >
                Cancel
              </button>
              <.button type="submit" phx-disable-with="Creating...">Create initiative</.button>
            </div>
          </.form>
        </div>
      <% end %>

      <%!-- Sort control. The hook (.06.2) seeds it from localStorage, pushes
           apply_sort, and persists changes — per-user, per-browser. --%>
      <form
        :if={@initiative_count > 0}
        id="initiative-sort"
        phx-hook="InitiativeSort"
        phx-update="ignore"
        class="flex items-center justify-end gap-2 mb-3 text-zinc-600 dark:text-zinc-300"
      >
        <label for="initiative-sort-mode" class="text-xs">Sort</label>
        <select id="initiative-sort-mode" name="mode" class="select select-bordered select-sm">
          <option value="">Recent</option>
          <option value="manual">Manual</option>
          <option value="name">Name</option>
          <option value="progress">Progress</option>
          <option value="created">Created</option>
          <option value="updated">Updated</option>
        </select>
        <label class="flex items-center gap-1 text-xs select-none">
          <input type="checkbox" name="reverse" value="true" class="checkbox checkbox-xs" /> Reverse
        </label>
      </form>

      <div id="initiatives" phx-update="stream" class="space-y-2">
        <div
          :for={{dom_id, initiative} <- @streams.initiatives}
          id={dom_id}
          class="rounded border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 hover:shadow-sm transition motion-reduce:transition-none"
        >
          <.link navigate={~p"/initiatives/#{initiative.id}"} class="block p-4">
            <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-1 sm:gap-3">
              <span class="font-medium text-zinc-800 dark:text-zinc-100 inline-flex items-center gap-2 min-w-0">
                <span class="text-emerald-600 dark:text-emerald-400 flex-none" aria-hidden="true">
                  <.botanical_icon kind={:grove} class="w-5 h-5" />
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
          </.link>
        </div>
      </div>

      <p :if={@initiative_count == 0 and not @show_form} class="text-zinc-500 dark:text-zinc-400 mt-4">
        No initiatives yet. Create one to get started.
      </p>
    </Layouts.app>
    """
  end
end
