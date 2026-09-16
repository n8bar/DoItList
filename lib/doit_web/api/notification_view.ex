defmodule DoItWeb.Api.NotificationView do
  @moduledoc """
  A notification as the browser client reads it (m04.01 item 4.6.1).

  One line of text and one link, computed HERE — the same sentences the
  LiveView flyout shows (`DoItWeb.Layouts`' `notif_line/1` and `notif_href/1`),
  so the two clients cannot end up describing the same event differently and
  the React client never re-implements the wording in TypeScript.

  The only deliberate difference is the link: this surface belongs to the
  client at `/app`, so a row links to the client's own route
  (`/app/initiatives/3?task=9`) rather than the LiveView's.

  Pure: a struct in, a map out. No database, no connection.
  """

  alias DoIt.Notifications.Notification

  @doc "The row `GET /app/api/notifications` and the `notification` push carry."
  @spec summary(Notification.t() | map()) :: map()
  def summary(%{id: id, kind: kind, read_at: read_at, inserted_at: inserted_at} = notification) do
    %{
      id: id,
      kind: kind,
      line: line(notification),
      href: href(notification),
      read: not is_nil(read_at),
      inserted_at: iso8601(inserted_at)
    }
  end

  @doc "One-line, human description of a notification."
  @spec line(map()) :: String.t()
  def line(%{kind: kind} = notification) do
    data = notification.data || %{}
    who = Map.get(data, "actor_name") || "Someone"
    title = Map.get(data, "task_title")
    role = Map.get(data, "role")

    case kind do
      "member_added" -> "#{who} added you to an Initiative"
      "member_removed" -> "#{who} removed you from an Initiative"
      "role_changed" -> "#{who} changed your role to #{role || "a new role"} in an Initiative"
      "assigned" -> "#{who} assigned you " <> task_phrase(title)
      "unassigned" -> "#{who} unassigned you from " <> task_phrase(title)
      "co_assigned" -> "#{who} added you as a co-assignee on " <> task_phrase(title)
      "co_unassigned" -> "#{who} removed you as a co-assignee from " <> task_phrase(title)
      _ -> "#{who} updated something"
    end
  end

  @doc """
  Where a notification row links, as a CLIENT path: the deep-linked task when
  one is recorded, else the Initiative, else the index.
  """
  @spec href(map()) :: String.t()
  def href(notification) do
    data = notification.data || %{}

    case {Map.get(data, "initiative_id"), Map.get(data, "task_id")} do
      {nil, _} -> "/app/initiatives"
      {initiative_id, nil} -> "/app/initiatives/#{initiative_id}"
      {initiative_id, task_id} -> "/app/initiatives/#{initiative_id}?task=#{task_id}"
    end
  end

  defp task_phrase(nil), do: "a task"
  defp task_phrase(title), do: "“#{title}”"

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt) <> "Z"
  defp iso8601(other), do: other
end
