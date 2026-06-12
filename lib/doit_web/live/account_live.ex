defmodule DoItWeb.AccountLive do
  use DoItWeb, :live_view

  alias DoIt.Accounts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Account")
     |> assign(:profile_form, to_form(Accounts.change_profile(user)))
     |> assign(:username_form, to_form(Accounts.change_username(user)))
     |> assign(:password_form, to_form(Accounts.change_password(user)))}
  end

  @impl true
  def handle_event("validate_profile", %{"user" => params}, socket) do
    changeset =
      socket.assigns.current_user
      |> Accounts.change_profile(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :profile_form, to_form(changeset))}
  end

  def handle_event("save_profile", %{"user" => params}, socket) do
    case Accounts.update_profile(socket.assigns.current_user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:profile_form, to_form(Accounts.change_profile(user)))
         |> put_flash(:info, "Profile updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  def handle_event("validate_password", %{"user" => params}, socket) do
    changeset =
      socket.assigns.current_user
      |> Accounts.change_password(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :password_form, to_form(changeset))}
  end

  def handle_event("save_password", %{"user" => params}, socket) do
    case Accounts.update_password(socket.assigns.current_user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:password_form, to_form(Accounts.change_password(user)))
         |> put_flash(:info, "Password updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :password_form, to_form(changeset))}
    end
  end

  def handle_event("delete_account", _params, socket) do
    case Accounts.delete_account(socket.assigns.current_user) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Account deleted.")
         |> redirect(to: ~p"/")}

      {:error, {:shared_initiatives, names}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You own Initiatives that other members belong to: #{Enum.join(names, ", ")}. " <>
             "Transfer or delete those first."
         )}
    end
  end

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
        <div class="mb-6 flex items-center gap-3">
          <.avatar user={@current_user} class="w-12 h-12 text-lg" />
          <div>
            <h1 class="text-2xl font-semibold text-zinc-800 dark:text-zinc-100">Account</h1>
            <p class="text-sm text-zinc-500 dark:text-zinc-400">
              Your identity across Do It List.
            </p>
          </div>
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
              <dt class="text-zinc-500 dark:text-zinc-400">Member since</dt>
              <dd class="text-zinc-800 dark:text-zinc-100">
                {Calendar.strftime(@current_user.inserted_at, "%b %-d, %Y")}
              </dd>
            </div>
          </dl>

          <.form
            for={@profile_form}
            id="profile-form"
            phx-change="validate_profile"
            phx-submit="save_profile"
            class="mt-4 pt-4 border-t border-zinc-200 dark:border-zinc-800 space-y-2"
          >
            <.input
              field={@profile_form[:name]}
              type="text"
              label="Display name"
              phx-debounce="300"
              autocomplete="name"
            />
            <p class="text-xs text-zinc-500 dark:text-zinc-400">
              Free-form — how your name reads to other members.
            </p>
            <.input
              field={@profile_form[:email]}
              type="email"
              label="Email"
              phx-debounce="300"
              autocomplete="email"
            />
            <div class="flex justify-end">
              <.button type="submit" phx-disable-with="Saving...">Save profile</.button>
            </div>
          </.form>

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

        <section
          id="account-security"
          class="rounded border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4 mb-4"
        >
          <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400 mb-3">
            Security
          </h2>

          <.form
            for={@password_form}
            id="password-form"
            phx-change="validate_password"
            phx-submit="save_password"
            class="space-y-2"
          >
            <.input
              field={@password_form[:current_password]}
              type="password"
              label="Current password"
              autocomplete="current-password"
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label="New password (min 8 chars)"
              phx-debounce="300"
              autocomplete="new-password"
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="Confirm new password"
              phx-debounce="300"
              autocomplete="new-password"
            />
            <div class="flex justify-end">
              <.button type="submit" phx-disable-with="Saving...">Change password</.button>
            </div>
          </.form>
        </section>

        <section
          id="account-danger"
          class="rounded border border-red-200 dark:border-red-900/60 bg-white dark:bg-zinc-900 p-4"
        >
          <h2 class="text-sm font-semibold uppercase tracking-wide text-red-600 dark:text-red-400 mb-3">
            Danger zone
          </h2>
          <p class="text-sm text-zinc-600 dark:text-zinc-300 mb-3">
            Deleting your account also deletes Initiatives only you belong to. While you own
            Initiatives with other members, deletion is blocked — transfer or delete those first.
          </p>

          <%!-- Two-step confirm, client-side (no round trip to open); KeepOpen
               holds it open across patches, e.g. the blocked-deletion flash. --%>
          <details id="delete-account-confirm" phx-hook="KeepOpen">
            <summary class="w-fit cursor-pointer list-none [&::-webkit-details-marker]:hidden px-3 py-1.5 rounded border border-red-300 dark:border-red-800 text-sm font-medium text-red-700 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950/40">
              Delete account…
            </summary>
            <div class="mt-3 flex flex-wrap items-center gap-3 rounded border border-red-200 dark:border-red-900/60 bg-red-50 dark:bg-red-950/30 p-3">
              <span class="text-sm text-red-800 dark:text-red-300">
                This can't be undone. Delete your account?
              </span>
              <button
                type="button"
                id="delete-account-button"
                phx-click="delete_account"
                phx-disable-with="Deleting..."
                class="px-3 py-1.5 rounded bg-red-600 text-sm font-medium text-white hover:bg-red-700"
              >
                Yes, delete my account
              </button>
            </div>
          </details>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
