defmodule Retain.RebuildPropertyTest do
  @moduledoc """
  The invariant everything rests on: replaying the log reproduces live state, and history at the
  final date agrees with both.
  """
  use Retain.DataCase, async: true
  use ExUnitProperties

  alias Retain.Item

  @moduletag timeout: 120_000

  property "for any review log, rebuild == live and history == live" do
    check all n_items <- integer(1..5),
              log <- log_generator(n_items),
              max_runs: 30 do
      uid = "p#{System.unique_integer([:positive])}"
      user!(uid)
      items!(uid, Enum.map(0..(n_items - 1), &%{key: "k#{&1}", tags: %{g: "#{rem(&1, 2)}"}}))

      # Reviews must be applied in time order per item; sort the whole log by time.
      log
      |> Enum.sort_by(fn {_, _, hours} -> hours end)
      |> Enum.each(fn {i, outcome, hours} ->
        {:ok, _} = Retain.review(uid, "k#{i}", outcome, at: DateTime.add(t0(), hours, :hour))
      end)

      live = snapshot(uid)

      Repo.update_all(from(i in Item, join: u in assoc(i, :user), where: u.uid == ^uid),
        set: [level: 3, reps: 7, lapses: 2]
      )

      {:ok, _} = Retain.rebuild(uid)
      assert snapshot(uid) == live

      # history's reading for the last day must match the live aggregates.
      last_at = DateTime.add(t0(), 31 * 24, :hour)
      today = Retain.Clock.local_date(last_at, tz())
      {:ok, [point]} = Retain.history(uid, from: today, to: today, now: last_at)
      {:ok, [%{count: count, mean_level: mean}]} = Retain.summary(uid, now: last_at)
      explored = Enum.count(live, fn {_, s} -> s.reps > 0 end) / count

      assert point.count == count
      assert_in_delta point.explored, explored, 1.0e-9
      assert_in_delta point.acquired, mean / 6, 1.0e-9
    end
  end

  # {item index, outcome, hours after t0}
  defp log_generator(n_items) do
    entry =
      {integer(0..(n_items - 1)), member_of([:pass, :partial, :fail]), integer(0..(30 * 24))}

    list_of(entry, max_length: 40)
  end

  defp snapshot(uid) do
    from(i in Item, join: u in assoc(i, :user), where: u.uid == ^uid, order_by: i.key)
    |> Repo.all()
    |> Map.new(&{&1.key, Map.take(&1, [:level, :due, :reps, :lapses, :last_reviewed_at])})
  end
end
