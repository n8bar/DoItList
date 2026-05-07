defmodule DoItWeb.OrchardIndexLive do
  use DoItWeb, :live_view

  alias DoIt.Orchards

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    orchards = Orchards.list_visible_orchards(user)

    {:ok,
     socket
     |> assign(:page_title, "Orchards")
     |> assign(:show_form, false)
     |> assign(:orchard_count, length(orchards))
     |> assign(:form, build_empty_form())
     |> stream(:orchards, orchards)}
  end

  @impl true
  def handle_event("show_new", _params, socket) do
    {:noreply, assign(socket, :show_form, true) |> assign(:form, build_empty_form())}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, :show_form, false)}
  end

  def handle_event("create", %{"orchard" => params}, socket) do
    user = socket.assigns.current_user

    case Orchards.create_orchard(user, params) do
      {:ok, orchard} ->
        {:noreply,
         socket
         |> assign(:show_form, false)
         |> update(:orchard_count, &(&1 + 1))
         |> put_flash(:info, "Orchard created.")
         |> stream_insert(:orchards, orchard, at: 0)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp build_empty_form do
    to_form(Orchards.change_orchard(%DoIt.Orchards.Orchard{}))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-semibold text-zinc-800">Your orchards</h1>
          <p class="text-sm text-zinc-500">
            Each Orchard holds a tree of tasks. Root tasks act as separate Lists.
          </p>
        </div>
        <button
          type="button"
          phx-click="show_new"
          class="px-3 py-2 rounded bg-emerald-600 text-white text-sm hover:bg-emerald-700"
        >
          New orchard
        </button>
      </div>

      <%= if @show_form do %>
        <div class="rounded border border-zinc-200 bg-white p-4 mb-6">
          <.form :let={f} for={@form} phx-submit="create" class="space-y-3">
            <.input field={f[:name]} type="text" label="Name" required />
            <.input field={f[:description]} type="textarea" label="Description (optional)" />
            <div class="flex justify-end gap-2">
              <button
                type="button"
                phx-click="cancel_new"
                class="px-3 py-1.5 rounded border border-zinc-300 text-sm text-zinc-700 hover:bg-zinc-50"
              >
                Cancel
              </button>
              <.button type="submit">Create orchard</.button>
            </div>
          </.form>
        </div>
      <% end %>

      <div id="orchards" phx-update="stream" class="space-y-2">
        <div
          :for={{dom_id, orchard} <- @streams.orchards}
          id={dom_id}
          class="rounded border border-zinc-200 bg-white p-4 hover:shadow-sm transition"
        >
          <.link navigate={~p"/orchards/#{orchard.id}"} class="block">
            <div class="flex items-center justify-between">
              <span class="font-medium text-zinc-800">{orchard.name}</span>
              <span class="text-xs text-zinc-500">
                Updated {Calendar.strftime(orchard.updated_at, "%b %-d, %Y")}
              </span>
            </div>
            <p :if={orchard.description} class="mt-1 text-sm text-zinc-500 line-clamp-2">
              {orchard.description}
            </p>
          </.link>
        </div>
      </div>

      <p :if={@orchard_count == 0 and not @show_form} class="text-zinc-500 mt-4">
        No orchards yet. Create one to get started.
      </p>
    </Layouts.app>
    """
  end
end
