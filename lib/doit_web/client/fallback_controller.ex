defmodule DoItWeb.Client.FallbackController do
  @moduledoc """
  Renders the `{:error, reason}` tuples the `/app/api` controllers return
  (m04.01 worklist 5).

  Everything but the 401 message is `DoItWeb.Api.FallbackController` verbatim —
  the 403/404/409/422 vocabulary is shared, so the two surfaces can't drift.
  Only `:unauthorized` is overridden: the browser is told to sign in, not to
  present a bearer token it is never supposed to hold.
  """
  use Phoenix.Controller, formats: [:json]

  alias DoItWeb.Api.FallbackController
  alias DoItWeb.Client.Api

  def call(conn, {:error, :unauthorized}), do: Api.unauthorized(conn)
  def call(conn, other), do: FallbackController.call(conn, other)
end
