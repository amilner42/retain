defmodule Retain.LogTest do
  @moduledoc "Amendment resolution, with no database in sight."
  use ExUnit.Case, async: true

  alias Retain.{Fold, Log}

  @t0 ~U[2026-07-15 03:00:00.000000Z]

  defp at(n), do: DateTime.add(@t0, n, :day)

  defp row(id, outcome, day, opts \\ []) do
    %{
      id: id,
      outcome: outcome,
      at: at(day),
      until: opts[:until],
      supersedes_id: opts[:supersedes_id]
    }
  end

  test "a log with no amendments is itself, oldest first" do
    rows = [row(2, :fail, 1), row(1, :pass, 0), row(3, :pass, 2)]

    assert Log.entries(rows) == [
             Fold.entry(:pass, at(0)),
             Fold.entry(:fail, at(1)),
             Fold.entry(:pass, at(2))
           ]
  end

  test "rows are ordered as instants, not as structs" do
    # 2026-07-01 vs 2026-06-02: term order on a DateTime compares `day` before `month`, so a
    # naive sort puts these the wrong way round.
    early = %{row(1, :pass, 0) | at: ~U[2026-06-02 00:00:00.000000Z]}
    late = %{row(2, :fail, 0) | at: ~U[2026-07-01 00:00:00.000000Z]}

    assert [%{outcome: :pass}, %{outcome: :fail}] = Log.entries([late, early])
  end

  test "an amendment replaces its target's outcome in the target's place in time" do
    rows = [row(1, :fail, 0), row(2, :pass, 1), row(3, :pass, 5, supersedes_id: 1)]

    # The correction sits on day 0, where the answer it corrects was given -- not on day 5.
    assert Log.entries(rows) == [Fold.entry(:pass, at(0)), Fold.entry(:pass, at(1))]
  end

  test "a chain takes the last word" do
    rows = [
      row(1, :fail, 0),
      row(2, :partial, 1, supersedes_id: 1),
      row(3, :known, 2, supersedes_id: 2)
    ]

    assert Log.entries(rows) == [Fold.entry(:known, at(0))]
  end

  test "two amendments of one row: the later one wins" do
    rows = [
      row(1, :fail, 0),
      row(2, :partial, 1, supersedes_id: 1),
      row(3, :pass, 3, supersedes_id: 1)
    ]

    assert Log.entries(rows) == [Fold.entry(:pass, at(0))]

    # ...and "later" is by instant, whatever order the rows arrive in.
    assert Log.entries(Enum.reverse(rows)) == [Fold.entry(:pass, at(0))]
  end

  test "corrections of one row are a tree, and the newest leaf wins" do
    # O has two corrections; one of those has a correction of its own. Following a single
    # chain from O picks whichever child it happens to keep and never sees row 4 at all.
    rows = [
      row(1, :fail, 0),
      row(2, :pass, 1, supersedes_id: 1),
      row(3, :partial, 2, supersedes_id: 1),
      row(4, :known, 3, supersedes_id: 2)
    ]

    assert Log.entries(rows) == [Fold.entry(:known, at(0))]
    assert Log.entries(Enum.reverse(rows)) == [Fold.entry(:known, at(0))]
  end

  test "the newest leaf is by instant, wherever it sits in the tree" do
    # The deepest correction is not the newest one here: row 3 is.
    rows = [
      row(1, :fail, 0),
      row(2, :pass, 1, supersedes_id: 1),
      row(3, :partial, 9, supersedes_id: 1),
      row(4, :known, 2, supersedes_id: 2)
    ]

    assert Log.entries(rows) == [Fold.entry(:partial, at(0))]
  end

  test "a defer keeps its until; an entry that is not a defer has none" do
    until = at(30)
    rows = [row(1, :pass, 0), row(2, :defer, 1, until: until)]

    assert Log.entries(rows) == [Fold.entry(:pass, at(0)), Fold.entry(:defer, at(1), until)]
  end

  test "a cycle resolves instead of hanging" do
    rows = [row(1, :fail, 0, supersedes_id: 2), row(2, :pass, 1, supersedes_id: 1)]

    # Both rows are amendments, so neither is an entry: nothing to fold, and no loop.
    assert Log.entries(rows) == []

    # A real entry whose corrections loop below it still terminates, and still answers.
    looped = [
      row(1, :fail, 0),
      row(2, :pass, 1, supersedes_id: 1),
      row(3, :known, 2, supersedes_id: 2),
      row(4, :partial, 3, supersedes_id: 3),
      %{row(5, :again, 4, supersedes_id: 4) | id: 2}
    ]

    assert [%{at: _}] = Log.entries(looped)
  end

  test "entry_row?/1 is what the ordering check asks" do
    assert Log.entry_row?(row(1, :pass, 0))
    refute Log.entry_row?(row(2, :pass, 1, supersedes_id: 1))
  end
end
