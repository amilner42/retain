defmodule Retain.Migration do
  @moduledoc """
  Creates and drops Retain's tables inside a host migration.

  Generate the host migration with `mix retain.gen.migration`, which produces:

      defmodule MyApp.Repo.Migrations.AddRetain do
        use Ecto.Migration

        def up, do: Retain.Migration.up()
        def down, do: Retain.Migration.down()
      end

  Migrations are versioned. `up/1` brings the schema to the latest version from whatever version
  is installed, so re-running the generator after upgrading Retain is safe.
  """
  use Ecto.Migration

  @versions [Retain.Migrations.V01]

  @doc "Migrates to the latest schema version."
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    installed = installed_version()

    @versions
    |> Enum.drop(installed)
    |> Enum.each(& &1.up(opts))

    :ok
  end

  @doc "Removes every Retain table."
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    @versions
    |> Enum.take(installed_version())
    |> Enum.reverse()
    |> Enum.each(& &1.down(opts))

    :ok
  end

  @doc "The latest schema version this release of Retain knows about."
  @spec latest_version() :: pos_integer()
  def latest_version, do: length(@versions)

  # Versions are recorded as a comment on the retain_users table, the way Oban does it, so no
  # extra bookkeeping table is needed.
  defp installed_version do
    query = """
    SELECT obj_description(c.oid, 'pg_class')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = 'retain_users' AND n.nspname = current_schema()
    """

    case repo().query!(query) do
      %{rows: [[comment]]} when is_binary(comment) -> String.to_integer(comment)
      _ -> 0
    end
  end
end
