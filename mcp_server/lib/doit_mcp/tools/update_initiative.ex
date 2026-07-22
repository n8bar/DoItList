defmodule DoitMcp.Tools.UpdateInitiative do
  @moduledoc """
  Content-only edit of an Initiative's fields (name, description, subtitle,
  progress calc, index style, auto-promote co-assignees, viewer+).
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

  (An `ai_knobs` write gate is dormant while AI Knobs is parked — m03.04.)
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.{Client, Elicitation, ImportGate, ToolResult}
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

  @knobs_confirm_schema %{
    "type" => "object",
    "properties" => %{
      "approve" => %{
        "type" => "boolean",
        "description" => "true records the proposed ai_knobs text; false records nothing"
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

    # AI-KNOBS-PARKED (m03.04): the ai_knobs param is off the tool pending the
    # skill rebuild, so agents can't write knobs; the API rejects the field too.
    # The knobs_gate below goes dormant (no param → :pass). Revive this field +
    # the :ai_knobs entry in do_update's Map.take + the knobs_gate tests.
    # field(:ai_knobs, :string,
    #   required: false,
    #   description:
    #     "Per-project agent settings store: structure/scope/style knobs only, holding what has " <>
    #       "no first-class field (never duplicate progress_calc or index_style — the column is " <>
    #       "the record). The first write into empty knobs is held for the operator's confirm"
    # )

    field(:auto_promote_co_assignees, :boolean, required: false)
    field(:viewer_plus, :boolean, required: false)
  end

  def execute(params, frame) do
    with :pass <- calc_gate(params),
         :pass <- knobs_gate(params) do
      do_update(params, frame)
    else
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
        # AI-KNOBS-PARKED (m03.04): revive with the schema field above.
        # :ai_knobs,
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

  # The knobs gate only ever engages on a FIRST write — an ai_knobs param
  # against an Initiative whose stored knobs are still empty (fix 23:
  # self-written knobs must not settle the import gate unseen). No ai_knobs
  # param takes zero extra round trips.
  defp knobs_gate(params) do
    case Map.get(params, :ai_knobs) do
      nil -> :pass
      proposed -> gate_first_knobs_write(params.initiative_id, proposed)
    end
  end

  defp gate_first_knobs_write(initiative_id, proposed) do
    case Client.get("/api/v1/initiatives/#{initiative_id}") do
      {:ok, initiative} when is_map(initiative) ->
        if ImportGate.knobs_empty?(Map.get(initiative, "ai_knobs")) do
          confirm_first_knobs_write(initiative_id, proposed)
        else
          :pass
        end

      # A fetch error / shape we can't read — the update itself will surface
      # the real error.
      _ ->
        :pass
    end
  end

  defp confirm_first_knobs_write(initiative_id, proposed) do
    cond do
      Counter.confirmed?({:ai_knobs, initiative_id, proposed}) ->
        :pass

      not Elicitation.client_supports_elicitation?() ->
        {:refuse,
         "This Initiative's ai_knobs is empty, and its first write needs the operator's " <>
           "confirmation — this client cannot ask them (no elicitation support). Not " <>
           "applied. The operator can set it themselves in the app: Initiative details " <>
           "pane → settings, the AI knobs control. Do not retry without the operator's " <>
           "request."}

      true ->
        elicit_knobs_approval(initiative_id, proposed)
    end
  end

  defp elicit_knobs_approval(initiative_id, proposed) do
    message =
      "The agent asks to write this Initiative's first ai_knobs — its per-project agent " <>
        "settings. Recording them settles this Initiative's import conventions, so the " <>
        "import gate stops asking. Proposed knobs, verbatim:\n\n" <>
        proposed <>
        "\n\nApprove only if this matches what you want on record — decline records nothing."

    case Elicitation.request(message, @knobs_confirm_schema, confirm_timeout()) do
      {:ok, %{"action" => "accept", "content" => %{"approve" => true}}} ->
        # Remembered for the session so a retry after a granted confirm (e.g.
        # the update itself failed) never re-asks the operator.
        Counter.mark_confirmed({:ai_knobs, initiative_id, proposed})
        :pass

      _decline_disapprove_timeout_or_no_session ->
        {:refuse,
         "The operator did not approve the first ai_knobs write — nothing was recorded, " <>
           "the Initiative's knobs stay empty, and the import gate stays armed. Do not " <>
           "retry without the operator's request."}
    end
  end

  defp confirm_timeout do
    Application.get_env(:doit_mcp, :calc_gate_confirm_timeout, @confirm_timeout)
  end
end
