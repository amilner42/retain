defmodule Mix.Tasks.Retain.Gen.Migration do
  @shortdoc "Generates the migration that creates Retain's tables"

  @moduledoc """
  Generates a migration in the host app that installs (or upgrades) Retain's tables.

      $ mix retain.gen.migration
      $ mix retain.gen.migration -r MyApp.OtherRepo

  The generated file delegates to `Retain.Migration`, so re-running this after upgrading Retain
  produces a migration that applies only what is new -- and rolls back to exactly where the host
  was before it, which for a first install is nothing at all:

      # first install
      def up, do: Retain.Migration.up(version: 2)
      def down, do: Retain.Migration.down(version: 0)

      # later, upgrading a host that already has v02
      def up, do: Retain.Migration.up(version: 3)
      def down, do: Retain.Migration.down(version: 2)

  "Where the host was before" is read from the migrations already in the repo's path, so no
  database connection is needed to generate one.
  """
  use Mix.Task

  import Mix.Ecto
  import Mix.Generator

  @impl Mix.Task
  def run(args) do
    no_umbrella!("retain.gen.migration")

    repo = args |> parse_repo() |> List.first()
    ensure_repo(repo, args)

    path = Ecto.Migrator.migrations_path(repo)
    version = Retain.Migration.latest_version()
    previous = installed_here(path)
    name = "add_retain_v#{String.pad_leading(Integer.to_string(version), 2, "0")}"
    file = Path.join(path, "#{timestamp()}_#{name}.exs")

    create_directory(path)

    create_file(file, """
    defmodule #{inspect(repo)}.Migrations.#{Macro.camelize(name)} do
      use Ecto.Migration

      def up, do: Retain.Migration.up(version: #{version})
      def down, do: Retain.Migration.down(version: #{previous})
    end
    """)
  end

  # The newest Retain version this host has already generated a migration for, or 0 if none.
  # Rolling back must undo what this migration did and no more: on a first install that is
  # every table, and assuming otherwise left v01 behind with nothing to remove it.
  defp installed_here(path) do
    path
    |> Path.join("*_add_retain_v*.exs")
    |> Path.wildcard()
    |> Enum.map(fn file ->
      case Regex.run(~r/_add_retain_v(\d+)\.exs$/, Path.basename(file)) do
        [_, version] -> String.to_integer(version)
        _ -> 0
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    Enum.map_join([y, m, d, hh, mm, ss], &String.pad_leading(Integer.to_string(&1), 2, "0"))
  end
end
