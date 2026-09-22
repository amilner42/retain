defmodule Mix.Tasks.Retain.Gen.MigrationTest do
  use ExUnit.Case, async: false

  test "a first install rolls all the way back, not to the version before the latest" do
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
      # Nothing was installed before this one, so `down` must remove everything. Emitting
      # `v - 1` left a host that rolled back its only Retain migration with v01 still there.
      assert source =~ "def down, do: Retain.Migration.down(version: 0)"
      assert Code.string_to_quoted!(source)
    after
      Application.put_env(:retain, Retain.TestRepo, config)
      File.rm_rf!(Path.dirname(dir))
    end
  end

  test "an upgrade rolls back to the version the host already had" do
    config = Application.get_env(:retain, Retain.TestRepo)
    priv = "tmp/gen_migration_#{System.unique_integer([:positive])}"
    Application.put_env(:retain, Retain.TestRepo, Keyword.put(config, :priv, priv))
    dir = Ecto.Migrator.migrations_path(Retain.TestRepo)

    try do
      File.mkdir_p!(dir)
      # The host is already on v01.
      File.write!(Path.join(dir, "20200101000000_add_retain_v01.exs"), "")

      Mix.Tasks.Retain.Gen.Migration.run(["-r", "Retain.TestRepo"])
      v = Retain.Migration.latest_version()
      [file] = Path.wildcard(Path.join(dir, "*_add_retain_v0#{v}.exs"))
      source = File.read!(file)

      assert source =~ "def up, do: Retain.Migration.up(version: #{v})"
      assert source =~ "def down, do: Retain.Migration.down(version: 1)"
    after
      Application.put_env(:retain, Retain.TestRepo, config)
      File.rm_rf!(Path.dirname(dir))
    end
  end
end
