defmodule Retain.ConcurrencyTest do
  @moduledoc """
  Runs outside the sandbox so each task really gets its own connection and the row locks are
  exercised for real. Each test cleans up after itself.

  The invariant every one of these asserts is the same, and it is the one the whole library rests
  on: whatever order the writes land in, replaying the log must reproduce the live state. A race
  that overwrites derived fields out from under a review breaks exactly that.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Retain.{Item, TestRepo}

  @at ~U[2026-07-15 03:00:00.000000Z]

  defp uid, do: "concurrent-#{System.unique_integer([:positive])}"

  defp derived(item), do: Map.take(item, [:level, :due, :reps, :lapses, :last_reviewed_at])

  # Live state must equal what replaying the log produces.
  defp assert_log_is_truth(uid, keys) do
    live = Map.new(keys, fn k -> {k, derived(elem(Retain.fetch_item(uid, k), 1))} end)
    {:ok, _} = Retain.rebuild(uid)
    rebuilt = Map.new(keys, fn k -> {k, derived(elem(Retain.fetch_item(uid, k), 1))} end)
    assert rebuilt == live
  end

  defp cleanup(uid) do
    case Retain.fetch_user(uid) do
      {:ok, user} -> TestRepo.delete!(user)
      _ -> :ok
    end
  end

  test "parallel reviews of one item never lose an update" do
    uid = uid()

    Sandbox.unboxed_run(TestRepo, fn ->
      {:ok, _} = Retain.put_user(uid, tz: "Etc/UTC")
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
        assert {:ok, %Item{reps: 40, level: 7, lapses: 0}} = Retain.fetch_item(uid, "a")
        assert TestRepo.aggregate(Retain.Review, :count) >= 40
      after
        cleanup(uid)
      end
    end)
  end

  test "put_user/2 racing to create the same learner gives them all the same one" do
    uid = uid()

    Sandbox.unboxed_run(TestRepo, fn ->
      try do
        results =
          1..12
          |> Task.async_stream(
            fn _ -> Retain.put_user(uid, tz: "Etc/UTC", new_per_day: 5) end,
            max_concurrency: 12,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        # Every caller gets the learner, not a unique violation.
        assert Enum.all?(results, &match?({:ok, %Retain.User{}}, &1)),
               "put_user raced to an error: #{inspect(Enum.reject(results, &match?({:ok, _}, &1)))}"

        ids = results |> Enum.map(fn {:ok, u} -> u.id end) |> Enum.uniq()
        assert length(ids) == 1
        assert TestRepo.aggregate(from(u in Retain.User, where: u.uid == ^uid), :count) == 1
      after
        cleanup(uid)
      end
    end)
  end

  test "start/3 racing review/4 on the same new item never overwrites the review" do
    uid = uid()
    keys = Enum.map(1..40, &"k#{&1}")

    Sandbox.unboxed_run(TestRepo, fn ->
      {:ok, _} = Retain.put_user(uid, tz: "Etc/UTC")
      {:ok, _} = Retain.put_items(uid, Enum.map(keys, &%{key: &1}), now: @at)

      try do
        # For each item, a start and a review go at it at the same moment. Whoever wins, the
        # review must be the last word on the ladder: start only ever moves a *new* item.
        keys
        |> Task.async_stream(
          fn key ->
            [
              Task.async(fn -> Retain.start(uid, [key], now: @at) end),
              Task.async(fn -> Retain.review(uid, key, :pass, at: @at) end)
            ]
            |> Task.await_many(30_000)
          end,
          max_concurrency: 8,
          timeout: 60_000
        )
        |> Stream.run()

        for key <- keys do
          {:ok, item} = Retain.fetch_item(uid, key)

          # The review happened exactly once and its ladder step stands: level 1, due one day
          # later. Before the fix, a start landing after the review reset due to @at.
          assert item.reps == 1, "#{key}: reps #{item.reps}"
          assert item.level == 1, "#{key}: level #{item.level}"
          assert item.due == DateTime.add(@at, 1, :day), "#{key}: due #{item.due}"
          assert item.started_at == @at
        end

        assert_log_is_truth(uid, keys)
      after
        cleanup(uid)
      end
    end)
  end

  test "start/3 racing itself starts each item once and counts honestly" do
    uid = uid()
    keys = Enum.map(1..30, &"k#{&1}")

    Sandbox.unboxed_run(TestRepo, fn ->
      {:ok, _} = Retain.put_user(uid, tz: "Etc/UTC")
      {:ok, _} = Retain.put_items(uid, Enum.map(keys, &%{key: &1}), now: @at)

      try do
        started =
          1..8
          |> Task.async_stream(fn _ -> Retain.start(uid, keys, now: @at) end,
            max_concurrency: 8,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, {:ok, %{started: n}}} -> n end)
          |> Enum.sum()

        # `started` is what this caller actually moved, so the totals add up to the items.
        assert started == length(keys)
        assert Enum.all?(keys, fn k -> elem(Retain.fetch_item(uid, k), 1).started_at == @at end)
      after
        cleanup(uid)
      end
    end)
  end

  test "suspend/3 racing review/4 leaves the log as the truth either way" do
    uid = uid()
    keys = Enum.map(1..40, &"k#{&1}")

    Sandbox.unboxed_run(TestRepo, fn ->
      {:ok, _} = Retain.put_user(uid, tz: "Etc/UTC")
      {:ok, _} = Retain.put_items(uid, Enum.map(keys, &%{key: &1}), now: @at, status: :active)

      try do
        outcomes =
          keys
          |> Task.async_stream(
            fn key ->
              [
                Task.async(fn -> Retain.suspend(uid, key) end),
                Task.async(fn -> Retain.review(uid, key, :pass, at: @at) end)
              ]
              |> Task.await_many(30_000)
              |> List.last()
            end,
            max_concurrency: 8,
            timeout: 60_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        # The review either got in before the suspension or was refused by it. Nothing else.
        assert Enum.all?(outcomes, &(match?({:ok, _}, &1) or match?({:error, :suspended}, &1)))

        for key <- keys do
          {:ok, item} = Retain.fetch_item(uid, key)
          assert item.suspended
          assert item.reps in [0, 1]
        end

        # Suspending writes no derived field, so a rebuild still agrees.
        assert_log_is_truth(uid, keys)
      after
        cleanup(uid)
      end
    end)
  end
end
