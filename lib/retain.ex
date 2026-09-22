defmodule Retain do
  @moduledoc """
  Plug-and-play spaced repetition for Ecto apps.

  Retain keeps a Leitner ladder over an append-only review log in your own Postgres. You tell it
  what a learner could drill and how each attempt went; it tells you what to drill next, how the
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

      Retain.put_user("u1", tz: "America/Vancouver", new_per_day: 10)

      # The whole map. Nothing is in rotation yet.
      Retain.put_items("u1", [
        %{key: "aller/present/je", tags: %{verb: "aller", tense: "present"}, position: 1},
        %{key: "aller/present/tu", tags: %{verb: "aller", tense: "present"}, position: 2}
      ])

      # A session: reviews that are due, plus new items within today's budget.
      {:ok, %{reviews: reviews, new: new}} = Retain.queue("u1", tags: %{tense: "present"})
      {:ok, %{level_before: 0, level_after: 1}} = Retain.review("u1", hd(new).key, :pass)

      Retain.summary("u1", group_by: [:verb])
      Retain.streak("u1")
      Retain.history("u1", group_by: :tense)

  ## Concepts

    * **Item** — something to drill. Identified by a `key` you choose, unique per user. Carries a
      flat `tags` map for filtering and grouping and an opaque `content` map Retain never reads.
    * **New / active / suspended** — an item is *new* until it is started, *active* while in
      rotation, *suspended* while paused. `put_items/3` adds items as new by default, so a host
      can load a whole map up front; `queue/2` introduces them a few per day, or `start/3` does
      it explicitly. Reviewing a new item starts it.
    * **Review** — one attempt, with an outcome of `:pass`, `:partial`, `:fail`, `:again` (back
      to the start) or `:known` for "I already know this" (see `master/3`).
    * **Log** — the rows behind an item. Append-only: nothing is ever updated or deleted, and
      every other number Retain reports is a fold over it. Two rows are not attempts — a
      `defer/4`, which only moves the due date, and an `amend/5`, which corrects an earlier row
      by superseding it. `Retain.Log` resolves both before the fold; `Retain.Fold` applies them.
    * **Ladder** — level 0..7 per item; `:pass` climbs, `:partial` holds, `:fail` drops one,
      `:again` drops to 0. Each level has an interval; see `Retain.Ladder`.
    * **User** — whoever your app says. `uid` is any string; `tz` is required because "today"
      and "due today" are calendar concepts; `new_per_day` is their budget of new items.
    * **Scope** — an optional partition of users (default `"default"`). One host serving several
      apps can keep their learners apart; a single app can ignore it.

  ## Return values

  Every function returns `{:ok, value}` or `{:error, reason}`. Unknown users and items are
  `{:error, :not_found}` rather than empty results, so a wrong `uid` or `scope` fails loudly.
  Every function takes `now:` for testing; it defaults to `DateTime.utc_now/0`.
  """

  import Ecto.Query

  alias Retain.{Clock, Config, Fold, History, Item, Ladder, Log, Review, User}

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
          required(:new_count) => non_neg_integer(),
          required(:active_count) => non_neg_integer(),
          required(:suspended_count) => non_neg_integer(),
          required(:due_count) => non_neg_integer(),
          required(:mean_level) => float()
        }

  @typedoc "What `queue/2` hands the host for a session."
  @type queue :: %{
          reviews: [Item.t()],
          new: [Item.t()],
          new_remaining_today: non_neg_integer()
        }

  @default_limit 20
  @insert_chunk 1_000

  ## Users

  @doc """
  Creates or updates a user.

  Options:

    * `tz:` — an IANA name such as `"America/Vancouver"`. Required when creating.
    * `new_per_day:` — how many new items `queue/2` may introduce per local day. Defaults to
      `config :retain, new_per_day:` (10) when creating.

      Retain.put_user("u1", tz: "Europe/Paris", new_per_day: 5)
  """
  @spec put_user(uid(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def put_user(uid, opts \\ []) when is_binary(uid) do
    scope = scope(opts)

    if opts[:tz] do
      # One statement, so two requests racing to create the same learner both end up with them
      # rather than one of them getting a unique violation. Only the fields the caller actually
      # gave are replaced, so `put_user(uid, tz: ...)` never resets `new_per_day`.
      attrs = %{
        scope: scope,
        uid: uid,
        tz: opts[:tz],
        new_per_day: opts[:new_per_day] || Config.new_per_day()
      }

      replace = [:tz, :updated_at] ++ if(opts[:new_per_day], do: [:new_per_day], else: [])

      %User{}
      |> User.changeset(attrs)
      |> repo().insert(
        on_conflict: {:replace, replace},
        conflict_target: [:scope, :uid],
        returning: true
      )
    else
      update_user(scope, uid, opts)
    end
  end

  # Without a timezone there is nothing to create, so this is an update of a learner that must
  # already exist. A missing one is reported the way creating them would have been.
  defp update_user(scope, uid, opts) do
    case repo().get_by(User, scope: scope, uid: uid) do
      nil ->
        changeset =
          User.changeset(%User{}, %{
            scope: scope,
            uid: uid,
            new_per_day: opts[:new_per_day] || Config.new_per_day()
          })

        {:error, %{changeset | action: :insert}}

      user ->
        user |> User.changeset(put_if(%{}, :new_per_day, opts[:new_per_day])) |> repo().update()
    end
  end

  @doc """
  Deletes a learner and everything Retain holds about them: their items and the whole review log.

  Irreversible, and the only way to remove a user. Returns what went with them.
  """
  @spec delete_user(uid(), keyword()) ::
          {:ok, %{items: non_neg_integer(), reviews: non_neg_integer()}} | {:error, :not_found}
  def delete_user(uid, opts \\ []) when is_binary(uid) do
    with {:ok, user} <- fetch_user(uid, opts) do
      repo().transaction(fn ->
        items = from(i in Item, where: i.user_id == ^user.id)

        counts = %{
          items: repo().aggregate(items, :count),
          reviews:
            repo().aggregate(
              from(r in Review, join: i in assoc(r, :item), where: i.user_id == ^user.id),
              :count
            )
        }

        # retain_items and retain_reviews cascade from the user.
        repo().delete!(user)
        counts
      end)
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
  Moves everything from one uid onto another and deletes the first. For when the same person
  ends up with two ids (a pre-signup id and an account, two devices). Not needed if every
  learner has one stable id.

  Items whose key already exists on `into_uid` have their reviews merged into the existing item,
  which is then re-derived from the combined log; it counts as started if either copy was. Both
  users must exist.

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

        # Lock every row either side of the merge, up front, in item-id order. Doing it per
        # from-item as the merge walked them locked the *target* rows in an order that
        # depended on which user was being merged, so two merges into one account could hold
        # each other's next row. One order for every multi-row path is the whole rule.
        lock_items(
          repo().all(from i in Item, where: i.user_id in ^[from.id, into.id], select: i.id)
        )

        into_by_key =
          repo().all(from i in Item, where: i.user_id == ^into.id) |> Map.new(&{&1.key, &1})

        from_items = repo().all(from i in Item, where: i.user_id == ^from.id, order_by: i.id)

        {moved, merged} =
          Enum.reduce(from_items, {0, 0}, fn item, {moved, merged} ->
            case Map.fetch(into_by_key, item.key) do
              :error ->
                repo().update!(Ecto.Changeset.change(item, user_id: into.id))
                {moved + 1, merged}

              {:ok, target} ->
                repo().update_all(from(r in Review, where: r.item_id == ^item.id),
                  set: [item_id: target.id]
                )

                repo().delete!(item)

                # The merged log may start before the target item did; an item must predate
                # its reviews or history would ignore the early ones.
                target
                |> Ecto.Changeset.change(
                  inserted_at: earliest(target.inserted_at, item.inserted_at),
                  started_at: earliest(target.started_at, item.started_at)
                )
                |> repo().update!()

                rederive_item!(target.id, ladder)
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
  converted), `:content` (any map) and `:position` (an integer; new items are introduced lowest
  first). Options:

    * `status:` — `:new` (default) adds items to the map without starting them; `:active`
      starts them now, level 0 and due immediately.
    * `suspended:` — add them paused.

      Retain.put_items("u1", [%{key: "pos:abc", tags: %{kind: "cube"}, content: %{xgid: "..."}}], status: :active)
      #=> {:ok, %{inserted: 1, existing: 0}}

  Returns `{:error, {:invalid_item, index, changeset}}` for the first invalid item, in which
  case nothing is written. Repeated keys *within one call* are collapsed to the first, and count
  as neither `inserted` nor `existing`, so the two do not necessarily add up to what was passed.
  """
  @spec put_items(uid(), [map()], keyword()) ::
          {:ok, %{inserted: non_neg_integer(), existing: non_neg_integer()}}
          | {:error, :not_found | {:invalid_item, non_neg_integer(), Ecto.Changeset.t()}}
  def put_items(uid, items, opts \\ []) when is_binary(uid) and is_list(items) do
    status = Keyword.get(opts, :status, :new)

    unless status in [:new, :active] do
      raise ArgumentError, "status: must be :new or :active, got: #{inspect(status)}"
    end

    with {:ok, user} <- fetch_user(uid, opts),
         {:ok, rows} <-
           item_rows(user, items, now(opts), status, Keyword.get(opts, :suspended, false)) do
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

  @doc """
  Puts new items into rotation now, at level 0 and due immediately.

  Pass a list of keys to start those, or an integer to start the next that many in introduction
  order (`position`, then creation), optionally within `tags:`. Items already started or
  suspended are skipped. Started items count against today's `new_per_day` budget.

      Retain.start("u1", ["aller/present/je"])
      Retain.start("u1", 5, tags: %{tense: "present"})
      #=> {:ok, %{started: 5}}
  """
  @spec start(uid(), [key()] | non_neg_integer(), keyword()) ::
          {:ok, %{started: non_neg_integer()}} | {:error, :not_found}
  def start(uid, keys_or_count, opts \\ []) when is_binary(uid) do
    unless is_list(keys_or_count) or (is_integer(keys_or_count) and keys_or_count >= 0) do
      raise ArgumentError,
            "start/3 takes a list of keys or a non-negative count, got: #{inspect(keys_or_count)}"
    end

    with {:ok, user} <- fetch_user(uid, opts) do
      now = now(opts)

      repo().transaction(fn ->
        # Pick in introduction order, then lock in item-id order (`lock_items/1`), then
        # re-check that they are still new in the update itself. All three matter: picking
        # decides *which*, the lock makes a concurrent `review/4` of the same item wait, and
        # the condition means that if the review got there first we start nothing rather than
        # overwriting the ladder state it just wrote.
        picked =
          case keys_or_count do
            keys when is_list(keys) -> new_items_query(user, opts) |> where([i], i.key in ^keys)
            count -> new_items_query(user, opts) |> limit(^count)
          end
          |> select([i], i.id)
          |> repo().all()

        ids = lock_items(picked)

        {started, _} =
          repo().update_all(
            from(i in Item,
              where: i.id in ^ids and is_nil(i.started_at) and not i.suspended
            ),
            set: [started_at: now, due: now, updated_at: now]
          )

        %{started: started}
      end)
    end
  end

  @doc """
  Marks items as already known: each jumps to the top level and is due at its interval, like
  any other item there. Recorded in the log as a `:known` review, so it survives `rebuild/2`
  and shows in `history/2`. Takes a key or a list of keys; unknown and suspended keys are
  ignored; new items are started.

      Retain.master("u1", ["être/present/je", "être/present/tu"])
      #=> {:ok, %{mastered: 2}}
  """
  @spec master(uid(), key() | [key()], keyword()) ::
          {:ok, %{mastered: non_neg_integer()}} | {:error, :not_found | :out_of_order}
  def master(uid, keys, opts \\ []) when is_binary(uid) do
    with {:ok, user} <- fetch_user(uid, opts) do
      at = now(opts)

      repo().transaction(fn ->
        # In item-id order, not the caller's: every path that locks more than one row of
        # retain_items takes them in the same order, or two callers holding each other's next
        # row deadlock. Keys that name nothing are dropped here rather than ignored later --
        # the count is of what moved either way.
        user
        |> keys_in_lock_order(List.wrap(keys))
        |> Enum.reduce(%{mastered: 0}, fn key, acc ->
          case do_entry(user, key, :known, at, opts, %{}, nil) do
            {:ok, _} -> %{acc | mastered: acc.mastered + 1}
            {:error, reason} when reason in [:not_found, :suspended] -> acc
            {:error, reason} -> repo().rollback(reason)
          end
        end)
      end)
    end
  end

  @doc """
  Pauses items: they leave `queue/2` and `due/2` and cannot be reviewed until resumed. Takes a
  key or a list of keys; unknown keys are ignored.

      Retain.suspend("u1", ["aller/present/je", "aller/present/tu"])
      #=> {:ok, %{suspended: 2}}
  """
  @spec suspend(uid(), key() | [key()], keyword()) ::
          {:ok, %{suspended: non_neg_integer()}} | {:error, :not_found}
  def suspend(uid, keys, opts \\ []) when is_binary(uid) do
    with {:ok, n} <- set_suspended(uid, List.wrap(keys), true, opts), do: {:ok, %{suspended: n}}
  end

  @doc "Un-pauses items. Their ladder state is exactly as it was when suspended."
  @spec resume(uid(), key() | [key()], keyword()) ::
          {:ok, %{resumed: non_neg_integer()}} | {:error, :not_found}
  def resume(uid, keys, opts \\ []) when is_binary(uid) do
    with {:ok, n} <- set_suspended(uid, List.wrap(keys), false, opts), do: {:ok, %{resumed: n}}
  end

  ## Reviews

  @doc """
  Records an attempt and moves the item on the ladder. This is the only write that changes
  ladder state, and it is the only way to. Reviewing a new item starts it.

  `outcome` is `:pass`, `:partial`, `:fail`, `:again` (back to level 0) or `:known` (jump to the
  top level). Options:

    * `at:` — when it happened; defaults to now. Must not be earlier than the item's creation,
      start or newest log entry, so the log stays in order (`{:error, :out_of_order}`).
    * `meta:` — any map to keep with the review (what was answered, timing). Retain stores it
      and never reads it.

      Retain.review("u1", "pos:abc", :fail, meta: %{picked: "pass", loss: 0.59})
      #=> {:ok, %{level_before: 2, level_after: 1, due: ~U[...], review_id: 42}}

  Retain does not police *when* you review. It does not check that the item was due, and it
  cannot tell a first answer from a retry of the same one — every call is another row in the
  log. A host that grades only the first attempt at a due item must decide that itself and call
  `review/4` once it has.
  """
  @spec review(uid(), key(), outcome(), keyword()) ::
          {:ok, review_result()}
          | {:error, :not_found | :suspended | :invalid_outcome | :out_of_order}
  def review(uid, key, outcome, opts \\ []) when is_binary(uid) and is_binary(key) do
    meta = meta!(opts)

    with :ok <- if(Ladder.outcome?(outcome), do: :ok, else: {:error, :invalid_outcome}),
         {:ok, user} <- fetch_user(uid, opts) do
      in_transaction(fn -> do_entry(user, key, outcome, given_at(opts), opts, meta, nil) end)
    end
  end

  @doc """
  Moves an item's due date without touching the ladder: burying, snoozing, "not today".

  The item keeps its level, its counters and its last-reviewed time; only `due` becomes `until`.
  A defer is a row in the log like any other, so `rebuild/2` and `history/2` reproduce it — but
  it is not an attempt, so it does not count towards `streak/2`, `reps` or `explored`.

  The item must be **in rotation**: a new one is `{:error, :not_started}`. Deferring something
  that has not started would mean nothing (a new item's `due` is not what `queue/2` reads), and
  `start/3` would overwrite it a moment later — which is the one way the derived state and the
  log could disagree. Start it, then defer it.

      Retain.defer("u1", "pos:abc", DateTime.add(DateTime.utc_now(), 3, :day))
      #=> {:ok, %{level_before: 2, level_after: 2, due: ~U[...], review_id: 43}}
  """
  @spec defer(uid(), key(), DateTime.t(), keyword()) ::
          {:ok, review_result()}
          | {:error, :not_found | :suspended | :not_started | :out_of_order}
  def defer(uid, key, %DateTime{} = until, opts \\ []) when is_binary(uid) and is_binary(key) do
    meta = meta!(opts)

    with {:ok, user} <- fetch_user(uid, opts) do
      in_transaction(fn ->
        do_entry(user, key, :defer, given_at(opts), opts, meta, usec(until))
      end)
    end
  end

  @doc """
  Corrects an earlier review, by appending rather than editing.

  `review_id` names a row of this item's log; `outcome` is what it should have said. The row
  stays; a new one is written that supersedes it, and every fold — `rebuild/2`, `history/2`, the
  item's live state — then reads the corrected outcome *in the original's place in time*. So
  amending yesterday's `:fail` to `:pass` leaves exactly the state a log that had said `:pass`
  yesterday would have produced. The item is re-derived from the whole log on the spot.

  This is the Anki-style override: the host grades an answer, shows it, and the learner says it
  was really a pass. Amend an amendment and the newest wins; a `:defer` cannot be amended.

      Retain.amend("u1", "pos:abc", 42, :pass)
      #=> {:ok, %{level_before: 1, level_after: 3, due: ~U[...], review_id: 44}}
  """
  @spec amend(uid(), key(), integer(), outcome(), keyword()) ::
          {:ok, review_result()}
          | {:error, :not_found | :suspended | :invalid_outcome | :not_amendable}
  def amend(uid, key, review_id, outcome, opts \\ [])
      when is_binary(uid) and is_binary(key) and is_integer(review_id) do
    meta = meta!(opts)

    with :ok <- if(Ladder.outcome?(outcome), do: :ok, else: {:error, :invalid_outcome}),
         {:ok, user} <- fetch_user(uid, opts) do
      in_transaction(fn ->
        with {:ok, item} <- lock_item(user, key),
             :ok <- if(item.suspended, do: {:error, :suspended}, else: :ok),
             {:ok, superseded} <- amendable(item, review_id) do
          # Stamped after the lock: two corrections of the same answer arriving together must
          # be ordered as they are applied, or the one that waited would look older than the
          # one that went first and silently lose to it.
          at = given_at(opts) || now(opts)

          row =
            repo().insert!(%Review{
              item_id: item.id,
              outcome: outcome,
              at: at,
              meta: meta,
              supersedes_id: superseded.id
            })

          # The correction lands in the past, so the tail of the fold changes: re-derive.
          next = rederive_item!(item.id, ladder())

          {:ok,
           %{
             level_before: item.level,
             level_after: next.level,
             due: next.due,
             review_id: row.id
           }}
        end
      end)
    end
  end

  # Runs `fun` in a transaction, turning its {:error, reason} into a rollback.
  defp in_transaction(fun) do
    repo().transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  # An explicit `at:`, or nil to say "read the clock once the row is locked".
  defp given_at(opts) do
    case Keyword.get(opts, :at) do
      nil -> nil
      at -> usec(at)
    end
  end

  defp meta!(opts) do
    meta = Keyword.get(opts, :meta, %{})
    unless is_map(meta), do: raise(ArgumentError, "meta: must be a map, got: #{inspect(meta)}")
    meta
  end

  # THE lock order for retain_items: ascending item id, everywhere, always. Any path that
  # takes more than one row of this table goes through here, so two of them can queue behind
  # each other but never hold what the other needs next.
  defp lock_items([]), do: []

  defp lock_items(ids) do
    repo().all(
      from i in Item,
        where: i.id in ^ids,
        order_by: i.id,
        select: i.id,
        lock: "FOR UPDATE"
    )
  end

  # The given keys that this user actually has, in item-id order.
  defp keys_in_lock_order(user, keys) do
    repo().all(
      from i in Item,
        where: i.user_id == ^user.id and i.key in ^keys,
        order_by: i.id,
        select: i.key
    )
  end

  defp lock_item(user, key) do
    case repo().one(
           from i in Item, where: i.user_id == ^user.id and i.key == ^key, lock: "FOR UPDATE"
         ) do
      nil -> {:error, :not_found}
      item -> {:ok, item}
    end
  end

  defp amendable(item, review_id) do
    row = repo().one(from r in Review, where: r.id == ^review_id and r.item_id == ^item.id)

    cond do
      is_nil(row) -> {:error, :not_found}
      row.outcome == :defer -> {:error, :not_amendable}
      true -> {:ok, row}
    end
  end

  # The body of review/4 and defer/4, to run inside a transaction. Writes nothing unless it
  # succeeds, so a caller batching several (master/3) can skip failures without poisoning its
  # transaction.
  defp do_entry(user, key, outcome, at, opts, meta, until) do
    with {:ok, item} <- lock_item(user, key) do
      # The clock is read after the lock, never before it. Two attempts that arrive together
      # are applied one after the other, and the one that waited must be stamped after the one
      # that went first -- otherwise it is refused as out of order for having queued.
      at = at || now(opts)

      cond do
        item.suspended ->
          {:error, :suspended}

        # A defer does not start an item, so a deferred new item would have `start/3` write
        # `due` back over it with no log row to show for it -- and the rebuild would then
        # re-apply the defer and disagree. Rotation first.
        outcome == :defer and is_nil(item.started_at) ->
          {:error, :not_started}

        not in_order?(item, at) ->
          {:error, :out_of_order}

        true ->
          state = Map.take(item, [:level, :due, :reps, :lapses, :last_reviewed_at])
          next = Fold.apply(state, ladder(), Fold.entry(outcome, at, until))

          # An attempt on a new item starts it. A defer never reaches here unstarted.
          changes =
            if item.started_at, do: next, else: Map.put(next, :started_at, at)

          repo().update!(Ecto.Changeset.change(item, changes))

          row =
            repo().insert!(%Review{
              item_id: item.id,
              outcome: outcome,
              at: at,
              until: until,
              meta: meta
            })

          {:ok,
           %{level_before: item.level, level_after: next.level, due: next.due, review_id: row.id}}
      end
    end
  end

  ## Reads

  @doc """
  A session's worth of work: the reviews that are due, and the new items to introduce.

  `reviews` is `due/2`. `new` is the next not-yet-started items in introduction order, at most
  the user's `new_per_day` minus however many were started today already (by any path), and at
  most `new_limit:` if given. `new_remaining_today` is that budget before this call.

  Options: `tags:`, `before:`, `limit:`, `offset:` (reviews) and `now:` as in `due/2`;
  `new_limit:`; and `new: :after_reviews` to hold new items back until nothing is due
  (default `:always`).

      Retain.queue("u1", tags: %{tense: "present"}, limit: 20)
      #=> {:ok, %{reviews: [...], new: [...], new_remaining_today: 7}}
  """
  @spec queue(uid(), keyword()) :: {:ok, queue()} | {:error, :not_found}
  def queue(uid, opts \\ []) when is_binary(uid) do
    with {:ok, user} <- fetch_user(uid, opts),
         {:ok, reviews} <- due(uid, opts) do
      now = now(opts)
      remaining = max(user.new_per_day - started_today_count(user, now), 0)

      new_limit =
        case Keyword.get(opts, :new_limit) do
          nil -> remaining
          n when is_integer(n) and n >= 0 -> min(n, remaining)
        end

      hold_back = Keyword.get(opts, :new, :always) == :after_reviews and reviews != []

      new =
        if new_limit == 0 or hold_back do
          []
        else
          new_items_query(user, opts) |> limit(^new_limit) |> repo().all()
        end

      {:ok, %{reviews: reviews, new: new, new_remaining_today: remaining}}
    end
  end

  @doc """
  Active items to review, weakest and most overdue first.

  Returns started, unsuspended items whose `due` is at or before `before:` (default: the start
  of tomorrow in the user's timezone, i.e. everything due today), ordered by level ascending
  then due ascending, at most `limit:` (default #{@default_limit}).

  `tags:` restricts to items whose tags contain every given pair. `offset:` skips that many,
  for a "keep going" that walks further down the same ordering; the order is total (level, due,
  id), so paging it cannot repeat or skip an item as long as nothing is reviewed in between.

      Retain.due("u1", tags: %{kind: "cube"}, limit: 5)
      Retain.due("u1", limit: 20, offset: 20)
  """
  @spec due(uid(), keyword()) :: {:ok, [Item.t()]} | {:error, :not_found}
  def due(uid, opts \\ []) when is_binary(uid) do
    with {:ok, user} <- fetch_user(uid, opts) do
      before = usec(Keyword.get(opts, :before) || Clock.start_of_tomorrow(now(opts), user.tz))
      limit = Keyword.get(opts, :limit, @default_limit)
      skip = Keyword.get(opts, :offset, 0)

      items =
        Item
        |> where([i], i.user_id == ^user.id and not i.suspended)
        |> where([i], not is_nil(i.started_at) and i.due <= ^before)
        |> filter_tags(opts[:tags])
        |> order_by([i], asc: i.level, asc: i.due, asc: i.id)
        |> limit(^limit)
        |> offset(^skip)
        |> repo().all()

      {:ok, items}
    end
  end

  @doc """
  Aggregates over a user's items, grouped by tag values.

  `group_by:` is a list of tag keys; each row's `:group` maps those keys to the item's values
  (`nil` where an item lacks the tag). With no `group_by:` there is one row. `tags:` filters as
  in `due/2`.

  Per row: `count` (all items), `new_count`, `active_count`, `suspended_count`, `due_count`
  (active items due by `before:`, default end of today) and `mean_level` over all items.

      Retain.summary("u1", group_by: [:kind])
      #=> {:ok, [%{group: %{"kind" => "cube"}, count: 23, new_count: 4, active_count: 19,
                   suspended_count: 0, due_count: 9, mean_level: 1.8}, ...]}
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
        |> select([i], %{
          tags: i.tags,
          level: i.level,
          due: i.due,
          suspended: i.suspended,
          started_at: i.started_at
        })
        |> repo().all()
        |> Enum.group_by(&Map.new(keys, fn k -> {k, &1.tags[k]} end))
        |> Enum.map(fn {group, members} ->
          statuses = Enum.map(members, &Item.status(struct(Item, &1)))
          count = length(members)

          %{
            group: group,
            count: count,
            new_count: Enum.count(statuses, &(&1 == :new)),
            active_count: Enum.count(statuses, &(&1 == :active)),
            suspended_count: Enum.count(statuses, &(&1 == :suspended)),
            due_count:
              Enum.count(members, fn m ->
                not m.suspended and m.started_at != nil and DateTime.compare(m.due, before) != :gt
              end),
            mean_level: (members |> Enum.map(& &1.level) |> Enum.sum()) / count
          }
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
      # Attempts only: a defer is not practice, and an amendment is a correction of a day already
      # counted, not a new one.
      dates =
        from(r in Review,
          join: i in assoc(r, :item),
          where: i.user_id == ^user.id and is_nil(r.supersedes_id) and r.outcome != ^:defer,
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

  Computed by replaying the log; see `Retain.History`. Days before a group's first item have no
  reading.
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

      # Amendments are resolved per item before the events are built, so history reads the
      # corrected outcome on the day the original was answered — which is what makes
      # "history at the last day == live state" hold after an amend.
      review_events =
        from(r in Review,
          join: i in subquery(item_query),
          on: i.id == r.item_id,
          select: %{
            item_id: r.item_id,
            id: r.id,
            outcome: r.outcome,
            at: r.at,
            until: r.until,
            supersedes_id: r.supersedes_id
          }
        )
        |> repo().all()
        |> Enum.group_by(& &1.item_id)
        |> Enum.flat_map(fn {id, rows} ->
          Enum.map(Log.entries(rows), &{:review, id, &1})
        end)

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
    %DateTime{microsecond: {us, _}} = dt = DateTime.shift_zone!(dt, "Etc/UTC", Clock.db())

    %{dt | microsecond: {us, 6}}
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp earliest(nil, b), do: b
  defp earliest(a, nil), do: a
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  defp item_rows(user, items, now, status, suspended) do
    started_at = if status == :active, do: now

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
            |> Map.merge(%{
              user_id: user.id,
              started_at: started_at,
              inserted_at: now,
              updated_at: now
            })

          {:cont, {:ok, [row | rows], MapSet.put(seen, changeset.changes.key)}}
      end
    end)
    |> case do
      {:ok, rows, _seen} -> {:ok, Enum.reverse(rows)}
      {:error, _} = error -> error
    end
  end

  defp set_suspended(uid, keys, suspended, opts) do
    with {:ok, user} <- fetch_user(uid, opts) do
      {n, _} =
        from(i in Item,
          where: i.user_id == ^user.id and i.key in ^keys and i.suspended != ^suspended
        )
        |> repo().update_all(set: [suspended: suspended, updated_at: now(opts)])

      {:ok, n}
    end
  end

  # Not-yet-started, unsuspended items in introduction order.
  defp new_items_query(user, opts) do
    Item
    |> where([i], i.user_id == ^user.id and is_nil(i.started_at) and not i.suspended)
    |> filter_tags(opts[:tags])
    |> order_by([i], asc_nulls_last: i.position, asc: i.inserted_at, asc: i.id)
  end

  # The learner's day as a half-open range of instants rather than a per-row timezone
  # conversion: same answer (`Clock.start_of_day/2` is monotone across DST gaps and folds), but
  # it is a range scan on [user_id, started_at] instead of a sequential scan of every item the
  # learner has, which is what `queue/2` used to pay on every call.
  defp started_today_count(user, now) do
    today = Clock.local_date(now, user.tz)
    from_at = Clock.start_of_day(today, user.tz)
    until_at = Clock.start_of_day(Date.add(today, 1), user.tz)

    Item
    |> where([i], i.user_id == ^user.id)
    |> where([i], i.started_at >= ^from_at and i.started_at < ^until_at)
    |> repo().aggregate(:count)
  end

  # An entry may not land before the item existed, before it started, or before the newest entry
  # already in its log. `last_reviewed_at` is not enough for the last of those: a defer does not
  # move it, and an amendment is not an entry at all, so ask the log itself.
  defp in_order?(item, at) do
    not_before = fn earlier -> is_nil(earlier) or DateTime.compare(at, earlier) != :lt end

    not_before.(item.inserted_at) and not_before.(item.started_at) and
      not_before.(newest_entry_at(item.id))
  end

  defp newest_entry_at(item_id) do
    repo().one(
      from r in Review,
        where: r.item_id == ^item_id and is_nil(r.supersedes_id),
        select: max(r.at)
    )
  end

  defp filter_tags(query, nil), do: query
  defp filter_tags(query, tags) when tags == %{}, do: query

  defp filter_tags(query, tags) when is_map(tags) do
    tags = Item.normalize_tags(tags)
    where(query, [i], fragment("? @> ?", i.tags, type(^tags, :map)))
  end

  # Re-derives one item from its log. Locks the row so a concurrent review cannot interleave.
  # Returns the state it wrote.
  defp rederive_item!(item_id, ladder) do
    item = repo().one!(from i in Item, where: i.id == ^item_id, lock: "FOR UPDATE")

    # A never-started item has no reviews; a started one is due from its start.
    origin = item.started_at || item.inserted_at
    state = Fold.replay(origin, ladder, Log.entries(log_rows(item_id)))
    repo().update!(Ecto.Changeset.change(item, state))
    state
  end

  defp log_rows(item_id) do
    repo().all(
      from r in Review,
        where: r.item_id == ^item_id,
        select: %{
          id: r.id,
          outcome: r.outcome,
          at: r.at,
          until: r.until,
          supersedes_id: r.supersedes_id
        }
    )
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
