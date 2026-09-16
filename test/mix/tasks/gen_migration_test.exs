defmodule Mix.Tasks.Retain.Gen.MigrationTest do
  use ExUnit.Case, async: false

  test "writes a migration that delegates to Retain.Migration" do
    config = Application.get_env(:retain, Retain.TestRepo)
    priv = "tmp/gen_migration_#{System.unique_integer([:positive])}"
    Application.put_env(:retain, Retain.TestRepo, Keyword.put(config, :priv, priv))
    dir = Ecto.Migrator.migrations_path(Retain.TestRepo)

    try do
      Mix.Tasks.Retain.Gen.Migration.run(["-r", "Retain.TestRepo"])
      v = Retain.Migration.latest_version()
      [file] = Path.wildcard(Path.join(dir, "*_add_retain_v0#{v}.exs"))
      source = File.read!(file)
      assert source =~ "defmodule Retain.TestRepo.Migrations.AddRetainV0#{v} do"
      assert source =~ "def up, do: Retain.Migration.up(version: #{v})"
      assert source =~ "def down, do: Retain.Migration.down(version: #{v - 1})"
      assert Code.string_to_quoted!(source)
    after
      Application.put_env(:retain, Retain.TestRepo, config)
      File.rm_rf!(Path.dirname(dir))
    end
  end
end
