# Retain

Plug-and-play spaced repetition for Elixir apps that use Ecto and Postgres.

Retain keeps a [Leitner](https://en.wikipedia.org/wiki/Leitner_system) ladder over an
append-only review log, in your own database. You tell it what a learner is drilling and how
each attempt went; it tells you what to drill next, how the learner is doing, and how that has
changed over time. It knows nothing about your domain: French verbs, backgammon positions and
flashcards all look the same to it.

There is nothing to run. No processes, no jobs, no supervisor. Just functions over your repo.

## Setup

```elixir
# mix.exs
{:retain, github: "amilner42/retain"}

# config/config.exs
config :retain, repo: MyApp.Repo
```

```sh
mix retain.gen.migration
mix ecto.migrate
```

## Usage

```elixir
# A learner. `uid` is whatever id your app already has. `tz` is required.
Retain.put_user("u1", tz: "America/Vancouver", new_per_day: 10)

# The whole map, up front. Nothing is in rotation yet. `key` is yours; `tags` filter and
# group; `position` is the order to introduce things; `content` is yours and never read.
Retain.put_items("u1", [
  %{key: "aller/present/je", tags: %{verb: "aller", tense: "present"}, position: 1},
  %{key: "aller/present/tu", tags: %{verb: "aller", tense: "present"}, position: 2}
])

# Or, for something to drill right now (a blunder you just made):
Retain.put_items("u1", [%{key: "pos:8f2a/cube", tags: %{kind: "cube"}, content: %{xgid: "..."}}], status: :active)

# A session: what is due, plus new items within today's budget.
{:ok, %{reviews: reviews, new: new, new_remaining_today: 7}} =
  Retain.queue("u1", tags: %{tense: "present"}, limit: 20)

# How it went. You grade; Retain schedules. Reviewing a new item starts it.
{:ok, %{level_before: 0, level_after: 1, due: due}} =
  Retain.review("u1", hd(new).key, :pass, meta: %{typed: "vais", ms: 4200})

# Or start things explicitly: the next five, or specific keys.
Retain.start("u1", 5, tags: %{tense: "present"})
Retain.start("u1", ["aller/present/il"])

# "I know this already" and "I don't want to see this".
Retain.master("u1", ["être/present/je", "être/present/tu"])   #=> {:ok, %{mastered: 2}}
Retain.suspend("u1", "aller/present/vous")                    #=> {:ok, %{suspended: 1}}

# How they're doing.
Retain.summary("u1", group_by: [:verb])
#=> {:ok, [%{group: %{"verb" => "aller"}, count: 24, new_count: 12, active_count: 12,
#            suspended_count: 0, due_count: 3, mean_level: 1.8}, ...]}

Retain.streak("u1")
#=> {:ok, %{streak: 4, longest: 9, days_active: 31}}

Retain.history("u1", group_by: :tense, from: ~D[2026-08-01], to: ~D[2026-08-31])
#=> {:ok, [%{date: ~D[2026-08-01], group: "present", count: 20, explored: 0.6, acquired: 0.31}, ...]}

# If one person ends up with two ids.
Retain.merge_users("old-uid", "u1")
```

Every function returns `{:ok, _}` or `{:error, reason}`. Unknown users and items are
`{:error, :not_found}` rather than empty results.

## How it works

**The ladder.** Every item has a level from 0 to 7. `:pass` climbs one, `:partial` holds,
`:fail` drops one, `:known` jumps to the top. Each level has an interval — `0, 1, 3, 7, 21, 58, 145, 365` days by default — and
an item is due that many days after its last review. New items are level 0 and due immediately.
Level 7 still comes back every year so it can be lost again. The curve is the one FSRS's
default weights produce for a card that is always answered "good", with Anki's one-day first
step in front; see the prior art in the docs.

```elixir
# Optional: your own intervals. Index is the level.
config :retain, intervals: [0, 1, 2, 5, 10, 30, 90, 180]
```

**New, active, suspended.** An item is *new* until it is started, *active* while in
rotation, *suspended* while paused. Load the whole map as new and let `queue/2` introduce it at
`new_per_day` per learner-local day (in `position` order, then creation order), or `start/3`
things explicitly. Reviewing a new item starts it. `queue/2` returns due reviews and new items
as separate lists so your UI can present them differently; pass `new: :after_reviews` to hold
new material back until the reviews are done.

**The log is the truth.** Every `review/4` appends a row and updates the item's derived fields
(`level`, `due`, `reps`, `lapses`, `last_reviewed_at`) by folding that one review in. Reviews are
never updated or deleted. `mix retain.rebuild` replays the whole log and overwrites the derived
fields; the result is always identical to what live reviews produced, and a property test says
so. `history/2` runs the same fold day by day. Change the intervals, run rebuild, done.

**Days are the learner's days.** "Due today", streaks and history buckets all go through the
user's IANA timezone. DST gaps and folds are handled in one place (`Retain.Clock`) and tested at
the edges.

**Streaks are simple.** A day counts if the learner reviewed anything. Today counts as soon as
they do; until then the streak is whatever it was yesterday. No XP, no goals, no freezes.

## Why these intervals

Every spaced-repetition system lands on roughly the same curve: ×2.5–3 per step, a short first
step, a top between four months and a year.

| System | Intervals |
|---|---|
| Leitner (1972) | 1, 2, 4, 8, 16 days |
| SM-2 / Anki, always "good" | 1, 6, 15, 38, 94, 235, 588… |
| WaniKani | 4h, 8h, 1d, 2d, 1w, 2w, 1mo, 4mo, then retired |
| Memrise | 4h, 12h, 1d, 6d, 12d, 48d, 96d, 180d |
| FSRS default weights, always "good" | 2, 7, 21, 58, 145, 365 |
| **Retain** | 0, 1, 3, 7, 21, 58, 145, 365 |

FSRS's weights are fit to a very large body of real review data at 90% target retention, so its
"good" sequence is the most evidence-backed shape available; Retain uses it with Anki's one-day
first step in front. A card that is never missed is seen on days 0, 1, 4, 11, 32, 90, 235 and
600, then yearly.

## What Retain does not do

Grade answers, pick which of several sentences to show, decide when to unlock new material,
send reminders, or authenticate anyone. Those belong to your app. Retain's whole surface is the
public functions on the `Retain` module.

## Scopes

Every function takes `scope:` (default `"default"`). Users are unique per scope, so one database
can hold learners from several apps without their ids colliding. A single app can ignore it.

## Development

```sh
mix test          # needs a local Postgres; see config/test.exs for credentials
mix dialyzer
mix docs
```

## License

MIT.
