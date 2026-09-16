defmodule DoItWeb.Api.Identity do
  @moduledoc """
  The acting user's own identity shape, shared by every surface that reports
  "who am I": `GET /api/v1/me` (bearer) and `GET /app/api/session` (browser
  session, m04.01 worklist 5). One definition, so the two can't drift.
  """

  alias DoIt.Accounts.User

  @doc "The acting user as the API reports them."
  @spec user(User.t()) :: map()
  def user(%User{} = user) do
    %{
      id: user.id,
      email: user.email,
      username: user.username,
      name: user.name
    }
  end
end
