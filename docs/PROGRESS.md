# Diorama — Progress log

This file is kept current while work is in progress, so that progress survives restarts and context limits.

## Current state (2026-10-25)
- **Every phase is implemented.** Automated verification is complete for everything that can be tested without credentials or live usage. The phase-by-phase status is in [implementation-plan.md](implementation-plan.md#phase-log).
- **Test suite:** `swift test`, **61 tests in 12 suites, all passing**. Five of them are contract tests with the real Claude Code CLI 2.1.296. There are 0 compiler warnings.
- **Release bundle:** `./scripts/bundle-app.sh` produces `dist/Diorama.app` and a zip, ad-hoc signed, passing `codesign --verify --deep --strict`.

## Completed work
| Area | Verification actually run |
|---|---|
| JSON index and splice | 9 tests, including 300 random documents compared with JSONSerialization and 500-deep nesting |
| Engine (rules, provider, edits, frozen decisions, replay, treatments) | 21 tests |
| Gateway, control API, daemon | 12 integration tests against a NIO mock upstream, plus a latency test (p95 4.8 ms added, debug build) |
| Runner, store, algorithms | 14 tests: diff, Wilson intervals, pricing, transcript parsing, heuristics, comparison caveats, blocked order, cloning, corruption recovery, schema guard, retention, profile versioning |
| Real Claude Code contract | 5 tests: rewrite and replay across turns, `--settings` precedence with the user's settings file untouched, lockdown, tool-result shapes, experiment runner end to end |
| Release-binary smoke tests | `diorama run` with real Claude Code against a mock model, through the daemon; failure path without a key; supervisor restart after `kill -9`; experiment run (6 trials) from the CLI; Anthropic provider round trip against a fake endpoint that checks the request shape |
| App | Built, bundled and launched; four screens checked visually through self-rendered snapshots of real data (`docs/assets`) |
| Docs | README, user guide, security, troubleshooting, release, architecture (updated to as built), decisions D1–D28, CONTRIBUTING, notices, changelog, examples, CI |

## Discoveries and decisions made during implementation
- **Deep recursion crashed the parser.** A recursive JSON parse overflowed a test thread's stack (SIGBUS), so the parser is now iterative.
- **Case-insensitive file systems caused two collisions.** The `Diorama` and `diorama` products collided at link time, and later `MacOS/diorama` overwrote `MacOS/Diorama` inside the bundle. The CLI and daemon now live in `Contents/Helpers`, and the bundle script guards against a regression (D20).
- **The control API runs on loopback with a bearer token** (D21). System SQLite and URLSession replace GRDB and async-http-client (D23).
- **`--settings` precedence works as needed.** It beats the user's settings-file `env`, so routing needs no file edits. Lockdown is done with `permissions.deny` (D26).
- **Exchange timing was racy.** Responses were recorded after the stream ended, so a client could read the timeline too early. The exchange is now recorded before the response ends.
- **The echo heuristic missed reused treatments.** Frozen treatments reuse rewrites without creating attempts, so the "echo" heuristic now diffs original against replacement (D28).
- **A plain shuffle can block variants together.** It produced "all steered, then all control" in a real run, so trials now use blocked randomization (D27).
- **Self-snapshots avoid permission prompts.** Screen capture needs a permission this environment doesn't have, so the app can render its own window (`DIORAMA_SNAPSHOT_DIR`).
- **Claude Code's auto-mode billing notice** appears with custom base URLs. It's harmless, and documented in troubleshooting.

## Blockers (need the maintainer)
- **Live verification** with real Anthropic usage (D22): a real rewrite, cache-hit numbers, WebSearch and MCP shapes, and the preserved-thinking check on an enforced account.
- **Distribution:** Developer ID signing, notarization, a trademark search, the final bundle ID and GitHub owner, pushing, and publishing.

## Next actions
1. The maintainer reviews the repository, and makes the initial commit if happy with it.
2. A live smoke test on the maintainer's own account (`docs/release.md` step 3).
3. Push to GitHub to run CI. Then sign, notarize and publish.
