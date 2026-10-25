# Diorama — Implementation plan

The work is incremental. **A phase is finished only when its exit criteria pass**: automated tests run green, plus the listed manual or live checks. Each phase ends with a short demo and a note in this file. Live tests against the real API show their cost before they run.

The project has two milestones:
- **M1 Interactive sessions are reliable** (Phases 0–5).
- **M2 Experiments** (Phases 6–7). Release preparation follows in Phase 8.

---

## Phase 0: Foundations and compatibility spike
**Goal:** a repository skeleton, plus *automated* evidence for every protocol assumption before building on it.

- Run `git init`. Add the Swift package skeleton with empty modules (as in architecture.md §2), an XcodeGen `project.yml` for the app, the Apache-2.0 `LICENSE`, `.gitignore`, and a CI workflow (`swift build`, `swift test` and an `xcodebuild` build on macOS).
- Port the proof of concept's mock upstream to a Swift test fixture (`MockAnthropicServer`) that serves scripted SSE responses.
- Build the contract-test harness: run the real `claude` CLI against an in-process mock with a dummy key, and capture the requests. Contract tests:
  1. The base-URL path prefix is preserved. (Already confirmed by hand.)
  2. Precedence between `--settings` env, shell env and `~/.claude/settings.json` env, using a temporary `HOME`.
  3. The shape of `tool_result` content for WebFetch, WebSearch, Bash, Read (text and image), Grep, an MCP stdio test server (text and image), errors (`is_error`), and parallel results.
  4. Hint headers (`x-claude-code-request-class`, agent IDs) with `CLAUDE_CODE_GATEWAY_HINT_HEADERS=1`.
  5. What Claude Code sends for old tool results in long sessions, to see whether the client clears or edits them.
- Write a live check script (manual, costs money): run the preserved-thinking self-test on the user's account, and confirm stable replay works with thinking blocks present.

**Exit:** CI is green, contract tests 1–5 pass or have documented answers, `docs/poc-findings.md` is updated, and the bundle ID and GitHub owner are decided.

## Phase 1: Pass-through gateway (`dioramad`)
**Goal:** Claude Code works identically through Diorama when no rules are active.

- A SwiftNIO server that does routing (`/s/{token}`), forwards upstream with `async-http-client`, and handles hop-by-hop headers and `Host`/`Origin` checks.
- Streaming pass-through, with a copy of the stream going to the SSE parser.
- The session registry (in memory for now), and the 403 response with `x-should-retry: false` for unknown tokens.
- `DioramaJSON.scan` to extract tool results and metadata, logged only, not yet rewriting.
- The GRDB store and blob store for exchanges, raw capture and credential redaction.

**Exit:**
- Contract tests show byte-identical forwarding of requests and of streamed responses.
- Integration tests cover streaming, errors, retries, large bodies (over 20 MB) and concurrent requests.
- p95 added latency is under 5 ms.
- A live session with real Claude Code is indistinguishable from a direct one, including cache-hit numbers.

## Phase 2: CLI, daemon lifecycle and the control API
**Goal:** `diorama run -- claude` is the real entry point.

- The control API over a Unix socket (HTTP + SSE), and a typed client.
- `diorama run`, `sessions`, `daemon start|stop|status`, and `doctor` with its version, settings-conflict, port, key and connectivity checks.
- The daemon auto-starts from the CLI. A LaunchAgent registration is ready for the app to use.
- Sessions are persisted with a frozen configuration, and the gateway environment is injected via `--settings` as well.

**Exit:**
- Starting, using and ending a routed session works from a plain terminal.
- `doctor` catches a deliberately conflicting `~/.claude/settings.json`.
- Restarting the daemon keeps sessions and their history.

## Phase 3: Rewrite engine
**Goal:** reproducible, auditable rewrites.

- Rules, profiles and session prompts with versioning, matchers, and JSON import and export.
- `RewriteProvider` and `AnthropicProvider`: raw HTTP, structured output, refusal and fallback handling, usage and cost accounting, and the API key in the Keychain.
- The decision cache with request deduplication, save-before-forward, exact replay and anomaly detection. Timeouts and the `onFailure` policies.
- `DioramaJSON.splice`, with property tests showing that only the target ranges change.
- Built-in templates for WebFetch and WebSearch. Lockdown presets.

**Exit:**
- Unit and property tests pass, and so do integration tests: multi-turn replay, concurrent requests, restarting the daemon mid-session, and rule edits mid-session having no effect.
- Live test: steer a WebFetch result in a real session. The rewrite is replayed byte-identically on every turn, cache reads hold across turns, and the API returns no errors.
- The no-rules path still passes the Phase 1 fidelity tests.

## Phase 4: SwiftUI app with the live timeline
**Goal:** the interactive workflow from start to finish.

- The app shell, connection to the daemon, and LaunchAgent registration.
- The sessions list, and a new-session sheet (folder, profile, prompt, lockdown) with *Open in Terminal* and *Copy command*.
- The live timeline: turns, tool calls, tool results, rewrite badges, request classes, latency and cache figures.
- The rewrite detail view: original and rewritten text side by side, a word-level diff, rules and prompts with their versions, explanation, model, cost, and failure reason or anomaly.
- The rules and profiles editor with version history. Settings: API key, default model, port, retention.

