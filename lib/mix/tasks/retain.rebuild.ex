defmodule Mix.Tasks.Retain.Rebuild do
  @shortdoc "Re-derives every item's ladder state from its reviews"

  @moduledoc """
  Replays the review log through the ladder and overwrites every item's derived fields.

      $ mix retain.rebuild

  Safe to run at any time; the log is the source of truth. Run it after changing
  `config :retain, intervals:`.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    {:ok, %{users: users, items: items}} = Retain.rebuild_all()
    Mix.shell().info("Rebuilt #{items} items across #{users} users.")
  end
end
