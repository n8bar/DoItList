defmodule DoItWeb.ProjectIndexLive do
  use DoItWeb, :live_view

  alias DoIt.Projects

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    projects = Projects.list_visible_projects(user)

    {:ok,
     socket
     |> assign(:page_title, "Projects")
     |> assign(:show_form, false)
     |> assign(:project_count, length(projects))
     |> assign(:form, build_empty_form())
     |> stream(:projects, projects)}
  end

  @impl true
  def handle_event("show_new", _params, socket) do
    {:noreply, assign(socket, :show_form, true) |> assign(:form, build_empty_form())}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, :show_form, false)}
  end

  def handle_event("create", %{"project" => params}, socket) do
    user = socket.assigns.current_user

    case Projects.create_project(user, params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:show_form, false)
         |> update(:project_count, &(&1 + 1))
         |> put_flash(:info, "Project created.")
         |> stream_insert(:projects, project, at: 0)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp build_empty_form do
    to_form(Projects.change_project(%DoIt.Projects.Project{}))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-semibold text-zinc-800">Your projects</h1>
          <p class="text-sm text-zinc-500">
            Each project holds a tree of tasks. Root tasks act as separate Lists.
          </p>
        </div>
        <button
          type="button"
          phx-click="show_new"
          class="px-3 py-2 rounded bg-emerald-600 text-white text-sm hover:bg-emerald-700"
        >
          New project
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
              <.button type="submit">Create project</.button>
            </div>
          </.form>
        </div>
      <% end %>

      <div id="projects" phx-update="stream" class="space-y-2">
        <div
          :for={{dom_id, project} <- @streams.projects}
          id={dom_id}
          class="rounded border border-zinc-200 bg-white p-4 hover:shadow-sm transition"
        >
          <.link navigate={~p"/projects/#{project.id}"} class="block">
            <div class="flex items-center justify-between">
              <span class="font-medium text-zinc-800">{project.name}</span>
              <span class="text-xs text-zinc-500">
                Updated {Calendar.strftime(project.updated_at, "%b %-d, %Y")}
              </span>
            </div>
            <p :if={project.description} class="mt-1 text-sm text-zinc-500 line-clamp-2">
              {project.description}
            </p>
          </.link>
        </div>
      </div>

      <p :if={@project_count == 0 and not @show_form} class="text-zinc-500 mt-4">
        No projects yet. Create one to get started.
      </p>
    </Layouts.app>
    """
  end
end
