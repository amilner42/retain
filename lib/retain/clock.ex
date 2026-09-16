defmodule Retain.Clock do
  @moduledoc """
  Timezone arithmetic. Every calendar date Retain reasons about (streak days, due-today cutoffs,
  history buckets) is derived from a UTC instant and the user's IANA timezone through this module,
  so the DST and midnight edge cases live in one place.
  """

  @db Tz.TimeZoneDatabase

  @doc "True if `tz` is a known IANA timezone name."
  @spec valid?(term()) :: boolean()
  def valid?(tz) when is_binary(tz) do
    match?({:ok, _}, DateTime.shift_zone(~U[2020-01-01 00:00:00Z], tz, @db))
  end

  def valid?(_), do: false

  @doc "The calendar date at `instant` in `tz`."
  @spec local_date(DateTime.t(), String.t()) :: Date.t()
  def local_date(%DateTime{} = instant, tz) do
    instant |> DateTime.shift_zone!(tz, @db) |> DateTime.to_date()
  end

  @doc """
  The UTC instant at which `date` begins in `tz`.

  If midnight does not exist that day (a DST gap at 00:00, as in Chile or Cuba) the day starts at
  the first instant after the gap. If midnight is ambiguous (a DST fold at 00:00) the earlier one
  is used.
  """
  @spec start_of_day(Date.t(), String.t()) :: DateTime.t()
  def start_of_day(%Date{} = date, tz) do
    local =
      case DateTime.new(date, ~T[00:00:00], tz, @db) do
        {:ok, dt} -> dt
        {:gap, _before, after_gap} -> after_gap
        {:ambiguous, first, _second} -> first
      end

    DateTime.shift_zone!(local, "Etc/UTC", @db)
  end

  @doc "The UTC instant at which the day after `instant`'s local date begins in `tz`."
  @spec start_of_tomorrow(DateTime.t(), String.t()) :: DateTime.t()
  def start_of_tomorrow(%DateTime{} = instant, tz) do
    instant |> local_date(tz) |> Date.add(1) |> start_of_day(tz)
  end
end
