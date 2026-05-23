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
         |> assign(:editing_initiative?, false)
         |> assign(:initiative_form, to_form(Initiatives.change_initiative(initiative)))
         |> assign(:add_task_for, nil)
         |> assign(:add_task_after, nil)
         |> assign(:new_task_title, "")
         |> assign(:pending_action, nil)
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
          :root -> nil
          id when is_integer(id) -> id
        end

      attrs = %{
        "initiative_id" => initiative.id,
        "parent_id" => parent_id,
        "title" => title,
        "weight" => Map.get(params, "weight", "1.0")
      }

      case Tasks.preview_create(user, attrs) do
        {:ok, %{scenario: nil}} ->
          {:noreply, commit_create(socket, attrs)}

        {:ok, %{scenario: scenario, titles: titles}} ->
          {:noreply,
           assign(socket, :pending_action, %{
             kind: :create,
             attrs: attrs,
             scenario: scenario,
             titles: titles
           })}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't create task: #{summarize_errors(cs)}.")}
      end
    end
  end

  def handle_event("select_task", %{"id" => id}, socket) do
    id = String.to_integer(id)

    if socket.assigns.selected_task_id == id do
      {:noreply,
       socket
       |> assign(:selected_task_id, nil)
       |> assign(:selected_task, nil)
       |> assign(:comments, [])
       |> assign(:activity, [])}
    else
      case Tasks.get_task_with_relations(id) do
        nil ->
          {:noreply, socket}

        task ->
          {:noreply,
           socket
           |> assign(:editing_initiative?, false)
           |> assign(:selected_task_id, id)
           |> assign(:selected_task, task)
           |> assign(:comments, Tasks.list_comments(id))
           |> assign(:activity, Tasks.list_task_activity(id))}
      end
    end
  end

  def handle_event("edit_initiative", _params, socket) do
    initiative = socket.assigns.initiative
    form = to_form(Initiatives.change_initiative(initiative))

    {:noreply,
     socket
     |> assign(:selected_task_id, nil)
     |> assign(:editing_initiative?, true)
     |> assign(:initiative_form, form)}
  end

  def handle_event("close_initiative", _params, socket) do
    {:noreply, assign(socket, :editing_initiative?, false)}
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
          {:noreply, socket |> load_tree() |> refresh_selected()}

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
          {:noreply, socket |> load_tree() |> refresh_selected()}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't toggle: #{summarize_errors(cs)}.")}
      end
    end
  end

  def handle_event("cascade_complete", %{"id" => id}, socket) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    else
      task = Tasks.get_task!(String.to_integer(id))
      user = socket.assigns.current_user

      case Tasks.cascade_complete(task, user) do
        {:ok, _} ->
          {:noreply, socket |> load_tree() |> refresh_selected()}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't cascade: #{summarize_errors(cs)}.")}
      end
    end
  end

  def handle_event("cascade_incomplete", %{"id" => id}, socket) do
    if not socket.assigns.can_edit do
      {:noreply, put_flash(socket, :error, "You don't have permission.")}
    else
      task = Tasks.get_task!(String.to_integer(id))
      user = socket.assigns.current_user

      case Tasks.cascade_incomplete(task, user) do
        {:ok, _} ->
          {:noreply, socket |> load_tree() |> refresh_selected()}

        {:error, cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't cascade: #{summarize_errors(cs)}.")}
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

  def handle_event("move_task", %{"task_id" => task_id} = params, socket) do
    if not socket.assigns.can_edit do
      {:reply, %{ok: false, error: "forbidden"},
       put_flash(socket, :error, "You don't have permission to move tasks.")}
    else
      task = Tasks.get_task!(task_id)
      user = socket.assigns.current_user

      attrs = %{
        "parent_id" => Map.get(params, "parent_id"),
        "position" => Map.get(params, "position")
      }

      case Tasks.preview_move(task, user, attrs) do
        {:ok, %{scenario: nil}} ->
          case commit_move(socket, task, attrs) do
            {:ok, socket} ->
              {:reply, %{ok: true}, socket}

            {:error, reason, socket} ->
              {:reply, %{ok: false, error: format_move_error(reason)}, socket}
          end

        {:ok, %{scenario: scenario, titles: titles}} ->
          {:reply, %{ok: true},
           assign(socket, :pending_action, %{
             kind: :move,
             task_id: task.id,
             attrs: attrs,
             scenario: scenario,
             titles: titles
           })}

        {:error, reason} ->
          {:reply, %{ok: false, error: format_move_error(reason)},
           put_flash(socket, :error, "Couldn't move task: #{format_move_error(reason)}.")}
      end
    end
  end

  def handle_event("confirm_pending", _params, socket) do
    case socket.assigns.pending_action do
      %{kind: :move, task_id: task_id, attrs: attrs} ->
        task = Tasks.get_task!(task_id)

        case commit_move(socket, task, attrs) do
          {:ok, socket} -> {:noreply, socket}
          {:error, _reason, socket} -> {:noreply, socket}
        end

      %{kind: :create, attrs: attrs} ->
        {:noreply, commit_create(socket, attrs)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_pending", _params, socket) do
    {:noreply, assign(socket, :pending_action, nil)}
  end

  # Keyboard alternative for task reorganization (M02 Arc 3 item 6).
  # When a task is selected (Details panel open) and the user has edit rights,
  # Alt+↑/↓ reorder among siblings; Alt+←/→ dedent / indent.
  def handle_event("kbd_move", %{"key" => key, "altKey" => true}, socket)
      when key in ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"] do
    cond do
      is_nil(socket.assigns.selected_task_id) ->
        {:noreply, socket}

      not socket.assigns.can_edit ->
        {:noreply, socket}

      true ->
        do_kbd_move(key, socket)
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
        |> assign(:pending_action, nil)
        |> put_flash(:info, "Task added.")
        |> load_tree()

      {:error, cs} ->
        socket
        |> assign(:pending_action, nil)
        |> put_flash(:error, "Couldn't create task: #{summarize_errors(cs)}.")
    end
  end

  defp commit_move(socket, task, attrs) do
    user = socket.assigns.current_user

    case Tasks.move_task(task, user, attrs) do
      {:ok, _moved} ->
        {:ok,
         socket
         |> assign(:pending_action, nil)
         |> load_tree()
         |> refresh_selected()}

      {:error, reason} ->
        {:error, reason,
         socket
         |> assign(:pending_action, nil)
         |> put_flash(:error, "Couldn't move task: #{format_move_error(reason)}.")}
    end
  end

  # --- PubSub ---------------------------------------------------------------

  @impl true
  def handle_info({:task_created, _id}, socket), do: {:noreply, load_tree(socket)}

  def handle_info({:task_updated, _id}, socket),
    do: {:noreply, socket |> load_tree() |> refresh_selected()}

  def handle_info({:task_deleted, _id}, socket), do: {:noreply, load_tree(socket)}
  def handle_info({:comment_added, _id}, socket), do: {:noreply, refresh_selected(socket)}

  def handle_info({:task_moved, _id}, socket),
    do: {:noreply, socket |> load_tree() |> refresh_selected()}

  # --- Render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div
        id="initiative-show-root"
        phx-hook=".KbdAltArrowGuard"
        phx-window-keydown="kbd_move"
        phx-throttle="100"
      >
        <script :type={Phoenix.LiveView.ColocatedHook} name=".KbdAltArrowGuard">
          export default {
            mounted() {
              this._handler = (e) => {
                if (e.altKey && (e.key === "ArrowUp" || e.key === "ArrowDown" ||
                                 e.key === "ArrowLeft" || e.key === "ArrowRight")) {
                  e.preventDefault();
                }
              };
              window.addEventListener("keydown", this._handler);
            },
            destroyed() {
              window.removeEventListener("keydown", this._handler);
            }
          }
        </script>
        <div class="relative flex items-start justify-between mb-6 pb-6">
          <div>
            <.link
              navigate={~p"/initiatives"}
              class="text-sm text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100"
            >
              ← All initiatives
            </.link>
            <div class="flex items-start gap-2 mt-1">
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
                class="mt-1 inline-flex items-center gap-1 px-2 py-0.5 rounded text-sm font-bold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
                aria-label="New list"
                title="New list"
              >
                <.icon name="hero-plus" class="w-4 h-4" />
                <span>New List</span>
              </button>
            </div>
            <p :if={@initiative.description} class="text-sm text-zinc-500 dark:text-zinc-400 mt-1">
              {@initiative.description}
            </p>
          </div>
          <div class="text-right text-xs text-zinc-500 dark:text-zinc-400">
            Your role: <span class="font-medium text-zinc-700 dark:text-zinc-200">{@role}</span>
          </div>

          <div
            class="absolute bottom-0 left-0 right-0 h-4 bg-zinc-100 dark:bg-zinc-800 rounded-full overflow-hidden"
            role="progressbar"
            aria-valuenow={initiative_progress(@tree)}
            aria-valuemin="0"
            aria-valuemax="100"
            aria-label={"Initiative progress: #{initiative_progress(@tree)}%"}
            style={"--progress: #{initiative_progress(@tree)}%"}
          >
            <div
              class="absolute inset-y-0 left-0 bg-emerald-400 rounded-full"
              style="width: var(--progress)"
            >
            </div>
            <span class="absolute inset-0 flex items-center justify-center text-xs font-semibold text-zinc-900 dark:text-zinc-50 progress-bar-text">
              {initiative_progress(@tree)}%
            </span>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-[1fr_360px] gap-6">
          <div class="min-w-0">
            <div :if={@add_task_for == :root} class="mb-3">
              <.task_form parent_id={nil} />
            </div>

            <div :if={@tree == []} class="text-zinc-500 dark:text-zinc-400 text-sm">
              No lists yet. Create one to start tracking work.
            </div>

            <ul class="space-y-2">
              <%= for t <- @tree do %>
                <.task_node
                  task={t}
                  depth={0}
                  add_task_for={@add_task_for}
                  add_task_after={@add_task_after}
                  can_edit={@can_edit}
                  selected_id={@selected_task_id}
                  initiative_id={@initiative.id}
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

          <aside class={[
            "space-y-4",
            (@selected_task_id || @editing_initiative?) &&
              "fixed lg:static inset-y-0 right-0 z-30 w-full sm:w-96 lg:w-auto bg-zinc-50 lg:bg-transparent dark:bg-zinc-950 lg:dark:bg-transparent shadow-xl lg:shadow-none p-4 lg:p-0 overflow-y-auto",
            !(@selected_task_id || @editing_initiative?) && "hidden lg:block"
          ]}>
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
                      phx-click="cancel_member"
                      class="text-xs text-zinc-500 hover:text-zinc-800 dark:text-zinc-100"
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

            <div
              :if={@editing_initiative?}
              class="rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 p-4"
            >
              <.initiative_editor form={@initiative_form} can_edit={@can_edit} />
            </div>

            <div
              :if={@selected_task_id && not @editing_initiative?}
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

      <.completion_confirm pending={@pending_action} verb={pending_verb(@pending_action)} />
    </Layouts.app>
    """
  end

  defp pending_verb(%{kind: :create}), do: "new task"
  defp pending_verb(%{kind: :move}), do: "move"
  defp pending_verb(_), do: "change"

  attr :pending, :map, default: nil
  attr :verb, :string, default: "change"

  defp completion_confirm(assigns) do
    ~H"""
    <div
      :if={@pending}
      id="completion-confirm"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-4"
      phx-click="cancel_pending"
    >
      <div
        class="w-full max-w-md rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900"
        phx-click-away="cancel_pending"
        onclick="event.stopPropagation()"
      >
        <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-100">
          Confirm completion change
        </h2>
        <p class="mt-2 text-sm text-zinc-700 dark:text-zinc-300">
          {completion_confirm_message(@pending.scenario, @verb)}
        </p>
        <ul
          :if={Map.get(@pending, :titles, []) != []}
          class="mt-3 max-h-40 overflow-y-auto rounded border border-zinc-200 bg-zinc-50 p-2 text-sm text-zinc-700 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-200"
        >
          <li :for={title <- @pending.titles} class="truncate">{title}</li>
        </ul>
        <div class="mt-5 flex justify-end gap-2">
          <button
            type="button"
            phx-click="cancel_pending"
            class="rounded border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-100 dark:border-zinc-600 dark:text-zinc-200 dark:hover:bg-zinc-800"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="confirm_pending"
            class="rounded bg-emerald-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-700"
          >
            Proceed
          </button>
        </div>
      </div>
    </div>
    """
  end

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
  attr :selected_id, :any, required: true
  attr :initiative_id, :integer, required: true

  def task_node(assigns) do
    ~H"""
    <li
      data-task-id={@task.id}
      data-depth={@depth}
      class="rounded border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 first:border-t-2 first:border-t-zinc-400 dark:first:border-t-zinc-500"
    >
      <div
        class={[
          "relative flex items-center gap-2 px-3 pt-2 pb-6 min-w-0 cursor-pointer",
          if(@selected_id == @task.id,
            do: "bg-emerald-50 dark:bg-emerald-950 hover:bg-emerald-100 dark:hover:bg-emerald-900",
            else: "hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
          )
        ]}
        phx-click="select_task"
        phx-value-id={@task.id}
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
          class="flex-none -my-2 w-11 h-11 flex items-center justify-center text-zinc-400 dark:text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 cursor-grab active:cursor-grabbing touch-none"
        >
          <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
        </span>
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
        <div :if={@task.children == []} class="flex-none w-5 h-5"></div>

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
          data-confirm={
            cond do
              @task.children == [] -> nil
              @task.status == "done" -> "Uncheck this task and all its children?"
              true -> "Mark this task and all its children completed?"
            end
          }
          aria-label={if @task.status == "done", do: "Reopen task", else: "Mark task completed"}
          aria-pressed={@task.status == "done"}
          class={[
            "flex-none w-5 h-5 rounded border-2 flex items-center justify-center transition-colors motion-reduce:transition-none",
            @task.status == "done" && "border-emerald-500 bg-emerald-500 text-white",
            @task.status != "done" && "border-zinc-300 dark:border-zinc-600 hover:border-emerald-500"
          ]}
        >
          <.icon :if={@task.status == "done"} name="hero-check" class="w-3 h-3" />
        </button>

        <%!-- Botanical icon: green tree on Lists, brown branch on parent tasks, green leaf on leaf tasks. --%>
        <span
          :if={@depth == 0}
          class="flex-none text-emerald-600 dark:text-emerald-400"
          aria-hidden="true"
        >
          <.botanical_icon kind={:tree} />
        </span>
        <span
          :if={@depth > 0 and @task.children != []}
          class="flex-none text-amber-700 dark:text-amber-600"
          aria-hidden="true"
        >
          <.botanical_icon kind={:branch} />
        </span>
        <span
          :if={@depth > 0 and @task.children == []}
          class="flex-none text-emerald-600 dark:text-emerald-400"
          aria-hidden="true"
        >
          <.botanical_icon kind={:leaf} />
        </span>

        <span class="flex-1 min-w-0 flex items-baseline gap-2">
          <span class={[
            "flex-none",
            @depth == 0 && "text-xl font-bold",
            @depth > 0 && "text-sm font-medium",
            @task.status == "done" && "line-through text-zinc-400 dark:text-zinc-500"
          ]}>
            {@task.title}
          </span>

          <%!-- Custom-attribute chips: weight (≠ 1), priority (≠ normal), assignee (set) --%>
          <span
            :if={not Decimal.equal?(@task.weight, Decimal.new(1))}
            class="text-xs px-1.5 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300 flex-none"
            title={"Weight #{Decimal.to_string(@task.weight)}"}
          >
            w={Decimal.to_string(@task.weight)}
          </span>
          <span
            :if={@task.priority != "normal"}
            class="text-xs px-1.5 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300 flex-none"
            title={"Priority: #{@task.priority}"}
          >
            {@task.priority}
          </span>
          <span
            :if={@task.assignee_id && @task.assignee}
            class="text-xs px-1.5 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300 flex-none"
            title="Assignee"
          >
            @{@task.assignee.name}
          </span>

          <%!-- Em-dash + description: hidden on very narrow; ellipsis on overflow --%>
          <span
            :if={@task.description && @task.description != ""}
            class="hidden sm:inline-block flex-1 min-w-0 text-sm text-zinc-400 dark:text-zinc-500 truncate"
          >
            {" — " <> @task.description}
          </span>
        </span>

        <div :if={@can_edit} class="flex-none relative">
          <div class="inline-flex rounded border border-emerald-600 dark:border-emerald-500 overflow-hidden">
            <button
              type="button"
              phx-click="show_add_child"
              phx-value-parent={@task.id}
              class="inline-flex items-center gap-1 min-w-11 px-2 py-0.5 text-xs font-bold text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
              aria-label={if(@depth == 0, do: "New task", else: "New subtask")}
              title={if(@depth == 0, do: "New task", else: "New subtask")}
            >
              <.icon name="hero-plus" class="w-4 h-4" />
              <span class="hidden sm:inline">
                {if(@depth == 0, do: "New Task", else: "New Subtask")}
              </span>
            </button>
            <button
              type="button"
              id={"add-menu-#{@task.id}"}
              phx-click={Phoenix.LiveView.JS.toggle(to: "#add-menu-panel-#{@task.id}")}
              aria-label="More add options"
              title="More add options"
              class="inline-flex items-center px-1 text-emerald-700 dark:text-emerald-400 border-l border-emerald-600 dark:border-emerald-500 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
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
              + Add Sibling
            </button>
          </div>
        </div>

        <div
          class="absolute bottom-1 left-2 right-2 h-4 bg-zinc-100 dark:bg-zinc-800 rounded-full overflow-hidden"
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
        class="pl-6 pb-2 space-y-1"
      >
        <%= for c <- @task.children do %>
          <.task_node
            task={c}
            depth={@depth + 1}
            add_task_for={@add_task_for}
            add_task_after={@add_task_after}
            can_edit={@can_edit}
            selected_id={@selected_id}
            initiative_id={@initiative_id}
          />
          <%= if @add_task_after == c.id and @add_task_for != c.id do %>
            <li class="rounded border border-emerald-500/40 bg-white dark:bg-zinc-900 px-3 py-2">
              <.task_form parent_id={@add_task_for} />
            </li>
          <% end %>
        <% end %>
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
        class="text-sm px-2 py-1.5 text-zinc-500 hover:text-zinc-800 dark:text-zinc-100"
      >
        Cancel
      </button>
    </form>
    """
  end

  attr :form, :map, required: true
  attr :can_edit, :boolean, required: true

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
          class="inline-flex items-center justify-center w-7 h-7 rounded bg-red-500/30 hover:bg-red-500/50 text-white font-bold"
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
        <.input
          field={@form[:description]}
          type="textarea"
          label="Description"
          disabled={not @can_edit}
          phx-debounce="600"
        />
      </.form>
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
          class="inline-flex items-center justify-center w-7 h-7 rounded bg-red-500/30 hover:bg-red-500/50 text-white font-bold"
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
            <label class="text-xs text-zinc-500 dark:text-zinc-400">Priority</label>
            <select
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
            <label class="text-xs text-zinc-500 dark:text-zinc-400">Weight</label>
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
            <label class="text-xs text-zinc-500 dark:text-zinc-400">Assignee</label>
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

        <div :if={not leaf?(@task)} class="text-xs text-zinc-500 dark:text-zinc-400 italic">
          Computed from children: {@task.computed_progress}%
        </div>
      </form>

      <div :if={not leaf?(@task)} class="space-y-1">
        <label
          for={"sort-mode-#{@task.id}"}
          class="text-xs text-zinc-500 dark:text-zinc-400"
        >
          Sort children by
        </label>
        <form
          id={"sort-form-#{@task.id}"}
          phx-hook="SortRecall"
          data-task-id={@task.id}
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
            <option
              :for={m <- sort_mode_options()}
              value={m}
              selected={@task.sort_mode == m}
            >
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
      </div>

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
            type="button"
            phx-click="delete_task"
            data-confirm="Delete this task and all its children?"
            class="text-xs text-red-600 hover:underline"
          >
            Delete
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

  defp sort_mode_inherit_label(%Task{sort_mode: nil} = task) do
    case Tasks.resolve_sort(task) do
      {"manual", _} -> "Inherit"
      {mode, _} -> "Inherit (#{sort_mode_label(mode)})"
    end
  end

  defp sort_mode_inherit_label(_), do: "Inherit"

  defp reverse_disabled?(%Task{sort_mode: mode}), do: mode in [nil, "manual"]

  defp progress_value(%{children: children, computed_progress: cp})
       when is_list(children) and children != [],
       do: cp

  defp progress_value(%{status: "done"}), do: 100
  defp progress_value(%{manual_progress: mp}), do: mp || 0

  # Equal-weighted average of root-task progress (custom root weights are
  # ignored at the Initiative level — the Initiative header is informational,
  # not itself a task).
  defp initiative_progress([]), do: 0

  defp initiative_progress(roots) do
    total = Enum.reduce(roots, 0, fn t, acc -> acc + progress_value(t) end)
    div(total, length(roots))
  end

  # --- Keyboard move helpers ------------------------------------------------

  # Compute and execute the right move_task call for the selected task given
  # an Alt+Arrow key. Returns {:noreply, socket}.
  defp do_kbd_move(key, socket) do
    user = socket.assigns.current_user
    task = Tasks.get_task!(socket.assigns.selected_task_id)
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
        case Tasks.move_task(task, user, attrs) do
          {:ok, _moved} ->
            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Couldn't move task: #{format_move_error(reason)}.")}
        end
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
    %{"parent_id" => task.parent_id, "position" => idx - 1}
  end

  # Alt+↓: swap with next sibling. No-op at last index.
  defp kbd_move_down(siblings, idx, %Task{} = task) do
    if idx >= length(siblings) - 1 do
      :noop
    else
      %{"parent_id" => task.parent_id, "position" => idx + 1}
    end
  end

  # Alt+→: become last child of previous sibling. No-op if no previous sibling.
  defp kbd_indent(_siblings, 0, _task), do: :noop

  defp kbd_indent(siblings, idx, _task) do
    new_parent_id = Enum.at(siblings, idx - 1)
    %{"parent_id" => new_parent_id, "position" => nil}
  end

  # Alt+←: become a sibling of the parent, inserted right after the parent
  # within the grandparent's children. No-op for root tasks.
  defp kbd_dedent(%Task{parent_id: nil}), do: :noop

  defp kbd_dedent(%Task{parent_id: parent_id} = task) do
    parent = Tasks.get_task!(parent_id)
    grandparent_id = parent.parent_id

    grand_sibling_ids =
      sibling_ids(%Task{parent_id: grandparent_id, initiative_id: task.initiative_id})

    parent_idx = Enum.find_index(grand_sibling_ids, &(&1 == parent.id)) || 0

    # Inserting "right after the parent" — among grand-siblings excluding the
    # moved task itself, that's parent_idx + 1.
    %{"parent_id" => grandparent_id, "position" => parent_idx + 1}
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
