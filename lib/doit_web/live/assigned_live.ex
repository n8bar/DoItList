defmodule DoItWeb.AssignedLive do
  @moduledoc """
  Assigned to Me (m02.08 worklist 1) — a cross-Initiative, flat view of every
  task the user is the primary or a co-assignee on, across all the Initiatives
  they currently belong to. Rows deep-link into the owning Initiative with the
  task selected (item 1.7).
  """
  use DoItWeb, :live_view

  import DoItWeb.AssignedComponents

  alias DoIt.Initiatives
  alias DoItWeb.AssignedActions
  alias DoItWeb.CollaboratorAdd

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Assigned to Me")
     |> assign(:rail_initiatives, Initiatives.list_visible_initiatives(user))
     |> assign(:rail_collaborators, Initiatives.list_collaborators(user))
     |> AssignedActions.assign_initial(user)}
  end

  @impl true
  def handle_event("assigned_toggle_completed", _params, socket) do
    {:noreply, AssignedActions.toggle_completed(socket, socket.assigns.current_user)}
  end

  def handle_event("assigned_toggle_archived_hidden", _params, socket) do
    {:noreply, AssignedActions.toggle_archived_hidden(socket, socket.assigns.current_user)}
  end

  def handle_event("assigned_toggle_group_by", _params, socket) do
    {:noreply, AssignedActions.toggle_group_by(socket, socket.assigns.current_user)}
  end

  # The rail renders here too, so a collaborator drag-drop lands on this view
  # (m03.04 2.21) — same shared core and trust gating as the workspace's rail
  # path. Malformed ids no-op with ok:false so the optimistic chip is pulled
  # (MUST NOT LIE) rather than crashing.
  def handle_event(
        "add_collaborator_to",
        %{"user-id" => uid, "initiative-id" => iid} = params,
        socket
      ) do
    user = socket.assigns.current_user

    case {CollaboratorAdd.parse_id(iid), CollaboratorAdd.parse_id(uid)} do
      {nil, _} ->
        {:reply, %{ok: false}, socket}

      {_, nil} ->
        {:reply, %{ok: false}, socket}

      {iid, uid} ->
        {ok?, _ack?, socket} =
          CollaboratorAdd.add_as_viewer(socket, user, iid, uid, params["trust_confirmed"] == "true")

        # Refresh both rail panes so the reply render carries the real avatar
        # (the optimistic chip reconciles against it) and a committed ack flips
        # the entry's data-trust-confirm in place.
        socket =
          socket
          |> assign(:rail_collaborators, Initiatives.list_collaborators(user))
          |> assign(:rail_initiatives, Initiatives.list_visible_initiatives(user))

        {:reply, %{ok: ok?}, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      width={:wide}
      rail_initiatives={@rail_initiatives}
      rail_current_id={nil}
      rail_collaborators={@rail_collaborators}
    >
      <%!-- §6.8 dead-window flush (WL4.2.2): EVERY LiveView in the authenticated
           live_session must register a livePush backend, so the global
           capture-phase interceptor (app.js) goes inert the moment THIS page is
           live, this page flushes its OWN dead-window queue on mount, and nothing
           survives a live <.link navigate> into another view (Defect #1).
           Mirrors .IndexLive / .TaskKeys. --%>
      <div id="assigned-root" phx-hook=".AssignedLive">
        <script :type={Phoenix.LiveView.ColocatedHook} name=".AssignedLive">
          export default {
            mounted() {
              this._livePush = (ev, payload, cb) => this.pushEvent(ev, payload, cb);
              window.DoitRegisterLivePush(this._livePush);
              // %-reference READ path (m03.04 item 3.10): document, not this.el —
              // the assigned list is a SIBLING of this shell div.
              window.DoitRenderRefs(document);
            },
            updated() {
              window.DoitRenderRefs(document);
            },
            destroyed() {
              window.DoitUnregisterLivePush(this._livePush);
            },
          }
        </script>
      </div>

      <%!-- Rail drag-add trust confirm (2.21): rendered whenever any rail entry
           could open it at drop; the JS fail-safes to Cancel when absent. --%>
      <Layouts.agent_trust_confirm :if={Enum.any?(@rail_initiatives, & &1.trust_confirm_required)} />

      <div class="mb-6">
        <h1 class="text-2xl font-semibold text-zinc-800 dark:text-zinc-100">Assigned to Me</h1>
        <p class="text-sm text-zinc-500 dark:text-zinc-400">
          Every task on your plate, across all your Initiatives.
        </p>
      </div>

      <.assigned_list
        id="assigned-page"
        rows={@streams.assigned_tasks}
        empty?={@assigned_empty?}
        show_completed={@show_completed}
        show_archived_hidden={@show_archived_hidden}
        group_by_initiative={@group_by_initiative}
        variant={:page}
      />
    </Layouts.app>
    """
  end
end
