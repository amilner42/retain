# Changelog

## Unreleased

Initial release.

- Users with a timezone and a daily budget of new items.
- Items with opaque `content`, flat `tags`, `position`; new until started, suspendable.
- Append-only reviews; a Leitner ladder folded over them; `rebuild` replays the log.
- `queue`, `due`, `summary`, `streak`, `history`, `start`, `master`, `suspend`, `merge_users`.
- Versioned schema with a migration generator.
- Default ladder `0, 1, 3, 7, 21, 58, 145, 365` days: eight levels, a year at the top.

### Schema v02

Run `mix retain.gen.migration` again and migrate.

- `:again` — an outcome that drops an item to level 0 wherever it was, due after the level-0
  interval. `:fail` still means "down one". Both count as a lapse.
- `defer/4` — move an item's due date without touching the ladder (burying, "not today"). It is
  a row in the log, so `rebuild/2` reproduces it, but it is not an attempt: no `reps`, no
  `last_reviewed_at`, no streak day. The item must already be in rotation; a new one is
  `{:error, :not_started}`, because a defer does not start anything and `start/3` would write
  `due` back over it with no log row to show for it.
- `amend/5` — correct an earlier review by appending, not editing. The named row stays; a new one
  supersedes it, and every fold reads the corrected outcome *in the original's place in time*.
  The corrections of one answer form a **tree** (a host re-amends whatever `review_id` it was
  last handed), and the newest leaf anywhere in that tree wins. `Retain.Log` is the (pure)
  resolution.
- `offset:` on `due/2` and `queue/2`, for walking further down the same ordering.
- `delete_user/2` — remove a learner, their items and their whole log.
- `put_user/2` creates with a single upsert, so concurrent callers no longer race to a unique
  violation.
- `start/3` locks the rows it picked and re-checks that they are still new, so a review landing
  at the same moment can no longer be overwritten.
- Two purpose-built partial indexes replace `[user_id, suspended, due, level]`, which could not
  serve `due/2`'s ordering at all: over a 5,000-item deck it was a sequential scan of 2,020 rows
  (0.89 ms), and is now an index-only scan (0.07 ms). The index leads with `level`, matching the
  `ORDER BY`, so the scan stops at `limit`; `due` is a filter within it. That costs a little when
  a caught-up deck has only a handful due — 4,000 active and 20 due measures 0.15 ms, and 0.21 ms
  if all 20 sit at the top level — and it is deliberate: leading with `due` instead measures
  0.04 ms on those shapes but **1.11 ms** on a backlog of 4,000 due, where it must sort the whole
  due set rather than stop early. The common case is cheap either way; the expensive case is
  cheaper this way round.
- All multi-row writes (`start/3`, `master/3`, `merge_users/3`) take their row locks in one
  global order (ascending item id). They used to differ — introduction order, caller key order,
  and for `merge_users` an order that depended on which account was being merged — so two of them
  could hold each other's next row and Postgres killed one with a deadlock.
- `review/4`, `amend/5` and `defer/4` read the clock **after** taking the row lock. Stamping
  before it meant the call that waited looked older than the one that went first and was refused
  as out of order.
- `queue/2`'s new-item budget is a range scan on `started_at` rather than a timezone conversion
  per row: 1.83 ms to 0.013 ms on the same deck, with the same answer at every DST edge.
- `config :retain, time_zone_database:` — a host that already carries `:tzdata` can use it
  instead of the bundled `:tz`.
- `mix retain.gen.migration` emits a `down/0` that reverts to the version the host actually had
  before (read from the migrations already in the repo's path), not `latest - 1`. Rolling back a
  first install used to leave v01 behind with nothing able to remove it.

**Changed public shapes.** `Retain.Fold.apply/3` and `Retain.Fold.replay/3` now take entry maps
(`%{outcome:, at:, until:}`, built by `Retain.Fold.entry/3`) rather than bare outcomes and
`{outcome, at}` pairs; `Retain.Fold.apply/4` is still the attempt shorthand.
`Retain.History.series/5` takes `{:review, item_id, entry}` events rather than
`{:review, item_id, outcome, at}`. Hosts that only call the `Retain` module are unaffected.