**Exit:** a user can start a session, apply a global rule plus a session prompt, and audit every change from the UI. UI tests cover the timeline and the detail view.

## Phase 5: Hardening (completes M1)
- Error handling throughout, retention and size limits, recovery after disk-full or a crashed daemon.
- Performance with 1M-token contexts and long sessions.
- Handling sessions resumed outside Diorama.
- Testing against the latest Claude Code release, and a recorded supported-version range.
- Documentation: user guide, rule cookbook, troubleshooting.

**Exit:** a week of real use with no data loss and no Claude Code breakage. Contract tests pass on the current CLI version. **Tag v0.1 (internal).**

## Phase 6: Experiment runner core
- The experiment definition model with versioning, APFS clones, trial orchestration (`claude -p`, `stream-json`), concurrency, and seeded interleaving of variants.
- The frozen-treatment cache (architecture.md §5), the reproducibility manifest, and the cost estimator with a mandatory confirmation step.
- `diorama experiment run <file>` from the CLI, so experiments can be scripted.

**Exit:**
- An experiment with 2 variants × 3 trials on a sample project completes.
- Manifests are complete. Trials never touch the original folder.
- With frozen treatment on, every trial sees identical rewrites. The estimate falls within the actual cost band.

## Phase 7: Comparison and reporting (completes M2)
- An Experiments tab: definition editor, run monitor, and the comparison view, with facts and heuristic signals shown separately.
- Statistics (Wilson intervals, spread), small-N warnings, and no causal wording.
- Export as a JSON bundle and as a Markdown report.

**Exit:** a real experiment, steered docs versus control, run end to end with a report that a third party could reproduce from the bundle. **Tag v0.2.**

## Phase 8: Public release preparation
- Developer ID signing and notarization, a Homebrew cask (with the CLI linked from the app bundle), and auto-update (Sparkle).
- README, responsible-use statement, CONTRIBUTING, issue templates, and a trademark search for the name.

**Exit:** a fresh Mac goes from `brew install --cask diorama` to a steered session in under 5 minutes. **Public v1.0.**

---

## Phase log
Legend: ✅ exit criteria met · ◐ met, except for items that need credentials or live usage (listed)

| Phase | Status | Evidence / remaining |
|---|---|---|
| Kickoff + PoC | ✅ 2026-10-25 | [poc-findings.md](poc-findings.md) |
| 0 Foundations and compatibility | ◐ | Repository, package and CI config exist. Contract tests 1–4 pass with the real CLI 2.1.296 (base path, `--settings` precedence, tool-result shapes for Read/Bash/Grep/image, hint headers). **Remaining:** CI hasn't run on GitHub because nothing is pushed. WebSearch and MCP result shapes, and client-side clearing of old tool results in long sessions, need a live session. The preserved-thinking self-test needs an enforced account and live calls. |
| 1 Pass-through gateway | ◐ | Byte-identical forwarding, streaming without buffering, errors, 20 MB bodies, gzip, concurrency and restart persistence are tested. Added latency is p95 4.8 ms in a debug build with a 200 KB body. **Remaining:** a live real-API session comparing cache-hit numbers (needs authorization, D22). |
| 2 CLI, daemon, control API | ✅ | All commands are implemented. The release binaries were smoke-tested, the daemon autostarts, the supervisor restarted a killed daemon on the same port, and sessions survive restarts (test). |
| 3 Rewrite engine | ◐ | 21 engine tests. A real HTTP round trip of the Anthropic provider against a fake endpoint that checks the request shape succeeded. **Remaining:** a live rewrite with a real API key. |
| 4 SwiftUI app | ◐ | Builds, bundles and launches, and autostarts the daemon from `Contents/Helpers`. Sessions, Experiments, Profiles and Settings were checked visually through self-rendered snapshots of real data. **Remaining:** no automated UI interaction tests. The editing and new-session sheets were built and compiled but not clicked through. |
| 5 Hardening | ◐ | Corruption recovery, newer-schema refusal, retention and garbage collection, umask 077, request size limit, host/origin checks, and redaction are tested. Docs (user guide, security, troubleshooting) are written. **Remaining:** "a week of real use". The tested Claude Code range is a single version (2.1.296). |
| 6 Experiment runner | ✅ | Runs end to end with the real `claude` CLI (contract test and release-CLI smoke run): isolation, frozen treatment, manifests, confirmation token, blocked randomization. |
| 7 Comparison and reporting | ✅ | Facts and heuristics separated, Wilson intervals, caveats, Markdown and JSON reports, app comparison view. |
| 8 Release preparation | ◐ | Bundle script with ad-hoc signing, icon, zip and sha256, Homebrew cask template, release guide, CONTRIBUTING, third-party notices, changelog, issue and PR templates. **Remaining (maintainer):** Developer ID signing, notarization, trademark search, final bundle ID and GitHub owner, publishing. |
