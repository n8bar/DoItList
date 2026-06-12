defmodule DoItWeb.AccountLive do
  use DoItWeb, :live_view

  alias DoIt.Accounts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Account")
     |> assign(:username_form, to_form(Accounts.change_username(user)))}
  end

  @impl true
  def handle_event("validate_username", %{"user" => params}, socket) do
    changeset =
      socket.assigns.current_user
      |> Accounts.change_username(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :username_form, to_form(changeset))}
  end

  def handle_event("save_username", %{"user" => params}, socket) do
    case Accounts.update_username(socket.assigns.current_user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:username_form, to_form(Accounts.change_username(user)))
         |> put_flash(:info, "Username updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :username_form, to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto max-w-2xl">
        <div class="mb-6">
          <h1 class="text-2xl font-semibold text-zinc-800 dark:text-zinc-100">Account</h1>
          <p class="text-sm text-zinc-500 dark:text-zinc-400">
            Your identity across Do It List.
          </p>
        </div>

        <section
          id="account-profile"
          class="rounded border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4 mb-4"
        >
          <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400 mb-3">
            Profile
          </h2>
          <dl class="space-y-3 text-sm">
            <div class="flex items-baseline justify-between gap-4">
              <dt class="text-zinc-500 dark:text-zinc-400">Name</dt>
              <dd class="text-zinc-800 dark:text-zinc-100 font-medium">{@current_user.name}</dd>
            </div>
            <div class="flex items-baseline justify-between gap-4">
              <dt class="text-zinc-500 dark:text-zinc-400">Email</dt>
              <dd class="text-zinc-800 dark:text-zinc-100 font-medium">{@current_user.email}</dd>
            </div>
            <div class="flex items-baseline justify-between gap-4">
              <dt class="text-zinc-500 dark:text-zinc-400">Member since</dt>
              <dd class="text-zinc-800 dark:text-zinc-100">
                {Calendar.strftime(@current_user.inserted_at, "%b %-d, %Y")}
              </dd>
            </div>
          </dl>

          <.form
            for={@username_form}
            id="username-form"
            phx-change="validate_username"
            phx-submit="save_username"
            class="mt-4 pt-4 border-t border-zinc-200 dark:border-zinc-800 space-y-2"
          >
            <.input
              field={@username_form[:username]}
              type="text"
              label="Username"
              phx-debounce="300"
              autocomplete="username"
            />
            <p class="text-xs text-zinc-500 dark:text-zinc-400">
              3–30 characters: letters, numbers, _ and -. Your login and @handle across the app.
            </p>
            <div class="flex justify-end">
              <.button type="submit" phx-disable-with="Saving...">Save username</.button>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
