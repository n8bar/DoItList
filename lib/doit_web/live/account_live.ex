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
     |> assign(:password_form, to_form(Accounts.change_password(user)))
     |> assign(:prefs_form, to_form(Accounts.change_preferences(Accounts.get_preferences(user))))
     |> assign(:api_token_form, new_api_token_form())
     # The just-minted plaintext, shown ONCE then dismissed. Never re-derivable.
     |> assign(:new_api_token, nil)
     |> assign(:api_tokens, Accounts.list_api_tokens(user))}
  end

  defp new_api_token_form, do: to_form(%{"label" => ""}, as: :api_token)

  @impl true
  def handle_event("validate_preferences", %{"user_preferences" => params}, socket) do
    changeset =
      socket.assigns.current_user
      |> Accounts.get_preferences()
      |> Accounts.change_preferences(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :prefs_form, to_form(changeset))}
  end

  def handle_event("save_preferences", %{"user_preferences" => params}, socket) do
    case Accounts.update_preferences(socket.assigns.current_user, params) do
      {:ok, prefs} ->
        {:noreply,
         socket
         |> assign(:prefs_form, to_form(Accounts.change_preferences(prefs)))
         |> put_flash(:info, "Preferences saved.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:prefs_form, to_form(Map.put(changeset, :action, :validate)))
         |> put_flash(:error, "Couldn't save preferences.")}
    end
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
    :ok = Accounts.delete_account(socket.assigns.current_user)

    {:noreply,
     socket
     |> put_flash(:info, "Account deleted.")
     |> redirect(to: ~p"/")}
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
        {:noreply,
         assign(socket, :username_form, to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  # --- API tokens (m03.01 worklist 1.2) --------------------------------------

  def handle_event("mint_api_token", %{"api_token" => %{"label" => label}}, socket) do
    user = socket.assigns.current_user

    case Accounts.mint_api_token(user, label) do
      {:ok, {plaintext, _token}} ->
        {:noreply,
         socket
         |> assign(:new_api_token, plaintext)
         |> assign(:api_token_form, new_api_token_form())
         |> assign(:api_tokens, Accounts.list_api_tokens(user))
         |> put_flash(:info, "Token minted. Copy it now — it won't be shown again.")}

      {:error, :token_limit_reached} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Token limit reached (#{Accounts.max_active_api_tokens()} active). Revoke one to mint another."
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(
           :api_token_form,
           to_form(Map.put(changeset, :action, :validate), as: :api_token)
         )
         |> put_flash(:error, "Couldn't mint token.")}
    end
  end

  def handle_event("revoke_api_token", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Accounts.revoke_api_token(user, id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:api_tokens, Accounts.list_api_tokens(user))
         |> put_flash(:info, "Token revoked.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Token not found.")}
    end
  end

  # Dismiss the one-time plaintext reveal so it can't be screen-scraped later.
  def handle_event("dismiss_api_token", _params, socket) do
    {:noreply, assign(socket, :new_api_token, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <%!-- §6.8 dead-window flush (WL4.2.2): EVERY LiveView in the authenticated
           live_session must register a livePush backend, so the global
           capture-phase interceptor (app.js) goes inert the moment THIS page is
           live, this page flushes its OWN dead-window queue on mount, and nothing
           survives a live <.link navigate> into another view (Defect #1).
           Mirrors .IndexLive / .TaskKeys. --%>
      <div id="account-root" phx-hook=".AccountLive">
        <script :type={Phoenix.LiveView.ColocatedHook} name=".AccountLive">
          export default {
            mounted() {
              this._livePush = (ev, payload, cb) => this.pushEvent(ev, payload, cb);
              window.DoitRegisterLivePush(this._livePush);
            },
            destroyed() {
              window.DoitUnregisterLivePush(this._livePush);
            },
          }
        </script>
      </div>

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
              data-protonpass-ignore="true"
              data-1p-ignore="true"
              data-lpignore="true"
              data-bwignore="true"
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
              <.button type="submit" data-latch="Saving…">Save profile</.button>
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
              <.button type="submit" data-latch="Saving…">Save username</.button>
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
              <.button type="submit" data-latch="Saving…">Change password</.button>
            </div>
          </.form>
        </section>

        <section
          id="account-api-tokens"
          class="rounded border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4 mb-4"
        >
          <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400 mb-3">
            API tokens
          </h2>
          <p class="text-sm text-zinc-600 dark:text-zinc-300 mb-4">
            Personal access tokens let scripts and AI agents act as you over the HTTP API, under your
            existing roles. Send one as <code phx-no-curly-interpolation class="text-xs">Authorization: Bearer &lt;token&gt;</code>.
          </p>

          <%!-- One-time plaintext reveal: shown once, right after minting; never
               again (the server keeps only a hash). A copy affordance + a clear
               "copy it now" note, and a Done button to dismiss it. --%>
          <%= if @new_api_token do %>
            <div
              id="api-token-reveal"
              role="status"
              aria-live="polite"
              class="mb-4 rounded border border-emerald-300 dark:border-emerald-800 bg-emerald-50 dark:bg-emerald-950/30 p-3"
            >
              <p class="text-sm font-medium text-emerald-800 dark:text-emerald-300 mb-2">
                Your new token — copy it now. It won't be shown again.
              </p>
              <div class="flex items-center gap-2">
                <input
                  id="api-token-value"
                  type="text"
                  readonly
                  value={@new_api_token}
                  aria-label="New API token"
                  class="flex-1 font-mono text-xs px-2 py-1.5 rounded border border-emerald-300 dark:border-emerald-800 bg-white dark:bg-zinc-900 text-zinc-800 dark:text-zinc-100"
                />
                <button
                  type="button"
                  id="api-token-copy"
                  phx-hook=".CopyToken"
                  data-token-target="api-token-value"
                  class="shrink-0 px-3 py-1.5 rounded border border-emerald-300 dark:border-emerald-800 text-sm font-medium text-emerald-800 dark:text-emerald-300 hover:bg-emerald-100 dark:hover:bg-emerald-900/40"
                >
                  Copy
                </button>
                <button
                  type="button"
                  id="api-token-dismiss"
                  phx-click="dismiss_api_token"
                  class="shrink-0 px-3 py-1.5 rounded border border-zinc-300 dark:border-zinc-700 text-sm text-zinc-700 dark:text-zinc-200 hover:bg-zinc-50 dark:hover:bg-zinc-800"
                >
                  Done
                </button>
              </div>
            </div>
          <% end %>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToken">
            export default {
              mounted() {
                this.el.addEventListener("click", async () => {
                  const target = document.getElementById(this.el.dataset.tokenTarget)
                  if (!target) return
                  try {
                    await navigator.clipboard.writeText(target.value)
                  } catch (_e) {
                    target.select()
                    document.execCommand("copy")
                  }
                  const original = this.el.textContent
                  this.el.textContent = "Copied!"
                  setTimeout(() => { this.el.textContent = original }, 1500)
                })
              }
            }
          </script>

          <.form
            for={@api_token_form}
            id="api-token-form"
            phx-submit="mint_api_token"
            class="space-y-2"
          >
            <.input
              field={@api_token_form[:label]}
              type="text"
              label="Label (optional)"
              placeholder="e.g. Claude Code, laptop CLI"
              autocomplete="off"
            />
            <p class="text-xs text-zinc-500 dark:text-zinc-400">
              A name to recognize this token later.
            </p>
            <div class="flex justify-end">
              <.button type="submit" data-latch="Minting…">Mint token</.button>
            </div>
          </.form>

          <div class="mt-4 pt-4 border-t border-zinc-200 dark:border-zinc-800">
            <h3 class="text-sm font-medium text-zinc-700 dark:text-zinc-200 mb-2">
              Active tokens
            </h3>
            <%= if @api_tokens == [] do %>
              <p class="text-sm text-zinc-500 dark:text-zinc-400">No tokens yet.</p>
            <% else %>
              <ul id="api-tokens-list" class="divide-y divide-zinc-200 dark:divide-zinc-800">
                <%= for token <- @api_tokens do %>
                  <li
                    id={"api-token-#{token.id}"}
                    class="flex items-center justify-between gap-4 py-2"
                  >
                    <div class="min-w-0">
                      <p class="text-sm text-zinc-800 dark:text-zinc-100 truncate">
                        {token.label || "Unlabeled token"}
                      </p>
                      <p class="text-xs text-zinc-500 dark:text-zinc-400">
                        Minted {Calendar.strftime(token.inserted_at, "%b %-d, %Y")} ·
                        <%= if token.last_used_at do %>
                          Last used {Calendar.strftime(token.last_used_at, "%b %-d, %Y")}
                        <% else %>
                          Never used
                        <% end %>
                      </p>
                    </div>
                    <button
                      type="button"
                      id={"revoke-api-token-#{token.id}"}
                      phx-click="revoke_api_token"
                      phx-value-id={token.id}
                      data-latch="Revoking…"
                      class="shrink-0 px-3 py-1.5 rounded border border-red-300 dark:border-red-800 text-sm text-red-700 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950/40"
                    >
                      Revoke
                    </button>
                  </li>
                <% end %>
              </ul>
            <% end %>
          </div>
        </section>

        <section
          id="account-preferences"
          phx-hook="ScrollOnHash"
          class="rounded border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4 mb-4"
        >
          <h2 class="text-sm font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400 mb-3">
            Preferences
          </h2>

          <.form
            for={@prefs_form}
            id="preferences-form"
            phx-change="validate_preferences"
            phx-submit="save_preferences"
            class="space-y-6"
          >
            <fieldset class="space-y-2">
              <legend class="text-sm font-medium text-zinc-700 dark:text-zinc-200">
                My Initiative Defaults
              </legend>
              <p class="text-xs text-zinc-500 dark:text-zinc-400">
                Applied to Initiatives you create.
              </p>
              <.input
                type="select"
                field={@prefs_form[:initiative_sort_mode]}
                label="Sort Lists by"
                options={[
                  {"Manual (default)", ""},
                  {"Alphabetical", "alphabetical"},
                  {"Completion %", "completion"},
                  {"Priority", "priority"},
                  {"First Created", "created"},
                  {"Last Updated", "updated"}
                ]}
              />
              <.input
                type="checkbox"
                field={@prefs_form[:initiative_sort_reverse]}
                label="Reverse sort"
              />
              <.input
                type="select"
                field={@prefs_form[:initiative_progress_calc]}
                label="Progress calculation"
                options={[
                  {"Leaf average (default)", ""},
                  {"Single level", "single_level"}
                ]}
              />
              <%!-- m02.05 item 12.6: seeds initiatives.viewer_plus on create. --%>
              <.input
                type="checkbox"
                field={@prefs_form[:initiative_viewer_plus]}
                label="Viewer+ (a viewer assigned a task can update progress and comment on it and the tasks under it)"
              />
            </fieldset>

            <fieldset class="space-y-2">
              <legend class="text-sm font-medium text-zinc-700 dark:text-zinc-200">
                My Task Defaults
              </legend>
              <p class="text-xs text-zinc-500 dark:text-zinc-400">
                Applied to new tasks in Initiatives you own — whoever adds them.
              </p>
              <.input
                type="select"
                field={@prefs_form[:task_sort_mode]}
                label="Sort children by"
                options={[
                  {"Match parent (default)", "match_parent"},
                  {"Manual", "manual"},
                  {"Alphabetical", "alphabetical"},
                  {"Completion %", "completion"},
                  {"Priority", "priority"},
                  {"First Created", "created"},
                  {"Last Updated", "updated"}
                ]}
              />
              <.input
                type="select"
                field={@prefs_form[:task_priority]}
                label="Priority"
                options={[
                  {"Normal (default)", "normal"},
                  {"Match parent", "match_parent"},
                  {"Low", "low"},
                  {"High", "high"}
                ]}
              />
              <.input
                type="checkbox"
                field={@prefs_form[:task_assign_owner]}
                label="Assign to owner"
              />
            </fieldset>

            <fieldset class="space-y-2">
              <legend class="text-sm font-medium text-zinc-700 dark:text-zinc-200">
                Display elements
              </legend>
              <.input
                type="checkbox"
                field={@prefs_form[:show_task_activity]}
                label="Show Task Activity log"
              />
              <p class="text-xs text-zinc-500 dark:text-zinc-400 pt-1">
                Task attributes shown on rows:
              </p>
              <.input type="checkbox" field={@prefs_form[:show_task_priority]} label="Priority" />
              <.input type="checkbox" field={@prefs_form[:show_task_assignee]} label="Assignee" />
              <.input
                type="checkbox"
                field={@prefs_form[:show_task_progress]}
                label="Checkbox & progress bar"
              />
              <.input
                type="checkbox"
                field={@prefs_form[:show_task_count]}
                label="Leaf / child count"
              />
            </fieldset>

            <div class="flex justify-end">
              <.button type="submit" data-latch="Saving…">Save preferences</.button>
            </div>
          </.form>

          <%!-- §2.5 — the "until a profile/settings page" home that .03.01.11
               promised the confirm-skip flags. Flags are client-local
               (localStorage), so the reset is too: no round trip. --%>
          <div class="mt-6 pt-4 border-t border-zinc-200 dark:border-zinc-800 space-y-2">
            <h3 class="text-sm font-medium text-zinc-700 dark:text-zinc-200">
              Confirmation prompts
            </h3>
            <p class="text-xs text-zinc-500 dark:text-zinc-400">
              Confirmations you've checked "don't ask me again" on stay suppressed in this browser.
            </p>
            <button
              type="button"
              id="reset-confirm-prompts"
              phx-hook=".ConfirmReset"
              class="px-3 py-1.5 rounded border border-zinc-300 dark:border-zinc-700 text-sm text-zinc-700 dark:text-zinc-200 hover:bg-zinc-50 dark:hover:bg-zinc-800"
            >
              Reset confirmation prompts
            </button>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".ConfirmReset">
              export default {
                mounted() {
                  this.el.addEventListener("click", () => {
                    Object.keys(localStorage)
                      .filter((k) => k.startsWith("doit:confirm-skip:"))
                      .forEach((k) => localStorage.removeItem(k))
                    const note = document.getElementById("reset-confirm-note")
                    if (note) note.hidden = false
                  })
                }
              }
            </script>
            <p id="reset-confirm-note" hidden class="text-xs text-emerald-700 dark:text-emerald-400">
              Done — every confirmation asks again. Initiative pages already open need a reload to notice.
            </p>
          </div>
        </section>

        <section
          id="account-danger"
          class="rounded border border-red-200 dark:border-red-900/60 bg-white dark:bg-zinc-900 p-4 mb-4"
        >
          <h2 class="text-sm font-semibold uppercase tracking-wide text-red-600 dark:text-red-400 mb-3">
            Danger zone
          </h2>
          <p class="text-sm text-zinc-600 dark:text-zinc-300 mb-3">
            Deleting your account also deletes Initiatives only you belong to. Initiatives you own
            with other members are handed to another member, so their work isn't lost.
          </p>

          <%!-- Two-step confirm, client-side (no round trip to open);
               data-keep="open" holds it open across any patch while the user decides. --%>
          <details id="delete-account-confirm" data-keep="open">
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
                data-latch="Deleting…"
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
