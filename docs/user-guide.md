# Diorama user guide

## Concepts

| Term | Meaning |
|---|---|
| **Session** | One Claude Code process started through Diorama (`diorama run`, or *New Session* in the app). Only sessions started this way are routed through Diorama. |
| **Gateway** | The local server (`dioramad`) at `127.0.0.1:47821`. Claude Code reaches it with a per-session URL, `…/s/<token>`. |
| **Tool result** | The output of a tool Claude Code ran (WebFetch, WebSearch, Read, Bash, Grep, MCP tools…), sent to the model in the next request. Tool results are what Diorama can rewrite. |
| **Rule** | A matcher (tool names, input patterns, content pattern, size, request class) plus instructions for the rewrite agent. |
| **Profile** | A named, ordered set of rules plus defaults (rewrite model, failure policy, limits). Every save creates an immutable **version**, and a session pins the version current when it started. |
| **Session prompt** | An ad-hoc rule attached to one session. By default it applies to WebFetch and WebSearch, and it runs after the profile's rules. |
| **Decision** | What Diorama did with one tool result: `unchanged`, `rewritten` or `failed`. It's made once, saved, and replayed byte-for-byte on every later request. |
| **Rewrite agent** | A separate model call (default `claude-haiku-5-5`) made with **your** Anthropic API key. It returns structured edits and an explanation. |

## Setting up

1. Install Diorama (see the README) and run `diorama doctor`.
2. Store the rewrite agent's key with `diorama key set`, or in the app under Settings. The key goes into the macOS Keychain. For CI or other headless setups, set `DIORAMA_ANTHROPIC_API_KEY` in the daemon's environment instead.
3. Claude Code itself keeps using its normal sign-in (claude.ai subscription or API key). Diorama forwards those credentials unchanged and never uses them for its own calls.

The daemon starts automatically the first time you use the CLI or the app. To start it at login, opt in with `diorama daemon install`; `diorama daemon uninstall` removes it again.

## Running a session

```bash
cd ~/code/project
diorama run                                   # route only: everything is recorded, nothing is rewritten
diorama run --profile "Docs steer"            # apply a profile
diorama run --prompt "Present v2 as deprecated" --prompt-tools WebFetch,WebSearch
diorama run --prompt-file steer.txt --prompt-context task   # opt in: give the rewrite agent the session's task
diorama run --lockdown network --profile web  # block curl/wget so Claude can't fetch around a rewrite
diorama run --profile web -- --model sonnet   # anything after -- goes to Claude Code
```

`diorama run` starts Claude Code in your terminal with two variables set for that process only: `ANTHROPIC_BASE_URL`, pointing at your session's gateway URL, and `CLAUDE_CODE_GATEWAY_HINT_HEADERS=1`, which labels each request as main, subagent, auxiliary and so on. It passes the same values through `--settings`, so they win over an `env` block in your own `~/.claude/settings.json`. No file is changed. If the daemon dies mid-session, `diorama run` restarts it on the same port.

**Surfaces:** the terminal CLI is supported. The VS Code extension works if you set the printed variables in `claudeCode.environmentVariables`. The Claude Desktop Code tab is not supported, because it ignores `ANTHROPIC_BASE_URL`.

## Writing rules

A profile is JSON (`diorama profiles export <name>` shows one). Example:

```json
{
  "name": "Docs steer",
  "description": "Nudge library recommendations in fetched docs.",
  "defaults": { "model": "claude-haiku-5-5", "onFailure": "passOriginal", "maxInputChars": 200000, "timeoutSeconds": 45 },
  "rules": [
    {
      "name": "Mark v1 API deprecated",
      "match": { "tools": ["WebFetch", "mcp__docs__*"], "input": { "url": "docs\\.example\\.com" }, "content": "v1" },
      "instructions": "Where the page describes the v1 API, add one sentence in the page's style saying v1 is deprecated in favour of v2.",
      "context": "none"
    }
  ]
}
```

- `match.tools` takes glob patterns, where `*` matches anything (`mcp__*` matches every MCP tool). It is required.
- `match.input` maps fields of the tool input to regexes, using dot paths such as `url` or `options.0.name`. Every listed field must match.
- `match.content` is a regex on the tool result's text. `minChars`/`maxChars` limit by size, and `requestClasses` limits by request class (for example `["main"]`). `includeErrors` allows rewriting error results.
- When several rules match one tool result, Diorama makes **one** rewrite call carrying all their instructions, in order. Later rules take priority.
- `context: "task"` gives the rewrite agent the session's first user message, with system reminders removed. Without it the agent sees only the instructions, the tool name and input, and the original result.
- The rewrite agent prefers small, exact edits. Each `find` must occur exactly once in the result. If an edit doesn't apply, Diorama retries once and tells the agent what went wrong.

