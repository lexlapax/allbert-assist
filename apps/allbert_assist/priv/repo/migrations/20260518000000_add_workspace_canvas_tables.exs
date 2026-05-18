defmodule AllbertAssist.Repo.Migrations.AddWorkspaceCanvasTables do
  use Ecto.Migration

  def up do
    create table(:workspace_canvas_tiles, primary_key: false) do
      add :id, :string, primary_key: true
      add :thread_id, :string, null: false
      add :user_id, :string, null: false
      add :kind, :string, null: false
      add :position, :integer, null: false, default: 0
      add :size_width, :integer, null: false, default: 400
      add :size_height, :integer, null: false, default: 300
      add :body_yaml_path, :string, null: false
      add :pinned, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspace_canvas_tiles, [:thread_id, :user_id],
             name: :workspace_canvas_tiles_thread_user_idx
           )

    create index(:workspace_canvas_tiles, [:user_id, :updated_at],
             name: :workspace_canvas_tiles_user_updated_idx
           )

    create index(:workspace_canvas_tiles, [:thread_id, :position],
             name: :workspace_canvas_tiles_thread_position_idx
           )

    create table(:workspace_canvas_tile_revisions, primary_key: false) do
      add :id, :string, primary_key: true

      add :tile_id, references(:workspace_canvas_tiles, type: :string, on_delete: :delete_all),
        null: false

      add :base_revision_id, :string
      add :yjs_update, :binary
      add :state_vector, :binary
      add :text_snapshot, :text
      add :snapshot_yaml_path, :string
      add :origin, :string, null: false
      add :conflict_count, :integer, null: false, default: 0
      add :authored_by, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspace_canvas_tile_revisions, [:tile_id, :inserted_at],
             name: :workspace_canvas_tile_revisions_tile_inserted_idx
           )

    create index(:workspace_canvas_tile_revisions, [:tile_id, :base_revision_id],
             name: :workspace_canvas_tile_revisions_tile_base_idx
           )

    alter table(:workspace_canvas_tiles) do
      add :current_revision_id,
          references(:workspace_canvas_tile_revisions, type: :string, on_delete: :nilify_all)
    end

    create table(:workspace_ephemeral_surfaces, primary_key: false) do
      add :id, :string, primary_key: true
      add :thread_id, :string, null: false
      add :user_id, :string, null: false
      add :kind, :string, null: false
      add :body_yaml_path, :string, null: false
      add :pinned, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}
      add :opened_at, :utc_datetime_usec, null: false
      add :dismissed_at, :utc_datetime_usec
      add :dismissed_by, :string
    end

    create index(:workspace_ephemeral_surfaces, [:thread_id, :user_id],
             name: :workspace_ephemeral_surfaces_thread_user_idx
           )

    create index(:workspace_ephemeral_surfaces, [:user_id, :opened_at],
             name: :workspace_ephemeral_surfaces_user_opened_idx
           )
  end

  def down do
    drop_if_exists index(:workspace_ephemeral_surfaces, [:user_id, :opened_at],
                     name: :workspace_ephemeral_surfaces_user_opened_idx
                   )

    drop_if_exists index(:workspace_ephemeral_surfaces, [:thread_id, :user_id],
                     name: :workspace_ephemeral_surfaces_thread_user_idx
                   )

    drop table(:workspace_ephemeral_surfaces)

    drop_if_exists index(:workspace_canvas_tile_revisions, [:tile_id, :base_revision_id],
                     name: :workspace_canvas_tile_revisions_tile_base_idx
                   )

    drop_if_exists index(:workspace_canvas_tile_revisions, [:tile_id, :inserted_at],
                     name: :workspace_canvas_tile_revisions_tile_inserted_idx
                   )

    drop table(:workspace_canvas_tile_revisions)

    drop_if_exists index(:workspace_canvas_tiles, [:thread_id, :position],
                     name: :workspace_canvas_tiles_thread_position_idx
                   )

    drop_if_exists index(:workspace_canvas_tiles, [:user_id, :updated_at],
                     name: :workspace_canvas_tiles_user_updated_idx
                   )

    drop_if_exists index(:workspace_canvas_tiles, [:thread_id, :user_id],
                     name: :workspace_canvas_tiles_thread_user_idx
                   )

    drop table(:workspace_canvas_tiles)
  end
end
