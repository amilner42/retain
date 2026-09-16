defmodule RetainTest do
  use Retain.DataCase, async: true

  alias Retain.{Item, User}

  describe "put_user/2 and fetch_user/2" do
    test "creates, then updates in place" do
      assert {:ok, %User{uid: "u1", tz: "America/Vancouver", scope: "default"} = user} =
               Retain.put_user("u1", tz: "America/Vancouver")

      assert {:ok, %User{id: id, tz: "Europe/Paris"}} = Retain.put_user("u1", tz: "Europe/Paris")
      assert id == user.id
      assert {:ok, %User{tz: "Europe/Paris"}} = Retain.put_user("u1")
      assert {:ok, %User{tz: "Europe/Paris"}} = Retain.fetch_user("u1")
    end

    test "new_per_day defaults from config and can be set" do
      assert {:ok, %User{new_per_day: 10}} = Retain.put_user("u1", tz: "Etc/UTC")
      assert {:ok, %User{new_per_day: 3}} = Retain.put_user("u1", new_per_day: 3)
      assert {:ok, %User{new_per_day: 0}} = Retain.put_user("u1", new_per_day: 0)

      assert {:error, %Ecto.Changeset{errors: [new_per_day: _]}} =
               Retain.put_user("u1", new_per_day: -1)
    end

    test "tz is required to create and must be a real zone" do
      assert {:error, %Ecto.Changeset{errors: [tz: {"can't be blank", _}]}} =
               Retain.put_user("u1")

      assert {:error, %Ecto.Changeset{errors: [tz: {"is not a known IANA timezone", _}]}} =
               Retain.put_user("u1", tz: "PST")

      assert {:error, :not_found} = Retain.fetch_user("u1")
    end

    test "scopes are separate namespaces" do
      user!("u1")
      user!("u1", scope: "oskol", tz: "Etc/UTC")
      assert {:ok, %User{tz: "America/Vancouver"}} = Retain.fetch_user("u1")
      assert {:ok, %User{tz: "Etc/UTC"}} = Retain.fetch_user("u1", scope: "oskol")
      assert {:error, :not_found} = Retain.fetch_user("u1", scope: "verbmap")
    end
  end

  describe "put_items/3" do
    setup do
      user!()
      :ok
    end

    test "inserts items as new by default, at level 0, and skips existing keys" do
      assert {:ok, %{inserted: 2, existing: 0}} =
               Retain.put_items(
                 "u1",
                 [%{key: "a", tags: %{kind: :cube}, content: %{x: 1}, position: 7}, %{key: "b"}],
                 now: t0()
               )

      assert {:ok, %{inserted: 1, existing: 2}} =
               Retain.put_items("u1", [%{key: "a"}, %{key: "b"}, %{key: "c"}])

      assert {:ok,
              %Item{level: 0, reps: 0, lapses: 0, suspended: false, started_at: nil, position: 7} =
                a} =
               Retain.fetch_item("u1", "a")

      assert Item.status(a) == :new
      assert a.tags == %{"kind" => "cube"}
      assert a.content == %{"x" => 1}
      assert {:ok, []} = Retain.due("u1", now: t0())
    end

    test "status: :active starts them immediately, due now" do
      assert {:ok, _} = Retain.put_items("u1", [%{key: "a"}], now: t0(), status: :active)
      assert %Item{started_at: started, due: due} = item = item!("u1", "a")
      assert started == t0()
      assert due == t0()
      assert Item.status(item) == :active
      assert {:ok, [%Item{key: "a"}]} = Retain.due("u1", now: t0())
      assert_raise ArgumentError, fn -> Retain.put_items("u1", [%{key: "z"}], status: :later) end
    end

    test "duplicate keys within one call are inserted once" do
      assert {:ok, %{inserted: 1, existing: 0}} =
               Retain.put_items("u1", [%{key: "a"}, %{key: "a", tags: %{k: "v"}}])

      assert item!("u1", "a").tags == %{}
    end

    test "an empty list is a no-op" do
      assert {:ok, %{inserted: 0, existing: 0}} = Retain.put_items("u1", [])
    end

    test "rejects invalid items without writing anything" do
      assert {:error, {:invalid_item, 1, %Ecto.Changeset{errors: [key: _]}}} =
               Retain.put_items("u1", [%{key: "ok"}, %{key: ""}])

      assert {:error, {:invalid_item, 0, %Ecto.Changeset{errors: [tags: _]}}} =
               Retain.put_items("u1", [%{key: "a", tags: %{"k" => 1}}])

      assert {:error, {:invalid_item, 0, %Ecto.Changeset{errors: [tags: _]}}} =
               Retain.put_items("u1", [%{key: "a", tags: %{"" => "v"}}])

      assert {:error, {:invalid_item, 0, %Ecto.Changeset{errors: [content: _]}}} =
               Retain.put_items("u1", [%{key: "a", content: "nope"}])

      assert {:error, :not_found} = Retain.fetch_item("u1", "ok")
    end

    test "unknown user" do
      assert {:error, :not_found} = Retain.put_items("nobody", [%{key: "a"}])
    end

    test "suspended: true adds paused items" do
      assert {:ok, _} = Retain.put_items("u1", [%{key: "a"}], suspended: true)
      assert item!("u1", "a").suspended
      assert {:ok, []} = Retain.due("u1", now: t0())
    end

    test "large batches are chunked" do
      items = for i <- 1..2_500, do: %{key: "k#{i}", tags: %{n: "#{rem(i, 3)}"}}
      assert {:ok, %{inserted: 2_500, existing: 0}} = Retain.put_items("u1", items)
      assert {:ok, [%{count: 2_500}]} = Retain.summary("u1")
    end
  end

  describe "suspend/3 and resume/3" do
    setup do
      user!()
      items!("u1", ["a"])
      :ok
    end

    test "round trip, and reviews are refused while suspended" do
      assert {:ok, %Item{suspended: true}} = Retain.suspend("u1", "a")
      assert {:error, :suspended} = Retain.review("u1", "a", :pass, at: t0())
      assert {:ok, []} = Retain.due("u1", now: t0())
      assert {:ok, %Item{suspended: false}} = Retain.resume("u1", "a")
      assert {:ok, [%Item{key: "a"}]} = Retain.due("u1", now: t0())
      assert {:error, :not_found} = Retain.suspend("u1", "zzz")
    end
  end

  describe "review/4" do
    setup do
      user!()
      items!("u1", ["a"])
      :ok
    end

    test "climbs, holds and drops the ladder, setting due from the new level" do
      assert {:ok, %{level_before: 0, level_after: 1, due: due, review_id: id}} =
               Retain.review("u1", "a", :pass, at: t0())

      assert due == days(1)
      assert is_integer(id)

      assert {:ok, %{level_before: 1, level_after: 2, due: due}} =
               Retain.review("u1", "a", :pass, at: days(1))

      assert due == days(4)

      assert {:ok, %{level_before: 2, level_after: 2}} =
               Retain.review("u1", "a", :partial, at: days(4))

      assert {:ok, %{level_before: 2, level_after: 1}} =
               Retain.review("u1", "a", :fail, at: days(5))

      assert %Item{level: 1, reps: 4, lapses: 1, last_reviewed_at: last} = item!("u1", "a")
      assert last == days(5)
    end

    test "reviewing a new item starts it at that instant" do
      items!("u1", ["fresh"], status: :new)

      assert {:ok, %{level_before: 0, level_after: 1}} =
               Retain.review("u1", "fresh", :pass, at: days(3))

      assert %Item{started_at: started, reps: 1} = item = item!("u1", "fresh")
      assert started == days(3)
      assert Item.status(item) == :active
    end

    test "a review earlier than an explicit start is out of order" do
      items!("u1", ["later"], status: :new)
      {:ok, %{started: 1}} = Retain.start("u1", ["later"], now: days(5))
      assert {:error, :out_of_order} = Retain.review("u1", "later", :pass, at: days(4))
      assert {:ok, _} = Retain.review("u1", "later", :pass, at: days(5))
    end

    test "stores meta verbatim on the review" do
      {:ok, %{review_id: id}} =
        Retain.review("u1", "a", :fail, at: t0(), meta: %{picked: "13/7", loss: 0.4})

      assert %Retain.Review{outcome: :fail, meta: %{"picked" => "13/7", "loss" => 0.4}} =
               Repo.get!(Retain.Review, id)
    end

    test "meta must be a map" do
      assert_raise ArgumentError, fn -> Retain.review("u1", "a", :pass, meta: "x") end
    end

    test "rejects unknown outcomes, items and users" do
      assert {:error, :invalid_outcome} = Retain.review("u1", "a", :correct)
      assert {:error, :not_found} = Retain.review("u1", "zzz", :pass)
      assert {:error, :not_found} = Retain.review("nobody", "a", :pass)
      assert %Item{reps: 0} = item!("u1", "a")
    end

    test "rejects reviews earlier than the item's creation or its last review" do
      assert {:error, :out_of_order} =
               Retain.review("u1", "a", :pass, at: DateTime.add(t0(), -1, :second))

      review!("u1", "a", :pass, at: days(2))
      assert {:error, :out_of_order} = Retain.review("u1", "a", :pass, at: days(1))
      # Same instant as the last review is allowed.
      assert {:ok, _} = Retain.review("u1", "a", :pass, at: days(2))
    end

    test "accepts timestamps in any zone and precision" do
      local = DateTime.shift_zone!(days(1), "Asia/Tokyo", Tz.TimeZoneDatabase)
      assert {:ok, %{due: due}} = Retain.review("u1", "a", :pass, at: local)
      assert due == days(2)
      assert %Item{last_reviewed_at: last} = item!("u1", "a")
      assert last == days(1)
      assert last.time_zone == "Etc/UTC"
    end

    test "defaults `at` to now" do
      before = DateTime.utc_now()
      {:ok, _} = Retain.review("u1", "a", :pass)
      assert DateTime.compare(item!("u1", "a").last_reviewed_at, before) != :lt
    end

    test "concurrent reviews of one item at the same instant all count" do
      1..20
      |> Task.async_stream(fn _ -> Retain.review("u1", "a", :pass, at: days(1)) end,
        max_concurrency: 10
      )
      |> Enum.each(fn {:ok, {:ok, _}} -> :ok end)

      assert %Item{reps: 20, level: 6} = item!("u1", "a")
    end
  end

  describe "due/2" do
    setup do
      user!()

      items!("u1", [
        %{key: "cube1", tags: %{kind: "cube"}},
        %{key: "move1", tags: %{kind: "move"}},
        %{key: "move2", tags: %{kind: "move"}}
      ])

      :ok
    end

    test "new items are due immediately, ordered by level then due" do
      assert {:ok, items} = Retain.due("u1", now: t0())
      assert Enum.map(items, & &1.key) == ["cube1", "move1", "move2"]
    end

    test "weakest first, then most overdue" do
      review!("u1", "cube1", :pass, at: t0())
      review!("u1", "cube1", :pass, at: days(1))
      review!("u1", "move1", :pass, at: t0())
      review!("u1", "move2", :fail, at: days(1))

      # Now at day 4 20:00 local: cube1 (level 2) due day 4, move1 (level 1) due day 1, move2 (level 0) due day 1.
      assert {:ok, items} = Retain.due("u1", now: days(4))
      assert Enum.map(items, &{&1.key, &1.level}) == [{"move2", 0}, {"move1", 1}, {"cube1", 2}]
    end

    test "the default cutoff is the end of the user's local day" do
      review!("u1", "cube1", :pass, at: t0())
      review!("u1", "move1", :pass, at: t0())
      review!("u1", "move2", :pass, at: t0())
      # All due at t0 + 1 day = 20:00 local on the 15th.
      assert {:ok, []} = Retain.due("u1", now: t0())
      # 00:01 local on the 15th: due later today counts.
      assert {:ok, [_, _, _]} = Retain.due("u1", now: ~U[2026-07-15 07:01:00Z])
      # Just before local midnight on the 14th does not.
      assert {:ok, []} = Retain.due("u1", now: ~U[2026-07-15 06:59:00Z])
    end

    test "before: overrides the cutoff" do
      review!("u1", "cube1", :pass, at: t0())
      assert {:ok, [_, _]} = Retain.due("u1", now: t0())
      assert {:ok, [_, _, _]} = Retain.due("u1", before: days(1))
    end

    test "tags: filters by containment" do
      assert {:ok, [%{key: "cube1"}]} = Retain.due("u1", now: t0(), tags: %{kind: "cube"})
      assert {:ok, [_, _]} = Retain.due("u1", now: t0(), tags: %{"kind" => "move"})
      assert {:ok, []} = Retain.due("u1", now: t0(), tags: %{kind: "move", phase: "x"})
      assert {:ok, [_, _, _]} = Retain.due("u1", now: t0(), tags: %{})
    end

    test "limit:" do
      assert {:ok, [_]} = Retain.due("u1", now: t0(), limit: 1)
    end

    test "unknown user" do
      assert {:error, :not_found} = Retain.due("nobody")
    end
  end

  describe "summary/2" do
    setup do
      user!()

      items!("u1", [
        %{key: "c1", tags: %{kind: "cube", phase: "early"}},
        %{key: "c2", tags: %{kind: "cube", phase: "late"}},
        %{key: "m1", tags: %{kind: "move", phase: "early"}},
        %{key: "x1"}
      ])

      review!("u1", "c1", :pass, at: t0())
      review!("u1", "c1", :pass, at: days(1))
      review!("u1", "c2", :pass, at: t0())
      :ok
    end

    test "no group_by: one row" do
      assert {:ok, [row]} = Retain.summary("u1", now: days(1))

      assert row == %{
               group: %{},
               count: 4,
               new_count: 0,
               active_count: 4,
               suspended_count: 0,
               due_count: 3,
               mean_level: 0.75
             }
    end

    test "new and suspended items are counted but never due" do
      items!("u1", [%{key: "n1", tags: %{kind: "cube"}}], status: :new)
      {:ok, _} = Retain.suspend("u1", "c2")

      assert {:ok, [row]} =
               Retain.summary("u1", tags: %{kind: "cube"}, group_by: [:kind], now: days(1))

      assert row == %{
               group: %{"kind" => "cube"},
               count: 3,
               new_count: 1,
               active_count: 1,
               suspended_count: 1,
               due_count: 0,
               mean_level: 1.0
             }
    end

    test "group_by one key; items missing the tag group under nil" do
      assert {:ok, rows} = Retain.summary("u1", group_by: [:kind], now: days(1))

      assert Enum.map(rows, &Map.take(&1, [:group, :count, :mean_level, :due_count])) == [
               %{group: %{"kind" => nil}, count: 1, mean_level: 0.0, due_count: 1},
               %{group: %{"kind" => "cube"}, count: 2, mean_level: 1.5, due_count: 1},
               %{group: %{"kind" => "move"}, count: 1, mean_level: 0.0, due_count: 1}
             ]
    end

    test "group_by two keys, tags filter, suspended excluded from due_count only" do
      {:ok, _} = Retain.suspend("u1", "m1")

      assert {:ok, rows} =
               Retain.summary("u1",
                 group_by: ["kind", :phase],
                 tags: %{phase: "early"},
                 now: days(1)
               )

      assert Enum.map(rows, &Map.take(&1, [:group, :count, :mean_level, :due_count])) == [
               %{
                 group: %{"kind" => "cube", "phase" => "early"},
                 count: 1,
                 mean_level: 2.0,
                 due_count: 0
               },
               %{
                 group: %{"kind" => "move", "phase" => "early"},
                 count: 1,
                 mean_level: 0.0,
                 due_count: 0
               }
             ]
    end

    test "empty user gives no rows" do
      user!("u2")
      assert {:ok, []} = Retain.summary("u2")
      assert {:error, :not_found} = Retain.summary("nobody")
    end
  end

  describe "streak/2" do
    setup do
      user!()
      items!("u1", ["a"])
      :ok
    end

    test "nothing reviewed" do
      assert {:ok, %{streak: 0, longest: 0, days_active: 0}} = Retain.streak("u1", now: t0())
    end

    test "today counts once reviewed; otherwise the streak is as of yesterday" do
      review!("u1", "a", :pass, at: days(0))
      review!("u1", "a", :pass, at: days(1))
      review!("u1", "a", :pass, at: days(2))

      assert {:ok, %{streak: 3, longest: 3, days_active: 3}} = Retain.streak("u1", now: days(2))
      # Day 3, not yet reviewed: still 3.
      assert {:ok, %{streak: 3}} = Retain.streak("u1", now: days(3))
      # Day 4, missed day 3: broken.
      assert {:ok, %{streak: 0, longest: 3, days_active: 3}} = Retain.streak("u1", now: days(4))

      review!("u1", "a", :pass, at: days(4))
      assert {:ok, %{streak: 1, longest: 3, days_active: 4}} = Retain.streak("u1", now: days(4))
    end

    test "several reviews on one day are one day" do
      review!("u1", "a", :pass, at: days(0))
      review!("u1", "a", :pass, at: DateTime.add(days(0), 1, :hour))
      assert {:ok, %{streak: 1, longest: 1, days_active: 1}} = Retain.streak("u1", now: days(0))
    end

    test "days are the user's local days, not UTC" do
      # 23:30 local on the 14th and 00:30 local on the 15th: consecutive local days, same UTC day.
      review!("u1", "a", :pass, at: ~U[2026-07-15 06:30:00Z])
      review!("u1", "a", :pass, at: ~U[2026-07-15 07:30:00Z])

      assert {:ok, %{streak: 2, days_active: 2}} =
               Retain.streak("u1", now: ~U[2026-07-15 08:00:00Z])

      # For a UTC user those are one day.
      user!("utc", tz: "Etc/UTC")
      items!("utc", ["a"])
      review!("utc", "a", :pass, at: ~U[2026-07-15 06:30:00Z])
      review!("utc", "a", :pass, at: ~U[2026-07-15 07:30:00Z])

      assert {:ok, %{streak: 1, days_active: 1}} =
               Retain.streak("utc", now: ~U[2026-07-15 08:00:00Z])
    end

    test "longest tracks the best run ever" do
      for n <- [0, 1, 2, 3, 5, 6, 10], do: review!("u1", "a", :pass, at: days(n))
      assert {:ok, %{streak: 1, longest: 4, days_active: 7}} = Retain.streak("u1", now: days(10))
    end

    test "changing the user's tz changes the days" do
      review!("u1", "a", :pass, at: ~U[2026-07-15 06:30:00Z])
      {:ok, _} = Retain.put_user("u1", tz: "Etc/UTC")
      # For UTC the review was on the 15th; "now" at 08:00Z on the 15th is the same day.
      assert {:ok, %{streak: 1}} = Retain.streak("u1", now: ~U[2026-07-15 08:00:00Z])
      # ...and on the 17th it is broken.
      assert {:ok, %{streak: 0}} = Retain.streak("u1", now: ~U[2026-07-17 08:00:00Z])
    end
  end

  describe "history/2" do
    setup do
      user!()
      items!("u1", [%{key: "c1", tags: %{kind: "cube"}}, %{key: "m1", tags: %{kind: "move"}}])
      review!("u1", "c1", :pass, at: days(0))
      review!("u1", "c1", :pass, at: days(1))
      :ok
    end

    test "defaults to the last 30 local days ending today; days before the first item have no reading" do
      assert {:ok, points} = Retain.history("u1", now: days(2))
      assert Enum.map(points, & &1.date) == [~D[2026-07-14], ~D[2026-07-15], ~D[2026-07-16]]

      assert List.last(points) == %{
               date: ~D[2026-07-16],
               group: nil,
               count: 2,
               explored: 0.5,
               acquired: 2 / 12
             }

      assert {:ok, points} = Retain.history("u1", now: days(40))
      assert length(points) == 30
      assert List.first(points).date == ~D[2026-07-25]
    end

    test "from/to, group_by and tags" do
      assert {:ok, points} =
               Retain.history("u1", from: ~D[2026-07-14], to: ~D[2026-07-15], group_by: :kind)

      assert points == [
               %{date: ~D[2026-07-14], group: "cube", count: 1, explored: 1.0, acquired: 1 / 6},
               %{date: ~D[2026-07-14], group: "move", count: 1, explored: 0.0, acquired: 0.0},
               %{date: ~D[2026-07-15], group: "cube", count: 1, explored: 1.0, acquired: 2 / 6},
               %{date: ~D[2026-07-15], group: "move", count: 1, explored: 0.0, acquired: 0.0}
             ]

      assert {:ok, [%{group: nil, count: 1, acquired: acquired}]} =
               Retain.history("u1",
                 from: ~D[2026-07-15],
                 to: ~D[2026-07-15],
                 tags: %{kind: "cube"}
               )

      assert acquired == 2 / 6
    end

    test "unknown user" do
      assert {:error, :not_found} = Retain.history("nobody")
    end
  end

  describe "merge_users/3" do
    setup do
      user!("guest")
      user!("acct")
      # The guest started five days before the account existed.
      items!("guest", [%{key: "only_guest", tags: %{k: "g"}}, %{key: "both"}], now: days(-5))
      items!("acct", [%{key: "only_acct"}, %{key: "both"}])
      review!("guest", "both", :pass, at: days(-5))
      review!("guest", "only_guest", :pass, at: days(-5))
      review!("acct", "both", :pass, at: days(1))
      :ok
    end

    test "moves unique items, merges shared ones by replaying the combined log, deletes the guest" do
      assert {:ok, %{moved: 1, merged: 1}} = Retain.merge_users("guest", "acct")
      assert {:error, :not_found} = Retain.fetch_user("guest")

      assert %Item{level: 1, reps: 1, tags: %{"k" => "g"}} = item!("acct", "only_guest")

      assert %Item{
               level: 2,
               reps: 2,
               last_reviewed_at: last,
               inserted_at: inserted,
               started_at: started
             } =
               item!("acct", "both")

      assert last == days(1)
      assert inserted == days(-5)
      assert started == days(-5)
      assert {:ok, [%{count: 3}]} = Retain.summary("acct")
      assert {:ok, %{days_active: 2}} = Retain.streak("acct", now: days(1))
    end

    test "history sees the guest's early reviews after the merge" do
      {:ok, _} = Retain.merge_users("guest", "acct")
      day = Retain.Clock.local_date(days(-5), tz())
      assert {:ok, [%{count: 2, explored: 1.0}]} = Retain.history("acct", from: day, to: day)
    end

    test "a new item merged with a started one is started either way" do
      items!("guest", ["g_new"], status: :new)
      items!("acct", ["g_new"])
      items!("guest", ["a_new"])
      items!("acct", ["a_new"], status: :new)
      {:ok, _} = Retain.merge_users("guest", "acct")
      assert Item.status(item!("acct", "g_new")) == :active
      assert Item.status(item!("acct", "a_new")) == :active
    end

    test "errors" do
      assert {:error, :same_user} = Retain.merge_users("acct", "acct")
      assert {:error, :not_found} = Retain.merge_users("nobody", "acct")
      assert {:error, :not_found} = Retain.merge_users("guest", "nobody")
    end
  end

  describe "rebuild/2 and rebuild_all/0" do
    setup do
      user!()
      items!("u1", ["a", "b"])
      review!("u1", "a", :pass, at: days(0))
      review!("u1", "a", :fail, at: days(1))
      review!("u1", "b", :pass, at: days(0))
      :ok
    end

    test "restores derived fields after they are corrupted" do
      before = {item!("u1", "a"), item!("u1", "b")}

      Repo.update_all(Item,
        set: [level: 5, reps: 99, lapses: 9, due: days(50), last_reviewed_at: nil]
      )

      assert {:ok, %{items: 2}} = Retain.rebuild("u1")
      assert {item!("u1", "a"), item!("u1", "b")} |> strip() == strip(before)

      Repo.update_all(Item, set: [level: 5])
      assert {:ok, %{users: 1, items: 2}} = Retain.rebuild_all()
      assert item!("u1", "a").level == 0
    end

    test "unknown user" do
      assert {:error, :not_found} = Retain.rebuild("nobody")
    end

    defp strip({a, b}),
      do: {Map.drop(a, [:updated_at, :__meta__]), Map.drop(b, [:updated_at, :__meta__])}
  end
end
