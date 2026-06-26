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

  @doc """
  Load `id` and authorize `user` for `capability` in one step — the single place
  the read controllers' **404-vs-403 policy** lives.

    * A non-integer / unknown id → `{:error, :not_found}` (404). A garbage id
      never raises an Ecto cast error — it's parsed defensively first.
    * The Initiative exists but `user` lacks `capability` → `{:error, :forbidden}`
      (403). A stranger hitting a real Initiative is denied at the role check,
      not leaked a 404-vs-403 oracle beyond "you can't view this".
    * Otherwise `{:ok, %Initiative{}}`.

  `capability` defaults to `:view` — the whole read surface is view-gated.
  """
  def fetch_initiative(%User{} = user, id, capability \\ :view) do
    case parse_id(id) do
      nil ->
        {:error, :not_found}

      int_id ->
        case Initiatives.get_initiative(int_id) do
          nil ->
            {:error, :not_found}

          %Initiative{} = initiative ->
            with :ok <- authorize(user, initiative, capability), do: {:ok, initiative}
        end
    end
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  defp permitted?(role, :view), do: Initiatives.can_view?(role)
  defp permitted?(role, :edit), do: Initiatives.can_edit?(role)
  defp permitted?(role, :admin), do: Initiatives.can_admin?(role)
end
