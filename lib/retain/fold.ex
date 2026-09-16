defmodule Retain.Fold do
  @moduledoc """
  The one function that turns reviews into ladder state, and the accumulator it produces.

  `Retain.review/4` applies it live; `Retain.rebuild/2` and `Retain.history/2` replay it over the
  log. Because all three share this module, "fold the log" and "live state" can never drift apart.
  """

  alias Retain.Ladder

  @type state :: %{
          level: Ladder.level(),
          due: DateTime.t(),
          reps: non_neg_integer(),
          lapses: non_neg_integer(),
          last_reviewed_at: DateTime.t() | nil
        }

  @doc "The state of an item that has never been reviewed: level 0, due the moment it was created."
  @spec initial(DateTime.t()) :: state()
  def initial(%DateTime{} = created_at) do
    %{level: 0, due: created_at, reps: 0, lapses: 0, last_reviewed_at: nil}
  end

  @doc "Applies one review."
  @spec apply(state(), Ladder.t(), Ladder.outcome(), DateTime.t()) :: state()
  def apply(%{level: level} = state, %Ladder{} = ladder, outcome, %DateTime{} = at) do
    next_level = Ladder.step(ladder, level, outcome)

    %{
      state
      | level: next_level,
        due: Ladder.due_after(ladder, next_level, at),
        reps: state.reps + 1,
        lapses: state.lapses + if(outcome == :fail, do: 1, else: 0),
        last_reviewed_at: at
    }
  end

  @doc """
  Replays a list of `{outcome, at}` pairs, already sorted by time, from the initial state.
  """
  @spec replay(DateTime.t(), Ladder.t(), [{Ladder.outcome(), DateTime.t()}]) :: state()
  def replay(%DateTime{} = created_at, %Ladder{} = ladder, reviews) do
    Enum.reduce(reviews, initial(created_at), fn {outcome, at}, state ->
      apply(state, ladder, outcome, at)
    end)
  end
end
