defmodule Retain.TestRepo.Migrations.AddRetainV01 do
  use Ecto.Migration

  def up, do: Retain.Migration.up(version: 1)
  def down, do: Retain.Migration.down(version: 0)
end
