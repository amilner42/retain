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
    reviews = [
      {:pass, @t0},
      {:pass, DateTime.add(@t0, 1, :day)},
      {:fail, DateTime.add(@t0, 5, :day)}
    ]

    expected =
      Enum.reduce(reviews, Fold.initial(@t0), fn {o, at}, s -> Fold.apply(s, @ladder, o, at) end)

    assert Fold.replay(@t0, @ladder, reviews) == expected
    assert Fold.replay(@t0, @ladder, []) == Fold.initial(@t0)
  end
end
