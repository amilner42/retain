defmodule Retain.Migrations.V01 do
  @moduledoc false
  use Ecto.Migration

  def up(_opts) do
    create table(:retain_users) do
      add :scope, :string, null: false
      add :uid, :string, null: false
      add :tz, :string, null: false
      add :new_per_day, :integer, null: false, default: 10

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:retain_users, [:scope, :uid])

    create table(:retain_items) do
      add :user_id, references(:retain_users, on_delete: :delete_all), null: false
      add :key, :string, null: false, size: 1024
      add :tags, :map, null: false, default: %{}
      add :content, :map, null: false, default: %{}
      add :position, :integer
      add :suspended, :boolean, null: false, default: false
      add :started_at, :utc_datetime_usec

      # Derived from retain_reviews; see Retain.Fold and Retain.rebuild/2.
      add :level, :integer, null: false, default: 0
      add :due, :utc_datetime_usec, null: false
      add :reps, :integer, null: false, default: 0
      add :lapses, :integer, null: false, default: 0
      add :last_reviewed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:retain_items, [:user_id, :key])
    create index(:retain_items, [:user_id, :suspended, :due, :level])
    create index(:retain_items, [:user_id, :started_at])
    create index(:retain_items, [:tags], using: :gin)

    create table(:retain_reviews) do
      add :item_id, references(:retain_items, on_delete: :delete_all), null: false
      add :outcome, :string, null: false
      add :at, :utc_datetime_usec, null: false
      add :meta, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:retain_reviews, [:item_id, :at])

    execute "COMMENT ON TABLE retain_users IS '1'"
  end

  def down(_opts) do
    drop table(:retain_reviews)
    drop table(:retain_items)
    drop table(:retain_users)
  end
end
