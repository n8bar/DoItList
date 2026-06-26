defmodule DoItWeb.Api.Authz do
  @moduledoc """
  Authorization for the API, reusing the **existing** Initiative role checks
  unchanged (m03.01 worklist 1.4).

  A token only identifies the acting user; it adds no authorization layer. This
  module resolves the user's role on an Initiative and runs it through the same
  `DoIt.Initiatives` predicates the LiveView uses — `can_view?/1`,
  `can_edit?/1`, `can_admin?/1`. A denial returns `{:error, :forbidden}`, which
  `DoItWeb.Api.FallbackController` renders as a 403.

  Worklists 2 and 3 call `authorize/3` before reading or mutating an Initiative;
  worklist 1 ships the helper + its 403 path with no Initiative-scoped endpoint
  yet beyond `/me`.
  """

  alias DoIt.Accounts.User
  alias DoIt.Initiatives
  alias DoIt.Initiatives.Initiative

  @type capability :: :view | :edit | :admin

  @doc """
  Return `:ok` if `user` holds `capability` on `initiative`, else
  `{:error, :forbidden}`. `capability` is one of `:view`, `:edit`, `:admin`.
  """
  def authorize(%User{} = user, %Initiative{} = initiative, capability)
      when capability in [:view, :edit, :admin] do
    role = Initiatives.get_role(initiative.id, user.id)
    if permitted?(role, capability), do: :ok, else: {:error, :forbidden}
  end

  defp permitted?(role, :view), do: Initiatives.can_view?(role)
  defp permitted?(role, :edit), do: Initiatives.can_edit?(role)
  defp permitted?(role, :admin), do: Initiatives.can_admin?(role)
end
