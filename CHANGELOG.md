# Changelog

Release notes are generated from this file. Add changes under **Unreleased**;
`scripts/release.sh X.Y.Z` stamps that section with the version and date.

## Unreleased

### New
- **Compare two sessions.** **Compare…** in the session header (or `diorama session compare`, MCP `compare_sessions`) shows two sessions side by side: counts, cost, duration and tokens with differences, tool results per tool, rules that rewrote, and both final answers (optionally diffed).
- The session header's actions moved to their own row, so long names and the id no longer get cut off.
- **Rule tests from real results.** **Add as rule test** in a tool result's audit record (or `diorama profiles add-test --decision`, MCP `add_rule_test`) saves it as a test case expecting the rules that match it now.
- **Rule tests.** Profiles can carry test cases (a sample tool result and the rules that should match it), checked live in the editor and with `diorama profiles check` (exit 1 on failure, works on a JSON file for CI) or MCP `run_profile_tests`. Matching only: free.
- **Folder defaults.** Give a project folder a default profile (`diorama folders set`, New Session, Settings → Folder defaults); `diorama run` in that folder or below uses it unless you pass `--profile`, `--prompt` or `--no-folder-default`.
- **More templates.** New starting points for shadow mode, review mode, sampling, a classifier rule and an input rule (appended, so `--template N` numbers are unchanged).
- **Spending history.** Settings → Spending charts rewrite-agent spending per day over 30 or 90 days, split into sessions, experiment trials and playground/what-if, with a per-profile breakdown. Also `diorama spend --days N` and MCP `get_spend_history`.

## 1.4.0 — 2026-10-25

### New
- **Shadow mode.** A profile can compute its AI rewrites without applying them: Claude gets the original, and each tool result records what would have changed (shown as a diff in its audit record, with a **shadow** badge). Trials ignore it.
- **Rule sampling.** `match.sample` (or **Apply to a sample** in the editor) applies a rule to a share of its matching tool results, chosen deterministically per result id, so changed and unchanged results can be compared within one session; skipped results say "not in the sample of …".
- **Session notes and tags.** Tag sessions and write notes in the session header (double-click the name to rename); filter the list by tag. Included in reports, data exports and MCP. Also `diorama session tag|note|rename`, `diorama sessions --tag`, MCP `annotate_session`.
- **Data export.** **Export Data…** (Sessions toolbar) and `diorama export` write every decided tool result as CSV or JSON Lines: session, profile version, tool and input, outcome, reason, rules, attempts, cost and sizes, optionally with the texts. Filter by time, profile, session, trials or rewritten only.
- **Share profiles.** **Export…** in the profile editor saves a profile as JSON; **Import Profile…** (or dropping `.json` files on the profile list) adds them, renaming on a name clash. Same format as `diorama profiles export` / `create --file`.
- **Compare profile versions.** **Compare with vN** in a profile's version history, and **Show Changes…** for unsaved edits, list rules added, removed, changed (field by field, with a word diff for instructions) or moved, plus changed defaults. Also `diorama profiles diff` and MCP `compare_profile_versions`.
- **Review mode.** A profile can hold each AI rewrite for your approval: Claude waits while Diorama shows the word diff (sheet, banner, menu bar, notification); approve to send it, reject or let the wait (15–120 s) run out to send the original. ⌘↩ / ⌘⌫ answer the oldest, and the menu bar can answer without opening the window. Also `diorama review`; MCP can list pending reviews but not answer them. Trials and input rules are exempt.
- **Rule usage.** The profile editor shows, per rule, how many tool results it matched and what came of them (rewritten, unchanged, failed), classifier answers, sessions and cost over 7, 30 or 90 days or all time, and flags rules that never matched. Also `diorama profiles stats` and MCP `get_rule_stats`.
- **Pause steering.** Stop Diorama changing anything, for one session (**Pause** in its header, `diorama session pause`) or everywhere (menu bar, Settings, `diorama pause`), without restarting Claude. Paused results pass through unchanged; redaction still applies and experiment runs aren't affected. Also MCP `set_steering_paused`.
- **Content-aware rules.** A rule can carry a classifier: a yes/no question a cheap model answers about the content ("Does this page state a price?"); the rule applies only on "yes", and a "no" or a failed call leaves the result unchanged. Verdicts are recorded as attempts (mode `classify`) and count toward the budget; the playground runs them on Run rewrite. Works with Anthropic models and `ollama:` models.
- **Session reports.** Export a session's audit trail as Markdown or self-contained HTML (**Export** in the session header, `diorama session report`, MCP `get_session_report`): configuration, summary, notices, each change with a word diff, rules, rewrite-agent work and what Claude did next, and what was left unchanged.

### Fixed
- The playground sent redaction rules (which have no instructions) to the rewrite agent along with the AI rules when both matched.

## 1.3.0 — 2026-10-25

