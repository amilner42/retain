defmodule Retain do
  @moduledoc """
  Plug-and-play spaced repetition for Ecto apps.

  Retain keeps a Leitner ladder over an append-only review log in your own Postgres. You tell it
  what a learner is drilling and how each attempt went; it tells you what to drill next, how the
  learner is doing, and how that has changed over time.

  ## Setup

      # mix.exs
      {:retain, github: "amilner42/retain"}

      # config/config.exs
      config :retain, repo: MyApp.Repo

      # once
      mix retain.gen.migration
      mix ecto.migrate

  There is nothing to start: Retain is functions over your repo.

  ## Usage

      Retain.put_user("u1", tz: "America/Vancouver")

      Retain.put_items("u1", [
        %{key: "aller/present/je", tags: %{verb: "aller", tense: "present"}},
        %{key: "aller/present/tu", tags: %{verb: "aller", tense: "present"}}
      ])

      {:ok, [item | _]} = Retain.due("u1", tags: %{tense: "present"}, limit: 10)
      {:ok, %{level_before: 0, level_after: 1}} = Retain.review("u1", item.key, :pass)

      Retain.summary("u1", group_by: [:verb])
      Retain.streak("u1")
      Retain.history("u1", group_by: :tense)

  ## Concepts

    * **Item** — something to drill. Identified by a `key` you choose, unique per user. Carries a
      flat `tags` map for filtering and grouping and an opaque `content` map Retain never reads.
    * **Review** — one attempt, with an outcome of `:pass`, `:partial` or `:fail`. Reviews are
      never updated or deleted; every other number Retain reports is derived from them.
    * **Ladder** — level 0..6 per item; `:pass` climbs, `:partial` holds, `:fail` drops. Each
      level has an interval; see `Retain.Ladder`.
    * **User** — whoever your app says. `uid` is any string; `tz` is required because "today"
      and "due today" are calendar concepts.
    * **Scope** — an optional partition of users (default `"default"`). One host serving several
      apps can keep their learners apart; a single app can ignore it.

  ## Return values

  Every function returns `{:ok, value}` or `{:error, reason}`. Unknown users and items are
  `{:error, :not_found}` rather than empty results, so a wrong `uid` or `scope` fails loudly.
  Every function takes `now:` for testing; it defaults to `DateTime.utc_now/0`.
  """

  import Ecto.Query

  alias Retain.{Clock, Config, Fold, History, Item, Ladder, Review, User}

  @type uid :: String.t()
  @type key :: String.t()
  @type tags :: %{optional(String.t() | atom()) => String.t() | atom()}
  @type outcome :: Ladder.outcome()

  @typedoc "The change one review made."
  @type review_result :: %{
          level_before: Ladder.level(),
          level_after: Ladder.level(),
          due: DateTime.t(),
          review_id: integer()
        }

  @typedoc "One row of `summary/2`: the grouping tag values plus the aggregates."
  @type summary_row :: %{
          required(:group) => %{optional(String.t()) => String.t() | nil},
          required(:count) => non_neg_integer(),
          required(:mean_level) => float(),
          required(:due_count) => non_neg_integer()
        }

  @default_due_limit 20
  @insert_chunk 1_000

  ## Users

  @doc """
  Creates or updates a user.

  `tz:` (an IANA name such as `"America/Vancouver"`) is required when creating and optional
  when updating.

      Retain.put_user("u1", tz: "Europe/Paris")
  """
  @spec put_user(uid(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def put_user(uid, opts \\ []) when is_binary(uid) do
    scope = scope(opts)
    attrs = %{scope: scope, uid: uid} |> put_if(:tz, opts[:tz])

    case repo().get_by(User, scope: scope, uid: uid) do
      nil -> %User{} |> User.changeset(attrs) |> repo().insert()
      user -> user |> User.changeset(attrs) |> repo().update()
    end
  end

  @doc "Fetches a user."
  @spec fetch_user(uid(), keyword()) :: {:ok, User.t()} | {:error, :not_found}
  def fetch_user(uid, opts \\ []) when is_binary(uid) do
    case repo().get_by(User, scope: scope(opts), uid: uid) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  Moves everything from one user to another and deletes the first. For turning a guest into an
  account.

  Items whose key already exists on `into_uid` have their reviews merged into the existing item,
  which is then re-derived from the combined log. Both users must exist.

  Returns how many items were moved and how many were merged.
  """
  @spec merge_users(uid(), uid(), keyword()) ::
          {:ok, %{moved: non_neg_integer(), merged: non_neg_integer()}}
          | {:error, :not_found | :same_user}
  def merge_users(from_uid, into_uid, opts \\ [])
      when is_binary(from_uid) and is_binary(into_uid) do
    with :ok <- if(from_uid == into_uid, do: {:error, :same_user}, else: :ok),
         {:ok, from} <- fetch_user(from_uid, opts),
         {:ok, into} <- fetch_user(into_uid, opts) do
      repo().transaction(fn ->
        ladder = ladder()

        into_keys =
          repo().all(from i in Item, where: i.user_id == ^into.id, select: {i.key, i.id})
          |> Map.new()

        from_items = repo().all(from i in Item, where: i.user_id == ^from.id)

        {moved, merged} =
          Enum.reduce(from_items, {0, 0}, fn item, {moved, merged} ->
            case Map.fetch(into_keys, item.key) do
              :error ->
                repo().update!(Ecto.Changeset.change(item, user_id: into.id))
                {moved + 1, merged}

              {:ok, target_id} ->
                repo().update_all(from(r in Review, where: r.item_id == ^item.id),
                  set: [item_id: target_id]
                )

                repo().delete!(item)

                # The merged log may start before the target item did; an item must predate
                # its reviews or history would ignore the early ones.
                repo().update_all(
                  from(i in Item,
                    where: i.id == ^target_id and i.inserted_at > ^item.inserted_at
                  ),
                  set: [inserted_at: item.inserted_at]
                )

                rederive_item!(target_id, ladder)
                {moved, merged + 1}
            end
          end)

        repo().delete!(from)
        %{moved: moved, merged: merged}
      end)
    end
  end

  ## Items

  @doc """
  Adds items for a user. Existing keys are left untouched, so this is safe to call repeatedly
  with overlapping sets.

  Each item is a map with `:key` (required), `:tags` (a flat map of strings; atoms are
  converted) and `:content` (any map). New items start at level 0, due immediately. Pass
  `suspended: true` to add them paused instead; see `resume/3`.

      Retain.put_items("u1", [%{key: "pos:abc", tags: %{kind: "cube"}, content: %{xgid: "..."}}])
      #=> {:ok, %{inserted: 1, existing: 0}}

  Returns `{:error, {:invalid_item, index, changeset}}` for the first invalid item, in which
  case nothing is written.
  """
  @spec put_items(uid(), [map()], keyword()) ::
          {:ok, %{inserted: non_neg_integer(), existing: non_neg_integer()}}
          | {:error, :not_found | {:invalid_item, non_neg_integer(), Ecto.Changeset.t()}}
  def put_items(uid, items, opts \\ []) when is_binary(uid) and is_list(items) do
    with {:ok, user} <- fetch_user(uid, opts),
         {:ok, rows} <- item_rows(user, items, now(opts), Keyword.get(opts, :suspended, false)) do
      inserted =
        rows
        |> Enum.chunk_every(@insert_chunk)
        |> Enum.reduce(0, fn chunk, acc ->
          {count, _} =
            repo().insert_all(Item, chunk,
              on_conflict: :nothing,
              conflict_target: [:user_id, :key]
            )

          acc + count
        end)

      {:ok, %{inserted: inserted, existing: length(rows) - inserted}}
    end
  end

  @doc "Fetches one item with its ladder state."
  @spec fetch_item(uid(), key(), keyword()) :: {:ok, Item.t()} | {:error, :not_found}
  def fetch_item(uid, key, opts \\ []) when is_binary(uid) and is_binary(key) do
    with {:ok, user} <- fetch_user(uid, opts) do
      case repo().get_by(Item, user_id: user.id, key: key) do
        nil -> {:error, :not_found}
        item -> {:ok, item}
      end
    end
  end

  @doc "Pauses an item: it stops appearing in `due/2` and cannot be reviewed until resumed."
  @spec suspend(uid(), key(), keyword()) :: {:ok, Item.t()} | {:error, :not_found}
  def suspend(uid, key, opts \\ []), do: set_suspended(uid, key, true, opts)

  @doc "Un-pauses an item. Its ladder state is exactly as it was when suspended."
  @spec resume(uid(), key(), keyword()) :: {:ok, Item.t()} | {:error, :not_found}
  def resume(uid, key, opts \\ []), do: set_suspended(uid, key, false, opts)

  ## Reviews

  @doc """
  Records an attempt and moves the item on the ladder. This is the only write that changes
  ladder state, and it is the only way to.

  `outcome` is `:pass`, `:partial` or `:fail`. Options:

    * `at:` — when it happened; defaults to now. Must not be earlier than the item's previous
      review or its creation, so the log stays in order (`{:error, :out_of_order}`).
    * `meta:` — any map to keep with the review (what was answered, timing). Retain stores it
      and never reads it.

      Retain.review("u1", "pos:abc", :fail, meta: %{picked: "pass", loss: 0.59})
      #=> {:ok, %{level_before: 2, level_after: 1, due: ~U[...], review_id: 42}}
  """
  @spec review(uid(), key(), outcome(), keyword()) ::
          {:ok, review_result()}
          | {:error, :not_found | :suspended | :invalid_outcome | :out_of_order}
  def review(uid, key, outcome, opts \\ []) when is_binary(uid) and is_binary(key) do
    at = usec(Keyword.get(opts, :at) || now(opts))
    meta = Keyword.get(opts, :meta, %{})
    unless is_map(meta), do: raise(ArgumentError, "meta: must be a map, got: #{inspect(meta)}")

    with :ok <- if(Ladder.outcome?(outcome), do: :ok, else: {:error, :invalid_outcome}),
         {:ok, user} <- fetch_user(uid, opts) do
      repo().transaction(fn ->
        item =
          repo().one(
            from i in Item, where: i.user_id == ^user.id and i.key == ^key, lock: "FOR UPDATE"
          ) ||
            repo().rollback(:not_found)

        if item.suspended, do: repo().rollback(:suspended)
        unless in_order?(item, at), do: repo().rollback(:out_of_order)

        next =
          Fold.apply(
            Map.take(item, [:level, :due, :reps, :lapses, :last_reviewed_at]),
            ladder(),
            outcome,
            at
          )

        repo().update!(Ecto.Changeset.change(item, next))
        review = repo().insert!(%Review{item_id: item.id, outcome: outcome, at: at, meta: meta})

        %{level_before: item.level, level_after: next.level, due: next.due, review_id: review.id}
      end)
    end
  end

  ## Reads

  @doc """
  Items to drill, weakest and most overdue first.

  Returns items whose `due` is at or before `before:` (default: the start of tomorrow in the
  user's timezone, i.e. everything due today), excluding suspended ones, ordered by level
  ascending then due ascending, at most `limit:` (default #{@default_due_limit}).

  `tags:` restricts to items whose tags contain every given pair.

      Retain.due("u1", tags: %{kind: "cube"}, limit: 5)
  """
  @spec due(uid(), keyword()) :: {:ok, [Item.t()]} | {:error, :not_found}
  def due(uid, opts \\ []) when is_binary(uid) do
    with {:ok, user} <- fetch_user(uid, opts) do
      before = usec(Keyword.get(opts, :before) || Clock.start_of_tomorrow(now(opts), user.tz))
      limit = Keyword.get(opts, :limit, @default_due_limit)

      items =
        Item
        |> where([i], i.user_id == ^user.id and not i.suspended and i.due <= ^before)
        |> filter_tags(opts[:tags])
        |> order_by([i], asc: i.level, asc: i.due, asc: i.id)
        |> limit(^limit)
        |> repo().all()

      {:ok, items}
    end
  end

  @doc """
  Aggregates over a user's items, grouped by tag values.

  `group_by:` is a list of tag keys; each row's `:group` maps those keys to the item's values
  (`nil` where an item lacks the tag). With no `group_by:` there is one row. `tags:` filters
  as in `due/2`. `due_count` counts unsuspended items due by `before:` (default: end of today).

      Retain.summary("u1", group_by: [:kind])
      #=> {:ok, [%{group: %{"kind" => "cube"}, count: 23, mean_level: 1.8, due_count: 9}, ...]}
  """
  @spec summary(uid(), keyword()) :: {:ok, [summary_row()]} | {:error, :not_found}
  def summary(uid, opts \\ []) when is_binary(uid) do
    with {:ok, user} <- fetch_user(uid, opts) do
      before = usec(Keyword.get(opts, :before) || Clock.start_of_tomorrow(now(opts), user.tz))
      keys = opts |> Keyword.get(:group_by, []) |> List.wrap() |> Enum.map(&to_string/1)

      rows =
        Item
        |> where([i], i.user_id == ^user.id)
        |> filter_tags(opts[:tags])
        |> select([i], {i.tags, i.level, i.due, i.suspended})
        |> repo().all()
        |> Enum.group_by(fn {tags, _, _, _} -> Map.new(keys, &{&1, tags[&1]}) end)
        |> Enum.map(fn {group, members} ->
          count = length(members)
          level_sum = members |> Enum.map(fn {_, level, _, _} -> level end) |> Enum.sum()

          due_count =
            Enum.count(members, fn {_, _, due, suspended} ->
              not suspended and DateTime.compare(due, before) != :gt
            end)

          %{group: group, count: count, mean_level: level_sum / count, due_count: due_count}
        end)
        |> Enum.sort_by(& &1.group)

      {:ok, rows}
    end
  end

  @doc """
  Consecutive local days with at least one review, ending today or yesterday.

  Today counts as soon as the user reviews something; until then the streak is whatever it was
  yesterday. Also returns the longest streak ever and the number of distinct days with a review.

      Retain.streak("u1")
      #=> {:ok, %{streak: 4, longest: 9, days_active: 31}}
  """
  @spec streak(uid(), keyword()) ::
          {:ok,
           %{
             streak: non_neg_integer(),
             longest: non_neg_integer(),
             days_active: non_neg_integer()
           }}
          | {:error, :not_found}
  def streak(uid, opts \\ []) when is_binary(uid) do
    with {:ok, user} <- fetch_user(uid, opts) do
      dates =
        from(r in Review,
          join: i in assoc(r, :item),
          where: i.user_id == ^user.id,
          distinct: true,
          select: fragment("((? AT TIME ZONE 'UTC') AT TIME ZONE ?)::date", r.at, ^user.tz)
        )
        |> repo().all()
        |> Enum.sort({:desc, Date})

      today = Clock.local_date(now(opts), user.tz)

      {:ok,
       %{
         streak: current_run(dates, today),
         longest: longest_run(dates),
         days_active: length(dates)
       }}
    end
  end

  @doc """
  Progress over time: a reading per local day per group.

  Each point has `count` (items that existed that day), `explored` (share reviewed at least
  once, 0.0..1.0) and `acquired` (mean level over the top level, 0.0..1.0). Options:

    * `from:`/`to:` — local dates, inclusive. Default: the last 30 days ending today.
    * `group_by:` — a single tag key; one series per distinct value. Default: one series,
      `group: nil`.
    * `tags:` — filters items as in `due/2`.

  Computed by replaying the log; see `Retain.History`.
  """
  @spec history(uid(), keyword()) :: {:ok, [History.point()]} | {:error, :not_found}
  def history(uid, opts \\ []) when is_binary(uid) do
    with {:ok, user} <- fetch_user(uid, opts) do
      to = Keyword.get(opts, :to) || Clock.local_date(now(opts), user.tz)
      from = Keyword.get(opts, :from) || Date.add(to, -29)
      group_key = opts |> Keyword.get(:group_by) |> then(&if(&1, do: to_string(&1)))

      item_query = Item |> where([i], i.user_id == ^user.id) |> filter_tags(opts[:tags])

      item_events =
        item_query
        |> select([i], {i.id, i.tags, i.inserted_at})
        |> repo().all()
        |> Enum.map(fn {id, tags, at} -> {:item, id, if(group_key, do: tags[group_key]), at} end)

      review_events =
        from(r in Review,
          join: i in subquery(item_query),
          on: i.id == r.item_id,
          select: {r.item_id, r.outcome, r.at}
        )
        |> repo().all()
        |> Enum.map(fn {id, outcome, at} -> {:review, id, outcome, at} end)

      {:ok, History.series(item_events ++ review_events, ladder(), user.tz, from, to)}
    end
  end

  ## Maintenance

  @doc """
  Re-derives every item's ladder state from its reviews. The result is always identical to what
  live reviews produced; run it after changing `config :retain, intervals:` or as an audit.
  """
  @spec rebuild(uid(), keyword()) :: {:ok, %{items: non_neg_integer()}} | {:error, :not_found}
  def rebuild(uid, opts \\ []) when is_binary(uid) do
    with {:ok, user} <- fetch_user(uid, opts) do
      ladder = ladder()
      ids = repo().all(from i in Item, where: i.user_id == ^user.id, select: i.id)
      Enum.each(ids, &rederive_item!(&1, ladder))
      {:ok, %{items: length(ids)}}
    end
  end

  @doc "`rebuild/2` for every user in every scope."
  @spec rebuild_all() :: {:ok, %{users: non_neg_integer(), items: non_neg_integer()}}
  def rebuild_all do
    ladder = ladder()
    ids = repo().all(from i in Item, select: i.id)
    Enum.each(ids, &rederive_item!(&1, ladder))
    {:ok, %{users: repo().aggregate(User, :count), items: length(ids)}}
  end

  ## Private

  defp repo, do: Config.repo!()
  defp ladder, do: Ladder.default()
  defp scope(opts), do: Keyword.get(opts, :scope, Config.default_scope())
  defp now(opts), do: usec(Keyword.get(opts, :now) || DateTime.utc_now())

  # Columns are UTC at microsecond precision; accept any zone and precision from callers.
  defp usec(%DateTime{} = dt) do
    %DateTime{microsecond: {us, _}} =
      dt = DateTime.shift_zone!(dt, "Etc/UTC", Tz.TimeZoneDatabase)

    %{dt | microsecond: {us, 6}}
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp item_rows(user, items, now, suspended) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {attrs, index}, {:ok, rows, seen} ->
      changeset = Item.changeset(%Item{}, Map.new(attrs))

      cond do
        not changeset.valid? ->
          {:halt, {:error, {:invalid_item, index, changeset}}}

        MapSet.member?(seen, changeset.changes.key) ->
          {:cont, {:ok, rows, seen}}

        true ->
          row =
            changeset.changes
            |> Map.put_new(:tags, %{})
            |> Map.put_new(:content, %{})
            |> Map.put_new(:suspended, suspended)
            |> Map.merge(Fold.initial(now))
            |> Map.merge(%{user_id: user.id, inserted_at: now, updated_at: now})

          {:cont, {:ok, [row | rows], MapSet.put(seen, changeset.changes.key)}}
      end
    end)
    |> case do
      {:ok, rows, _seen} -> {:ok, Enum.reverse(rows)}
      {:error, _} = error -> error
    end
  end

  defp set_suspended(uid, key, suspended, opts) do
    with {:ok, item} <- fetch_item(uid, key, opts) do
      item |> Ecto.Changeset.change(suspended: suspended) |> repo().update()
    end
  end

  defp in_order?(item, at) do
    DateTime.compare(at, item.inserted_at) != :lt and
      (is_nil(item.last_reviewed_at) or DateTime.compare(at, item.last_reviewed_at) != :lt)
  end

  defp filter_tags(query, nil), do: query
  defp filter_tags(query, tags) when tags == %{}, do: query

  defp filter_tags(query, tags) when is_map(tags) do
    tags = Item.normalize_tags(tags)
    where(query, [i], fragment("? @> ?", i.tags, type(^tags, :map)))
  end

  # Re-derives one item from its reviews. Locks the row so a concurrent review cannot interleave.
  defp rederive_item!(item_id, ladder) do
    item = repo().one!(from i in Item, where: i.id == ^item_id, lock: "FOR UPDATE")

    reviews =
      repo().all(
        from r in Review,
          where: r.item_id == ^item_id,
          order_by: [asc: r.at, asc: r.id],
          select: {r.outcome, r.at}
      )

    repo().update!(Ecto.Changeset.change(item, Fold.replay(item.inserted_at, ladder, reviews)))
  end

  # dates: distinct local dates, descending.
  defp current_run(dates, today) do
    start =
      cond do
        today in dates -> today
        Date.add(today, -1) in dates -> Date.add(today, -1)
        true -> nil
      end

    if start, do: run_length(dates, start), else: 0
  end

  defp run_length(dates, start) do
    set = MapSet.new(dates)

    Stream.iterate(start, &Date.add(&1, -1))
    |> Enum.take_while(&MapSet.member?(set, &1))
    |> length()
  end

  defp longest_run([]), do: 0

  defp longest_run(dates) do
    dates
    |> Enum.reverse()
    |> Enum.reduce({0, 0, nil}, fn date, {best, run, prev} ->
      run = if prev && Date.diff(date, prev) == 1, do: run + 1, else: 1
      {max(best, run), run, date}
    end)
    |> elem(0)
  end
end
