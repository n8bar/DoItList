defmodule DoItWeb.ImportApprovalComponents do
  @moduledoc """
  The in-app import-approval card (m03.04 2.8.8, repointed by 2.8.10): an
  import whose declaration excludes the source's completed work, parked by
  the MCP adapter for the operator's one-click call — Approve / Dismiss —
  where the server records the decision, so no agent attestation is
  load-bearing. Account-homed only (container `#import-approvals` on the
  account page — a bootstrap batch's Initiative doesn't exist yet). The
  hosting LiveView owns the two events
  (`approve_import` / `dismiss_import`); every action is a server-gated
  write, so the buttons carry `data-latch` in-flight labels (§6.7) and the
  card leaves the pending slot on the decided ack — never a faked success.
  """
  use Phoenix.Component

  import DoItWeb.CoreComponents

  attr :id, :string, required: true
  attr :approvals, :list, required: true

  def import_approval_cards(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :for={approval <- @approvals}
        id={"import-approval-card-#{approval.id}"}
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
              It wants to import into “{approval.initiative_name}” — {approval.task_count} tasks, declaredly leaving the source's completed work out of the tree. Approve if that's what you
              asked for; dismiss to make it change the batch or come talk to you.
            </p>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <button
            type="button"
            id={"import-approval-approve-#{approval.id}"}
            phx-click="approve_import"
            phx-value-id={approval.id}
            data-latch="Approving…"
            class="px-3 py-1.5 rounded bg-emerald-600 text-sm font-medium text-white hover:bg-emerald-700"
          >
            Approve
          </button>
          <button
            type="button"
            id={"import-approval-dismiss-#{approval.id}"}
            phx-click="dismiss_import"
            phx-value-id={approval.id}
            data-latch="Dismissing…"
            title="Decline — the agent must change the batch or talk to you"
            class="px-3 py-1.5 rounded border border-amber-400 dark:border-amber-700 text-sm font-medium text-amber-900 dark:text-amber-200 hover:bg-amber-100 dark:hover:bg-amber-900/40"
          >
            Dismiss
          </button>
        </div>
      </div>
    </div>
    """
  end
end
