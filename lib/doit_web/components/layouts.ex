defmodule DoItWeb.Layouts do
  @moduledoc """
  Application layouts and shared chrome (header, flash group).
  """
  use DoItWeb, :html

  alias Phoenix.LiveView.JS

  embed_templates "layouts/*"

  @doc """
  Returns the value to use for `<html data-theme=...>` based on the current
  user's saved preference. Returns nil for "system" / no user, which omits
  the attribute and lets DaisyUI's `prefersdark` handle it.
  """
  def theme_attr(assigns) do
    case assigns[:current_user] do
      %{theme: theme} when theme in ["light", "dark"] -> theme
      _ -> nil
    end
  end

  attr :flash, :map, required: true
  attr :current_user, :map, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-900">
      <div class="mx-auto max-w-6xl flex items-center justify-between px-4 sm:px-6 py-3">
        <a href="/" class="flex items-center gap-2 font-semibold text-zinc-800 dark:text-zinc-100">
          <span class="inline-block w-2.5 h-2.5 rounded-sm bg-emerald-500"></span>
          Do It List
        </a>

        <nav class="flex items-center gap-3 text-sm">
          <.theme_toggle />
          <%= if @current_user do %>
            <.link navigate={~p"/initiatives"} class="hover:text-emerald-700 dark:text-zinc-200 dark:hover:text-emerald-400">Initiatives</.link>
            <span class="text-zinc-400 dark:text-zinc-600">·</span>
            <span class="text-zinc-600 dark:text-zinc-300">{@current_user.name}</span>
            <.link
              href={~p"/users/log_out"}
              method="delete"
              class="text-zinc-500 hover:text-zinc-800 dark:text-zinc-400 dark:hover:text-zinc-100"
            >
              Log out
            </.link>
          <% else %>
            <.link navigate={~p"/users/log_in"} class="hover:text-emerald-700 dark:text-zinc-200 dark:hover:text-emerald-400">Log in</.link>
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

    <main class="mx-auto max-w-6xl px-4 sm:px-6 py-8">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Three-state theme toggle (System / Light / Dark). Each button dispatches
  the `phx:set-theme` event for the client-side handler in `root.html.heex`
  (which sets `data-theme` and writes localStorage), and pushes `set_theme`
  to the LiveView for server-side persistence on the user record (handled
  globally via the on_mount hook in `DoItWeb.UserAuth`).
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="join" role="group" aria-label="Theme">
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
