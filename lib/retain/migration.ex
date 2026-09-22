defmodule Retain.Migration do
  @moduledoc """
  Creates, upgrades and drops Retain's tables inside a host migration.

  Generate the host migration with `mix retain.gen.migration`, which produces:

      defmodule MyApp.Repo.Migrations.AddRetainV01 do
        use Ecto.Migration

        def up, do: Retain.Migration.up(version: 1)
        def down, do: Retain.Migration.down(version: 0)
      end

  Retain's schema is versioned; the installed version is recorded on the `retain_users` table.
  `up/1` applies every version newer than the installed one, up to `version:` (default: the
  latest). `down/1` reverts to `version:` (default: 0, which drops everything). Re-running the
  generator after upgrading Retain produces a migration that applies only what is new.
  """
  use Ecto.Migration

  @versions [Retain.Migrations.V01, Retain.Migrations.V02]

  @doc "Migrates from the installed version up to `version:` (default: latest)."
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    target = Keyword.get(opts, :version, latest_version())
    installed = installed_version()

    if target > installed do
      @versions
      |> Enum.slice(installed, target - installed)
      |> Enum.each(& &1.up(opts))
    end

    :ok
  end

  @doc "Reverts from the installed version down to `version:` (default: 0, nothing installed)."
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    target = Keyword.get(opts, :version, 0)
    installed = installed_version()

    if target < installed do
      @versions
      |> Enum.slice(target, installed - target)
      |> Enum.reverse()
      |> Enum.each(& &1.down(opts))
    end

    :ok
  end

  @doc "The latest schema version this release of Retain knows about."
  @spec latest_version() :: pos_integer()
  def latest_version, do: length(@versions)

  # The version is a comment on the retain_users table, the way Oban does it, so no extra
  # bookkeeping table is needed. Each version's migration sets it.
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
