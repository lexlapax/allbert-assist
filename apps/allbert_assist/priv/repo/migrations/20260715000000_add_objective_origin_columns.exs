defmodule AllbertAssist.Repo.Migrations.AddObjectiveOriginColumns do
  use Ecto.Migration

  # v1.0.1 M4.2.3 (piece 4): objectives carry their originating channel and
  # surface so objective-driven work can stamp confirmation origin like a
  # turn-raised request. Additive only — existing columns untouched (v1 freeze).
  def up do
    alter table(:objectives) do
      add :source_channel, :string
      add :source_surface, :string
    end
  end

  def down do
    alter table(:objectives) do
      remove :source_surface
      remove :source_channel
    end
  end
end
