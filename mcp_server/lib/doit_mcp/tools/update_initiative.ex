defmodule DoitMcp.Tools.UpdateInitiative do
  @moduledoc """
  Content-only edit of an Initiative's fields (name, description, subtitle,
  progress calc, index style, AI knobs, auto-promote co-assignees, viewer+).
  `description` and `subtitle` accept `%<task_id>` cross-reference tokens.
  This tool does NOT touch state (archived/hidden/trashed — see
  `set_initiative_state`) or ownership — those are rejected here or
  handled elsewhere.

  ## Progress-calc gate (m03.04 fix 17)

  A `progress_calc` CHANGE to a non-default value is held for the operator's
  confirm before it applies: the server elicits a yes/no from the operator
  (once per Initiative per value per session), because only a human can know
  whether they actually asked for it. Setting it back to `leaf_average` (the
  default), or re-sending the current value, applies ungated. Clients without
  elicitation support get a refusal naming the in-app control instead.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.{Client, Elicitation, ToolResult}
  alias DoitMcp.ImportGate.Counter

  @default_calc "leaf_average"

  # A human is reading one question — same generous window as the import gate.
  @confirm_timeout to_timeout(minute: 5)

  @confirm_schema %{
    "type" => "object",
    "properties" => %{
      "approve" => %{
        "type" => "boolean",
        "description" => "true switches the progress calculation; false leaves it unchanged"
      }
    },
    "required" => ["approve"]
  }

  schema do
    field(:initiative_id, :integer, required: true)
    field(:name, :string, required: false)
    field(:description, :string, required: false)
    field(:subtitle, :string, required: false)

    field(:progress_calc, :string,
      required: false,
      description:
        "leaf_average (default) weighs progress by decomposition and prevails unless the " <>
          "OPERATOR asked otherwise; single_level's one trigger is completed work riding as " <>
          "single done leaves that leaf_average would hide — never pick it to \"equalize\" " <>
          "differently-sized siblings (decomposition IS the weighting). A change to " <>
          "non-default is held for the operator's confirm"
    )

    field(:index_style, :string, required: false)

    field(:ai_knobs, :string,
      required: false,
      description:
        "Per-project agent settings store — structure/scope/style knobs for this Initiative " <>
          "only; plain text the product stores but never interprets"
    )

    field(:auto_promote_co_assignees, :boolean, required: false)
    field(:viewer_plus, :boolean, required: false)
  end

  def execute(params, frame) do
    case calc_gate(params) do
      :pass -> do_update(params, frame)
      {:refuse, message} -> {:reply, Response.error(Response.tool(), message), frame}
    end
  end

  defp do_update(params, frame) do
    data =
      params
      |> Map.take([
        :name,
        :description,
        :subtitle,
        :progress_calc,
        :index_style,
        :ai_knobs,
        :auto_promote_co_assignees,
        :viewer_plus
      ])
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    [%{"op" => "update", "type" => "initiative", "id" => params.initiative_id, "data" => data}]
    |> Client.operations()
    |> then(&ToolResult.reply(frame, &1))
  end

  # The gate only ever engages on a calc CHANGE to non-default; a params map
  # without progress_calc (or returning to the default) takes zero extra
  # round trips.
  defp calc_gate(params) do
    case Map.get(params, :progress_calc) do
      nil -> :pass
      @default_calc -> :pass
      requested -> gate_non_default(params.initiative_id, requested)
    end
  end

  defp gate_non_default(initiative_id, requested) do
    case Client.get("/api/v1/initiatives/#{initiative_id}") do
      {:ok, %{"progress_calc" => current}} when current != requested ->
        confirm_change(initiative_id, current, requested)

      # Same value (no change happening) — or a fetch error / shape we can't
      # read, where the update itself will surface the real error.
      _ ->
        :pass
    end
  end

  defp confirm_change(initiative_id, current, requested) do
    cond do
      Counter.confirmed?({:progress_calc, initiative_id, requested}) ->
        :pass

      not Elicitation.client_supports_elicitation?() ->
        {:refuse,
         "Changing progress_calc to \"#{requested}\" needs the operator's confirmation, and " <>
           "this client cannot ask them (no elicitation support). Not applied. The operator " <>
           "can set it themselves in the app: Initiative details pane → settings, the " <>
           "progress-calculation control. Do not retry without the operator's request."}

      true ->
        elicit_approval(initiative_id, current, requested)
    end
  end

  defp elicit_approval(initiative_id, current, requested) do
    message =
      "The agent asks to switch this Initiative's progress calculation from #{current} to " <>
        "#{requested}. leaf_average (the default) weighs progress by decomposition; " <>
        "single_level weighs each child equally per level. Approve only if you asked for " <>
        "this — decline otherwise."

    case Elicitation.request(message, @confirm_schema, confirm_timeout()) do
      {:ok, %{"action" => "accept", "content" => %{"approve" => true}}} ->
        # Remembered for the session so a retry after a granted confirm (e.g.
        # the update itself failed) never re-asks the operator.
        Counter.mark_confirmed({:progress_calc, initiative_id, requested})
        :pass

      _decline_disapprove_timeout_or_no_session ->
        {:refuse,
         "The operator did not approve the progress-calc change — progress_calc is " <>
           "unchanged and nothing was applied. Do not retry without the operator's request."}
    end
  end

  defp confirm_timeout do
    Application.get_env(:doit_mcp, :calc_gate_confirm_timeout, @confirm_timeout)
  end
end
