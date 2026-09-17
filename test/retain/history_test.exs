defmodule Retain.HistoryTest do
  use ExUnit.Case, async: true

  alias Retain.{History, Ladder}

  @ladder Ladder.new([0, 1, 3, 7, 21, 58, 145, 365])
  @tz "America/Vancouver"
  # 20:00 local on 2026-07-14
  @t0 ~U[2026-07-15 03:00:00Z]

  defp d(n), do: Date.add(~D[2026-07-14], n)
  defp t(n), do: DateTime.add(@t0, n, :day)

  test "empty input gives an empty series" do
    assert History.series([], @ladder, @tz, d(0), d(5)) == []
  end

  test "from after to gives an empty series" do
    assert History.series([{:item, 1, nil, @t0}], @ladder, @tz, d(5), d(0)) == []
  end

  test "one item, no reviews: exists from its creation date, unexplored, unacquired" do
    series = History.series([{:item, 1, nil, t(1)}], @ladder, @tz, d(0), d(2))

    assert series == [
             %{date: d(1), group: nil, count: 1, explored: 0.0, acquired: 0.0},
             %{date: d(2), group: nil, count: 1, explored: 0.0, acquired: 0.0}
           ]
  end

  test "reviews move the readings and quiet days carry forward" do
    events = [
      {:item, 1, nil, t(0)},
      {:item, 2, nil, t(0)},
      {:review, 1, :pass, t(0)},
      {:review, 1, :pass, t(1)},
      {:review, 2, :fail, t(3)}
    ]

    series = History.series(events, @ladder, @tz, d(0), d(4))
    by_date = Map.new(series, &{&1.date, &1})

    assert by_date[d(0)] == %{date: d(0), group: nil, count: 2, explored: 0.5, acquired: 1 / 14}
    assert by_date[d(1)] == %{date: d(1), group: nil, count: 2, explored: 0.5, acquired: 2 / 14}
    assert by_date[d(2)] == by_date[d(1)] |> Map.put(:date, d(2))
    assert by_date[d(3)] == %{date: d(3), group: nil, count: 2, explored: 1.0, acquired: 2 / 14}
    assert by_date[d(4)] == by_date[d(3)] |> Map.put(:date, d(4))
  end

  test "events before `from` are applied, events after `to` are not" do
    events = [{:item, 1, nil, t(0)}, {:review, 1, :pass, t(0)}, {:review, 1, :pass, t(5)}]

    assert History.series(events, @ladder, @tz, d(2), d(2)) ==
             [%{date: d(2), group: nil, count: 1, explored: 1.0, acquired: 1 / 7}]
  end

  test "groups are separate series, appearing when their first item does" do
    events = [
      {:item, 1, "cube", t(0)},
      {:item, 2, "move", t(1)},
      {:review, 2, :pass, t(1)}
    ]

    series = History.series(events, @ladder, @tz, d(0), d(1))

    assert series == [
             %{date: d(0), group: "cube", count: 1, explored: 0.0, acquired: 0.0},
             %{date: d(1), group: "cube", count: 1, explored: 0.0, acquired: 0.0},
             %{date: d(1), group: "move", count: 1, explored: 1.0, acquired: 1 / 7}
           ]
  end

  test "reviews for unknown items are ignored, duplicate item events are idempotent" do
    events = [{:item, 1, nil, t(0)}, {:item, 1, nil, t(0)}, {:review, 9, :pass, t(0)}]
    assert [%{count: 1, explored: +0.0}] = History.series(events, @ladder, @tz, d(0), d(0))
  end

  test "event order in the input does not matter" do
    events = [
      {:review, 1, :pass, t(2)},
      {:review, 1, :fail, t(1)},
      {:item, 1, nil, t(0)},
      {:review, 1, :pass, t(0)}
    ]

    assert History.series(events, @ladder, @tz, d(0), d(2)) ==
             History.series(Enum.reverse(events), @ladder, @tz, d(0), d(2))

    assert [_, _, %{acquired: sixth}] = History.series(events, @ladder, @tz, d(0), d(2))
    assert sixth == 1 / 7
  end

  test "days are local: a review at 23:30 Vancouver counts for that local date" do
    # 2026-07-15 06:30Z is 23:30 PDT on 2026-07-14.
    events = [{:item, 1, nil, @t0}, {:review, 1, :pass, ~U[2026-07-15 06:30:00Z]}]

    assert [%{date: ~D[2026-07-14], explored: 1.0}] =
             History.series(events, @ladder, @tz, d(0), d(0))

    # In UTC both the item (03:00Z) and the review are on the 15th, so there is no reading for
    # the 14th at all.
    assert [%{date: ~D[2026-07-15], explored: 1.0}] =
             History.series(events, @ladder, "Etc/UTC", d(0), d(1))
  end
end
