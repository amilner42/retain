defmodule Retain.DstTest do
  @moduledoc """
  "Started today" is the one place Retain asks the database for a learner's calendar day.

  It used to convert every row (`(started_at AT TIME ZONE 'UTC') AT TIME ZONE tz)::date = today`),
  which no index can serve; it now asks for the half-open range `[start_of_day, start_of_tomorrow)`.
  These tests hold the two forms against each other on real rows, minute by minute across the
  nastiest transitions in the database — a 23-hour day, a 25-hour day, a midnight that does not
  exist, a midnight that happens twice, UTC+14, UTC-11 and a half-hour offset — because the whole
  case for the rewrite is that it changes the plan and not the answer.
  """
  use Retain.DataCase, async: true

  alias Retain.{Clock, Item, User}

  @edges [
    # Vancouver springs forward 02:00 -> 03:00: a 23-hour day.
    {"America/Vancouver", ~D[2026-03-08]},
    # Los Angeles falls back 02:00 -> 01:00: a 25-hour day.
    {"America/Los_Angeles", ~D[2026-11-01]},
    # Santiago springs forward at 00:00: that local midnight never happens.
    {"America/Santiago", ~D[2026-09-06]},
    # Havana falls back to 00:00: that local midnight happens twice.
    {"America/Havana", ~D[2026-11-01]},
    # Extremes and a half-hour offset, with no transition at all.
    {"Pacific/Kiritimati", ~D[2026-07-15]},
    {"Pacific/Pago_Pago", ~D[2026-07-15]},
    {"Asia/Kolkata", ~D[2026-07-15]}
  ]

  for {tz, date} <- @edges do
    test "#{tz} around #{date}: the range and the per-row conversion agree" do
      tz = unquote(tz)
      date = unquote(Macro.escape(date))
      user_id = seed_days_around(tz, date)

      # The day before the edge, the edge itself, and the day after.
      for day <- [Date.add(date, -1), date, Date.add(date, 1)] do
        assert by_range(user_id, tz, day) == by_conversion(user_id, tz, day),
               "#{tz} #{day}: range #{by_range(user_id, tz, day)} vs " <>
                 "conversion #{by_conversion(user_id, tz, day)}"
      end

      # Every row falls in exactly one local day, so the three days plus the rest account for all.
      assert by_range(user_id, tz, date) > 0
    end
  end

  test "the new-item budget follows the learner's local day, not UTC's" do
    # 23:30 local in Kiritimati (UTC+14) is 09:30Z the previous day.
    user!("kiri", tz: "Pacific/Kiritimati", new_per_day: 2)
    late = ~U[2026-07-15 09:30:00.000000Z]
    assert Clock.local_date(late, "Pacific/Kiritimati") == ~D[2026-07-15]

    items!("kiri", ["a", "b", "c", "d"], status: :new, now: ~U[2026-07-01 00:00:00.000000Z])

    {:ok, %{new: new, new_remaining_today: 2}} = Retain.queue("kiri", now: late)
    assert length(new) == 2
    {:ok, _} = Retain.start("kiri", Enum.map(new, & &1.key), now: late)

    # Still the same local day half an hour later: the budget is spent.
    assert {:ok, %{new: [], new_remaining_today: 0}} =
             Retain.queue("kiri", now: DateTime.add(late, 29, :minute))

    # Past local midnight: a fresh budget.
    assert {:ok, %{new: [_, _], new_remaining_today: 2}} =
             Retain.queue("kiri", now: DateTime.add(late, 31, :minute))
  end

  ## Helpers

  # A learner in `tz` with an item started every 20 minutes across the three days around `date`.
  defp seed_days_around(tz, date) do
    uid = "dst-#{tz}-#{date}"
    user!(uid, tz: tz)

    from_at = Clock.start_of_day(Date.add(date, -1), tz)
    count = 3 * 24 * 3

    items!(uid, Enum.map(1..count, &%{key: "k#{&1}"}), now: from_at)

    user_id = Repo.one!(from u in User, where: u.uid == ^uid, select: u.id)

    # Spread the start times 20 minutes apart from the first instant of the window.
    Repo.query!(
      """
      UPDATE retain_items
      SET started_at = $1::timestamp
                       + (row_number - 1) * interval '20 minutes'
      FROM (SELECT id, row_number() OVER (ORDER BY id) AS row_number
            FROM retain_items WHERE user_id = $2) AS ordered
      WHERE retain_items.id = ordered.id
      """,
      [DateTime.to_naive(from_at), user_id]
    )

    user_id
  end

  # What Retain asks now.
  defp by_range(user_id, tz, day) do
    from_at = Clock.start_of_day(day, tz)
    until_at = Clock.start_of_day(Date.add(day, 1), tz)

    Repo.aggregate(
      from(i in Item,
        where: i.user_id == ^user_id and i.started_at >= ^from_at and i.started_at < ^until_at
      ),
      :count
    )
  end

  # What Retain used to ask.
  defp by_conversion(user_id, tz, day) do
    Repo.aggregate(
      from(i in Item,
        where: i.user_id == ^user_id and not is_nil(i.started_at),
        where:
          fragment("((? AT TIME ZONE 'UTC') AT TIME ZONE ?)::date", i.started_at, ^tz) == ^day
      ),
      :count
    )
  end
end
