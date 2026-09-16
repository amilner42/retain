defmodule Retain.StreakParityTest do
  @moduledoc """
  `Retain.streak/2` computes local dates in SQL; everything else uses `Retain.Clock`. This pins
  the two to each other across timezones and DST edges.
  """
  use Retain.DataCase, async: true
  use ExUnitProperties

  alias Retain.Clock

  @zones [
    "America/Vancouver",
    "America/Los_Angeles",
    "America/Santiago",
    "America/Havana",
    "Pacific/Kiritimati",
    "Pacific/Pago_Pago",
    "Asia/Kathmandu",
    "Australia/Lord_Howe",
    "Etc/UTC"
  ]
  @epoch ~U[2026-01-01 00:00:00.000000Z]

  property "SQL local dates agree with Clock.local_date for every review" do
    check all tz <- member_of(@zones),
              offsets <- list_of(integer(0..(365 * 24 * 3600)), min_length: 1, max_length: 12),
              max_runs: 40 do
      uid = "parity#{System.unique_integer([:positive])}"
      user!(uid, tz: tz)
      items!(uid, ["a"], now: @epoch)

      instants = offsets |> Enum.sort() |> Enum.map(&DateTime.add(@epoch, &1, :second))
      Enum.each(instants, &review!(uid, "a", :pass, at: &1))

      expected = instants |> Enum.map(&Clock.local_date(&1, tz)) |> Enum.uniq() |> length()
      assert {:ok, %{days_active: ^expected}} = Retain.streak(uid, now: List.last(instants))
    end
  end

  test "instants either side of every DST transition land on the right local day" do
    # {tz, instant just before, instant just after}: the transitions in 2026.
    transitions = [
      {"America/Los_Angeles", ~U[2026-03-08 09:59:59Z], ~U[2026-03-08 10:00:00Z]},
      {"America/Los_Angeles", ~U[2026-11-01 08:59:59Z], ~U[2026-11-01 09:00:00Z]},
      {"America/Santiago", ~U[2026-09-06 03:59:59Z], ~U[2026-09-06 04:00:00Z]},
      {"America/Havana", ~U[2026-11-01 04:59:59Z], ~U[2026-11-01 05:00:00Z]}
    ]

    for {tz, before, after_} <- transitions do
      uid = "dst-#{System.unique_integer([:positive])}"
      user!(uid, tz: tz)
      items!(uid, ["a"], now: @epoch)
      review!(uid, "a", :pass, at: before)
      review!(uid, "a", :pass, at: after_)

      expected =
        [before, after_] |> Enum.map(&Clock.local_date(&1, tz)) |> Enum.uniq() |> length()

      assert {:ok, %{days_active: ^expected}} = Retain.streak(uid, now: after_)
    end
  end
end
