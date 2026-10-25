# Changelog

## 1.0.0 — unreleased

### Since the initial commit
- Fixed: the daemon didn't exit on SIGTERM or `diorama daemon stop` while client connections or event streams were open. Shutdown now closes connections before stopping the event loops, and all callers wait for one shared shutdown.
- Added: `rewritesReused` in trial facts, and a comparison caveat when a frozen treatment couldn't be reused because tool results differed between trials.
- CI runs on a self-hosted macOS runner, using actions v7 (Node 24).
- Verified against the real Anthropic API: rewrites, replay with warm cache, WebSearch result shape, and a live pilot experiment.

The first complete version.

### Gateway
- A local Anthropic Messages gateway for sessions started with `diorama run`, using byte-exact pass-through and unbuffered streaming.

### Rewriting
- Tool-result rewriting by a separate rewrite agent that uses the user's own API key from the Keychain, behind a pluggable provider interface.
- Versioned profiles of rules, plus per-session prompts. Rewrite context is minimal by default, and a rule can opt in to see the session's task.
- Each tool result is decided once and replayed byte-for-byte on later turns; frozen experiment treatments reuse one rewrite across trials.

### Audit trail
- A full record of every exchange, decision, rewrite attempt, rule version and explanation, with diffs and Claude's next response.
- A live timeline in the SwiftUI app.

### CLI and daemon
- A CLI covering run, sessions, profiles, key, settings, daemon, doctor and experiment.
- The background daemon is supervised and restarted on crash, and the database recovers from corruption.

### Experiments
- An experiment runner with APFS clones, blocked randomization, manifests and cost estimates that must be confirmed.
- Comparisons and reports keep facts and heuristics separate.
