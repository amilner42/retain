defmodule Retain.Fold do
  @moduledoc """
  The one function that turns log entries into ladder state, and the accumulator it produces.

  `Retain.review/4` applies it live; `Retain.rebuild/2` and `Retain.history/2` replay it over the
  log. Because all three share this module, "fold the log" and "live state" can never drift apart.

  An entry is either an attempt (`:pass`, `:partial`, `:fail`, `:again`, `:known`) or a `:defer`,
  which carries the `until` it moves `due` to. A defer is not an attempt: it leaves the level, the
  counters and `last_reviewed_at` alone. Entries come from `Retain.Log`, which resolves
  amendments before the fold sees them, so the fold never has to know a correction happened.
  """

  alias Retain.Ladder

  @type state :: %{
          level: Ladder.level(),
          due: DateTime.t(),
          reps: non_neg_integer(),
          lapses: non_neg_integer(),
          last_reviewed_at: DateTime.t() | nil
        }

  @typedoc "One thing that happened to an item, as the fold sees it."
  @type entry :: %{
          outcome: Ladder.outcome() | :defer,
          at: DateTime.t(),
          until: DateTime.t() | nil
        }

  @doc "The state of an item that has never been reviewed: level 0, due the moment it was created."
  @spec initial(DateTime.t()) :: state()
  def initial(%DateTime{} = created_at) do
    %{level: 0, due: created_at, reps: 0, lapses: 0, last_reviewed_at: nil}
  end

  @doc "Builds an entry. `until` is only read for `:defer`."
  @spec entry(Ladder.outcome() | :defer, DateTime.t(), DateTime.t() | nil) :: entry()
  def entry(outcome, %DateTime{} = at, until \\ nil) when is_atom(outcome) do
    %{outcome: outcome, at: at, until: until}
  end

  @doc """
  Applies one entry.

  `apply(state, ladder, outcome, at)` is the shorthand for an attempt.
  """
  @spec apply(state(), Ladder.t(), entry()) :: state()
  def apply(state, ladder, entry)

  def apply(state, %Ladder{}, %{outcome: :defer, until: %DateTime{} = until}) do
    %{state | due: until}
  end

  def apply(%{level: level} = state, %Ladder{} = ladder, %{outcome: outcome, at: %DateTime{} = at}) do
    next_level = Ladder.step(ladder, level, outcome)

    %{
      state
      | level: next_level,
        due: Ladder.due_after(ladder, next_level, at),
        reps: state.reps + 1,
        lapses: state.lapses + if(Ladder.lapse?(outcome), do: 1, else: 0),
        last_reviewed_at: at
    }
  end

  @spec apply(state(), Ladder.t(), Ladder.outcome(), DateTime.t()) :: state()
  def apply(state, %Ladder{} = ladder, outcome, %DateTime{} = at) when is_atom(outcome) do
    __MODULE__.apply(state, ladder, entry(outcome, at))
  end

  @doc """
  Replays entries, already sorted by time, from the initial state.
  """
  @spec replay(DateTime.t(), Ladder.t(), [entry()]) :: state()
  def replay(%DateTime{} = created_at, %Ladder{} = ladder, entries) do
    Enum.reduce(entries, initial(created_at), fn entry, state ->
      __MODULE__.apply(state, ladder, entry)
    end)
  end
end
