defmodule DoItWeb.Layouts do
  @moduledoc """
  Application layouts and shared chrome (header, flash group).
  """
  use DoItWeb, :html

  alias Phoenix.LiveView.JS

  embed_templates "layouts/*"

  @doc """
  Returns the value to use for `<html data-theme=...>` based on the current
  user's saved preference. Returns nil for "system" / no user — the boot
  script in root.html.heex then resolves the OS preference to an explicit
  light/dark before first paint.
  """
  def theme_attr(assigns) do
    case assigns[:current_user] do
      %{theme: theme} when theme in ["light", "dark"] -> theme
      _ -> nil
    end
  end

  attr :flash, :map, required: true
  attr :current_user, :map, default: nil
  attr :width, :atom, values: [:default, :wide], default: :default
  attr :rail_initiatives, :list, default: nil
  attr :rail_current_id, :any, default: nil
  attr :rail_current_name, :string, default: nil
  attr :rail_collaborators, :list, default: []
  attr :rail_online_ids, :any, default: %MapSet{}
  attr :rail_member_ids, :any, default: %MapSet{}
  slot :rail_right, doc: "Optional ultrawide right (third) pane, a sibling of the left rail."
  slot :inner_block, required: true

  def app(assigns) do
    # The container cap is shared chrome: the header mirrors the body so the
    # two stay visually aligned at every width (m02.05 item 1). `:default`
    # keeps the readable 6xl column (login / account / marketing); `:wide`
    # lets the Initiative pages breathe on big monitors, stepping up at
    # xl:/2xl: but staying bounded so body text never sprawls. At `3xl:` the
    # cap jumps wider so the ultrawide left rail (item 4) is *added* width —
    # not stolen from the main column, which would shrink it crossing the
    # threshold (jank).
    container =
      case assigns.width do
        :wide -> "mx-auto max-w-6xl xl:max-w-7xl 2xl:max-w-[90rem] 3xl:max-w-[140rem]"
        :default -> "mx-auto max-w-6xl"
      end

    assigns = assign(assigns, :container, container)

    ~H"""
    <header class="flex-none border-b border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-900">
      <div class={[@container, "flex items-center justify-between px-4 sm:px-6 py-3"]}>
        <a href="/" class="flex items-center gap-2 font-semibold text-zinc-800 dark:text-zinc-100">
          <span class="inline-block w-2.5 h-2.5 rounded-sm bg-emerald-500"></span> Do It List
        </a>

        <nav class="flex items-center gap-3 text-sm">
          <%= if @current_user do %>
            <%!-- Desktop: inline nav. --%>
            <div class="hidden sm:flex items-center gap-3">
              <.link
                navigate={~p"/initiatives"}
                class="hover:text-emerald-700 dark:text-zinc-200 dark:hover:text-emerald-400"
              >
                Initiatives
              </.link>
              <span class="h-5 w-px bg-zinc-300 dark:bg-zinc-700" aria-hidden="true"></span>
              <.theme_toggle variant={:group} current_user={@current_user} />
              <span class="h-5 w-px bg-zinc-300 dark:bg-zinc-700" aria-hidden="true"></span>
              <%!-- Account menu — same JS-free details/summary pattern as the
                   hamburger; root.html.heex's data-menu light-dismiss covers
                   outside clicks and Escape. --%>
              <details class="relative" data-menu>
                <summary
                  title="Account menu"
                  class="inline-flex items-center gap-1.5 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden text-zinc-600 dark:text-zinc-300 hover:text-emerald-700 dark:hover:text-emerald-400"
                >
                  <.avatar user={@current_user} class="w-5 h-5 text-[10px]" />
                  {@current_user.name}
                  <.icon name="hero-chevron-down" class="w-3 h-3" />
                </summary>
                <ul class="absolute right-0 mt-2 w-44 space-y-1 rounded-lg border border-zinc-200 bg-white p-2 text-sm shadow-lg z-50 dark:border-zinc-700 dark:bg-zinc-900">
                  <li>
                    <.link
                      navigate={~p"/account"}
                      class="block rounded px-2 py-1.5 text-zinc-700 hover:bg-zinc-100 dark:text-zinc-200 dark:hover:bg-zinc-800"
                    >
                      Account &amp; preferences
                    </.link>
                  </li>
                  <li>
                    <.link
                      href={~p"/users/log_out"}
                      method="delete"
                      class="block rounded px-2 py-1.5 text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800"
                    >
                      Log out
                    </.link>
                  </li>
                </ul>
              </details>
            </div>

            <%!-- Mobile: hamburger (JS-free details/summary — works on dead views too). --%>
            <details class="relative sm:hidden" data-menu>
              <summary
                class="btn btn-sm btn-ghost cursor-pointer list-none [&::-webkit-details-marker]:hidden"
                aria-label="Menu"
              >
                <.icon name="hero-bars-3" class="w-6 h-6" />
              </summary>
              <ul class="absolute right-0 mt-2 w-56 space-y-1 rounded-lg border border-zinc-200 bg-white p-2 text-sm shadow-lg z-50 dark:border-zinc-700 dark:bg-zinc-900">
                <li>
                  <.link
                    navigate={~p"/account"}
                    class="flex items-center gap-1.5 rounded px-2 py-1 font-medium text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800"
                  >
                    <.avatar user={@current_user} class="w-5 h-5 text-[10px]" />
                    {@current_user.name}
                  </.link>
                </li>
                <li>
                  <.link
                    navigate={~p"/initiatives"}
                    class="block rounded px-2 py-1.5 text-zinc-700 hover:bg-zinc-100 dark:text-zinc-200 dark:hover:bg-zinc-800"
                  >
                    Initiatives
                  </.link>
                </li>
                <li class="flex items-center justify-between px-2 py-1.5">
                  <span class="text-zinc-600 dark:text-zinc-300">Theme</span>
                  <.theme_toggle variant={:group} current_user={@current_user} />
                </li>
                <li>
                  <.link
                    href={~p"/users/log_out"}
                    method="delete"
                    class="block rounded px-2 py-1.5 text-zinc-600 hover:bg-zinc-100 dark:text-zinc-300 dark:hover:bg-zinc-800"
                  >
                    Log out
                  </.link>
                </li>
              </ul>
            </details>
          <% else %>
            <.theme_toggle current_user={@current_user} />
            <span class="h-5 w-px bg-zinc-300 dark:bg-zinc-700" aria-hidden="true"></span>
            <.link
              navigate={~p"/users/log_in"}
              class="hover:text-emerald-700 dark:text-zinc-200 dark:hover:text-emerald-400"
            >
              Log in
            </.link>
            <.link
              navigate={~p"/users/register"}
              class="px-3 py-1.5 rounded bg-emerald-600 text-white hover:bg-emerald-700"
            >
              Register
            </.link>
          <% end %>
        </nav>
      </div>
    </header>

    <main class="flex-1 overflow-y-auto">
      <div class={[@container, "px-1 sm:px-6 py-8"]}>
        <%= if @rail_initiatives do %>
          <%!-- Narrow flyout (item 11): below 3xl the rail isn't in the layout;
               on an open Initiative (current_id) a left-edge tab slides it in as
               an overlay. Absent on the plain index — there the index IS the
               main column. Pure client toggle (no round trip). --%>
          <button
            :if={@rail_current_id}
            type="button"
            phx-click={
              JS.set_attribute({"data-open", "true"}, to: "#left-rail")
              |> JS.remove_class("hidden", to: "#left-rail-backdrop")
            }
            aria-label="Open Initiatives panel"
            title="Initiatives"
            class="3xl:hidden fixed left-0 top-1/2 z-20 inline-flex h-12 w-7 -translate-y-1/2 items-center justify-center rounded-r-lg bg-zinc-200/90 text-zinc-600 shadow hover:bg-zinc-300 dark:bg-zinc-800/90 dark:text-zinc-300 dark:hover:bg-zinc-700"
          >
            <.icon name="hero-chevron-right" class="w-5 h-5" />
          </button>
          <div
            id="left-rail-backdrop"
            phx-click={
              JS.remove_attribute("data-open", to: "#left-rail")
              |> JS.add_class("hidden", to: "#left-rail-backdrop")
            }
            class="hidden 3xl:hidden fixed inset-0 z-30 bg-black/50"
            aria-hidden="true"
          >
          </div>
          <%!-- Ultrawide triple-pane (m02.05 items 4–7): the left rail joins
               the layout at 3xl as the Initiatives index in chrome, and an
               optional right pane (rail_right) rides alongside as its sibling
               — e.g. the index's "Assigned to Me" pane (item 6). Both flank
               the page content; the column count flexes on whether a right
               pane was given. Below 3xl neither rail is in flow (both render
               hidden), so the page is the wide-tuned two-pane from items 1–3. --%>
          <div class={[
            "3xl:grid 3xl:gap-6 3xl:items-start",
            if(@rail_right != [],
              do: "3xl:grid-cols-[17rem_minmax(0,1fr)_27.5rem]",
              else: "3xl:grid-cols-[17rem_minmax(0,1fr)]"
            )
          ]}>
            <.left_rail
              initiatives={@rail_initiatives}
              current_id={@rail_current_id}
              current_name={@rail_current_name}
              collaborators={@rail_collaborators}
              online_ids={@rail_online_ids}
              member_ids={@rail_member_ids}
            />
            <div class="min-w-0">
              {render_slot(@inner_block)}
            </div>
            <aside
              :if={@rail_right != []}
              class="hidden 3xl:block 3xl:sticky 3xl:top-8 3xl:self-start"
            >
              {render_slot(@rail_right)}
            </aside>
          </div>
        <% else %>
          {render_slot(@inner_block)}
        <% end %>
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Ultrawide left rail (m02.05 item 5): the Initiatives index rendered in
  compressed form for the rail width — the same list, not a bespoke widget.
  Each entry carries the grove icon, name, role badge, and a small progress
  bar; the current Initiative is highlighted. Clicking the current entry
  navigates back to `/initiatives` (item 7 — closes it); any other entry
  opens that Initiative. Hidden below the `3xl:` threshold.
  """
  attr :initiatives, :list, required: true
  attr :current_id, :any, default: nil
  attr :current_name, :string, default: nil
  attr :collaborators, :list, default: []
  attr :online_ids, :any, default: %MapSet{}
  attr :member_ids, :any, default: %MapSet{}

  def left_rail(assigns) do
    ~H"""
    <aside
      id="left-rail"
      class={
        [
          "3xl:sticky 3xl:top-8 3xl:self-start 3xl:max-h-[calc(100dvh-7rem)] overflow-y-auto [scrollbar-gutter:stable]",
          # Closed: hidden below 3xl, always shown at 3xl. Open (flyout, item 11):
          # a fixed left overlay below 3xl; at 3xl the data-open overrides drop
          # back to the inline sticky column (handles resize-while-open). The
          # 3xl "show" must match `not-data-open:hidden`'s specificity, so it's
          # `3xl:not-data-open:block` (not plain `3xl:block`, which loses to the
          # :not() selector and collapses the rail) — mirrors the right rail.
          "not-data-open:hidden 3xl:not-data-open:block",
          "data-open:block data-open:fixed 3xl:data-open:static data-open:inset-y-0 data-open:left-0 data-open:z-40 data-open:w-72",
          "data-open:bg-white dark:data-open:bg-zinc-900 3xl:data-open:bg-transparent",
          "data-open:shadow-xl 3xl:data-open:shadow-none data-open:p-4 3xl:data-open:p-0"
        ]
      }
    >
      <%!-- Flyout close (item 11): visible only as the narrow overlay. --%>
      <div class="3xl:hidden mb-2 flex justify-end">
        <button
          type="button"
          phx-click={
            JS.remove_attribute("data-open", to: "#left-rail")
            |> JS.add_class("hidden", to: "#left-rail-backdrop")
          }
          aria-label="Close Initiatives panel"
          title="Close"
          class="inline-flex h-8 w-8 items-center justify-center rounded bg-zinc-500/20 text-zinc-700 hover:bg-zinc-500/40 dark:text-zinc-200"
        >
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>
      </div>
      <h2 class="px-2 mb-1 text-xs font-semibold uppercase tracking-wide text-zinc-400 dark:text-zinc-500">
        Initiatives
      </h2>
      <nav class="space-y-0.5">
        <.link
          :for={init <- @initiatives}
          navigate={
            if(init.id == @current_id, do: ~p"/initiatives", else: ~p"/initiatives/#{init.id}")
          }
          aria-current={(init.id == @current_id && "page") || nil}
          data-rail-initiative-id={init.id}
          class={[
            "group block rounded px-2 py-1.5",
            if(init.id == @current_id,
              do: "bg-emerald-50 dark:bg-emerald-900/30",
              else: "hover:bg-zinc-100 dark:hover:bg-zinc-800"
            )
          ]}
        >
          <div class="flex items-center gap-2 min-w-0">
            <.botanical_icon
              kind={:grove}
              class="w-4 h-4 flex-none text-emerald-600 dark:text-emerald-400"
            />
            <span class={[
              "flex-1 min-w-0 truncate text-sm",
              if(init.id == @current_id,
                do: "font-semibold text-emerald-800 dark:text-emerald-300",
                else: "text-zinc-700 dark:text-zinc-200"
              )
            ]}>
              {init.name}
            </span>
            <span
              :if={init.my_role}
              class={[
                "flex-none text-[9px] uppercase tracking-wide font-semibold px-1 py-0.5 rounded",
                role_badge_class(init.my_role)
              ]}
              title={"Your role: #{init.my_role}"}
            >
              {init.my_role}
            </span>
          </div>
          <div class="mt-1 h-1 rounded-full bg-zinc-200 dark:bg-zinc-700 overflow-hidden">
            <div class="h-full bg-emerald-400" style={"width: #{init.progress || 0}%"}></div>
          </div>
        </.link>
      </nav>

      <%!-- Collaborators pane (item 8): everyone the user shares an Initiative
           with, most-shared-first. Renders nothing when there's no one — no
           empty-state hint. --%>
      <div :if={@collaborators != []} class="mt-6">
        <h2 class="px-2 mb-1 text-xs font-semibold uppercase tracking-wide text-zinc-400 dark:text-zinc-500">
          My Collaborators
        </h2>
        <ul class="space-y-0.5">
          <%!-- Each row is draggable onto an Initiative rail entry to add the
               person there as a viewer (item 10, desktop-only; CollaboratorDrag
               suppresses the click after a real drag so the item-9 menu won't
               pop). A plain click falls through to that menu. --%>
          <li
            :for={collab <- @collaborators}
            id={"collabrow-#{collab.user.id}"}
            phx-hook="CollaboratorDrag"
            data-user-id={collab.user.id}
            class="min-w-0"
          >
            <%!-- With an Initiative open (current_id), clicking a collaborator
                 opens a client-toggled menu (item 9, no round trip) with the
                 contextual add/remove. On the plain index there's no current
                 Initiative, so the row is display-only (a no-op). --%>
            <details
              :if={@current_id}
              id={"collab-#{collab.user.id}"}
              data-menu
              class="relative"
            >
              <summary class="flex items-center gap-2 rounded px-2 py-1.5 min-w-0 cursor-pointer list-none [&::-webkit-details-marker]:hidden hover:bg-zinc-100 dark:hover:bg-zinc-800">
                <.avatar
                  user={collab.user}
                  online={MapSet.member?(@online_ids, collab.user.id)}
                  class="w-6 h-6 text-[10px] flex-none"
                />
                <span class="flex-1 min-w-0 truncate text-sm text-zinc-700 dark:text-zinc-200">
                  {collab.user.name}
                </span>
                <span class="flex-none text-xs tabular-nums text-zinc-400 dark:text-zinc-500">
                  {collab.shared_count}
                </span>
              </summary>
              <div class="absolute left-2 right-0 z-50 mt-1 rounded-lg border border-zinc-200 bg-white p-1 shadow-lg dark:border-zinc-700 dark:bg-zinc-900">
                <button
                  :if={MapSet.member?(@member_ids, collab.user.id)}
                  type="button"
                  phx-click={
                    JS.push("remove_member", value: %{"user-id" => to_string(collab.user.id)})
                    |> JS.remove_attribute("open", to: "#collab-#{collab.user.id}")
                  }
                  class="block w-full rounded px-2 py-1.5 text-left text-sm text-red-700 hover:bg-red-50 dark:text-red-400 dark:hover:bg-red-900/30"
                >
                  Remove from {@current_name}
                </button>
                <button
                  :if={not MapSet.member?(@member_ids, collab.user.id)}
                  type="button"
                  phx-click={
                    JS.push("add_collaborator_to",
                      value: %{
                        "user-id" => to_string(collab.user.id),
                        "initiative-id" => to_string(@current_id)
                      }
                    )
                    |> JS.remove_attribute("open", to: "#collab-#{collab.user.id}")
                  }
                  class="block w-full rounded px-2 py-1.5 text-left text-sm text-emerald-700 hover:bg-emerald-50 dark:text-emerald-400 dark:hover:bg-emerald-900/30"
                >
                  Add to {@current_name}
                </button>
              </div>
            </details>

            <div :if={!@current_id} class="flex items-center gap-2 rounded px-2 py-1.5 min-w-0">
              <.avatar
                user={collab.user}
                online={MapSet.member?(@online_ids, collab.user.id)}
                class="w-6 h-6 text-[10px] flex-none"
              />
              <span class="flex-1 min-w-0 truncate text-sm text-zinc-700 dark:text-zinc-200">
                {collab.user.name}
              </span>
              <span
                class="flex-none text-xs tabular-nums text-zinc-400 dark:text-zinc-500"
                title={"#{collab.shared_count} shared #{ngettext_initiative(collab.shared_count)}"}
              >
                {collab.shared_count}
              </span>
            </div>
          </li>
        </ul>
      </div>
    </aside>
    """
  end

  # "Initiative" / "Initiatives" for the Collaborators shared-count tooltip.
  defp ngettext_initiative(1), do: "Initiative"
  defp ngettext_initiative(_), do: "Initiatives"

  @doc """
  Three-state theme toggle (System / Light / Dark). Each button dispatches
  the `phx:set-theme` event for the client-side handler in `root.html.heex`
  (which sets `data-theme` and writes localStorage), and pushes `set_theme`
  to the LiveView for server-side persistence on the user record (handled
  globally via the on_mount hook in `DoItWeb.UserAuth`).
  """
  attr :current_user, :map, default: nil
  attr :variant, :atom, values: [:auto, :group], default: :auto

  def theme_toggle(assigns) do
    state =
      case assigns[:current_user] do
        %{theme: t} when t in ["light", "dark", "system"] -> t
        _ -> "system"
      end

    assigns = assign(assigns, :state, state)

    ~H"""
    <%!-- :auto (login screens) shows a single cycling icon on mobile + the group
         on desktop; :group (logged-in hamburger / desktop nav) is just the group.
         The ThemeCycle hook owns the single icon's display (phx-update="ignore"). --%>
    <button
      :if={@variant == :auto}
      type="button"
      id="theme-cycle"
      phx-hook="ThemeCycle"
      phx-update="ignore"
      aria-label="Switch theme"
      title="Switch theme"
      class="btn btn-xs sm:hidden"
    >
      <span data-theme-icon="system" class={@state != "system" && "hidden"}>
        <.icon name="hero-computer-desktop" class="w-4 h-4" />
      </span>
      <span data-theme-icon="light" class={@state != "light" && "hidden"}>
        <.icon name="hero-sun" class="w-4 h-4" />
      </span>
      <span data-theme-icon="dark" class={@state != "dark" && "hidden"}>
        <.icon name="hero-moon" class="w-4 h-4" />
      </span>
    </button>

    <div
      class={["join", @variant == :auto && "hidden sm:inline-flex"]}
      role="group"
      aria-label="Theme"
    >
      <button
        type="button"
        data-phx-theme="system"
        phx-click={JS.dispatch("phx:set-theme") |> JS.push("set_theme", value: %{theme: "system"})}
        aria-label="Use system theme"
        title="System"
        class="btn btn-xs join-item"
      >
        <.icon name="hero-computer-desktop" class="w-4 h-4" />
      </button>
      <button
        type="button"
        data-phx-theme="light"
        phx-click={JS.dispatch("phx:set-theme") |> JS.push("set_theme", value: %{theme: "light"})}
        aria-label="Use light theme"
        title="Light"
        class="btn btn-xs join-item"
      >
        <.icon name="hero-sun" class="w-4 h-4" />
      </button>
      <button
        type="button"
        data-phx-theme="dark"
        phx-click={JS.dispatch("phx:set-theme") |> JS.push("set_theme", value: %{theme: "dark"})}
        aria-label="Use dark theme"
        title="Dark"
        class="btn btn-xs join-item"
      >
        <.icon name="hero-moon" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="fixed top-4 right-4 z-50 space-y-2">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end
end
