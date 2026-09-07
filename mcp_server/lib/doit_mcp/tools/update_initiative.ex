defmodule DoitMcp.Tools.UpdateInitiative do
  @moduledoc """
  Update one Initiative's name, description, subtitle, progress calculation, task numbering, co-assignee auto-promotion, or viewer+ access. `description` and `subtitle` accept `%<task_id>` cross-reference tokens. Use `set_initiative_state` for archived, hidden, or trashed state; this tool never changes state or ownership.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.Tools.ExpectedVersion
  alias DoitMcp.{Client, ToolResult}

  # CALC-GATE-PARKED (m03.04): gate-only deps. Revive with the gated execute +
  # gate functions below.
  # alias Anubis.Server.Response
  # alias DoitMcp.Elicitation

  # CALC-GATE-PARKED (m03.04): fix 17's confirm on a non-default progress_calc
  # change is parked — see the m03.04 arc doc. Revive these attributes with the
  # calc_gate below.
  # @default_calc "leaf_average"
  #
  # # A human is reading one question — a generous window.
  # @confirm_timeout to_timeout(minute: 5)
  #
  # @confirm_schema %{
  #   "type" => "object",
  #   "properties" => %{
  #     "approve" => %{
  #       "type" => "boolean",
  #       "description" => "true switches the progress calculation; false leaves it unchanged"
  #     }
  #   },
  #   "required" => ["approve"]
  # }

  @expected_version_doc ExpectedVersion.description()

  schema do
    field(:initiative_id, :integer, required: true)
    field(:name, :string, required: false)
    field(:description, :string, required: false)
    field(:subtitle, :string, required: false)

    # CALC-GATE-PARKED (m03.04): while the gate ran, the description ended
    # ". A change to non-default is held for the operator's confirm".
    field(:progress_calc, :string,
      required: false,
      description:
        "leaf_average (default) weights progress through decomposition. Retain it unless the user asks for single_level. Recommend single_level only when completed work represented as single done leaves would otherwise be hidden; never merely to equalize differently sized siblings"
    )

    field(:index_style, :string, required: false)

    field(:auto_promote_co_assignees, :boolean, required: false)
    field(:viewer_plus, :boolean, required: false)

    field(:expected_version, :integer,
      required: false,
      description: @expected_version_doc
    )
  end

  # CALC-GATE-PARKED (m03.04): fix 17's write gate is parked — updates apply
  # ungated. Revive this gated execute with the gate functions and the aliases
  # above.
  # def execute(params, frame) do
  #   case calc_gate(params) do
  #     :pass -> do_update(params, frame)
  #     {:refuse, message} -> {:reply, Response.error(Response.tool(), message), frame}
  #   end
  # end

  def execute(params, frame), do: do_update(params, frame)

  defp do_update(params, frame) do
    data =
      params
      |> Map.take([
        :name,
        :description,
        :subtitle,
        :progress_calc,
        :index_style,
        :auto_promote_co_assignees,
        :viewer_plus,
        :expected_version
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "update", "type" => "initiative", "id" => params.initiative_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end

  # CALC-GATE-PARKED (m03.04): fix 17's progress-calc confirm — held a calc
  # CHANGE to non-default for the operator's yes/no (once per Initiative per
  # value per session); refused with the in-app control on clients without
  # elicitation. Revive with the gated execute above.
  #
  # # The gate only ever engages on a calc CHANGE to non-default; a params map
  # # without progress_calc (or returning to the default) takes zero extra
  # # round trips.
  # defp calc_gate(params) do
  #   case Map.get(params, :progress_calc) do
  #     nil -> :pass
  #     @default_calc -> :pass
  #     requested -> gate_non_default(params.initiative_id, requested)
  #   end
  # end
  #
  # defp gate_non_default(initiative_id, requested) do
  #   case Client.get("/api/v1/initiatives/#{initiative_id}") do
  #     {:ok, %{"progress_calc" => current}} when current != requested ->
  #       confirm_change(initiative_id, current, requested)
  #
  #     # Same value (no change happening) — or a fetch error / shape we can't
  #     # read, where the update itself will surface the real error.
  #     _ ->
  #       :pass
  #   end
  # end
  #
  # defp confirm_change(initiative_id, current, requested) do
  #   # Revival needs its own per-session memory of a granted confirm, so a
  #   # retry never re-asks the operator; the counter process this used was
  #   # deleted with the import ceremony (m03.04 3.1).
  #   cond do
  #     not Elicitation.client_supports_elicitation?() ->
  #       {:refuse,
  #        "Changing progress_calc to \"#{requested}\" needs the operator's confirmation, and " <>
  #          "this client cannot ask them (no elicitation support). Not applied. The operator " <>
  #          "can set it themselves in the app: Initiative details pane → settings, the " <>
  #          "progress-calculation control. Do not retry without the operator's request."}
  #
  #     true ->
  #       elicit_approval(initiative_id, current, requested)
  #   end
  # end
  #
  # defp elicit_approval(initiative_id, current, requested) do
  #   message =
  #     "The agent asks to switch this Initiative's progress calculation from #{current} to " <>
  #       "#{requested}. leaf_average (the default) weighs progress by decomposition; " <>
  #       "single_level weighs each child equally per level. Approve only if you asked for " <>
  #       "this — decline otherwise."
  #
  #   case Elicitation.request(message, @confirm_schema, confirm_timeout()) do
  #     {:ok, %{"action" => "accept", "content" => %{"approve" => true}}} ->
  #       # Record the granted confirm for the session here (see
  #       # confirm_change/3) so a retry never re-asks the operator.
  #       :pass
  #
  #     _decline_disapprove_timeout_or_no_session ->
  #       {:refuse,
  #        "The operator did not approve the progress-calc change — progress_calc is " <>
  #          "unchanged and nothing was applied. Do not retry without the operator's request."}
  #   end
  # end

  # CALC-GATE-PARKED (m03.04): served the gate's elicitation. Revive with the
  # gate.
  # defp confirm_timeout do
  #   Application.get_env(:doit_mcp, :calc_gate_confirm_timeout, @confirm_timeout)
  # end
end
