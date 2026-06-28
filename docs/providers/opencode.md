# OpenCode Go

> Tracks observed OpenCode Go spend from local OpenCode history on this machine.

## Overview

- **Provider id:** `opencode-go`
- **Source of truth:** `~/.local/share/opencode/opencode.db` (OpenCode's local SQLite history)
- **Detection signal:** `~/.local/share/opencode/auth.json`
- **Usage scope:** local observed assistant spend only — no remote or other-device usage

OpenCode publishes no usage API, so OpenUsage reads spend straight from OpenCode's own local database
and shows it against the published OpenCode Go plan limits.

## When it shows up

The provider stays hidden until there's a sign OpenCode Go is in use, then it appears. Either is enough:

- `auth.json` has an `opencode-go` entry with a non-empty `key`, or
- the local history already contains `opencode-go` assistant messages with a numeric cost.

If neither is present, the provider stays hidden.

## What it tracks

Three meters, each showing local spend as a percentage of the fixed plan limit (clamped at 100%):

| Meter   | Window                                            | Limit |
| ------- | ------------------------------------------------- | ----- |
| Session | rolling last 5 hours                              | $12   |
| Weekly  | UTC Monday 00:00 → next UTC Monday 00:00          | $30   |
| Monthly | subscription-style month anchored to first usage  | $60   |

Session and Weekly are shown above the fold; Monthly sits behind the "Shown on expand" caret. Only
assistant messages with a numeric cost count toward the totals.

The monthly window is inferred from local history, not read from an account API: it uses the earliest
observed local OpenCode Go usage timestamp as the monthly anchor. Before any usage is recorded, it falls
back to UTC calendar-month boundaries.

## Errors

- **Not detected** — neither auth nor local history indicates OpenCode Go is in use. The provider is
  hidden until you log in with OpenCode Go or use it locally.
- **No usage data** — auth or prior history shows OpenCode Go is in use, but the local database is
  currently missing or unreadable. The provider stays visible with a grey status badge rather than
  failing hard.

## Future compatibility

The provider id stays `opencode-go`. If OpenCode later exposes account-truth usage by API key, the
backend can be swapped without changing the provider id or the meters shown.
