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
    field :index_sort_reverse, :boolean, default: false

    field :initiative_sort_mode, :string
    field :initiative_sort_reverse, :boolean, default: false
    field :initiative_progress_calc, :string

    field :task_sort_mode, :string, default: "match_parent"
    field :task_priority, :string, default: "normal"
    field :task_assign_owner, :boolean, default: false

    field :show_task_activity, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def index_sort_modes, do: @index_sort_modes
  def progress_calcs, do: @progress_calcs
  def task_priorities, do: @task_priorities

  def changeset(prefs, attrs) do
    prefs
    |> cast(attrs, [
      :index_sort_mode,
      :index_sort_reverse,
      :initiative_sort_mode,
      :initiative_sort_reverse,
      :initiative_progress_calc,
      :task_sort_mode,
      :task_priority,
      :task_assign_owner,
      :show_task_activity
    ])
    |> validate_inclusion(:index_sort_mode, [nil | @index_sort_modes])
    |> validate_inclusion(:initiative_sort_mode, [nil | Task.sort_modes()])
    |> validate_inclusion(:initiative_progress_calc, [nil | @progress_calcs])
    |> validate_inclusion(:task_sort_mode, ["match_parent" | Task.sort_modes()])
    |> validate_inclusion(:task_priority, @task_priorities)
    |> unique_constraint(:user_id)
  end
end
