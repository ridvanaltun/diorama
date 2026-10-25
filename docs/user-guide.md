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

**Surfaces:** `diorama run` covers the terminal CLI. The VS Code extension also works if you set the printed variables in `claudeCode.environmentVariables`. The Claude desktop app's Code tab sets its own `ANTHROPIC_BASE_URL` for every session and can't be routed through the gateway. Use hook mode for it, described next.

## Claude desktop and IDEs (hook mode)

Hook mode connects a project folder to Diorama through Claude Code's hooks instead of the gateway. It works wherever Claude Code reads the project's settings: the Claude desktop app's Code tab, IDE extensions, and the terminal.

```bash
cd ~/code/project
diorama hook install --profile "Docs steer"           # or --prompt "…" --prompt-tools WebFetch,Read
diorama hook status                                    # what's installed here
diorama hook uninstall
```

`diorama hook install` adds three entries (`SessionStart`, `PostToolUse` and `SessionEnd`) to the project's `.claude/settings.local.json`. Claude Code keeps that file out of version control, and the install leaves your other settings and hooks as they are. In the app, use **New Session → Claude desktop & IDEs**. After each tool call, the hook (`diorama hook run`) sends the result to the daemon. The daemon applies the same profiles, prompts and rewrite agent, records the decision, and returns the rewritten text, which Claude Code shows the model in place of the original. Sessions appear in the app with a **hook mode** badge; desktop sessions are named `<folder> · Desktop`.

- **Start a new session after installing.** Sessions that are already open don't pick up new hooks. A session's configuration is fixed when its first event arrives, and resuming it continues the same Diorama session.
- **What hook mode doesn't see.** It has no model requests or responses, so no token usage, cache hits or latency, and no record of Claude's replies. Pre-extraction (`stage: page`) isn't available either, because WebFetch's summarizing call isn't visible to hooks. Experiments always use the gateway.
- **Which results it can rewrite.** Read (text files), WebFetch, Bash, Grep (content mode), MCP tools that return text blocks, and best-effort WebSearch commentary. Other results are recorded as unchanged with the reason.
- **It never blocks Claude Code.** If the daemon can't be reached, or anything else goes wrong, the hook prints nothing and the original result is used. Errors go to `logs/hook.log`.
- **No double rewrites.** Sessions started with `diorama run` set `DIORAMA_SESSION`, and an installed hook ignores them, because the gateway already handles them.
- `diorama hook install --user` installs into `~/.claude/settings.json` instead, so that every Claude Code session on your account reports to Diorama.

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

### Where a rule applies: tool result or raw page

By default (`"stage": "result"`), a rule rewrites the **tool result** Claude receives. For WebFetch, that's a summary: WebFetch downloads the page and has a small model extract what Claude asked for, and Claude only sees that extract.

With `"stage": "page"` (WebFetch only), the rule rewrites the **raw page** before the summarizing model reads it ("pre-extraction"):

```json
{ "name": "Rename on page", "match": { "tools": ["WebFetch"], "input": { "url": "example\\.com" }, "stage": "page" },
  "instructions": "Replace the product name X with Y everywhere." }
```

- **Reproducible:** a page is identified by its URL and content, not by the prompt Claude happened to write. Frozen experiment treatments are therefore reused across trials, unlike WebFetch summaries, which vary from run to run.
- **Indirect:** Claude sees the summarizer's interpretation of your edit, which is closer to how a real altered web page would reach it.
- **Session prompts too:** `diorama run --prompt "…" --prompt-stage page`, or the pre-extraction toggle in the app's New Session sheet.
- **In the audit trail:** page decisions appear as `WebFetch (page)` entries with the id `page:<tool_use_id>`.

### Rewrite models

Any Anthropic model id works (default `claude-haiku-5-5`). A rule's `model` overrides the profile default.

For **local models**, install [Ollama](https://ollama.com), pull a model, and use the `ollama:` prefix, for example `"model": "ollama:llama3.1"`. The Ollama server address is a setting:

```bash
diorama settings set ollamaURL http://127.0.0.1:11434
```

Local models never send content off your Mac and cost nothing, but they follow the edit format less reliably. Diorama retries once when an edit doesn't apply.

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
  Reuse needs byte-identical tool results. WebFetch summarizes pages with a model, so its output usually differs between trials, and each trial then gets its own rewrite. The comparison says so when that happens. Read, Bash, Grep and most MCP tools return deterministic output and are reused. For WebFetch, use **page-stage rules** to get reuse.
- `judge` (optional): `{"model": "claude-haiku-5-5"}` turns on the LLM judge. After the run, every successful trial is rated `adopted`, `not_adopted` or `unclear`, according to whether its final answer used the changed information. Controls are rated against the same changes, as a baseline. This costs one small call per trial on your rewrite key (or $0 with `ollama:` models).

`diorama experiment run exp.json` shows an estimate for Claude Code usage and the rewrite agent, then asks you to type `yes`. The control API also refuses to start a run without the estimate's confirmation token. Trials run in blocked random order: every variant once per round, shuffled by the seed.

**Results** (app → Experiments, or `diorama experiment compare <run>`):
- **Observed facts** are measured values: errors, turns, duration, tokens, Claude Code's reported cost, rewrite cost, rewrites applied, tool calls, distinct final outputs, and files changed.
- **Heuristic signals** are pattern matches, always labeled as heuristics:
  - *echoed rewritten content*: text introduced by a rewrite appears in the final answer
  - *flagged suspicion*: wording such as "looks altered" or "doesn't match"
  - *tried to verify*: re-fetching a rewritten URL, or curl/wget after a rewrite
  - *LLM judge: adopted* (when enabled): a model's verdict, with its rationale stored in each trial's evidence
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
| `ollamaURL` | Ollama server for `ollama:` models (default `http://127.0.0.1:11434`) |

## Menu bar

Diorama puts a small open-box icon in the menu bar. Its dot fills while a routed session is running. The panel lists running sessions; click one to open it in the app. The panel also has New Session, Open Diorama and Quit.

Closing the window doesn't quit Diorama: it keeps running in the menu bar, without a Dock icon, until you choose Quit (⌘Q). To get the old behavior back, turn off **Settings → App → Show Diorama in the menu bar**; closing the window then quits the app. Either way the daemon keeps running, and so do routed sessions, until you run `diorama daemon stop`.

## Updates

```bash
diorama update             # is there a newer release?
diorama update --download  # downloads the zip to ~/Downloads and verifies its checksum
```

The app checks once a day and shows a notice in the sidebar. Turn that off or check now under Settings → Updates. Diorama never replaces itself. To install an update:
1. Quit the app and run `diorama daemon stop`.
2. Replace `/Applications/Diorama.app` with the new copy.
3. Run `xattr -dr com.apple.quarantine /Applications/Diorama.app`.

The builds aren't notarized. For a private repository, the check uses the signed-in `gh` CLI.

## Data locations

Everything lives under `~/Library/Application Support/Diorama/`, or under `$DIORAMA_HOME` if set:
- `diorama.sqlite`
- `blobs/` (compressed, content-addressed captures)
- `runs/` (trial transcripts)
- `logs/dioramad.log`
- `daemon.json` (port and control token, mode 0600)

Delete the folder to reset Diorama. Remove the API key with `diorama key delete`.
