defmodule DoIt.Tasks.CoalesceBroadcastsTest do
  @moduledoc """
  `DoIt.Tasks.coalesce_task_broadcasts/1` (m03.03 item 5.8.2) — collapsing a
  committed batch's per-op broadcast queue into per-batch signals. Pure
  function over `{topic, message}` entries; no DB.
  """
  use ExUnit.Case, async: true

  alias DoIt.Tasks

  @topic "initiative:1"
  @other_topic "initiative:2"

  test "N task_created on one topic collapse to the first one" do
    entries = for id <- 1..5, do: {@topic, {:task_created, id}}

    assert Tasks.coalesce_task_broadcasts(entries) == [{@topic, {:task_created, 1}}]
  end

  test "reload kinds are kept one per KIND (created/moved/deleted stay distinct)" do
    entries = [
      {@topic, {:task_created, 1}},
      {@topic, {:task_moved, 2}},
      {@topic, {:task_created, 3}},
      {@topic, {:task_deleted, 4}},
      {@topic, {:task_moved, 5}}
    ]

    assert Tasks.coalesce_task_broadcasts(entries) == [
             {@topic, {:task_created, 1}},
             {@topic, {:task_moved, 2}},
             {@topic, {:task_deleted, 4}}
           ]
  end

  test "task_updated is dropped when the topic also carries a full-reload kind" do
    entries = [
      {@topic, {:task_updated, 10}},
      {@topic, {:task_created, 1}},
      {@topic, {:task_updated, 11}}
    ]

    assert Tasks.coalesce_task_broadcasts(entries) == [{@topic, {:task_created, 1}}]
  end

  test "task_updated dedupes by id when no reload kind rides the topic" do
    entries = [
      {@topic, {:task_updated, 10}},
      {@topic, {:task_updated, 11}},
      {@topic, {:task_updated, 10}}
    ]

    assert Tasks.coalesce_task_broadcasts(entries) == [
             {@topic, {:task_updated, 10}},
             {@topic, {:task_updated, 11}}
           ]
  end

  test "topics are independent — a reload on one topic doesn't eat another's patches" do
    entries = [
      {@topic, {:task_created, 1}},
      {@other_topic, {:task_updated, 20}},
      {@topic, {:task_updated, 2}}
    ]

    assert Tasks.coalesce_task_broadcasts(entries) == [
             {@topic, {:task_created, 1}},
             {@other_topic, {:task_updated, 20}}
           ]
  end

  test "comment signals dedupe by task, across both comment kinds independently" do
    entries = [
      {@topic, {:comment_added, 7}},
      {@topic, {:comment_added, 7}},
      {@topic, {:comment_added, 8}},
      {@topic, {:comment_changed, 7}}
    ]

    assert Tasks.coalesce_task_broadcasts(entries) == [
             {@topic, {:comment_added, 7}},
             {@topic, {:comment_added, 8}},
             {@topic, {:comment_changed, 7}}
           ]
  end

  test "unknown kinds, notification payloads, and after_commit markers pass through in order" do
    fun = fn -> :ok end

    entries = [
      {@topic, {:members_changed, 1}},
      {:after_commit, fun},
      {"user:9", {:notification, %{id: 42}}},
      {@topic, {:members_changed, 1}},
      {@topic, {:initiative_updated, 1}}
    ]

    # members_changed carries no per-op payload, but it isn't a task-tree
    # message — the coalescer passes every copy through untouched.
    assert Tasks.coalesce_task_broadcasts(entries) == entries
  end

  test "empty queue coalesces to empty" do
    assert Tasks.coalesce_task_broadcasts([]) == []
  end
end
