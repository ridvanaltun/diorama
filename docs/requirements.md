# Diorama — Requirements (v1)

> Stage what your coding agent sees. Measure what it does.

Status: **agreed in the kickoff interview, 2026-10-25.** Changes go through [decisions.md](decisions.md).

## 1. Product summary

Diorama is a macOS app for **steering and experimenting with the tool results Claude Code receives**. It sits between Claude Code and the Anthropic API as a local gateway, rewrites selected tool results with a separate AI agent driven by the user's prompts, records every change in a full audit trail, and lets the user run controlled A/B experiments to compare how Claude Code behaves with and without those changes.

It is a research and control tool. It is **not** a security filter, and it is not a general traffic viewer.

## 2. Users and use cases

Primary user: a developer or researcher studying how AI coding agents react to the information they're given.

- **U1 Steer a live session.** Start a Claude Code session in Diorama, apply global rules plus a session-specific prompt, work normally, and watch each rewrite and Claude's next actions in a live timeline.
- **U2 Audit a change.** For any tool result, see the original, the rewritten version, a diff, the rules and prompts that applied, the rewrite agent's explanation, and what Claude did next.
- **U3 Run an experiment.** Define a task, a project folder, and two or more variants including an unmodified control. Run N trials per variant in isolated copies of the project, then compare the results.
- **U4 Reproduce a result.** Re-run or inspect any session or trial with its exact model, settings, prompts, rule versions and configuration.

## 3. Functional requirements

### 3.1 Interception (gateway)
- **FR-1** Run a local Anthropic Messages API gateway that Claude Code reaches through `ANTHROPIC_BASE_URL`.
- **FR-2** Preserve the API protocol completely: pass through all `anthropic-*` headers and body fields as-is, without filtering them against a known list; stream server-sent events without buffering; forward response headers, including `retry-after`, `x-should-retry` and `anthropic-ratelimit-unified-*`; forward error bodies unmodified.
- **FR-3** Work with the user's existing Claude Code sign-in, whether a claude.ai subscription or an API key, by forwarding the client's credentials. Diorama never reuses those credentials for its own calls.
- **FR-4** Parse outgoing `/v1/messages` and `/v1/messages/count_tokens` requests. Identify every `tool_result` block and resolve its tool name and input from the matching `tool_use` block.
- **FR-5** Modify only the bytes of the `tool_result` content being rewritten. Everything else in the request stays byte-identical.
- **FR-6** Requests with nothing to rewrite are forwarded byte-for-byte.

### 3.2 Sessions (v1: app-launched only)
- **FR-7** Sessions are started from the app or with `diorama run -- claude …`. Diorama never routes sessions it didn't start.
- **FR-8** Each session has a name, working folder, profile (a set of global rules at a specific version), an optional session prompt, and optional tool lockdown. All of these are fixed before the first request.
- **FR-9** Sessions are told apart by an unguessable token in the base URL path. Claude Code's own session, subagent and request-class headers are recorded.
- **FR-10** Supported surfaces: the terminal CLI first, with the VS Code extension as a bonus. The Claude desktop Code tab ignores `ANTHROPIC_BASE_URL`, so it is covered by hook mode (D36), which handles tool results only.

### 3.3 Rules, prompts and the rewrite agent
- **FR-11** Global rules, grouped into profiles, plus a session-specific prompt. A rule decides when it fires with cheap deterministic conditions (tool name or wildcard pattern, input field patterns such as the URL's domain, content patterns, size limits, request class) and carries rewrite instructions.
- **FR-12** Rules and profiles are versioned and immutable once used. Every rewrite records the exact versions that produced it.
- **FR-13** Rewrite agent: the Anthropic Messages API with the user's own API key, stored in the Keychain, behind a pluggable `RewriteProvider` interface. The model is chosen per rule, with a global default.
- **FR-14** By default the rewrite agent sees only the rule instructions, the tool name and input, and the original result. A rule can opt in to also see the session's task (the user's first message).
- **FR-15** The rewrite agent returns structured output: a decision (`rewrite` or `unchanged`), the new content, an explanation, and a list of changes.
- **FR-16** Any tool can be targeted, including MCP tools. Built-in templates cover WebFetch and WebSearch.
- **FR-17** Tool lockdown (optional, per session or experiment) blocks tools that let Claude get around a rewrite, for example `curl` through Bash. It works through `permissions.deny` in the per-session `--settings` (D26).

