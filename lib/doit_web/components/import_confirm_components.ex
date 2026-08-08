defmodule DoItWeb.ImportConfirmComponents do
  @moduledoc """
  The in-app import-confirm card (m03.04 item 30.2): a readback a gated MCP
  apply parked for the operator, decided here — Approve / Correct (with
  text) / Hold — where the server records the decision, so no agent client
  capability is load-bearing. One component serves both homes: the
  Initiative workspace (container `#import-confirm`) and the account page
  (`#import-confirms`). The hosting LiveView owns the three events
  (`approve_import_confirm` / `correct_import_confirm` /
  `hold_import_confirm`); every action is a server-gated write, so the
  buttons carry `data-latch` in-flight labels (§6.7) and the card leaves the
  pending slot on the decided ack — never a faked success.
  """
  use Phoenix.Component

  import DoItWeb.CoreComponents

  attr :id, :string, required: true
  attr :confirms, :list, required: true

  def import_confirm_cards(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :for={confirm <- @confirms}
        id={"import-confirm-card-#{confirm.id}"}
        class="mb-4 rounded border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-950/40 p-4 space-y-3"
      >
        <div class="flex items-start gap-2">
          <.icon
            name="hero-hand-raised"
            class="w-5 h-5 flex-none text-amber-700 dark:text-amber-300"
          />
          <div>
            <h3 class="text-sm font-semibold text-amber-900 dark:text-amber-200">
              An agent wants to import — your call
            </h3>
            <p class="text-xs text-amber-800 dark:text-amber-300">
              Review the readback below, then decide. The import applies only after you approve.
            </p>
          </div>
        </div>

        <pre class="whitespace-pre-wrap rounded border border-amber-200 dark:border-amber-800 bg-white dark:bg-zinc-900 px-3 py-2 font-sans text-sm text-zinc-800 dark:text-zinc-100">{confirm.readback}</pre>

        <div class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            id={"import-confirm-approve-#{confirm.id}"}
            phx-click="approve_import_confirm"
            phx-value-id={confirm.id}
            data-latch="Approving…"
            class="px-3 py-1.5 rounded bg-emerald-600 text-sm font-medium text-white hover:bg-emerald-700"
          >
            Approve
          </button>
          <button
            type="button"
            id={"import-confirm-hold-#{confirm.id}"}
            phx-click="hold_import_confirm"
            phx-value-id={confirm.id}
            data-latch="Holding…"
            title="Don't apply — have the agent ask you more questions first"
            class="px-3 py-1.5 rounded border border-amber-400 dark:border-amber-700 text-sm font-medium text-amber-900 dark:text-amber-200 hover:bg-amber-100 dark:hover:bg-amber-900/40"
          >
            Hold
          </button>
        </div>

        <%!-- Correct: the disclosure opens client-side (no round trip before
             typing); the submit is the server-gated write. data-keep="open"
             holds it open across patches while the operator types. --%>
        <details id={"import-confirm-correct-#{confirm.id}"} data-keep="open">
          <summary class="w-fit cursor-pointer list-none [&::-webkit-details-marker]:hidden text-sm font-medium text-amber-900 dark:text-amber-200 hover:underline">
            Correct instead…
          </summary>
          <form
            id={"import-confirm-correct-form-#{confirm.id}"}
            phx-submit="correct_import_confirm"
            class="mt-2 space-y-2"
          >
            <input type="hidden" name="confirm_id" value={confirm.id} />
            <textarea
              id={"import-confirm-corrections-#{confirm.id}"}
              name="corrections"
              rows="3"
              required
              placeholder="What should change? The agent gets this text and revises before re-applying."
              class="w-full rounded border border-amber-300 dark:border-amber-700 bg-white dark:bg-zinc-900 px-2 py-1.5 text-sm text-zinc-800 dark:text-zinc-100"
            ></textarea>
            <button
              type="submit"
              data-latch="Sending…"
              class="px-3 py-1.5 rounded border border-amber-400 dark:border-amber-700 text-sm font-medium text-amber-900 dark:text-amber-200 hover:bg-amber-100 dark:hover:bg-amber-900/40"
            >
              Send corrections
            </button>
          </form>
        </details>
      </div>
    </div>
    """
  end
end
