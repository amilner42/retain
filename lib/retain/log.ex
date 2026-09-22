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

  Chains take the last word. Amend an amendment and the newest wins; amend the same row twice
  and the later amendment wins (ties broken by row id, so the resolution is total and stable).
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

    # Sorted ascending, so a later amendment of the same row overwrites an earlier one here.
    amendments =
      rows
      |> Enum.filter(& &1.supersedes_id)
      |> Map.new(&{&1.supersedes_id, &1})

    rows
    |> Enum.reject(& &1.supersedes_id)
    |> Enum.map(fn row ->
      last = last_word(row, amendments, MapSet.new([row.id]))
      Fold.entry(last.outcome, row.at, last.until)
    end)
  end

  @doc "The rows that are entries in their own right: what `at` values the fold actually sees."
  @spec entry_row?(row()) :: boolean()
  def entry_row?(row), do: is_nil(row.supersedes_id)

  # Rows carry UTC datetimes; compare them as instants, never as structs (term order on a
  # DateTime compares `day` before `month`).
  defp sort(rows), do: Enum.sort_by(rows, &{DateTime.to_unix(&1.at, :microsecond), &1.id})

  defp last_word(row, amendments, seen) do
    case Map.fetch(amendments, row.id) do
      {:ok, next} ->
        # A chain can only point backwards in time, so this cannot loop; guard anyway rather
        # than hang on a log some other writer corrupted.
        if MapSet.member?(seen, next.id),
          do: row,
          else: last_word(next, amendments, MapSet.put(seen, next.id))

      :error ->
        row
    end
  end
end
