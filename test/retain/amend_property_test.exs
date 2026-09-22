defmodule Retain.AmendPropertyTest do
  @moduledoc """
  The invariant that makes an append-only correction safe: amending a log and rebuilding it gives
  exactly the state a log that had said the right thing all along would have given.
  """
  use Retain.DataCase, async: true
  use ExUnitProperties

  alias Retain.Ladder

  @moduletag timeout: 120_000

  property "amend then rebuild == a fresh log with the corrected outcome" do
    check all steps <- list_of(step(), min_length: 1, max_length: 12),
              correction <- member_of(Ladder.outcomes()),
              pick <- integer(0..50),
              max_runs: 25 do
      uid = "amend#{System.unique_integer([:positive])}"
      user!(uid)
      items!(uid, [%{key: "a"}, %{key: "b"}])

      written = play(uid, "a", steps)
      attempts = Enum.reject(written, fn {_index, outcome, _id} -> outcome == :defer end)

      if attempts != [] do
        {index, _outcome, review_id} = Enum.at(attempts, rem(pick, length(attempts)))

        {:ok, _} = Retain.amend(uid, "a", review_id, correction, at: hours(1000))
        {:ok, _} = Retain.rebuild(uid)

        # The same log, written correctly the first time, onto an identical item.
        play(uid, "b", List.replace_at(steps, index, {:review, correction}))

        assert derived(item!(uid, "a")) == derived(item!(uid, "b"))
      end
    end
  end

  property "again and defer round-trip through rebuild" do
    check all steps <- list_of(step(), min_length: 1, max_length: 12), max_runs: 25 do
      uid = "roundtrip#{System.unique_integer([:positive])}"
      user!(uid)
      items!(uid, [%{key: "a"}])
      play(uid, "a", steps)

      live = derived(item!(uid, "a"))

      # Scribble over the derived fields so a rebuild that did nothing would be caught.
      Repo.update_all(from(i in Retain.Item, join: u in assoc(i, :user), where: u.uid == ^uid),
        set: [level: 3, reps: 7, lapses: 2, due: hours(9999)]
      )

      {:ok, _} = Retain.rebuild(uid)
      assert derived(item!(uid, "a")) == live
    end
  end

  # One step of a log: an attempt, or a defer to somewhere between 1 and 60 days out.
  defp step do
    one_of([
      tuple({constant(:review), member_of(Ladder.outcomes())}),
      tuple({constant(:defer), integer(1..60)})
    ])
  end

  # Writes the steps an hour apart, oldest first. Returns {index, outcome, review_id} per step.
  defp play(uid, key, steps) do
    steps
    |> Enum.with_index()
    |> Enum.map(fn {stepp, index} ->
      at = hours(index)

      case stepp do
        {:review, outcome} ->
          {:ok, %{review_id: id}} = Retain.review(uid, key, outcome, at: at)
          {index, outcome, id}

        {:defer, days_ahead} ->
          {:ok, %{review_id: id}} = Retain.defer(uid, key, days(days_ahead, at), at: at)
          {index, :defer, id}
      end
    end)
  end

  defp hours(n), do: DateTime.add(t0(), n, :hour)
  defp derived(item), do: Map.take(item, [:level, :due, :reps, :lapses, :last_reviewed_at])
end
