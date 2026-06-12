defmodule DoItWeb.AccountLive do
  use DoItWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Account")}
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
        </section>
      </div>
    </Layouts.app>
    """
  end
end
