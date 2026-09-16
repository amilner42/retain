defmodule Retain.MigrationRoundtripTest do
  @moduledoc """
  Rolls the test schema all the way down and back up, one version at a time, outside the
  sandbox. Proves every `down` reverts its `up` and that the version bookkeeping is right.
  """
  use ExUnit.Case, async: false

  alias Retain.TestRepo

  # The host-side migration files in priv/test_repo/migrations, one per Retain version.
  @v1 20_260_101_000_000
  @v2 20_260_916_000_000

  test "down to 0 and up to latest, version by version" do
    # The migrator opens its own connections (one holds the migration lock), which the sandbox
    # would refuse; run with real pooled connections. This module is async: false, so nothing
    # else touches the DB meanwhile.
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :auto)
    # The migrator recompiles the migration files each run; the test alias already loaded them.
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(TestRepo, :down, to: @v2, log: false)
      assert installed() == 1
      Ecto.Migrator.run(TestRepo, :down, to: @v1, log: false)
      assert installed() == 0
      Ecto.Migrator.run(TestRepo, :up, to: @v1, log: false)
      assert installed() == 1
      Ecto.Migrator.run(TestRepo, :up, to: @v2, log: false)
      assert installed() == 2
    after
      # Whatever happened, leave the schema at latest for the other tests.
      Ecto.Migrator.run(TestRepo, :up, all: true, log: false)
      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      Code.put_compiler_option(:ignore_module_conflict, false)
    end
  end

  defp installed do
    case TestRepo.query!(
           "SELECT obj_description(c.oid, 'pg_class') FROM pg_class c WHERE c.relname = 'retain_users'"
         ) do
      %{rows: [[v]]} when is_binary(v) -> String.to_integer(v)
      _ -> 0
    end
  end
end
