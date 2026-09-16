defmodule Retain.Config do
  @moduledoc """
  Reads Retain's application configuration.

      config :retain,
        repo: MyApp.Repo,
        # optional: interval in days for each ladder level, index = level
        intervals: [0, 1, 3, 7, 21, 60, 120]

  `repo` is required. Everything else has a default.
  """

  @default_intervals [0, 1, 3, 7, 21, 60, 120]
  @default_scope "default"

  @doc "The host's `Ecto.Repo`. Raises with a setup hint when unconfigured."
  @spec repo!() :: module()
  def repo! do
    case Application.fetch_env(:retain, :repo) do
      {:ok, repo} when is_atom(repo) ->
        repo

      _ ->
        raise ArgumentError, """
        Retain needs to know your repo. Add this to your config:

            config :retain, repo: MyApp.Repo
        """
    end
  end

  @doc "Interval in days for each ladder level; the list index is the level."
  @spec intervals() :: [non_neg_integer(), ...]
  def intervals do
    case Application.get_env(:retain, :intervals, @default_intervals) do
      [_ | _] = intervals ->
        intervals

      other ->
        raise ArgumentError,
              "config :retain, :intervals must be a non-empty list, got: #{inspect(other)}"
    end
  end

  @doc "The scope used when a call passes none. Scopes partition users; see `Retain`."
  @spec default_scope() :: String.t()
  def default_scope, do: @default_scope
end
