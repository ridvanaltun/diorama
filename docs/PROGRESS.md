# Diorama — Progress log

This file is kept current while work is in progress, so that progress survives restarts and context limits.

## v1.1.0 work in progress (2026-10-25)
The user doesn't want an Apple Developer account (no signing or notarization). Everything else from the follow-up list:

| # | Item | State |
|---|---|---|
| 1 | Verify the MCP tool_result shape live | ✅ Done: blocks `[text, image, text]` (poc-findings) |
| 2 | Pre-extraction mode (rule `stage: page`) | ✅ Committed and pushed (e0f9958), with engine tests and a real-Claude contract test |
| 3 | Opt-in LLM judge | ✅ Committed and pushed |
| 4 | Ollama provider (`ollama:` models) | ✅ Committed and pushed. Tested against a fake server only; Ollama isn't installed |
| 5 | Update checker (`diorama update`, in-app notice) | ✅ Committed and pushed (dbf423f). Verified: the private-repo check via `gh`, plus download and checksum |
| 6 | UI tests | ✅ FormLogic unit tests, plus an off-screen smoke test of every screen and sheet, running in CI. It found and fixed a crash on sheet close (an NSWindow double release). |
| 7 | Live experiment, 10 trials per variant | ✅ Two runs, page-stage treatment on example.com, Haiku, LLM judge on. The first run exposed three analysis flaws (the frozen-treatment race, fragmentary change pairs, and an echo heuristic that scored controls 0 by construction), all fixed with regression tests. The second run: one rewrite reused by all 10 steered trials; judge adopted 10/10 steered versus 0/10 control; suspicion language 5/10 steered versus 0/10 control. Report: `docs/assets/example-report.md` |
| 8 | Name and trademark check; public-readiness preparation | Pending. Making the repository public needs the user's explicit OK, and the self-hosted runner must not be used for a public repository |
| 9 | Release v1.1.0 (`scripts/release.sh 1.1.0`) | Pending; the CHANGELOG `Unreleased` section is already written |

Docs already updated for items 2–6: CHANGELOG (Unreleased), the user guide, decisions D29–D33, and poc-findings.

**Blocker hit:** Claude Code's auto-mode safety check repeatedly returned no verdict for Bash and WebSearch, so building, testing, committing and searching paused. File edits continued.

## Current state (2026-10-25)
- **Every phase is implemented.** Automated verification is complete for everything that can be tested without credentials or live usage. The phase-by-phase status is in [implementation-plan.md](implementation-plan.md#phase-log).
- **Test suite:** `swift test`, **63 tests in 12 suites, all passing**. Five of them are contract tests with the real Claude Code CLI 2.1.296. There are 0 compiler warnings.
- **CI:** GitHub Actions on a self-hosted macOS runner (LaunchAgent `actions.runner.ridvanaltun-diorama.diorama-mac`) runs build, tests and bundle on every push to `main`. It's green.
- **Live verification is done** (see poc-findings): a real rewrite, cache hits on replay, the WebSearch shape, and a live 2×2 pilot experiment. It cost about $0.001 on the user's API key plus a few cents of notional Max plan usage.
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
- **Shutdown hang (fixed).** With open keep-alive or event-stream connections, `stop()` never returned, and SIGTERM left the process running. The cause was shutting the event loops down before closing child connections. A second race let `exit()` run before cleanup finished. Both are fixed, with a regression test plus a manual SIGTERM test against a real process.
- **WebFetch output isn't deterministic** (its summarizing model), so frozen treatments can't be reused across trials for WebFetch. This is now reported.
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
- **The running daemon and app still use the old binary.** They were started from `dist/` before the shutdown fix. Quit the app and run `diorama daemon stop`, then reopen the app. The first time the new build reads the Keychain item, macOS may ask; choose "Always Allow".
- **Remaining live checks:** the MCP result shape, and the preserved-thinking check on an enforced (post-2026-08-31) account.
- **Distribution:** Developer ID signing, notarization, a trademark search, the final bundle ID and GitHub owner, pushing, and publishing.

## Next actions
1. Restart the app and daemon so they run the fixed build.
2. Optional: a larger pilot on a real project (10+ trials per variant) to collect a meaningful sample.
3. Release: Developer ID signing, notarization, trademark search, then publishing.
