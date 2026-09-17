# Changelog

## Unreleased

Initial release.

- Users with a timezone and a daily budget of new items.
- Items with opaque `content`, flat `tags`, `position`; new until started, suspendable.
- Append-only reviews; a Leitner ladder folded over them; `rebuild` replays the log.
- `queue`, `due`, `summary`, `streak`, `history`, `start`, `master`, `suspend`, `merge_users`.
- Versioned schema with a migration generator.
- Default ladder `0, 1, 3, 7, 21, 58, 145, 365` days: eight levels, a year at the top.
