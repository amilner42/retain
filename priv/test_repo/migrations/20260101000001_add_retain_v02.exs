defmodule Retain.TestRepo.Migrations.AddRetainV02 do
  use Ecto.Migration

  def up, do: Retain.Migration.up(version: 2)
  def down, do: Retain.Migration.down(version: 1)
end
