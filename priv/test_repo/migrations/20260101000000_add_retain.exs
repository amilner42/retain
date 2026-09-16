defmodule Retain.TestRepo.Migrations.AddRetain do
  use Ecto.Migration

  def up, do: Retain.Migration.up()
  def down, do: Retain.Migration.down()
end
