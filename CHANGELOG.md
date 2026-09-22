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
  `last_reviewed_at`, no streak day.
- `amend/5` — correct an earlier review by appending, not editing. The named row stays; a new one
  supersedes it, and every fold reads the corrected outcome *in the original's place in time*.
  Chains take the last word. `Retain.Log` is the (pure) resolution.
- `delete_user/2` — remove a learner, their items and their whole log.
- `put_user/2` creates with a single upsert, so concurrent callers no longer race to a unique
  violation.
- `start/3` locks the rows it picked and re-checks that they are still new, so a review landing
  at the same moment can no longer be overwritten.
- Two purpose-built partial indexes replace `[user_id, suspended, due, level]`, which could not
  serve `due/2`'s ordering. Over a 5,000-item deck, `due/2` goes from a sequential scan of 2,020
  rows (0.89 ms) to a 20-row index-only scan (0.07 ms).
- `queue/2`'s new-item budget is a range scan on `started_at` rather than a timezone conversion
  per row: 1.83 ms to 0.013 ms on the same deck, with the same answer at every DST edge.
- `config :retain, time_zone_database:` — a host that already carries `:tzdata` can use it
  instead of the bundled `:tz`.
