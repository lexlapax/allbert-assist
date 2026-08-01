defmodule AllbertAssist.Repo.Migrations.AddConfirmationResumeBindingToObjectiveSteps do
  use Ecto.Migration

  def change do
    alter table(:objective_steps) do
      add :confirmation_resume_params_sha256, :string
    end
  end
end