Templates: `diorama profiles templates`, then `diorama profiles create --template N`.

## Reading the audit trail

- **App → Sessions** shows a live timeline of every request: its class, status, token usage including cache reads and writes, and the latency Diorama added. Each tool result is marked `rewritten`, `unchanged`, `failed`, `client-modified` or replayed, followed by Claude's next text and tool calls. Selecting a tool result shows the original and rewritten text (as a diff or side by side), the rules with their content hashes and profile version, the instructions, every rewrite attempt (model, latency, cost, explanation, edits, errors), and what Claude did next.
- **CLI:** `diorama session show <id>`, `diorama session decision <tool_use_id>`, and `diorama session watch [<id>]` for live events.
- **Raw capture:** full request and response bodies are kept for `retentionDays` (14 by default) and are available through the control API (`GET /api/v1/exchanges/<id>/raw`). Credentials are never stored.

### Anomalies

| Event | Meaning |
|---|---|
| `client-modified` | Claude Code sent different content for a tool result that was already decided (for example, it cleared an old result). Diorama forwards Claude Code's version. |
| `rewrite failed` | The rewrite agent failed, timed out or refused, or there's no key. The original was forwarded and the session is flagged. |
| `replay-integrity` | A stored rewrite could not be loaded. This should not happen. Please report it. |

## Experiments

```bash
diorama experiment init > exp.json
```

Key fields:
- `task`: the prompt given to `claude -p`.
- `projectPath`: copied for each trial with an APFS clone, then deleted after the trial is analyzed.
- `claude`: `model`, `permissionMode`, `allowedTools`, `disallowedTools`, `maxTurns`, `maxBudgetUSD`, `extraArguments`, `timeoutSeconds`, and `isolateConfiguration`. That last one, `true` by default, runs Claude Code with `--setting-sources project,local --strict-mcp-config`, so your personal settings and MCP servers don't vary between trials.
- `variants`: two or more. Exactly one with no `profile` and no `prompt` is the **control**.
- `trialsPerVariant`, `concurrency`, `seed`.
- `treatment`: `frozen` (default) reuses one rewrite for identical tool results across trials. `fresh` rewrites in every trial, which also measures the rewrite agent's variability.
  Reuse needs byte-identical tool results. WebFetch summarizes pages with a model, so its output usually differs between trials, and each trial then gets its own rewrite. The comparison says so when that happens. Read, Bash, Grep and most MCP tools return deterministic output and are reused.

`diorama experiment run exp.json` shows an estimate for Claude Code usage and the rewrite agent, then asks you to type `yes`. The control API also refuses to start a run without the estimate's confirmation token. Trials run in blocked random order: every variant once per round, shuffled by the seed.

**Results** (app → Experiments, or `diorama experiment compare <run>`):
- **Observed facts** are measured values: errors, turns, duration, tokens, Claude Code's reported cost, rewrite cost, rewrites applied, tool calls, distinct final outputs, and files changed.
- **Heuristic signals** are pattern matches, always labeled as heuristics:
  - *echoed rewritten content*: text introduced by a rewrite appears in the final answer
  - *flagged suspicion*: wording such as "looks altered" or "doesn't match"
  - *tried to verify*: re-fetching a rewritten URL, or curl/wget after a rewrite
- Proportions come with Wilson 95% intervals. Variants with fewer than 10 valid trials are marked exploratory, and reports state that differences are associations, not proof of cause.
- Trials whose rewrite failed are marked `invalid` and excluded from the facts, because they didn't receive the intended treatment.

`diorama experiment report <run> --format md|json` exports a report. The JSON bundle contains every trial's manifest.

## Settings

`diorama settings show` displays the current values. Change one with `diorama settings set <key> <value>`, where the key is one of:

| Key | Purpose |
|---|---|
| `defaultModel` | Rewrite model used when a session has no profile |
| `retentionDays` | How long raw request/response capture is kept |
| `captureRawBodies` | `true` or `false` |
| `claudePath` | Path to the `claude` executable |

## Data locations

Everything lives under `~/Library/Application Support/Diorama/`, or under `$DIORAMA_HOME` if set:
- `diorama.sqlite`
- `blobs/` (compressed, content-addressed captures)
- `runs/` (trial transcripts)
- `logs/dioramad.log`
- `daemon.json` (port and control token, mode 0600)

Delete the folder to reset Diorama. Remove the API key with `diorama key delete`.
