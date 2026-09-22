defmodule Retain.FoldTest do
  use ExUnit.Case, async: true

  alias Retain.{Fold, Ladder}

  @ladder Ladder.new([0, 1, 3, 7, 21, 58, 145, 365])
  @t0 ~U[2026-07-15 03:00:00Z]

  test "initial state is level 0 and due at creation" do
    assert Fold.initial(@t0) == %{level: 0, due: @t0, reps: 0, lapses: 0, last_reviewed_at: nil}
  end

  test "apply moves the level, sets due from the new level, counts reps and lapses" do
    s0 = Fold.initial(@t0)

    s1 = Fold.apply(s0, @ladder, :pass, @t0)

    assert s1 == %{
             level: 1,
             due: DateTime.add(@t0, 1, :day),
             reps: 1,
             lapses: 0,
             last_reviewed_at: @t0
           }

    t1 = DateTime.add(@t0, 1, :day)
    s2 = Fold.apply(s1, @ladder, :pass, t1)
    assert s2.level == 2
    assert s2.due == DateTime.add(t1, 3, :day)
    assert s2.reps == 2

    t2 = DateTime.add(t1, 3, :day)
    s3 = Fold.apply(s2, @ladder, :fail, t2)

    assert s3 == %{
             level: 1,
             due: DateTime.add(t2, 1, :day),
             reps: 3,
             lapses: 1,
             last_reviewed_at: t2
           }

    s4 = Fold.apply(s3, @ladder, :partial, t2)
    assert s4.level == 1
    assert s4.reps == 4
    assert s4.lapses == 1
  end

  test "a fail at level 0 is due immediately" do
    s = Fold.apply(Fold.initial(@t0), @ladder, :fail, @t0)
    assert s.level == 0
    assert s.due == @t0
    assert s.lapses == 1
  end

  test ":known jumps to the top and is due at the top interval; a later fail drops one" do
    s = Fold.apply(Fold.initial(@t0), @ladder, :known, @t0)

    assert s == %{
             level: 7,
             due: DateTime.add(@t0, 365, :day),
             reps: 1,
             lapses: 0,
             last_reviewed_at: @t0
           }

    assert %{level: 6, lapses: 1} = Fold.apply(s, @ladder, :fail, s.due)
  end

  test "replay is the same as applying one by one" do
    entries = [
      Fold.entry(:pass, @t0),
      Fold.entry(:pass, DateTime.add(@t0, 1, :day)),
      Fold.entry(:fail, DateTime.add(@t0, 5, :day))
    ]

    expected =
      Enum.reduce(entries, Fold.initial(@t0), fn e, s -> Fold.apply(s, @ladder, e) end)

    assert Fold.replay(@t0, @ladder, entries) == expected
    assert Fold.replay(@t0, @ladder, []) == Fold.initial(@t0)
  end

  test ":again drops to level 0 and is due after the level-0 interval; it is a lapse" do
    s = Fold.replay(@t0, @ladder, Enum.map(0..4, &Fold.entry(:pass, DateTime.add(@t0, &1, :day))))
    assert s.level == 5

    t = DateTime.add(@t0, 9, :day)
    again = Fold.apply(s, @ladder, :again, t)

    assert again.level == 0
    assert again.due == DateTime.add(t, 0, :day)
    assert again.reps == s.reps + 1
    assert again.lapses == s.lapses + 1
    assert again.last_reviewed_at == t
  end

  test "a defer moves due and touches nothing else" do
    s = Fold.apply(Fold.initial(@t0), @ladder, :pass, @t0)
    until = DateTime.add(@t0, 30, :day)

    deferred = Fold.apply(s, @ladder, Fold.entry(:defer, DateTime.add(@t0, 1, :hour), until))

    assert deferred == %{s | due: until}
  end
end
