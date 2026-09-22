defmodule Retain.Log do
  @moduledoc """
  The append-only log, resolved into the entries `Retain.Fold` sees. Pure.

  A row is either an **entry** (`supersedes_id` is nil) or an **amendment** of one
  (`Retain.amend/5`). Rows are never updated or deleted, so a correction is another row; it is
  this module that makes the correction count.

  An amendment never enters the fold on its own. It replaces the outcome of the row it
  supersedes, *in that row's place in time* — so amending yesterday's `:fail` to `:pass` gives
  exactly the state a log that had said `:pass` yesterday would have produced. That is the whole
  point: `Retain.rebuild/2` over an amended log equals a rebuild of the corrected log.

  Corrections take the last word, and "last" is over the whole tree of them, not one chain.
  A host that amends a row twice, or amends an amendment, or does both, hands back whichever
  `review_id` it was last given -- so the amendments of one entry form a tree rather than a
  line, and the newest leaf anywhere in that tree is the answer. Ties break on row id, so the
  resolution is total and stable.
  """

  alias Retain.{Fold, Ladder}

  @typedoc "A row of `retain_reviews`, as loaded."
  @type row :: %{
          required(:id) => term(),
          required(:outcome) => Ladder.outcome() | :defer,
          required(:at) => DateTime.t(),
          required(:until) => DateTime.t() | nil,
          required(:supersedes_id) => term() | nil
        }

  @doc """
  The entries for one item, oldest first, with amendments resolved.

  Rows may arrive in any order. The result is a pure function of the rows.
  """
  @spec entries([row()]) :: [Fold.entry()]
  def entries(rows) do
    rows = sort(rows)
    corrections = rows |> Enum.filter(& &1.supersedes_id) |> Enum.group_by(& &1.supersedes_id)

    rows
    |> Enum.reject(& &1.supersedes_id)
    |> Enum.map(fn row ->
      last = last_word(row, corrections)
      Fold.entry(last.outcome, row.at, last.until)
    end)
  end

  @doc "The rows that are entries in their own right: what `at` values the fold actually sees."
  @spec entry_row?(row()) :: boolean()
  def entry_row?(row), do: is_nil(row.supersedes_id)

  # Rows carry UTC datetimes; compare them as instants, never as structs (term order on a
  # DateTime compares `day` before `month`).
  defp sort(rows), do: Enum.sort_by(rows, &{DateTime.to_unix(&1.at, :microsecond), &1.id})

  # The newest correction anywhere under `row`, or `row` itself when it has none.
  defp last_word(row, corrections) do
    case subtree(corrections, [row.id], MapSet.new([row.id]), []) do
      [] -> row
      found -> Enum.max_by(found, &{DateTime.to_unix(&1.at, :microsecond), &1.id})
    end
  end

  # Everything under these ids, breadth first. The visited set is global rather than per
  # branch, so a log some other writer corrupted into a cycle terminates instead of hanging.
  defp subtree(_corrections, [], _seen, found), do: found

  defp subtree(corrections, [id | rest], seen, found) do
    children =
      corrections |> Map.get(id, []) |> Enum.reject(&MapSet.member?(seen, &1.id))

    seen = Enum.reduce(children, seen, fn child, acc -> MapSet.put(acc, child.id) end)
    subtree(corrections, rest ++ Enum.map(children, & &1.id), seen, found ++ children)
  end
end
