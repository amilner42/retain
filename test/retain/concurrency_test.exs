defmodule Retain.ConcurrencyTest do
  @moduledoc """
  Real connections, real row locks.

  Getting this wrong is easy and silent, and this file had it wrong. `Sandbox.unboxed_run/2`
  plus `Task` looks concurrent, but a task inherits `$callers` and therefore its parent's one
  checked-out connection: measured, eight tasks shared **one** `pg_backend_pid`, so no
  `FOR UPDATE` in the library was ever contended and none of these tests proved anything about
  locking.

  What fixes it is `:auto` mode -- then each process checks out its own connection, and eight
  tasks are eight backends. Dropping `$callers` is belt and braces for a task that would
  otherwise borrow a connection some caller had checked out. `assert_backends/1` measures it
  rather than trusting it, so this cannot quietly regress to running single-file again.

  The invariant every one of these asserts is the same, and it is the one the whole library
  rests on: whatever order the writes land in, replaying the log must reproduce the live state.
  A race that overwrites derived fields out from under a review breaks exactly that, and a
  deadlock is a crash rather than a wrong answer -- both are failures here.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Retain.{Item, TestRepo}

  @at ~U[2026-07-15 03:00:00.000000Z]

  setup_all do
    # These tests commit for real, so a run that died mid-test (a deadlock, a killed suite)
    # leaves rows behind that the next run's global counts would trip over. Sweep first.
    Sandbox.mode(TestRepo, :auto)
    TestRepo.delete_all(from(u in Retain.User, where: like(u.uid, "concurrent-%")))
    Sandbox.mode(TestRepo, :manual)
    :ok
  end

  setup do
    # Real connections for everyone, not the sandbox's one.
    Sandbox.mode(TestRepo, :auto)
    on_exit(fn -> Sandbox.mode(TestRepo, :manual) end)
    :ok
  end

  defp uid, do: "concurrent-#{System.unique_integer([:positive])}"

  # Run `fun` on a connection of this process's own. Without dropping `$callers` the task
  # borrows its parent's, and the whole suite runs single-file without saying so.
  defp concurrently(enumerable, fun, opts \\ []) do
    enumerable
    |> Task.async_stream(
      fn arg ->
        Process.delete(:"$callers")
        fun.(arg)
      end,
      Keyword.merge([max_concurrency: 8, timeout: 60_000], opts)
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # Proof that the above worked: how many distinct backends the tasks actually used.
  defp assert_backends(n) do
    pids =
      concurrently(1..8, fn _ ->
        %{rows: [[pid]]} = TestRepo.query!("SELECT pg_backend_pid()")
        pid
      end)

    assert length(Enum.uniq(pids)) >= n,
           "expected at least #{n} database connections, got #{length(Enum.uniq(pids))}"
  end

  test "the tasks in this file really do get their own connections" do
    assert_backends(2)
  end

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

    {:ok, _} = Retain.put_user(uid, tz: "Etc/UTC")
    {:ok, _} = Retain.put_items(uid, [%{key: "a"}], now: @at)

    try do
      results = concurrently(1..40, fn _ -> Retain.review(uid, "a", :pass, at: @at) end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert {:ok, %Item{reps: 40, level: 7, lapses: 0}} = Retain.fetch_item(uid, "a")
      assert reviews(uid) >= 40
    after
      cleanup(uid)
    end
  end

  test "put_user/2 racing to create the same learner gives them all the same one" do
    uid = uid()

    try do
      results =
        concurrently(1..12, fn _ -> Retain.put_user(uid, tz: "Etc/UTC", new_per_day: 5) end,
          max_concurrency: 12
        )

      # Every caller gets the learner, not a unique violation.
      assert Enum.all?(results, &match?({:ok, %Retain.User{}}, &1)),
             "put_user raced to an error: #{inspect(Enum.reject(results, &match?({:ok, _}, &1)))}"

      ids = results |> Enum.map(fn {:ok, u} -> u.id end) |> Enum.uniq()
      assert length(ids) == 1
      assert TestRepo.aggregate(from(u in Retain.User, where: u.uid == ^uid), :count) == 1
    after
      cleanup(uid)
    end
  end

  test "start/3 racing review/4 on the same new item never overwrites the review" do
    uid = uid()
    keys = Enum.map(1..40, &"k#{&1}")

    {:ok, _} = Retain.put_user(uid, tz: "Etc/UTC")
    {:ok, _} = Retain.put_items(uid, Enum.map(keys, &%{key: &1}), now: @at)

    try do
      # For each item, a start and a review go at it at the same moment. Whoever wins, the
      # review must be the last word on the ladder: start only ever moves a *new* item.
      concurrently(keys, fn key ->
        [
          Task.async(fn ->
            Process.delete(:"$callers")
            Retain.start(uid, [key], now: @at)
          end),
          Task.async(fn ->
            Process.delete(:"$callers")
            Retain.review(uid, key, :pass, at: @at)
          end)
        ]
        |> Task.await_many(30_000)
      end)

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
  end

  test "start/3 racing itself starts each item once and counts honestly" do
    uid = uid()
    keys = Enum.map(1..30, &"k#{&1}")

    {:ok, _} = Retain.put_user(uid, tz: "Etc/UTC")
    {:ok, _} = Retain.put_items(uid, Enum.map(keys, &%{key: &1}), now: @at)

    try do
      started =
        1..8
        |> concurrently(fn _ -> Retain.start(uid, keys, now: @at) end)
        |> Enum.map(fn {:ok, %{started: n}} -> n end)
        |> Enum.sum()

      # `started` is what this caller actually moved, so the totals add up to the items.
      assert started == length(keys)
      assert Enum.all?(keys, fn k -> elem(Retain.fetch_item(uid, k), 1).started_at == @at end)
    after
      cleanup(uid)
    end
  end

  test "suspend/3 racing review/4 leaves the log as the truth either way" do
    uid = uid()
    keys = Enum.map(1..40, &"k#{&1}")

    {:ok, _} = Retain.put_user(uid, tz: "Etc/UTC")
    {:ok, _} = Retain.put_items(uid, Enum.map(keys, &%{key: &1}), now: @at, status: :active)

    try do
      outcomes =
        concurrently(keys, fn key ->
          [
            Task.async(fn ->
              Process.delete(:"$callers")
              Retain.suspend(uid, key)
            end),
            Task.async(fn ->
              Process.delete(:"$callers")
              Retain.review(uid, key, :pass, at: @at)
            end)
          ]
          |> Task.await_many(30_000)
          |> List.last()
        end)

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
  end

  test "start/3 and master/3 on one deck do not deadlock" do
    # Two multi-row paths over the same items. They used to take their locks in different
    # orders -- start in introduction order, master in the caller's key order -- so each could
    # hold the row the other wanted next and Postgres killed one with a 40P01.
    uid = uid()
    keys = Enum.map(1..40, &"k#{&1}")

    {:ok, _} = Retain.put_user(uid, tz: "Etc/UTC")
    {:ok, _} = Retain.put_items(uid, Enum.map(keys, &%{key: &1}), now: @at)

    try do
      results =
        concurrently(1..8, fn n ->
          # Opposite key orders, which is what made the old lock orders diverge.
          ordered = if rem(n, 2) == 0, do: keys, else: Enum.reverse(keys)

          if rem(n, 2) == 0 do
            Retain.start(uid, ordered, now: @at)
          else
            Retain.master(uid, ordered, now: @at)
          end
        end)

      assert Enum.all?(results, &match?({:ok, _}, &1)),
             "deadlocked: #{inspect(Enum.reject(results, &match?({:ok, _}, &1)))}"

      assert_log_is_truth(uid, keys)
    after
      cleanup(uid)
    end
  end

  test "two merges into one account do not deadlock" do
    # merge_users locked the target's items in the order of the *source's* items, so two
    # merges into the same account took the same rows in different orders.
    into = uid()
    shared = Enum.map(1..30, &"k#{&1}")
    {:ok, _} = Retain.put_user(into, tz: "Etc/UTC")
    {:ok, _} = Retain.put_items(into, Enum.map(shared, &%{key: &1}), now: @at)

    sources =
      for n <- 1..4 do
        from_uid = "#{uid()}-src#{n}"
        {:ok, _} = Retain.put_user(from_uid, tz: "Etc/UTC")
        # Each source offers the same keys in a different order.
        keys = Enum.shuffle(shared)
        {:ok, _} = Retain.put_items(from_uid, Enum.map(keys, &%{key: &1}), now: @at)
        {:ok, _} = Retain.review(from_uid, hd(keys), :pass, at: @at)
        from_uid
      end

    try do
      results = concurrently(sources, fn from_uid -> Retain.merge_users(from_uid, into) end)

      assert Enum.all?(results, &match?({:ok, _}, &1)),
             "deadlocked: #{inspect(Enum.reject(results, &match?({:ok, _}, &1)))}"

      assert Enum.all?(sources, &(Retain.fetch_user(&1) == {:error, :not_found}))
      assert_log_is_truth(into, shared)
    after
      Enum.each(sources, &cleanup/1)
      cleanup(into)
    end
  end

  defp reviews(uid) do
    TestRepo.aggregate(
      from(r in Retain.Review,
        join: i in assoc(r, :item),
        join: u in assoc(i, :user),
        where: u.uid == ^uid
      ),
      :count
    )
  end
end
