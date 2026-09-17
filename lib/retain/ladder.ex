defmodule Retain.Ladder do
  @moduledoc """
  The Leitner ladder: a level per item and an interval per level. Pure.

  An item starts at level 0 and is due immediately. Each review moves it:

    * `:pass`    climbs one level
    * `:partial` holds
    * `:fail`    drops one level
    * `:known`   jumps to the top level ("I already know this")

  The top level still resurfaces at its interval so it can be lost again.

      iex> ladder = Retain.Ladder.new([0, 1, 3, 7, 21, 58, 145, 365])
      iex> Retain.Ladder.step(ladder, 2, :pass)
      3
      iex> Retain.Ladder.step(ladder, 7, :pass)
      7
      iex> Retain.Ladder.step(ladder, 0, :fail)
      0
      iex> Retain.Ladder.step(ladder, 4, :partial)
      4
      iex> Retain.Ladder.step(ladder, 1, :known)
      7
      iex> Retain.Ladder.interval_days(ladder, 3)
      7
      iex> Retain.Ladder.due_after(ladder, 3, ~U[2026-01-01 12:00:00Z])
      ~U[2026-01-08 12:00:00Z]
  """

  @enforce_keys [:intervals]
  defstruct [:intervals]

  @type outcome :: :pass | :partial | :fail | :known
  @type level :: non_neg_integer()
  @type t :: %__MODULE__{intervals: tuple()}

  @outcomes [:pass, :partial, :fail, :known]

  @doc "All valid outcomes."
  @spec outcomes() :: [outcome(), ...]
  def outcomes, do: @outcomes

  @doc "Builds a ladder from a list of day intervals; the list index is the level."
  @spec new([non_neg_integer(), ...]) :: t()
  def new(intervals) do
    unless is_list(intervals) and intervals != [] and
             Enum.all?(intervals, &(is_integer(&1) and &1 >= 0)) do
      raise ArgumentError,
            "ladder intervals must be a non-empty list of non-negative integers, got: #{inspect(intervals)}"
    end

    %__MODULE__{intervals: List.to_tuple(intervals)}
  end

  @doc "The ladder from application config (`config :retain, intervals: [...]`)."
  @spec default() :: t()
  def default, do: new(Retain.Config.intervals())

  @doc "The highest level."
  @spec max(t()) :: level()
  def max(%__MODULE__{intervals: intervals}), do: tuple_size(intervals) - 1

  @doc "The next level after reviewing at `level` with `outcome`."
  @spec step(t(), level(), outcome()) :: level()
  def step(%__MODULE__{} = ladder, level, :pass), do: min(level + 1, max(ladder))
  def step(%__MODULE__{}, level, :partial), do: level
  def step(%__MODULE__{}, level, :fail), do: Kernel.max(level - 1, 0)
  def step(%__MODULE__{} = ladder, _level, :known), do: max(ladder)

  @doc "Days until an item at `level` is due again."
  @spec interval_days(t(), level()) :: non_neg_integer()
  def interval_days(%__MODULE__{intervals: intervals}, level)
      when level >= 0 and level < tuple_size(intervals) do
    elem(intervals, level)
  end

  @doc "When an item reviewed at `at` and now at `level` is next due."
  @spec due_after(t(), level(), DateTime.t()) :: DateTime.t()
  def due_after(%__MODULE__{} = ladder, level, %DateTime{} = at) do
    DateTime.add(at, interval_days(ladder, level), :day)
  end

  @doc "True for `:pass`, `:partial`, `:fail`."
  @spec outcome?(term()) :: boolean()
  def outcome?(term), do: term in @outcomes
end
