defmodule Retain.Migrations.V02 do
  @moduledoc false
  use Ecto.Migration

  # Items can now be in the map without being in rotation (`started_at` nil), have an
  # introduction order (`position`), and users have a daily budget of new items.
  def up(_opts) do
    alter table(:retain_users) do
      add :new_per_day, :integer, null: false, default: 10
    end

    alter table(:retain_items) do
      add :started_at, :utc_datetime_usec
      add :position, :integer
    end

    # Everything that existed before this version was in rotation from creation.
    execute "UPDATE retain_items SET started_at = inserted_at"

    create index(:retain_items, [:user_id, :started_at])

    execute "COMMENT ON TABLE retain_users IS '2'"
  end

  def down(_opts) do
    drop index(:retain_items, [:user_id, :started_at])

    alter table(:retain_items) do
      remove :started_at
      remove :position
    end

    alter table(:retain_users) do
      remove :new_per_day
    end

    execute "COMMENT ON TABLE retain_users IS '1'"
  end
end
