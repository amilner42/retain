defmodule Mix.Tasks.Retain.Gen.Migration do
  @shortdoc "Generates the migration that creates Retain's tables"

  @moduledoc """
  Generates a migration in the host app that installs (or upgrades) Retain's tables.

      $ mix retain.gen.migration
      $ mix retain.gen.migration -r MyApp.OtherRepo

  The generated file delegates to `Retain.Migration`, so re-running this after upgrading Retain
  produces a migration that applies only what is new.
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
    name = "add_retain_v#{String.pad_leading(Integer.to_string(version), 2, "0")}"
    file = Path.join(path, "#{timestamp()}_#{name}.exs")

    create_directory(path)

    create_file(file, """
    defmodule #{inspect(repo)}.Migrations.#{Macro.camelize(name)} do
      use Ecto.Migration

      def up, do: Retain.Migration.up()
      def down, do: Retain.Migration.down()
    end
    """)
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    Enum.map_join([y, m, d, hh, mm, ss], &String.pad_leading(Integer.to_string(&1), 2, "0"))
  end
end
