defmodule DoItWeb.Layouts do
  @moduledoc """
  Application layouts and shared chrome (header, flash group).
  """
  use DoItWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_user, :map, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="border-b border-zinc-200 bg-white">
      <div class="mx-auto max-w-6xl flex items-center justify-between px-4 sm:px-6 py-3">
        <a href="/" class="flex items-center gap-2 font-semibold text-zinc-800">
          <span class="inline-block w-2.5 h-2.5 rounded-sm bg-emerald-500"></span>
          Do It List
        </a>

        <nav class="flex items-center gap-3 text-sm">
          <%= if @current_user do %>
            <.link navigate={~p"/projects"} class="hover:text-emerald-700">Projects</.link>
            <span class="text-zinc-400">·</span>
            <span class="text-zinc-600">{@current_user.name}</span>
            <.link
              href={~p"/users/log_out"}
              method="delete"
              class="text-zinc-500 hover:text-zinc-800"
            >
              Log out
            </.link>
          <% else %>
            <.link navigate={~p"/users/log_in"} class="hover:text-emerald-700">Log in</.link>
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