### New
- **Input rules.** `"stage": "input"` rules change a tool call's arguments before it runs: redirect a WebFetch URL, steer a WebSearch query, change a Read path. The agent may change values but not add or remove parameters. Claude Code always asks you to approve a changed call (`claude -p` denies it and tells the model why). Works in hook mode and `diorama run` (a PreToolUse hook is added automatically); not in experiment trials. Existing hook installs need `diorama hook install` again.
- **Redaction rules.** A rule can redact instead of rewrite: secrets (API keys, tokens, JWTs, private keys), optionally email and IP addresses, and custom regexes become `[REDACTED:kind]` before Claude sees the result. Local, free, no AI; runs before AI rewrites (so the rewrite agent never sees secrets) and still applies when the budget is used up or a rewrite fails. New template "Privacy: redact secrets"; the playground previews it for free.
- **Search across sessions.** A search field on the Sessions screen (and `diorama search`, MCP `search`) finds tool results (original and rewritten), tool inputs like URLs and queries, rewrite reasons, and Claude's replies across all sessions, ranked, with highlighted matches; click a result to open it. Backed by a local SQLite full-text index that also indexes earlier sessions on first start.
- **Stronger experiment statistics.** Runs show each steered variant's difference from the control with a 95% interval per metric (Newcombe for shares, Welch for means), highlighting intervals that exclude zero, in the app, `experiment compare` and the Markdown report. Completed runs of an experiment can be pooled (**All runs (pooled)**, `--pooled`), and **Compare two trials…** puts two trials' numbers and final answers side by side.
- **Experiment from a session.** **Experiment…** in a session's header prefills an experiment with the session's task (its first prompt), project, tools and model, an unmodified control, and the session's steering pinned to the exact profile version it used. Review, create, then estimate and run as usual. Also `diorama session experiment` and the MCP tool `draft_experiment_from_session`. Profile references now accept a version id (`pv_…`) to pin one version.
- **Notifications.** While Diorama is in the background, macOS notifications tell you when an experiment run finishes, when the rewrite budget is used up (once a day), and when rewrites start failing in a session (at most once per session every 10 minutes). Click to open the run or session; choose them in Settings → Notifications.

### Fixed
- `diorama session show` now lists a hook-mode session's tool results (it showed only model requests, which hook sessions don't have), and includes budget warnings.

## 1.2.0 — 2026-10-25

### New
- **Claude desktop support (hook mode).** `diorama hook install` (or **New Session → Claude desktop & IDEs** in the app) connects a project through Claude Code hooks. Sessions in the Claude desktop app's Code tab, and in IDEs, then have their tool results rewritten and recorded with the same profiles and prompts. They appear with a "hook mode" badge. Hook mode doesn't capture model traffic or do pre-extraction; `diorama run` remains the full mode and runs experiments.
- **AI control (MCP).** One click on **Connect to Claude…** (sidebar, menu bar or Settings) in the app, or `diorama mcp install --claude-code` / `--claude-desktop`, lets Claude list sessions, read audit records, write profiles, connect projects for hook mode, and run experiments. Starting a run needs the cost estimate's confirmation token. `--read-only` exposes inspection tools only.
- **Rule playground.** Try rules on a past tool result or pasted text before using them: see which rules match (and for the others, the condition that failed), then optionally run the rewrite agent once and see the diff, explanation and cost. Nothing is recorded. Open it with **Test Rules…** in the profile editor (it uses the unsaved draft), the test-tube button on any tool result, `diorama profiles test`, or the MCP tool `test_rules`.
- **What-if replay.** Re-run a session's recorded tool results through another profile, a specific version, a prompt or a draft, and compare: newly rewritten, rewritten differently, same, or no longer rewritten. The check and its cost estimate are free; the rewrite run is capped (25 by default). Nothing is recorded. In the app it's **What if…** in a session's header; also `diorama session whatif` and the MCP tool `what_if_replay`.
- **Budget guard.** Daily caps on rewrite-agent spending, overall (`dailyBudgetUSD` in settings) and per profile (`defaults.dailyBudgetUSD`). When one is used up, matching results pass through unchanged, the session is flagged and warned, and paid playground and what-if runs are refused; experiments are exempt (they have their own approved estimate). Today's spending shows in Settings, the menu bar and `diorama spend`.
- **Menu bar icon.** Diorama lives in the menu bar: running sessions, New Session, Open Diorama, Quit. Closing the window keeps the app running there (no Dock icon) instead of quitting. You can turn this off in Settings → App.
- **New icon.** The app icon and the menu bar icon are now the same open box, seen at a slight angle, with the yellow dot inside. Every edge has the same width, so the menu bar version stays legible at 16 px. In the menu bar, the dot fills while a session is running.

