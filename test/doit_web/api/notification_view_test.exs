defmodule DoItWeb.Api.NotificationViewTest do
  @moduledoc """
  The one place a notification becomes a line of text and a link (m04.01 item
  4.6.1). Pure: no database, no connection — a struct in, a map out.
  """
  use ExUnit.Case, async: true

  alias DoIt.Notifications
  alias DoIt.Notifications.Notification
  alias DoItWeb.Api.NotificationView

  defp notif(kind, data, opts \\ []) do
    %Notification{
      id: Keyword.get(opts, :id, 7),
      kind: kind,
      data: data,
      read_at: Keyword.get(opts, :read_at),
      inserted_at: ~U[2026-09-16 10:00:00Z]
    }
  end

  describe "line/1" do
    test "says who did what, in one line, for every kind we generate" do
      for kind <- Notifications.kinds() do
        line = NotificationView.line(notif(kind, %{"actor_name" => "Dana", "role" => "editor"}))
        assert is_binary(line) and String.trim(line) != ""
        assert String.starts_with?(line, "Dana")
      end
    end

    test "names the task when there is one, and stays readable when there isn't" do
      assert NotificationView.line(
               notif("assigned", %{"actor_name" => "Dana", "task_title" => "Ship it"})
             ) == "Dana assigned you “Ship it”"

      assert NotificationView.line(notif("assigned", %{"actor_name" => "Dana"})) ==
               "Dana assigned you a task"
    end

    test "falls back to Someone when the actor is not recorded" do
      assert NotificationView.line(notif("member_added", %{})) ==
               "Someone added you to an Initiative"
    end

    test "carries the new role when a role changed" do
      assert NotificationView.line(
               notif("role_changed", %{"actor_name" => "Dana", "role" => "editor"})
             ) == "Dana changed your role to editor in an Initiative"
    end
  end

  describe "href/1" do
    test "deep links the task through the CLIENT's routes" do
      assert NotificationView.href(notif("assigned", %{"initiative_id" => 3, "task_id" => 9})) ==
               "/app/initiatives/3?task=9"
    end

    test "falls back to the Initiative, then to the index" do
      assert NotificationView.href(notif("member_added", %{"initiative_id" => 3})) ==
               "/app/initiatives/3"

      assert NotificationView.href(notif("member_added", %{})) == "/app/initiatives"
    end
  end

  describe "summary/1" do
    test "is the row the flyout renders, with read as a boolean" do
      assert NotificationView.summary(
               notif("assigned", %{"actor_name" => "Dana", "initiative_id" => 3, "task_id" => 9},
                 id: 42
               )
             ) == %{
               id: 42,
               kind: "assigned",
               line: "Dana assigned you a task",
               href: "/app/initiatives/3?task=9",
               read: false,
               inserted_at: "2026-09-16T10:00:00Z"
             }
    end

    test "a notification with a read_at is read" do
      row = NotificationView.summary(notif("assigned", %{}, read_at: ~U[2026-09-16 11:00:00Z]))
      assert row.read == true
    end
  end
end
