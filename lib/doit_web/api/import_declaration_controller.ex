defmodule DoItWeb.Api.ImportDeclarationController do
  @moduledoc """
  Recording a first-import declaration (m03.04 2.8.10):

    * `POST /api/v1/import_declarations` — `create`:
      `{"initiative_id": ..., "source_total": ..., "source_completed": ...,
      "excluded_count": ..., "exclusions": ..., "ordering": ...}`. The MCP
      adapter posts it once its arithmetic accepts the Initiative's first
      import; edit-gated through `Authz.fetch_initiative/3` like every write.
      Idempotent per `DoIt.ImportDeclarations.record/2` — the first
      declaration binds, a standing row returns as-is.

  Reading is not here: the adapter consults the declaration on the
  `task_count` read it already makes per target
  (`GET /api/v1/initiatives/:id/task_count`).
  """
  use DoItWeb, :controller

  alias DoIt.ImportDeclarations
  alias DoItWeb.Api
  alias DoItWeb.Api.{Authz, Errors, Serializer}

  action_fallback DoItWeb.Api.FallbackController

  def create(conn, %{"initiative_id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, initiative} <- Authz.fetch_initiative(user, id, :edit),
         {:ok, declaration} <- ImportDeclarations.record(initiative.id, params) do
      json(conn, Api.data(Serializer.import_declaration(declaration)))
    end
  end

  def create(conn, _params) do
    Errors.send_error(
      conn,
      422,
      :unprocessable_entity,
      "Request body must carry \"initiative_id\" plus the declaration fields " <>
        "(integer \"source_total\" and \"source_completed\"; optional integer " <>
        "\"excluded_count\", string \"exclusions\" and \"ordering\")."
    )
  end
end