### Fixed
- Profiles whose names contain spaces couldn't be looked up by name through the control API (`diorama profiles show "Docs steer"`): the path was percent-encoded twice.
- Two daemons started at the same moment, for example by the app and the CLI, could race the database setup. The daemon now takes its single-instance lock before it opens the database, and the app shares one connection attempt across its windows.

### Improved
- **Sessions timeline, redesigned.** Requests are grouped into turns: the tool results Claude received, what Diorama did to each, and Claude's response. Background requests (WebFetch's summarizer, token counts) fold under their turn. Each tool result shows its target (URL, query, file), and replayed results are hidden unless you ask for them. The session header has stat tiles.
- **Decision detail, reordered.** It shows the outcome and reason first, then the changes, what Claude did next, the rules that applied, and the rewrite agent's edits. IDs and hashes move into a collapsed "Technical details" section.
- **Getting started.** With no sessions yet, the app shows a three-step checklist (API key, profile, first session) and the command-line install.
- **Experiment results are easier to read.** Runs are titled by date. Caveats sit in a callout. Heuristic signals are bars with 95% interval whiskers. Numbers drop noise ("3", not "3.0 ± 0.0"). The definition view and the new-experiment form are reorganized, with variants shown up front.
- **Profiles and Settings.** The rule editor flags rules that can never work (no tools, no instructions, invalid regex). Version history marks the current version. Settings adds a command-line install helper and a "Show in Finder" button for the data folder. The new-session form is grouped and shows its advanced options only when relevant.

## 1.1.0 — 2026-10-25

### New
- **Pre-extraction mode for WebFetch.** Rules and session prompts with `"stage": "page"` rewrite the raw page before WebFetch's summarizing model reads it. Pages are matched by URL, so frozen experiment treatments are reused across trials even though WebFetch summaries vary. Use `diorama run --prompt-stage page …`, the "Applies to" picker in the rule editor, or the new "Web: edit pages before summarization" template.
- **LLM judge for experiments (opt-in, heuristic).** After a run, a model rates whether each trial's final answer adopted the changed information; controls are judged too, as a baseline. Verdicts appear with the heuristics, never with the facts. Turn it on with `"judge": {}` in the experiment definition, or the toggle in the app.
- **Local models through Ollama.** Use a model id like `ollama:llama3.1` for rewrites or the judge. Nothing leaves your Mac and the cost is $0. Set the server with `diorama settings set ollamaURL …`.
- **Update checks.** `diorama update` checks GitHub Releases, and `diorama update --download` downloads the zip and verifies its checksum. The app checks once a day (configurable) and shows a notice when a newer version exists.
- **UI smoke test in CI.** Every screen and sheet is rendered off-screen on each push.

### Improved
- Experiment comparisons record how many rewrites were reused (`rewritesReused`), and warn when a frozen treatment couldn't be reused.
- Frozen treatments are serialized: trials running in parallel now wait for one rewrite instead of each making its own (seen in a live run).
- The "echoed rewritten content" heuristic is computed the same way for every trial, controls included, against the whole run's set of new words. Words already present in the original page no longer count. Before, controls scored 0 by construction.
- Changes shown to the LLM judge are now whole phrases rather than single words, which removes a false "adopted" verdict seen on a control trial.
- Verified against real Claude Code: MCP tool results (text and image blocks) and WebSearch results.

## 1.0.0 — 2026-10-25

The first complete version of Diorama.

### Steering
- A local Anthropic Messages gateway for Claude Code sessions started with `diorama run` or the app. Diorama changes no global settings: routing applies only to sessions it starts.
- Tool results (WebFetch, WebSearch, Read, Bash, Grep, MCP…) are rewritten by a separate rewrite agent that uses your own Anthropic API key, stored in the macOS Keychain.
- Global rules come as versioned profiles, plus per-session prompts. Rewrite context is minimal by default, and a rule can opt in to see the session's task.
- Reproducible: each tool-result decision is made once and replayed byte-for-byte on later turns, which keeps the history consistent and the prompt cache warm.

### Auditing
- A live session timeline: requests, tool results, rewrites, cache usage, added latency, and what Claude did next.
- For every rewrite: the original and rewritten text with a diff, the rules with their content hashes and versions, the instructions, the rewrite attempts with model, cost and latency, and the explanation.

### Experiments
- A/B experiments: an unmodified control plus steered variants, with repeated `claude -p` trials in APFS clones of your project.
- Blocked randomization, frozen treatments, a reproducibility manifest for each trial, and a cost estimate that must be confirmed before a run starts.
- Comparisons keep observed facts separate from heuristic signals, with Wilson intervals, small-sample caveats and no causal claims. Reports can be exported as Markdown or JSON.

### Tooling
- A `diorama` CLI covering run, sessions, profiles, key, settings, daemon, doctor and experiment, plus a SwiftUI app and the `dioramad` background service, which is restarted if it crashes.
- Verified against the real Anthropic API with Claude Code 2.1.296.
