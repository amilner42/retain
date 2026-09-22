defmodule Retain.Migrations.V02 do
  @moduledoc false
  use Ecto.Migration

  # `retain_items` indexes. V01 indexed [user_id, suspended, due, level], which can serve
  # `due/2`'s filter but never its `ORDER BY level, due` — so every session sorted the user's
  # whole active set. These two partial indexes match the two hot queries column for column.
  @due_index "retain_items_due_index"
  @new_index "retain_items_new_index"

  def up(_opts) do
    alter table(:retain_reviews) do
      add :until, :utc_datetime_usec
      add :supersedes_id, references(:retain_reviews, on_delete: :delete_all)
    end

    create index(:retain_reviews, [:supersedes_id], where: "supersedes_id IS NOT NULL")

    drop index(:retain_items, [:user_id, :suspended, :due, :level])

    create index(:retain_items, [:user_id, :level, :due, :id],
             where: "suspended = false AND started_at IS NOT NULL",
             name: @due_index
           )

    create index(:retain_items, [:user_id, :position, :inserted_at, :id],
             where: "started_at IS NULL AND suspended = false",
             name: @new_index
           )

    execute "COMMENT ON TABLE retain_users IS '2'"
  end

  def down(_opts) do
    drop index(:retain_items, [:user_id, :position, :inserted_at, :id], name: @new_index)
    drop index(:retain_items, [:user_id, :level, :due, :id], name: @due_index)
    create index(:retain_items, [:user_id, :suspended, :due, :level])

    drop index(:retain_reviews, [:supersedes_id], where: "supersedes_id IS NOT NULL")

    alter table(:retain_reviews) do
      remove :supersedes_id
      remove :until
    end

    execute "COMMENT ON TABLE retain_users IS '1'"
  end
end