### 3.4 Reproducibility and stability
- **FR-18** The decision for each tool result is made once and then frozen. That covers rewrite, unchanged, and failed decisions. Later requests replay the stored bytes exactly, across turns, retries, subagents, compaction and resumed sessions.
- **FR-19** The frozen decision is saved to disk before the request is forwarded.
- **FR-20** Editing a rule mid-session never changes a tool result that has already been decided.
- **FR-21** Replay problems are detected and shown: content Claude Code itself changed, a stored decision that's missing, or a session resumed outside Diorama.
- **FR-22** Rewrite failures are handled by policy. The default is to pass the original through and mark the session. Every failure is recorded.

### 3.5 Observability (interactive, built first)
- **FR-23** A live timeline per session: requests and turns, tool calls, tool results, rewrite events, and Claude's following actions, all linked together.
- **FR-24** A rewrite detail view showing original, rewritten, diff, applied rules and prompts with their versions, explanation, model, latency, tokens, cost and failure reason if any.
- **FR-25** Per-request metadata: model, request class, agent ID, status, time to first byte, added latency, token usage including prompt-cache reads and writes, and rate-limit headers.
- **FR-26** Raw request and response capture with configurable retention. Credentials are never stored.

### 3.6 Experiment runner (built after interactive sessions are reliable)
- **FR-27** An experiment defines a task prompt, a project folder, Claude Code settings (model, permission mode, allowed and blocked tools, turn and budget limits), two or more variants including an unmodified control, the number of trials per variant, and how many run at once.
- **FR-28** Each trial runs headless with `claude -p` in an isolated copy of the project, using an APFS clone where possible.
- **FR-29** The treatment is frozen across trials by default: the same rule version, tool input and original content reuse one rewrite. A switch allows a fresh rewrite on every trial.
- **FR-30** Each trial records a reproducibility manifest: Claude Code version, model, CLI arguments, cleaned-up environment, settings hash, profile and rule versions, rewrite-agent system prompt version, Diorama version, project snapshot identity, and timestamps.
- **FR-31** Before any batch starts, Diorama shows a cost estimate covering Claude Code usage and rewrite agent usage. Starting the batch requires explicit confirmation.
- **FR-32** Comparison covers final outputs, tool activity, rewrite events, duration, token usage, and cost where available.
- **FR-33** Observed facts are shown separately from heuristic signals, and heuristics are always labeled as such. The UI shows sample sizes and uncertainty, warns when N is small, and never claims causation.
- **FR-34** Experiments can be exported as a JSON bundle and as a Markdown report.

## 4. Non-functional requirements

- **NFR-1 Fidelity.** With no rules active, Claude Code behaves identically through Diorama. This is verified by contract tests against the real CLI.
- **NFR-2 Latency.** Pass-through adds less than 5 ms before forwarding at the 95th percentile, excluding rewrite time. Streaming adds no buffering delay.
- **NFR-3 Safety margin.** Holding a request for rewrites must finish well inside Claude Code's 5-minute streaming idle limits: 45 seconds per rewrite and 120 seconds per request by default.
- **NFR-4 Privacy.** Everything stays local. The only outbound traffic is Claude Code's own traffic to its usual destination and rewrite-agent calls to the Anthropic API. The gateway listens on loopback only. Credentials are never written to disk outside the Keychain.
- **NFR-5 Robustness.** If the app crashes, running sessions keep working: the gateway runs in a separate daemon process. Large requests of 1M-token context, many megabytes, are supported.
- **NFR-6 Open-source quality.** Clean module boundaries, tests, CI, no personal paths, documented setup. Apache-2.0 license. Public on GitHub when ready.
- **NFR-7 Platform.** macOS 15 or later, Apple Silicon and Intel, Swift 6, SwiftUI.

## 5. Out of scope for v1

- Raw HTTPS man-in-the-middle interception. This may come later as an optional "wire mode".
- Rewriting the raw page inside WebFetch's extraction call, before Claude's extraction step. This is a possible later "pre-extraction mode".
- Global capture of all Claude Code sessions. This may come later as an opt-in.
- Claude Desktop Code tab sessions and cloud sessions.
- Rewriting model *responses*. Only outgoing tool results are rewritten.
- Local model providers. The provider interface allows them later.
- Mac App Store distribution.
- An LLM-judge signal in experiments. This may come later, labeled as a heuristic.

## 6. Open items (non-blocking)

| Item | Proposed default | When needed |
|---|---|---|
| Default rewrite model | **Resolved:** `claude-haiku-5-5`; selectable per rule and per profile (D19) | — |
| Bundle ID and GitHub owner | Placeholder `io.github.diorama.Diorama`, overridable with `BUNDLE_ID=`; the owner is a placeholder in the cask and docs | Before first release |
| Apple Developer account | Needed for signing and notarization | Phase 8 (release) |
| Trademark search for "Diorama" | Before public launch | Phase 8 |
