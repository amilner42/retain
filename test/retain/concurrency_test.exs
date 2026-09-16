defmodule Retain.ConcurrencyTest do
  @moduledoc """
  Runs outside the sandbox so each task really gets its own connection and the row lock in
  `Retain.review/4` is exercised for real. Cleans up after itself.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Retain.{Item, TestRepo}

  @at ~U[2026-07-15 03:00:00.000000Z]

  test "parallel reviews of one item never lose an update" do
    uid = "concurrent-#{System.unique_integer([:positive])}"

    Sandbox.unboxed_run(TestRepo, fn ->
      {:ok, user} = Retain.put_user(uid, tz: "Etc/UTC")
      {:ok, _} = Retain.put_items(uid, [%{key: "a"}], now: @at)

      try do
        results =
          1..40
          |> Task.async_stream(fn _ -> Retain.review(uid, "a", :pass, at: @at) end,
            max_concurrency: 8,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert Enum.all?(results, &match?({:ok, _}, &1))
        assert {:ok, %Item{reps: 40, level: 6, lapses: 0}} = Retain.fetch_item(uid, "a")
        assert TestRepo.aggregate(Retain.Review, :count) >= 40
      after
        TestRepo.delete!(user)
      end
    end)
  end
end
