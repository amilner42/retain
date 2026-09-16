defmodule Retain.DataCase do
  @moduledoc """
  Sandboxed DB tests. Every test runs in a transaction that is rolled back.

  Also provides `put_user/2`, `put_items/3` and `review!/4` fixtures that assume success, and
  fixed instants so tests never depend on the wall clock.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto.Query
      import Retain.DataCase

      alias Retain.TestRepo, as: Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Retain.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  # A Wednesday, 20:00 in Vancouver (PDT, UTC-7).
  def t0, do: ~U[2026-07-15 03:00:00.000000Z]
  def tz, do: "America/Vancouver"

  def user!(uid \\ "u1", opts \\ []) do
    {:ok, user} = Retain.put_user(uid, Keyword.put_new(opts, :tz, tz()))
    user
  end

  def items!(uid, keys_or_items, opts \\ []) do
    items =
      Enum.map(keys_or_items, fn
        k when is_binary(k) -> %{key: k}
        m when is_map(m) -> m
      end)

    {:ok, result} = Retain.put_items(uid, items, Keyword.put_new(opts, :now, t0()))
    result
  end

  def review!(uid, key, outcome, opts \\ []) do
    {:ok, result} = Retain.review(uid, key, outcome, Keyword.put_new(opts, :at, t0()))
    result
  end

  def item!(uid, key, opts \\ []) do
    {:ok, item} = Retain.fetch_item(uid, key, opts)
    item
  end

  def days(n, from \\ t0()), do: DateTime.add(from, n, :day)
end
