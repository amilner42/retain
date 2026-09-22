defmodule Retain.AmendTest do
  @moduledoc "The three things Retain grew for Oskol: `:again`, `defer/4` and `amend/5`."
  use Retain.DataCase, async: true

  alias Retain.Item

  setup do
    user!()
    items!("u1", ["a"])
    :ok
  end

  describe ":again" do
    test "drops to level 0 from anywhere and is due after the level-0 interval" do
      review!("u1", "a", :pass, at: t0())
      review!("u1", "a", :pass, at: days(1))
      review!("u1", "a", :pass, at: days(4))
      assert %Item{level: 3, lapses: 0} = item!("u1", "a")

      assert {:ok, %{level_before: 3, level_after: 0, due: due}} =
               Retain.review("u1", "a", :again, at: days(11))

      # The default ladder's level-0 interval is 0 days: back in this session.
      assert due == days(11)
      assert %Item{level: 0, reps: 4, lapses: 1} = item!("u1", "a")
    end

    test "counts as a lapse, and survives a rebuild" do
      review!("u1", "a", :pass, at: t0())
      review!("u1", "a", :again, at: days(1))
      before = item!("u1", "a")

      {:ok, _} = Retain.rebuild("u1")
      assert derived(item!("u1", "a")) == derived(before)
      assert before.lapses == 1
    end
  end

  describe "defer/4" do
    test "moves due, keeps the ladder, and is not an attempt" do
      review!("u1", "a", :pass, at: t0())
      assert %Item{level: 1, reps: 1, due: due} = item!("u1", "a")
      assert due == days(1)

      until = days(30)

      assert {:ok, %{level_before: 1, level_after: 1, due: ^until, review_id: id}} =
               Retain.defer("u1", "a", until, at: days(1))

      assert is_integer(id)

      assert %Item{level: 1, reps: 1, lapses: 0, due: ^until, last_reviewed_at: last} =
               item!("u1", "a")

      # Not an attempt: the counters and the last-reviewed stamp are untouched.
      assert last == t0()
    end

    test "round-trips through rebuild" do
      review!("u1", "a", :pass, at: t0())
      {:ok, _} = Retain.defer("u1", "a", days(30), at: days(1))
      before = item!("u1", "a")

      {:ok, _} = Retain.rebuild("u1")
      assert derived(item!("u1", "a")) == derived(before)
      assert item!("u1", "a").due == days(30)
    end

    test "a review after a defer folds from the level the defer left alone" do
      review!("u1", "a", :pass, at: t0())
      {:ok, _} = Retain.defer("u1", "a", days(30), at: days(1))

      assert {:ok, %{level_before: 1, level_after: 2}} =
               Retain.review("u1", "a", :pass, at: days(30))

      before = item!("u1", "a")
      {:ok, _} = Retain.rebuild("u1")
      assert derived(item!("u1", "a")) == derived(before)
    end

    test "it does not count towards the streak" do
      {:ok, _} = Retain.defer("u1", "a", days(30), at: t0())
      assert {:ok, %{streak: 0, days_active: 0}} = Retain.streak("u1", now: t0())

      review!("u1", "a", :pass, at: t0())
      assert {:ok, %{streak: 1, days_active: 1}} = Retain.streak("u1", now: t0())
    end

    test "it does not start a new item" do
      items!("u1", ["fresh"], status: :new)
      {:ok, _} = Retain.defer("u1", "fresh", days(30), at: t0())

      assert %Item{started_at: nil} = item = item!("u1", "fresh")
      assert Item.status(item) == :new
      assert item.due == days(30)
    end

    test "refuses suspended, unknown and out-of-order" do
      {:ok, _} = Retain.suspend("u1", "a")
      assert {:error, :suspended} = Retain.defer("u1", "a", days(3), at: t0())
      {:ok, _} = Retain.resume("u1", "a")

      assert {:error, :not_found} = Retain.defer("u1", "zzz", days(3))
      assert {:error, :not_found} = Retain.defer("nobody", "a", days(3))

      assert {:error, :out_of_order} =
               Retain.defer("u1", "a", days(3), at: DateTime.add(t0(), -1, :second))
    end

    test "a defer is the newest log entry, so an earlier review is out of order" do
      {:ok, _} = Retain.defer("u1", "a", days(30), at: days(5))
      assert {:error, :out_of_order} = Retain.review("u1", "a", :pass, at: days(4))
      assert {:ok, _} = Retain.review("u1", "a", :pass, at: days(5))
    end
  end

  describe "amend/5" do
    test "the corrected outcome takes effect where the original was, and the log keeps both" do
      {:ok, %{review_id: first}} = Retain.review("u1", "a", :fail, at: t0())
      {:ok, _} = Retain.review("u1", "a", :pass, at: days(1))
      assert %Item{level: 1, lapses: 1} = item!("u1", "a")

      assert {:ok, %{level_before: 1, level_after: 2, due: due, review_id: amendment}} =
               Retain.amend("u1", "a", first, :pass, at: days(1))

      refute amendment == first
      # The fold is now pass-then-pass: level 2, due three days after the *second* review.
      assert due == days(4)
      assert %Item{level: 2, reps: 2, lapses: 0, due: ^due} = item!("u1", "a")

      # Append-only: the row it corrected is still there, untouched.
      assert %Retain.Review{outcome: :fail} = Repo.get!(Retain.Review, first)
      assert Repo.aggregate(Retain.Review, :count) == 3
    end

    test "equals a fresh log with the corrected outcome" do
      {:ok, %{review_id: first}} = Retain.review("u1", "a", :fail, at: t0())
      {:ok, _} = Retain.review("u1", "a", :pass, at: days(1))
      {:ok, _} = Retain.amend("u1", "a", first, :partial, at: days(2))
      {:ok, _} = Retain.rebuild("u1")
      amended = derived(item!("u1", "a"))

      items!("u1", ["b"])
      review!("u1", "b", :partial, at: t0())
      review!("u1", "b", :pass, at: days(1))

      assert derived(item!("u1", "b")) == amended
    end

    test "amending an amendment takes the newest word" do
      {:ok, %{review_id: first}} = Retain.review("u1", "a", :fail, at: t0())
      {:ok, %{review_id: second}} = Retain.amend("u1", "a", first, :pass, at: days(1))
      {:ok, _} = Retain.amend("u1", "a", second, :known, at: days(2))

      assert %Item{level: 7, reps: 1, lapses: 0} = item!("u1", "a")
    end

    test "amending the same row twice takes the later amendment" do
      {:ok, %{review_id: first}} = Retain.review("u1", "a", :fail, at: t0())
      {:ok, _} = Retain.amend("u1", "a", first, :pass, at: days(1))
      {:ok, _} = Retain.amend("u1", "a", first, :known, at: days(2))

      assert %Item{level: 7, reps: 1} = item!("u1", "a")
    end

    test "history reads the correction on the day of the answer it corrects" do
      {:ok, %{review_id: first}} = Retain.review("u1", "a", :fail, at: t0())
      {:ok, _} = Retain.amend("u1", "a", first, :known, at: days(3))

      today = Retain.Clock.local_date(t0(), tz())
      {:ok, [point]} = Retain.history("u1", from: today, to: today, now: t0())

      # Level 7 of 7 on the day it was answered, not three days later.
      assert point.explored == 1.0
      assert point.acquired == 1.0
    end

    test "an amendment is not a day practised" do
      {:ok, %{review_id: first}} = Retain.review("u1", "a", :fail, at: t0())
      {:ok, _} = Retain.amend("u1", "a", first, :pass, at: days(3))

      assert {:ok, %{days_active: 1}} = Retain.streak("u1", now: days(3))
    end

    test "refuses a defer, an outcome it does not know, and rows that are not this item's" do
      {:ok, %{review_id: deferred}} = Retain.defer("u1", "a", days(30), at: t0())
      assert {:error, :not_amendable} = Retain.amend("u1", "a", deferred, :pass)

      {:ok, %{review_id: id}} = Retain.review("u1", "a", :pass, at: days(30))
      assert {:error, :invalid_outcome} = Retain.amend("u1", "a", id, :correct)
      assert {:error, :invalid_outcome} = Retain.amend("u1", "a", id, :defer)

      items!("u1", ["other"])
      assert {:error, :not_found} = Retain.amend("u1", "other", id, :pass)
      assert {:error, :not_found} = Retain.amend("u1", "zzz", id, :pass)
      assert {:error, :not_found} = Retain.amend("nobody", "a", id, :pass)
      assert {:error, :not_found} = Retain.amend("u1", "a", id + 10_000, :pass)

      # Nothing was written by any of those.
      assert Repo.aggregate(Retain.Review, :count) == 2
    end

    test "refuses to amend a suspended item" do
      {:ok, %{review_id: id}} = Retain.review("u1", "a", :pass, at: t0())
      {:ok, _} = Retain.suspend("u1", "a")
      assert {:error, :suspended} = Retain.amend("u1", "a", id, :fail)
    end
  end

  defp derived(item), do: Map.take(item, [:level, :due, :reps, :lapses, :last_reviewed_at])
end
