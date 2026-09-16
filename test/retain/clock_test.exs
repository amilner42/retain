defmodule Retain.ClockTest do
  use ExUnit.Case, async: true

  alias Retain.Clock

  describe "valid?/1" do
    test "accepts IANA names and rejects everything else" do
      assert Clock.valid?("America/Vancouver")
      assert Clock.valid?("Etc/UTC")
      assert Clock.valid?("Pacific/Kiritimati")
      refute Clock.valid?("PST")
      refute Clock.valid?("Mars/Olympus")
      refute Clock.valid?("")
      refute Clock.valid?(nil)
      refute Clock.valid?(:"America/Vancouver")
    end
  end

  describe "local_date/2" do
    # {instant, tz, expected local date}
    @cases [
      {~U[2026-07-15 03:00:00Z], "America/Vancouver", ~D[2026-07-14]},
      {~U[2026-07-15 06:59:59Z], "America/Vancouver", ~D[2026-07-14]},
      {~U[2026-07-15 07:00:00Z], "America/Vancouver", ~D[2026-07-15]},
      # PST in winter: UTC-8
      {~U[2026-01-15 07:59:59Z], "America/Vancouver", ~D[2026-01-14]},
      {~U[2026-01-15 08:00:00Z], "America/Vancouver", ~D[2026-01-15]},
      # Kiritimati is UTC+14: a UTC morning is already tomorrow.
      {~U[2026-07-15 10:00:00Z], "Pacific/Kiritimati", ~D[2026-07-16]},
      # Pago Pago is UTC-11.
      {~U[2026-07-15 10:00:00Z], "Pacific/Pago_Pago", ~D[2026-07-14]},
      {~U[2026-07-15 10:00:00Z], "Etc/UTC", ~D[2026-07-15]}
    ]

    for {instant, tz, expected} <- @cases do
      test "#{instant} in #{tz} is #{expected}" do
        assert Clock.local_date(unquote(Macro.escape(instant)), unquote(tz)) ==
                 unquote(Macro.escape(expected))
      end
    end
  end

  describe "start_of_day/2" do
    test "plain days" do
      assert Clock.start_of_day(~D[2026-07-15], "America/Vancouver") == ~U[2026-07-15 07:00:00Z]
      assert Clock.start_of_day(~D[2026-01-15], "America/Vancouver") == ~U[2026-01-15 08:00:00Z]
      assert Clock.start_of_day(~D[2026-07-15], "Etc/UTC") == ~U[2026-07-15 00:00:00Z]
    end

    test "the day of a spring-forward transition (02:00 -> 03:00) still starts at local midnight" do
      # Vancouver springs forward 2026-03-08 at 02:00 PST.
      assert Clock.start_of_day(~D[2026-03-08], "America/Vancouver") == ~U[2026-03-08 08:00:00Z]
      # The following day starts at 07:00Z, 23 hours later.
      assert Clock.start_of_day(~D[2026-03-09], "America/Vancouver") == ~U[2026-03-09 07:00:00Z]
    end

    test "the day of a fall-back transition is 25 hours long" do
      # Los Angeles falls back 2026-11-01 at 02:00 PDT. (Not Vancouver: the tz database has
      # British Columbia moving to permanent daylight time in November 2026.)
      start = Clock.start_of_day(~D[2026-11-01], "America/Los_Angeles")
      next = Clock.start_of_day(~D[2026-11-02], "America/Los_Angeles")
      assert DateTime.diff(next, start, :hour) == 25
    end

    test "a midnight that does not exist (DST gap at 00:00) starts the day after the gap" do
      # Chile springs forward at 00:00 -> 01:00 on the first Sunday of September.
      start = Clock.start_of_day(~D[2026-09-06], "America/Santiago")
      assert DateTime.shift_zone!(start, "America/Santiago", Tz.TimeZoneDatabase).hour == 1
      # ...and every instant that local day maps back to that date.
      assert Clock.local_date(start, "America/Santiago") == ~D[2026-09-06]

      assert Clock.local_date(DateTime.add(start, -1, :second), "America/Santiago") ==
               ~D[2026-09-05]
    end

    test "an ambiguous midnight (DST fold at 00:00) picks the earlier instant" do
      # Havana falls back 01:00 -> 00:00 on the first Sunday of November, so 00:00-01:00 on
      # 2026-11-01 happens twice.
      start = Clock.start_of_day(~D[2026-11-01], "America/Havana")
      assert Clock.local_date(start, "America/Havana") == ~D[2026-11-01]

      assert Clock.local_date(DateTime.add(start, -1, :second), "America/Havana") ==
               ~D[2026-10-31]
    end
  end

  describe "start_of_tomorrow/2" do
    test "is the first instant of the next local date" do
      now = ~U[2026-07-15 03:00:00Z]
      tomorrow = Clock.start_of_tomorrow(now, "America/Vancouver")
      assert tomorrow == ~U[2026-07-15 07:00:00Z]
      assert Clock.local_date(tomorrow, "America/Vancouver") == ~D[2026-07-15]

      assert Clock.local_date(DateTime.add(tomorrow, -1, :microsecond), "America/Vancouver") ==
               ~D[2026-07-14]
    end

    test "is always in the future and within 26 hours" do
      for tz <- [
            "America/Vancouver",
            "Pacific/Kiritimati",
            "Pacific/Pago_Pago",
            "Asia/Kolkata",
            "Etc/UTC"
          ],
          now <- [~U[2026-03-08 09:30:00Z], ~U[2026-11-01 08:30:00Z], ~U[2026-07-15 23:59:59Z]] do
        tomorrow = Clock.start_of_tomorrow(now, tz)
        assert DateTime.compare(tomorrow, now) == :gt, "#{tz} #{now}"
        assert DateTime.diff(tomorrow, now, :hour) <= 26, "#{tz} #{now}"
      end
    end
  end
end
