defmodule DoItWeb.InitiativeShowLive do
  use DoItWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Tasks.Task

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
         |> assign(:role, role)
         |> assign(:can_edit, Initiatives.can_edit?(role))
         |> assign(:can_admin, Initiatives.can_admin?(role))
         |> assign(:members, Initiatives.list_members(initiative.id))
         |> assign(:show_member_form, false)
         |> assign(:member_email, "")
         |> assign(:selected_task_id, nil)
         |> assign(:add_task_for, nil)
         |> assign(:new_task_title, "")
         |> load_tree()}
    end
  end

  defp load_tree(socket) do
    initiative_id = socket.assigns.initiative.id
    tree = Tasks.initiative_task_tree(initiative_id)
    assign(socket, :tree, tree)
  end

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
  def handle_event("show_add_root", _params, socket) do
    {:noreply, socket |> assign(:add_task_for, :root) |> assign(:new_task_title, "")}
  end

  def handle_event("show_add_child", %{"parent" => parent_id}, socket) do
    {:noreply,
     socket
     |> assign(:add_task_for, String.to_integer(parent_id))
     |> assign(:new_task_title, "")}
  end

  def handle_event("cancel_add", _params, socket) do
    {:noreply, assign(socket, :add_task_for, nil)}
  end

  def handle_event("create_task", %{"title" => title} = params, socket) do
    user = socket.assigns.current_user
    initiative = socket.assigns.initiative

    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission to add tasks.")}
    else
      parent_id =
        case socket.assigns.add_task_for do
          :root -> nil
          id when is_integer(id) -> id
        end

      attrs = %{
        "initiative_id" => initiative.id,
        "parent_id" => parent_id,
        "title" => title,
        "weight" => Map.get(params, "weight", "1.0")
      }

      case Tasks.create_task(user, attrs) do
        {:ok, _task} ->
          {:noreply,
           socket
           |> assign(:add_task_for, nil)
           |> assign(:new_task_title, "")
           |> put_flash(:info, "Task added.")
           |> load_tree()}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't create task: #{summarize_errors(cs)}.")}
      end
    end
  end

  def handle_event("select_task", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Tasks.get_task_with_relations(id) do
      nil ->
        {:noreply, socket}

      task ->
        {:noreply,
         socket
         |> assign(:selected_task_id, id)
         |> assign(:selected_task, task)
         |> assign(:comments, Tasks.list_comments(id))
         |> assign(:activity, Tasks.list_task_activity(id))}
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
          {:noreply,
           socket
           |> put_flash(:info, "Saved.")
           |> load_tree()
           |> refresh_selected()}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't save task: #{summarize_errors(cs)}.")}
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
        {:ok, _} -> {:noreply, socket |> load_tree() |> refresh_selected()}
        {:error, cs} -> {:noreply, put_flash(socket, :error, "Invalid progress: #{summarize_errors(cs)}.")}
      end
    end
  end

  def handle_event("toggle_done", _params, socket) do
    if not socket.assigns.can_edit do
      {:noreply, socket}
    else
      task = socket.assigns.selected_task
      user = socket.assigns.current_user

      new_status = if task.status == "done", do: "open", else: "done"

      case Tasks.update_task(task, user, %{"status" => new_status}) do
        {:ok, _} -> {:noreply, socket |> load_tree() |> refresh_selected()}
        {:error, _} -> {:noreply, socket}
      end
    end
  end

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

  def handle_event("delete_task", _params, socket) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    else
      task = socket.assigns.selected_task
      user = socket.assigns.current_user

      case Tasks.delete_task(task, user) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:selected_task_id, nil)
           |> put_flash(:info, "Task deleted.")
           |> load_tree()}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't delete task: #{summarize_errors(cs)}.")}
      end
    end
  end

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
              {:noreply, put_flash(socket, :error, "Couldn't add member: #{summarize_errors(cs)}.")}
          end
      end
    end
  end

  # --- PubSub ---------------------------------------------------------------

  @impl true
  def handle_info({:task_created, _id}, socket), do: {:noreply, load_tree(socket)}
  def handle_info({:task_updated, _id}, socket), do: {:noreply, socket |> load_tree() |> refresh_selected()}
  def handle_info({:task_deleted, _id}, socket), do: {:noreply, load_tree(socket)}
  def handle_info({:comment_added, _id}, socket), do: {:noreply, refresh_selected(socket)}

  # --- Render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex items-start justify-between mb-6">
        <div>
          <.link navigate={~p"/initiatives"} class="text-sm text-zinc-500 hover:text-zinc-800">
            ← All initiatives
          </.link>
          <h1 class="text-2xl font-semibold text-zinc-800 mt-1">{@initiative.name}</h1>
          <p :if={@initiative.description} class="text-sm text-zinc-500 mt-1">{@initiative.description}</p>
        </div>
        <div class="text-right text-xs text-zinc-500">
          Your role: <span class="font-medium text-zinc-700">{@role}</span>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-[1fr_360px] gap-6">
        <div>
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-lg font-medium text-zinc-800">Lists & tasks</h2>
            <button
              :if={@can_edit}
              type="button"
              phx-click="show_add_root"
              class="text-sm px-2 py-1 rounded border border-zinc-300 hover:bg-zinc-50"
            >
              + New list
            </button>
          </div>

          <div :if={@add_task_for == :root} class="mb-3">
            <.task_form parent_id={nil} />
          </div>

          <div :if={@tree == []} class="text-zinc-500 text-sm">
            No lists yet. Create one to start tracking work.
          </div>

          <ul class="space-y-2">
            <.task_node
              :for={t <- @tree}
              task={t}
              depth={0}
              add_task_for={@add_task_for}
              can_edit={@can_edit}
              selected_id={@selected_task_id}
            />
          </ul>
        </div>

        <aside class="space-y-4">
          <div class="rounded border border-zinc-200 bg-white p-4">
            <div class="flex items-center justify-between mb-2">
              <h3 class="font-medium text-zinc-800">Members</h3>
              <button
                :if={@can_admin}
                type="button"
                phx-click="show_member_form"
                class="text-xs text-emerald-700 hover:underline"
              >
                + Add
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
                    class="text-xs text-zinc-500 hover:text-zinc-800"
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
                <span class="text-zinc-700">{m.user.name}</span>
                <span class="text-xs text-zinc-500">{m.role}</span>
              </li>
            </ul>
          </div>

          <div :if={@selected_task_id} class="rounded border border-zinc-200 bg-white p-4">
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
    </Layouts.app>
    """
  end

  # --- Components -----------------------------------------------------------

  attr :task, :map, required: true
  attr :depth, :integer, required: true
  attr :add_task_for, :any, required: true
  attr :can_edit, :boolean, required: true
  attr :selected_id, :any, required: true

  def task_node(assigns) do
    ~H"""
    <li class="rounded border border-zinc-200 bg-white">
      <div class={[
        "flex items-center gap-2 px-3 py-2",
        @selected_id == @task.id && "bg-emerald-50"
      ]}>
        <span class="text-zinc-400 text-xs w-10 tabular-nums">
          {progress_value(@task)}%
        </span>
        <div class="w-24 h-1.5 bg-zinc-100 rounded overflow-hidden">
          <div
            class={[
              "h-full rounded",
              @task.status == "done" && "bg-emerald-500",
              @task.status != "done" && "bg-emerald-400"
            ]}
            style={"width: #{progress_value(@task)}%"}
          >
          </div>
        </div>

        <button
          type="button"
          phx-click="select_task"
          phx-value-id={@task.id}
          class="flex-1 text-left text-sm hover:underline"
        >
          <span class={[
            "font-medium",
            @task.status == "done" && "line-through text-zinc-400"
          ]}>
            {@task.title}
          </span>
          <span :if={@task.assignee} class="ml-2 text-xs text-zinc-500">
            @{@task.assignee.name}
          </span>
        </button>

        <span class="text-xs text-zinc-400">
          w={Decimal.to_string(@task.weight)}
        </span>

        <button
          :if={@can_edit}
          type="button"
          phx-click="show_add_child"
          phx-value-parent={@task.id}
          class="text-xs text-zinc-500 hover:text-emerald-700"
          title="Add subtask"
        >
          +
        </button>
      </div>

      <div :if={@add_task_for == @task.id} class="px-3 pb-3">
        <.task_form parent_id={@task.id} />
      </div>

      <ul :if={@task.children != []} class="pl-6 pb-2 space-y-1">
        <.task_node
          :for={c <- @task.children}
          task={c}
          depth={@depth + 1}
          add_task_for={@add_task_for}
          can_edit={@can_edit}
          selected_id={@selected_id}
        />
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
        autofocus
        placeholder={if(@parent_id, do: "New subtask...", else: "New list / root task...")}
        class="flex-1 input input-bordered input-sm"
      />
      <input
        type="number"
        name="weight"
        value="1"
        min="0.01"
        step="0.01"
        class="w-20 input input-bordered input-sm"
        title="Weight"
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
        class="text-sm px-2 py-1.5 text-zinc-500 hover:text-zinc-800"
      >
        Cancel
      </button>
    </form>
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
        <h3 class="font-medium text-zinc-800">Task details</h3>
        <button
          type="button"
          phx-click="close_task"
          class="text-xs text-zinc-500 hover:text-zinc-800"
        >
          Close
        </button>
      </div>

      <form phx-change="update_task" phx-submit="update_task" class="space-y-3">
        <div>
          <label class="text-xs text-zinc-500">Title</label>
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
          <label class="text-xs text-zinc-500">Description</label>
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
            <label class="text-xs text-zinc-500">Status</label>
            <select
              name="task[status]"
              class="w-full select select-bordered select-sm"
              disabled={not @can_edit}
            >
              <option :for={s <- DoIt.Tasks.Task.statuses()} value={s} selected={@task.status == s}>
                {s}
              </option>
            </select>
          </div>
          <div>
            <label class="text-xs text-zinc-500">Priority</label>
            <select
              name="task[priority]"
              class="w-full select select-bordered select-sm"
              disabled={not @can_edit}
            >
              <option :for={p <- DoIt.Tasks.Task.priorities()} value={p} selected={@task.priority == p}>
                {p}
              </option>
            </select>
          </div>
          <div>
            <label class="text-xs text-zinc-500">Weight</label>
            <input
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
            <label class="text-xs text-zinc-500">Assignee</label>
            <select
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
          <label class="text-xs text-zinc-500">Manual progress: {@task.manual_progress}%</label>
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

        <div :if={not leaf?(@task)} class="text-xs text-zinc-500 italic">
          Computed from children: {@task.computed_progress}%
        </div>
      </form>

      <div class="flex items-center justify-between gap-2 border-t border-zinc-100 pt-3">
        <div class="text-xs text-zinc-500">
          <%= if @task.updated_by do %>
            Last updated by <span class="font-medium text-zinc-700">{@task.updated_by.name}</span>
            <span title={@task.updated_at}>({Calendar.strftime(@task.updated_at, "%b %-d %H:%M")})</span>
          <% else %>
            Updated {Calendar.strftime(@task.updated_at, "%b %-d %H:%M")}
          <% end %>
        </div>
        <div class="flex items-center gap-2">
          <button
            :if={@can_edit}
            type="button"
            phx-click="toggle_done"
            class={[
              "text-xs px-2 py-1 rounded",
              @task.status == "done" && "bg-zinc-100 text-zinc-700",
              @task.status != "done" && "bg-emerald-600 text-white hover:bg-emerald-700"
            ]}
          >
            {if @task.status == "done", do: "Reopen", else: "Mark done"}
          </button>
          <button
            :if={@can_edit}
            type="button"
            phx-click="delete_task"
            data-confirm="Delete this task and all its children?"
            class="text-xs text-red-600 hover:underline"
          >
            Delete
          </button>
        </div>
      </div>

      <div class="border-t border-zinc-100 pt-3">
        <h4 class="text-xs font-medium text-zinc-700 mb-2">Comments</h4>
        <ul class="space-y-2 mb-2">
          <li :for={c <- @comments} class="text-sm">
            <div class="text-xs text-zinc-500">
              {c.user && c.user.name}
              · {Calendar.strftime(c.inserted_at, "%b %-d %H:%M")}
            </div>
            <div class="text-zinc-800 whitespace-pre-wrap">{c.body}</div>
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

      <div class="border-t border-zinc-100 pt-3">
        <h4 class="text-xs font-medium text-zinc-700 mb-2">Activity</h4>
        <ul class="space-y-1 text-xs text-zinc-600">
          <li :for={e <- @activity}>
            <span class="text-zinc-500">{Calendar.strftime(e.inserted_at, "%b %-d %H:%M")}</span>
            · <span class="font-medium">{e.user && e.user.name || "system"}</span>
            · {e.kind}
            <span :if={Map.get(e.data, "from") || Map.get(e.data, "to")} class="text-zinc-500">
              ({inspect(Map.get(e.data, "from"))} → {inspect(Map.get(e.data, "to"))})
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp leaf?(%Task{} = task) do
    case Map.get(task, :children) do
      children when is_list(children) ->
        children == []

      _ ->
        Repo.one(
          from t in Task, where: t.parent_id == ^task.id, select: count(t.id)
        ) == 0
    end
  end

  defp progress_value(%{children: children, computed_progress: cp})
       when is_list(children) and children != [],
       do: cp

  defp progress_value(%{status: "done"}), do: 100
  defp progress_value(%{manual_progress: mp}), do: mp || 0

  defp summarize_errors(%Ecto.Changeset{errors: errors}) do
    Enum.map_join(errors, "; ", fn {field, {msg, _}} ->
      "#{humanize(field)} #{msg}"
    end)
  end

  defp humanize(field), do: field |> to_string() |> String.replace("_", " ")
end
