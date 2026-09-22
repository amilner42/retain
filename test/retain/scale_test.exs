defmodule Retain.ScaleTest do
  @moduledoc """
  What a session costs a learner with a real deck behind them (5,000 items).

  These assert the *plan*, not the clock: that `due/2` and `queue/2` read their two purpose-built
  indexes and never sort the learner's whole deck to find twenty rows. A wall-clock bound would
  be flaky on a loaded machine; a sequential scan or a sort node is a regression whatever the
  machine is doing. The timings are printed so a change to them is visible in CI output.
  """
  use Retain.DataCase, async: false

  @items 5_000
  @moduletag :scale

  setup do
    user!("big", new_per_day: 20)

    # 4,000 in rotation, spread over every level and a wide range of due dates; 1,000 still new.
    active =
      for n <- 1..4_000 do
        %{key: "a#{n}", position: n, tags: %{kind: Enum.at(~w(cube move), rem(n, 2))}}
      end

    new = for n <- 1..1_000, do: %{key: "n#{n}", position: n, tags: %{kind: "cube"}}

    {:ok, %{inserted: 4_000}} = Retain.put_items("big", active, now: t0(), status: :active)
    {:ok, %{inserted: 1_000}} = Retain.put_items("big", new, now: t0(), status: :new)

    # Spread level, due and the day each item entered rotation, so the ordering has real work to
    # do and "started today" is the small slice it is for a real learner.
    Repo.query!("""
    UPDATE retain_items
    SET level = id % 8,
        due = due + ((id % 400) - 200) * interval '1 day',
        started_at = started_at - (id % 365) * interval '1 day',
        inserted_at = inserted_at - (id % 365) * interval '1 day'
    WHERE started_at IS NOT NULL
    """)

    Repo.query!("ANALYZE retain_items")
    :ok
  end

  test "due/2 reads the due index, sorts nothing, and touches a handful of rows" do
    {{:ok, items}, queries} = capture(fn -> Retain.due("big", limit: 20, now: t0()) end)
    assert length(items) == 20

    plan = explain(pick(queries, "retain_items"))

    assert plan =~ "retain_items_due_index", plan
    refute plan =~ "Seq Scan on retain_items", plan
    refute plan =~ "Sort", plan

    IO.puts("\n  due/2 over #{@items} items: #{ms(queries)} ms\n#{indent(plan)}")
  end

  test "a caught-up deck with only a few cards due still reads the index, not the table" do
    # The shape the index is worst at: 4,000 in rotation and only a handful due, all of them
    # at the top level, so a scan in (level, due) order walks every lower level before it
    # finds one. It is still an index scan of a compact index -- measured at a fifth of a
    # millisecond -- which is why the ordering leads with `level` and not with `due`.
    # Leading with `due` is faster here and 28x slower on a backlog, where it also has to sort
    # the whole due set instead of stopping at `limit`.
    Repo.query!("""
    UPDATE retain_items
    SET level = CASE WHEN id % 200 = 0 THEN 7 ELSE id % 7 END,
        due = CASE WHEN id % 200 = 0
                   THEN #{quoted(days(-2))}
                   ELSE #{quoted(days(40))} END
    WHERE started_at IS NOT NULL
    """)

    Repo.query!("ANALYZE retain_items")

    {{:ok, items}, queries} = capture(fn -> Retain.due("big", limit: 20, now: t0()) end)
    assert items != []

    plan = explain(pick(queries, "retain_items"))

    assert plan =~ "retain_items_due_index", plan
    refute plan =~ "Seq Scan on retain_items", plan
    refute plan =~ "Sort", plan

    IO.puts("\n  due/2, 4000 active and a handful due at the top level: #{ms(queries)} ms")
  end

  test "queue/2 reads its indexes and never scans the deck to count today's new items" do
    {{:ok, %{reviews: reviews}}, queries} =
      capture(fn -> Retain.queue("big", limit: 20, now: t0()) end)

    assert length(reviews) == 20

    joined = queries |> Enum.map(&explain/1) |> Enum.join("\n")

    refute joined =~ "Seq Scan on retain_items", joined
    assert joined =~ "retain_items_due_index", joined

    # Today's new-item budget: a range scan on started_at, not a timezone conversion per row.
    # Before, this was `(started_at AT TIME ZONE ...)::date = today`, which no index can serve.
    assert joined =~ "retain_items_user_id_started_at_index", joined

    IO.puts("\n  queue/2 over #{@items} items: #{ms(queries)} ms (#{length(queries)} queries)")
  end

  test "the new-item queue reads the new index in introduction order" do
    # Free up today's budget so `new` is actually fetched.
    {{:ok, %{new: new}}, queries} = capture(fn -> Retain.queue("big", now: days(1)) end)
    assert length(new) == 20
    assert Enum.map(new, & &1.key) == Enum.map(1..20, &"n#{&1}")

    joined = queries |> Enum.map(&explain/1) |> Enum.join("\n")
    assert joined =~ "retain_items_new_index", joined
    refute joined =~ "Seq Scan on retain_items", joined
  end

  ## Helpers

  # Every SQL statement Ecto ran inside `fun`, with its params and time.
  defp capture(fun) do
    ref = make_ref()
    parent = self()
    handler = "scale-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:retain, :test_repo, :query],
      fn _event, measurements, meta, _ ->
        send(parent, {ref, meta.query, meta.params, measurements[:query_time] || 0})
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, drain(ref, [])}
  end

  defp drain(ref, acc) do
    receive do
      {^ref, query, params, time} -> drain(ref, [{query, params, time} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp pick(queries, fragment) do
    Enum.find(queries, fn {sql, _, _} -> String.contains?(sql, fragment) end) ||
      flunk("no query mentioning #{fragment} in #{inspect(Enum.map(queries, &elem(&1, 0)))}")
  end

  defp explain({sql, params, _time}) do
    %{rows: rows} = Repo.query!("EXPLAIN (ANALYZE, BUFFERS) " <> sql, params)
    Enum.map_join(rows, "\n", &List.first/1)
  end

  defp ms(queries) do
    queries
    |> Enum.map(&elem(&1, 2))
    |> Enum.sum()
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1000)
    |> Float.round(2)
  end

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))

  defp quoted(%DateTime{} = at), do: "TIMESTAMP '#{DateTime.to_naive(at)}'"
end
