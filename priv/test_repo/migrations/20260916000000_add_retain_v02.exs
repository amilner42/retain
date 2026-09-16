defmodule Retain.TestRepo.Migrations.AddRetainV02 do
  use Ecto.Migration

  # The upgrade path a host takes after bumping Retain: only V02 is applied.
  def up, do: Retain.Migration.up(version: 2)
  def down, do: Retain.Migration.down(version: 1)
end
