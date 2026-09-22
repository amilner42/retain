defmodule Retain.History do
  @moduledoc """
  Progress over time, computed by replaying items and reviews through the ladder and taking a
  reading at the end of every local day. Pure: give it the events and it gives you the series.
  """

  alias Retain.{Clock, Fold, Ladder}

  @typedoc """
  An item creation, or one log entry for it.

  The entries are `Retain.Log`'s, not raw rows: amendments are already resolved, so an entry sits
  on the day the answer it corrects was given.
  """
  @type event ::
          {:item, item_id :: term(), group :: String.t() | nil, created_at :: DateTime.t()}
          | {:review, item_id :: term(), Fold.entry()}

  @typedoc """
  One reading: how many items existed in the group that day, what share had been reviewed at
  least once (`explored`), and the mean level as a share of the top level (`acquired`).
  """
  @type point :: %{
          date: Date.t(),
          group: String.t() | nil,
          count: non_neg_integer(),
          explored: float(),
          acquired: float()
        }

  @doc """
  Readings for every date from `from` to `to` inclusive, per group, in date order.

  Events may be in any order. Days with no events repeat the previous reading, so the series is
  continuous. A group appears from the first day one of its items exists.
  """
  @spec series([event()], Ladder.t(), String.t(), Date.t(), Date.t()) :: [point()]
  def series(events, %Ladder{} = ladder, tz, %Date{} = from, %Date{} = to) do
    if Date.compare(from, to) == :gt do
      []
    else
      events =
        events
        |> Enum.map(&{Clock.local_date(event_at(&1), tz), &1})
        |> Enum.sort_by(
          fn {date, event} -> {date, event_at(event), event_rank(event)} end,
          &sort_key_lte/2
        )

      {items, groups, rest} = apply_through(events, Date.add(from, -1), %{}, %{}, ladder)

      from
      |> Date.range(to)
      |> Enum.reduce({items, groups, rest, []}, fn date, {items, groups, rest, acc} ->
        {items, groups, rest} = apply_through(rest, date, items, groups, ladder)
        {items, groups, rest, [readings(date, groups, ladder) | acc]}
      end)
      |> elem(3)
      |> Enum.reverse()
      |> List.flatten()
    end
  end

  # Applies every event dated on or before `date`; returns the untouched remainder.
  defp apply_through([{date, event} | rest], through, items, groups, ladder) do
    if Date.compare(date, through) != :gt do
      {items, groups} = apply_event(event, items, groups, ladder)
      apply_through(rest, through, items, groups, ladder)
    else
      {items, groups, [{date, event} | rest]}
    end
  end

  defp apply_through([], _through, items, groups, _ladder), do: {items, groups, []}

  # items:  item_id => {group, state}
  # groups: group   => %{count, explored, level_sum}
  defp apply_event({:item, id, group, created_at}, items, groups, _ladder) do
    if Map.has_key?(items, id) do
      {items, groups}
    else
      items = Map.put(items, id, {group, Fold.initial(created_at)})

      groups =
        Map.update(
          groups,
          group,
          %{count: 1, explored: 0, level_sum: 0},
          &%{&1 | count: &1.count + 1}
        )

      {items, groups}
    end
  end

  defp apply_event({:review, id, entry}, items, groups, ladder) do
    case Map.fetch(items, id) do
      {:ok, {group, before}} ->
        after_ = Fold.apply(before, ladder, entry)
        items = Map.put(items, id, {group, after_})

        groups =
          Map.update!(groups, group, fn g ->
            %{
              g
              | explored: g.explored + if(before.reps == 0, do: 1, else: 0),
                level_sum: g.level_sum - before.level + after_.level
            }
          end)

        {items, groups}

      # A review for an item we were not given (filtered out by the caller): ignore it.
      :error ->
        {items, groups}
    end
  end

  defp readings(date, groups, ladder) do
    max = Ladder.max(ladder)

    groups
    |> Enum.sort_by(fn {group, _} -> group end)
    |> Enum.map(fn {group, %{count: count, explored: explored, level_sum: level_sum}} ->
      %{
        date: date,
        group: group,
        count: count,
        explored: explored / count,
        acquired: if(max == 0, do: 1.0, else: level_sum / (count * max))
      }
    end)
  end

  defp event_at({:item, _, _, at}), do: at
  defp event_at({:review, _, entry}), do: entry.at

  # An item must exist before it is reviewed at the same instant.
  defp event_rank({:item, _, _, _}), do: 0
  defp event_rank({:review, _, _}), do: 1

  defp sort_key_lte({d1, t1, r1}, {d2, t2, r2}) do
    case Date.compare(d1, d2) do
      :lt ->
        true

      :gt ->
        false

      :eq ->
        case DateTime.compare(t1, t2) do
          :lt -> true
          :gt -> false
          :eq -> r1 <= r2
        end
    end
  end
end
