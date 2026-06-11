defmodule DoIt.Repo.Migrations.RenameFirstGenerationToSingleLevel do
  use Ecto.Migration

  def up do
    execute(
      "UPDATE initiatives SET progress_calc = 'single_level' WHERE progress_calc = 'first_generation'"
    )
  end

  def down do
    execute(
      "UPDATE initiatives SET progress_calc = 'first_generation' WHERE progress_calc = 'single_level'"
    )
  end
end
