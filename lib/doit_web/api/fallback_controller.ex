defmodule DoItWeb.Api.FallbackController do
  @moduledoc """
  Translates the `{:error, reason}` tuples that API controllers return into the
  documented single-error JSON shape (m03.01 worklist 1.4 / 1.6).

  Wire it into a controller with `action_fallback DoItWeb.Api.FallbackController`
  and let actions simply return `{:error, :forbidden}` (etc.) — the 403 path,
  reused unchanged by worklists 2 and 3, lands here. Authorization itself runs
  through the existing role checks (`DoItWeb.Api.Authz` over the
  `DoIt.Initiatives` `can_view?`/`can_edit?`/`can_admin?` predicates); this
  controller only renders the denial.
  """
  use Phoenix.Controller, formats: [:json]

  alias DoItWeb.Api.Errors

  def call(conn, {:error, :unauthorized}) do
    Errors.send_error(conn, 401, :unauthorized, "Missing or invalid bearer token.")
  end

  def call(conn, {:error, :forbidden}) do
    Errors.send_error(conn, 403, :forbidden, "You don't have permission to perform this action.")
  end

  def call(conn, {:error, :not_found}) do
    Errors.send_error(conn, 404, :not_found, "Not found.")
  end

  def call(conn, {:error, :rate_limited}) do
    Errors.send_error(conn, 429, :rate_limited, "Rate limit exceeded. Try again later.")
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    Errors.send_error(conn, 422, :unprocessable_entity, changeset_message(changeset))
  end

  # A bare reason atom we don't have a specific clause for → 422.
  def call(conn, {:error, reason}) when is_atom(reason) do
    Errors.send_error(conn, 422, :unprocessable_entity, humanize(reason))
  end

  # Collapse changeset errors into a single human message for the single-error
  # shape. (The per-op endpoint in worklist 3 reports field pointers instead.)
  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field} #{Enum.join(errors, ", ")}" end)
  end

  defp humanize(reason), do: reason |> to_string() |> String.replace("_", " ")
end
