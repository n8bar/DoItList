defmodule DoItWeb.ImportApprovalComponents do
  @moduledoc """
  The in-app import-approval card (m03.04 2.8.8, repointed by 2.8.10 and
  2.8.5.3): an import the MCP adapter parked for the operator's call —
  Approve / Reject — where the server records the decision, so no agent
  attestation is load-bearing. One card serves every parked family, so it
  shows WHAT is being imported (a sample drawn from the batch's deepest
  branch, 2.11.2) rather than naming one family's reason: a flattened
  import reads as a flat list at a glance, and the operator judges content
  they recognise instead of our classification. Rejecting takes optional
  words that reach the agent verbatim. Account-homed only (container `#import-approvals` on the
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
              Import incoming
            </h3>
            <p class="text-xs text-amber-800 dark:text-amber-300">
              {approval.task_count} tasks are ready for import into “{approval.initiative_name}”. Reject if anything looks off.
            </p>
          </div>
        </div>

        <%!-- The snapshot: the batch's deepest branch, indented by depth.
             Nothing here exists yet — these rows are read from the parked
             payload, not the tree. --%>
        <ol
          :if={sample_nodes(approval) != []}
          id={"import-approval-sample-#{approval.id}"}
          class="rounded border border-amber-200 dark:border-amber-800/60 bg-white/70 dark:bg-zinc-900/40 py-2 pr-3 text-xs"
        >
          <li
            :for={node <- sample_nodes(approval)}
            style={"padding-left: #{0.75 + (node["depth"] - 1) * 1.1}rem"}
            class="py-0.5 text-zinc-700 dark:text-zinc-300"
          >
            <span class="text-zinc-400 dark:text-zinc-600 select-none">└</span>
            <span class="font-medium">{node["title"]}</span>
            <span :if={node["description"]} class="text-zinc-500 dark:text-zinc-400">
              — {node["description"]}
            </span>
          </li>
        </ol>

        <form phx-submit="dismiss_import" class="space-y-2">
          <input type="hidden" name="approval_id" value={approval.id} />
          <input
            type="text"
            id={"import-approval-reason-#{approval.id}"}
            name="reason"
            maxlength="500"
            placeholder="Optional — what's wrong with it? The agent sees this."
            class="w-full px-2 py-1.5 rounded border border-amber-300 dark:border-amber-800 bg-white dark:bg-zinc-900 text-xs text-zinc-800 dark:text-zinc-100 placeholder:text-zinc-400"
          />
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
              type="submit"
              id={"import-approval-dismiss-#{approval.id}"}
              data-latch="Rejecting…"
              title="Reject — the agent must change the batch or come talk to you"
              class="px-3 py-1.5 rounded border border-amber-400 dark:border-amber-700 text-sm font-medium text-amber-900 dark:text-amber-200 hover:bg-amber-100 dark:hover:bg-amber-900/40"
            >
              Reject
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # The parked payload's snapshot rows, ordered as the adapter composed them
  # (root of the deepest branch first). Absent or malformed samples render
  # nothing — an older parked row predates the column.
  defp sample_nodes(%{sample: %{"nodes" => nodes}}) when is_list(nodes), do: nodes
  defp sample_nodes(_approval), do: []
end
