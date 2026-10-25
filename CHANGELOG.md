# Changelog

Release notes are generated from this file. Add changes under **Unreleased**;
`scripts/release.sh X.Y.Z` stamps that section with the version and date.

## Unreleased

### New
- **Claude desktop support (hook mode).** `diorama hook install` (or **New Session → Claude desktop & IDEs** in the app) connects a project through Claude Code hooks. Sessions in the Claude desktop app's Code tab, and in IDEs, then have their tool results rewritten and recorded with the same profiles and prompts. They appear with a "hook mode" badge. Hook mode doesn't capture model traffic or do pre-extraction; `diorama run` remains the full mode and runs experiments.
- **New icon.** The app icon and the menu bar icon are now the same open box, seen at a slight angle, with the yellow dot inside. Every edge has the same width, so the menu bar version stays legible at 16 px. In the menu bar, the dot fills while a session is running.
- **Menu bar icon.** Diorama lives in the menu bar: running sessions, New Session, Open Diorama, Quit. Closing the window keeps the app running there (no Dock icon) instead of quitting. You can turn this off in Settings → App.

### Fixed
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
