defmodule Retain.LadderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Retain.Ladder

  doctest Ladder

  @ladder Ladder.new([0, 1, 3, 7, 21, 58, 145, 365])

  test "default ladder comes from config" do
    assert Ladder.default() == @ladder
    assert Ladder.max(@ladder) == 7
  end

  test "rejects bad intervals" do
    for bad <- [[], [1, -1], [1, 2.5], [1, "3"], [nil]] do
      assert_raise ArgumentError, fn -> Ladder.new(bad) end
    end
  end

  test "interval_days is only defined for real levels" do
    assert Ladder.interval_days(@ladder, 0) == 0
    assert Ladder.interval_days(@ladder, 7) == 365
    assert_raise FunctionClauseError, fn -> Ladder.interval_days(@ladder, 8) end
    assert_raise FunctionClauseError, fn -> Ladder.interval_days(@ladder, -1) end
  end

  test "outcome?/1" do
    assert Ladder.outcome?(:pass)
    assert Ladder.outcome?(:partial)
    assert Ladder.outcome?(:fail)
    assert Ladder.outcome?(:known)
    refute Ladder.outcome?(:correct)
    refute Ladder.outcome?("pass")
  end

  property "step always lands on a real level, and moves at most one except for :known" do
    check all level <- integer(0..7), outcome <- member_of(Ladder.outcomes()) do
      next = Ladder.step(@ladder, level, outcome)
      assert next in 0..7
      if outcome == :known, do: assert(next == 7), else: assert(abs(next - level) <= 1)
    end
  end

  property "pass never lowers, fail never raises, partial never moves" do
    check all level <- integer(0..7) do
      assert Ladder.step(@ladder, level, :pass) >= level
      assert Ladder.step(@ladder, level, :fail) <= level
      assert Ladder.step(@ladder, level, :partial) == level
    end
  end

  property "due_after is exactly interval days later" do
    check all level <- integer(0..7), offset <- integer(0..100_000) do
      at = DateTime.add(~U[2026-01-01 00:00:00Z], offset, :second)
      due = Ladder.due_after(@ladder, level, at)
      assert DateTime.diff(due, at, :day) == Ladder.interval_days(@ladder, level)
    end
  end
end
