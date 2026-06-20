defmodule DoIt.Accounts.UserPreferences do
  @moduledoc """
  Per-user preferences (m02.04 § User Preferences) — one row per user,
  created lazily on first save. Nil sort/calc values mean "no preference":
  the app behaves exactly as it would without a row.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Tasks.Task

  @index_sort_modes ~w(manual name progress created updated)
  @progress_calcs ~w(leaf_average single_level)
  @task_priorities ~w(match_parent low normal high)

  schema "user_preferences" do
    belongs_to :user, DoIt.Accounts.User

    field :index_sort_mode, :string
    # Reverse is remembered per mode (key = mode, "" for the default
    # "Recent"), matching the index control's shipped behavior.
    field :index_sort_reverse_by_mode, :map, default: %{}

    field :initiative_sort_mode, :string
    field :initiative_sort_reverse, :boolean, default: false
    field :initiative_progress_calc, :string
    field :initiative_auto_promote, :boolean, default: false
    # Seeds initiatives.viewer_plus on create (m02.05 item 12.6); default ON.
    field :initiative_viewer_plus, :boolean, default: true

    field :task_sort_mode, :string, default: "match_parent"
    field :task_priority, :string, default: "normal"
    field :task_assign_owner, :boolean, default: false

    field :show_task_activity, :boolean, default: true
    field :show_task_priority, :boolean, default: true
    field :show_task_assignee, :boolean, default: true
    # Checkbox + progress bar as one element.
    field :show_task_progress, :boolean, default: true
    # The chevron's leaf / child count badge.
    field :show_task_count, :boolean, default: true

    # Group-by-Initiative toggle for the Assigned-to-Me page (m02.08 worklist 1
    # item 6) — persistent, account-following. Off = a flat list.
    field :assigned_group_by_initiative, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def index_sort_modes, do: @index_sort_modes
  def progress_calcs, do: @progress_calcs
  def task_priorities, do: @task_priorities

  def changeset(prefs, attrs) do
    prefs
    |> cast(attrs, [
      :index_sort_mode,
      :index_sort_reverse_by_mode,
      :initiative_sort_mode,
      :initiative_sort_reverse,
      :initiative_progress_calc,
      :initiative_auto_promote,
      :initiative_viewer_plus,
      :task_sort_mode,
      :task_priority,
      :task_assign_owner,
      :show_task_activity,
      :show_task_priority,
      :show_task_assignee,
      :show_task_progress,
      :show_task_count,
      :assigned_group_by_initiative
    ])
    |> validate_inclusion(:index_sort_mode, [nil | @index_sort_modes])
    |> validate_change(:index_sort_reverse_by_mode, fn _, map ->
      if is_map(map) and Enum.all?(map, fn {k, v} -> is_binary(k) and is_boolean(v) end),
        do: [],
        else: [index_sort_reverse_by_mode: "is invalid"]
    end)
    |> validate_inclusion(:initiative_sort_mode, [nil | Task.sort_modes()])
    |> validate_inclusion(:initiative_progress_calc, [nil | @progress_calcs])
    |> validate_inclusion(:task_sort_mode, ["match_parent" | Task.sort_modes()])
    |> validate_inclusion(:task_priority, @task_priorities)
    |> unique_constraint(:user_id)
  end
end
