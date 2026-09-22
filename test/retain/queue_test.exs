defmodule Retain.QueueTest do
  @moduledoc "Introducing new items: `start/3`, `queue/2` and the daily budget."
  use Retain.DataCase, async: true

  alias Retain.Item

  setup do
    user!("u1", new_per_day: 3)

    # A map of six: positions decide introduction order, not creation order or key.
    items!(
      "u1",
      [
        %{key: "p5", position: 5, tags: %{tense: "present"}},
        %{key: "p1", position: 1, tags: %{tense: "present"}},
        %{key: "p3", position: 3, tags: %{tense: "past"}},
        %{key: "p2", position: 2, tags: %{tense: "present"}},
        %{key: "np_a", tags: %{tense: "past"}},
        %{key: "np_b", tags: %{tense: "past"}}
      ],
      status: :new
    )

    :ok
  end

  describe "start/3" do
    test "by count: next items in position order, unpositioned last by creation" do
      assert {:ok, %{started: 4}} = Retain.start("u1", 4, now: t0())
      started = for k <- ~w(p1 p2 p3 p5 np_a np_b), do: {k, Item.status(item!("u1", k))}

      assert started == [
               {"p1", :active},
               {"p2", :active},
               {"p3", :active},
               {"p5", :active},
               {"np_a", :new},
               {"np_b", :new}
             ]

      assert {:ok, %{started: 2}} = Retain.start("u1", 10, now: t0())
      assert Item.status(item!("u1", "np_a")) == :active
      assert {:ok, %{started: 0}} = Retain.start("u1", 10, now: t0())
    end

    test "by count within tags" do
      assert {:ok, %{started: 2}} = Retain.start("u1", 2, tags: %{tense: "past"}, now: t0())
      assert Item.status(item!("u1", "p3")) == :active
      assert Item.status(item!("u1", "np_a")) == :active
      assert Item.status(item!("u1", "p1")) == :new
    end

    test "by keys: skips unknown, already started and suspended" do
      {:ok, _} = Retain.suspend("u1", "p2")
      assert {:ok, %{started: 2}} = Retain.start("u1", ["p1", "p2", "p5", "nope"], now: t0())
      assert {:ok, %{started: 0}} = Retain.start("u1", ["p1", "p5"], now: t0())
      assert Item.status(item!("u1", "p2")) == :suspended
    end

    test "started items are level 0 and due at the start instant" do
      {:ok, _} = Retain.start("u1", ["p1"], now: days(2))
      assert %Item{level: 0, due: due, started_at: started} = item!("u1", "p1")
      assert due == days(2)
      assert started == days(2)
      assert {:ok, [%Item{key: "p1"}]} = Retain.due("u1", now: days(2))
    end

    test "unknown user" do
      assert {:error, :not_found} = Retain.start("nobody", 1)
    end
  end

  describe "queue/2" do
    test "with nothing started: no reviews, new items up to the daily budget" do
      assert {:ok, %{reviews: [], new: new, new_remaining_today: 3}} =
               Retain.queue("u1", now: t0())

      assert keys(new) == ["p1", "p2", "p3"]
      # Nothing is started by looking.
      assert Item.status(item!("u1", "p1")) == :new
    end

    test "the budget shrinks as items are started today, by any path" do
      {:ok, _} = Retain.start("u1", ["p5"], now: t0())
      review!("u1", "p1", :pass, at: t0())

      assert {:ok, %{new: new, new_remaining_today: 1}} = Retain.queue("u1", now: t0())
      assert keys(new) == ["p2"]

      review!("u1", "p2", :pass, at: t0())
      assert {:ok, %{new: [], new_remaining_today: 0}} = Retain.queue("u1", now: t0())
    end

    test "the budget resets at the user's local midnight" do
      {:ok, _} = Retain.start("u1", 3, now: t0())
      assert {:ok, %{new: [], new_remaining_today: 0}} = Retain.queue("u1", now: t0())

      # t0 is 20:00 local; four hours later it is tomorrow in Vancouver.
      tomorrow = DateTime.add(t0(), 4, :hour)
      assert {:ok, %{new: new, new_remaining_today: 3}} = Retain.queue("u1", now: tomorrow)
      assert keys(new) == ["p5", "np_a", "np_b"]
    end

    test "reviews come from due/2 and new items respect tags and new_limit" do
      review!("u1", "p3", :fail, at: t0())

      assert {:ok, %{reviews: reviews, new: new, new_remaining_today: 2}} =
               Retain.queue("u1", now: t0(), tags: %{tense: "present"}, new_limit: 1)

      assert keys(reviews) == []
      assert keys(new) == ["p1"]

      assert {:ok, %{reviews: reviews, new: new}} =
               Retain.queue("u1", now: t0(), tags: %{tense: "past"})

      assert keys(reviews) == ["p3"]
      assert keys(new) == ["np_a", "np_b"]
    end

    test "new: :after_reviews holds new items until nothing is due" do
      review!("u1", "p3", :fail, at: t0())
      assert {:ok, %{reviews: [_], new: []}} = Retain.queue("u1", now: t0(), new: :after_reviews)
      review!("u1", "p3", :pass, at: t0())

      assert {:ok, %{reviews: [], new: [_, _]}} =
               Retain.queue("u1", now: t0(), new: :after_reviews)
    end

    test "new_per_day: 0 means introduce only by start/3" do
      {:ok, _} = Retain.put_user("u1", new_per_day: 0)
      assert {:ok, %{new: [], new_remaining_today: 0}} = Retain.queue("u1", now: t0())
      assert {:ok, %{started: 1}} = Retain.start("u1", 1, now: t0())
      assert {:ok, %{reviews: [%Item{key: "p1"}], new: []}} = Retain.queue("u1", now: t0())
    end

    test "suspended new items are skipped" do
      {:ok, _} = Retain.suspend("u1", "p1")
      assert {:ok, %{new: new}} = Retain.queue("u1", now: t0())
      assert keys(new) == ["p2", "p3", "p5"]
    end

    test "unknown user" do
      assert {:error, :not_found} = Retain.queue("nobody")
    end
  end

  describe "due/2 offset" do
    test "walks further down the same ordering without repeating or skipping" do
      user!()
      items!("u1", Enum.map(1..12, &%{key: "k#{&1}"}))

      # Give every item a distinct place in the (level, due, id) ordering.
      for n <- 1..12, do: review!("u1", "k#{n}", :pass, at: DateTime.add(t0(), n, :second))

      {:ok, all} = Retain.due("u1", limit: 12, before: days(400))
      assert length(all) == 12

      {:ok, first} = Retain.due("u1", limit: 5, before: days(400))
      {:ok, second} = Retain.due("u1", limit: 5, offset: 5, before: days(400))
      {:ok, third} = Retain.due("u1", limit: 5, offset: 10, before: days(400))

      assert keys(first ++ second ++ third) == keys(all)
      assert length(third) == 2

      # Past the end is empty, not an error.
      assert {:ok, []} = Retain.due("u1", limit: 5, offset: 99, before: days(400))
    end

    test "queue/2 passes it through to the reviews" do
      user!()
      items!("u1", Enum.map(1..6, &%{key: "k#{&1}"}))
      for n <- 1..6, do: review!("u1", "k#{n}", :pass, at: DateTime.add(t0(), n, :second))

      {:ok, %{reviews: page}} = Retain.queue("u1", limit: 2, offset: 4, before: days(400))
      assert length(page) == 2

      {:ok, %{reviews: everything}} = Retain.queue("u1", limit: 6, before: days(400))
      assert keys(page) == keys(Enum.drop(everything, 4))
    end
  end
end
