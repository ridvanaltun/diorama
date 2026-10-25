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

## AI control (MCP)

Diorama includes a Model Context Protocol server, so Claude (or another MCP client) can inspect and steer it for you: "which tool results were rewritten in my last session?", "make a profile that marks v1 of the API as deprecated and connect ~/code/app", "run that experiment with 10 trials".

```bash
diorama mcp install --claude-code        # Claude Code, for your user
diorama mcp install --claude-desktop     # the Claude desktop app (restart it afterwards)
diorama mcp install --claude-code --read-only   # inspection tools only
diorama mcp uninstall --claude-code --claude-desktop
```

In the app, click **Connect to Claude…** at the bottom of the sidebar (also in the menu bar panel and Settings). It shows where Diorama is connected, and connects or disconnects each client in one click. The server is `diorama mcp serve`, speaking JSON-RPC over stdio, and any MCP client can launch it.

| Tools | What they do |
|---|---|
| `diorama_status`, `list_sessions`, `get_session`, `get_decision` | Daemon health; sessions; one session's decisions; one result's full audit record (original, rewrite, rules, attempts, what Claude did next) |
| `list_profiles`, `get_profile`, `list_rule_templates`, `create_profile`, `update_profile` | Read and write profiles. Every save is a new version. |
| `what_if_replay` | Re-run a session's tool results through other rules and compare. Free check by default; `rewrite` runs the agent (capped). A read-only server allows the check only. |
| `test_rules` | The rule playground: which rules match a past result or some text, and (with `rewrite`) what the agent would produce. Nothing is recorded. A read-only server allows the free check only. |
| `get_hook_status`, `install_hook`, `uninstall_hook` | Connect a project folder for hook mode (Claude desktop, IDEs) |
| `end_session` | Mark a session ended |
| `list_experiments`, `create_experiment`, `estimate_experiment_run`, `start_experiment_run`, `cancel_experiment_run`, `get_run_report` | The experiment workflow |

**Spending is gated.** `start_experiment_run` needs the confirmation token that `estimate_experiment_run` returns. The server tells the assistant to show you the estimate and wait for your approval. Your MCP client also asks before any tool call you haven't allowed. The server never sets the API key, changes settings, deletes profiles or stops the daemon. `--read-only` removes every tool that changes something.

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

### Sampling: change only some results

`"match": {"sample": 0.3}`, or **Apply to a sample** in the rule editor, makes a rule apply to only 30% of the tool results it matches. The rest pass through unchanged with the reason "not in the sample of “Rule” (30%)". This gives you changed and unchanged results side by side in one live session, for example to see whether Claude notices. Which results are in the sample is decided from each result's id, so a result is always in or always out: replays, the playground and what-if all agree with the session. Different rules sample independently. Sampling runs before a classifier, so results outside the sample cost nothing. Rule usage counts only results inside the sample.

### Content-aware rules (classifier)

Regexes only see words. A **classifier** lets a cheap model decide whether a rule applies, from a yes/no question about the content:

```json
{"name": "Raise prices", "match": {"tools": ["WebFetch"],
  "classifier": {"question": "Does this page state a product's price?"}},
 "instructions": "Increase every listed price by 20%. Change nothing else."}
```

In the editor, turn on **Only when a model answers yes to a question about the content**.

- **When it runs:** after a rule's other conditions match, once per tool result, with the profile's rewrite model by default (`"model"` overrides it). It runs before the rewrite and after any redaction, so it never sees redacted secrets.
- **Outcome:** "yes" lets the rule apply. "No", or a failed call, leaves the result unchanged; the decision says why, for example *Classifier "Does this page state a product's price?": no — it's a blog post*.
- **Audit and cost:** each question is recorded as an attempt (mode `classify`) and counts toward the budget. In the playground, the free check lists classifier rules as pending, and **Run rewrite** asks the question first. Redaction rules can't use a classifier.

### Input rules: change a tool call before it runs

With `"stage": "input"` (in the editor: **Applies to → Tool input, before the call**), a rule edits a tool call's *arguments* before the tool runs. For example, it can point a WebFetch at a different URL, steer a WebSearch query, or change a Read path. The rewrite agent edits the input as JSON: it can change values, but it can't add or remove parameters.

```json
{"name": "Docs → staging", "match": {"tools": ["WebFetch"], "stage": "input"},
 "instructions": "If the URL is on docs.example.com, point it at staging-docs.example.com instead."}
```

**You approve every change.** When Diorama changes an input, Claude Code shows a permission prompt with the changed call and the reason ("Diorama changed this call's input: …"). In non-interactive runs (`claude -p`) nobody can approve it, so the call is denied and Claude sees that reason. Input rules work in hook mode and in `diorama run` sessions, which get a `PreToolUse` hook added automatically through their `--settings`. They don't apply in experiment trials. Projects that installed the hook before input rules existed need `diorama hook install` again; `diorama hook status` says so. Changed inputs show with an **input** badge in the timeline.

### Redaction rules (no AI)

A rule with `redact` instead of instructions masks matches locally before Claude sees the result. It's deterministic, costs nothing and makes no API call. In the editor, set **Action → Redact**.

```json
{"name": "Redact secrets", "match": {"tools": ["*"], "includeErrors": true},
 "redact": {"presets": ["secrets", "emails", "ipAddresses"], "patterns": ["ACME-\\d{4,}"]}}
```

- **Presets:** `secrets` covers Anthropic, OpenAI, AWS, GitHub, Slack, Stripe and Google keys, JWTs, bearer tokens and private-key blocks. It matches known formats only, so ordinary text stays as it is. `emails` and `ipAddresses` are opt-in. `patterns` are your own regexes.
- **Output:** each match becomes `[REDACTED:kind]`, and the decision's reason says what was masked, for example "redacted 2 matches (anthropic-key ×1, private-key ×1)".
- **Order:** redaction runs before AI rewrites, so the rewrite agent never sees the secrets either.
- **It always applies:** it still applies when the budget is used up or an AI rewrite fails.
- **Template:** "Privacy: redact secrets" (`diorama profiles templates`). The playground previews redaction for free.

This is a convenience, not a guarantee. Formats it doesn't know aren't masked.

### Testing rules before you use them

The rule playground tries rules on content without starting a session, and records nothing.

- In the app, click **Test Rules…** in the profile editor; it uses your current draft, including unsaved changes. Or click the test-tube button on any tool result's detail to try rules on that result.
- Pick a past tool result (its original, before any rewrite) or paste text with the tool it comes from and, optionally, its input JSON, such as `{"url": "https://docs.example.com"}`.
- The playground shows which rules match, and for the others the first condition that failed, for example *input "url" (https://example.org) doesn't match /docs\./*. This check is free and updates as you edit.
- **Run rewrite** calls the rewrite agent once, as a session would. It shows the diff, the agent's explanation and edits, the model, the latency and the cost.

```bash
diorama profiles test "Docs steer" --decision toolu_01abc
diorama profiles test "Docs steer" --text "Version 1 is current" --input '{"url":"https://docs.example.com"}' --rewrite
diorama profiles test --file draft.json --text-file page.txt
```

### What-if replay: compare rules on a past session

**What if…** in a session's header re-runs that session's recorded tool results (their originals) through other rules: another profile, a specific earlier or later version, your session prompt, or an unsaved draft (CLI/MCP). It compares the outcome with what the session actually did.

- The check is free and immediate. It shows which results the new rules would send to the rewrite agent, which would **no longer be rewritten**, and the estimated cost of a full run.
- **Run N rewrites** calls the agent for each matching result: at most 25 by default, at most 60, four at a time. Each result is then marked **newly rewritten**, **rewritten differently**, **same rewrite** or **no longer rewritten**. Expanding a result shows a diff from what Claude saw to what it would see.
- Nothing is recorded, and the session's audit trail stays as it was. **Copy as Markdown** puts a summary on the clipboard.
- This doesn't run Claude Code again, so it can't tell you how Claude would have *responded*. Use an experiment for that.

```bash
diorama session whatif ses_123 --profile "Docs steer"          # the profile's current version (free check)
diorama session whatif ses_123 --version pv_abc --rewrite      # a specific version, with rewrites
diorama session whatif ses_123 --file draft.json --rewrite --max 10
```

### Review mode: approve rewrites before Claude sees them

Turn on **Review rewrites before Claude sees them** in a profile's defaults (`"defaults": {"review": true, "reviewTimeoutSeconds": 60}`) to hold every AI rewrite until you answer. Claude waits meanwhile. Diorama opens **Review rewrites** with a word diff of what Claude would see, and shows a banner, a menu bar row and, while it's in the background, a notification.

- **Approve** sends the rewrite. **Reject** sends the original, with any redaction still applied.
- If you don't answer within the wait time (15–120 s, default 60), Claude gets the original. In hook mode a review also ends 150 s after the tool result arrived, before Claude Code's 180 s hook limit.
- `diorama review` lists what's waiting, and `diorama review approve|reject <id>` answers. The MCP tool `list_pending_reviews` can only list: AI clients can't approve rewrites.
- Not used for experiment trials (nobody is there to answer) or input rules (Claude Code already asks you about those).

The decision records the outcome: "not rewritten: rewrite rejected in review" or "no review in time". The rewrite agent's attempt and cost are kept either way.

### Sharing profiles

**Export…** in the profile editor saves the profile's saved version as a `.diorama-profile.json` file. **Import Profile…** in the Profiles toolbar, or dropping `.json` files on the profile list, adds each one as a new profile at version 1. If the name is taken, a number is appended, for example "Docs steer (2)". The files are plain JSON in the same format as `diorama profiles export` and `diorama profiles create --file`, so they work in git, in pull requests or on another Mac. They hold only rules and defaults, never keys.

### Comparing profile versions

Every save makes a new version. In the editor's **Version history**, **Compare with vN** shows what changed from an older version to the current one. While you have unsaved edits, **Show Changes…** compares them with the saved version. Rules are matched by id, so each one shows as added, removed, changed (each field, old → new, with a word diff for instructions) or moved. Changes to the name, description and defaults are listed too.

```bash
diorama profiles diff "Docs steer"                 # the previous version vs the current one
diorama profiles diff "Docs steer" --from 1 --to 3 --json
```

The MCP tool `compare_profile_versions` returns the same list.

### Rule usage: which rules fire, and what they cost

The **Usage** section of the profile editor lists each rule with how many tool results it matched, how many of those were rewritten, left unchanged or failed, classifier answers, the sessions involved and the rewrite-agent cost. Choose 7, 30 or 90 days, or all time. Each rule's row in the rule list also shows its count, and rules that matched nothing are marked **never matched**, so you can fix or remove them. Counts cover every version of the profile, and rules removed in later versions are listed as **older version**. A tool result that several rules matched counts, with its cost, for each of them. Experiment trials are left out.

```bash
diorama profiles stats "Docs steer"              # last 30 days
diorama profiles stats "Docs steer" --days 0 --trials --json
```

The MCP tool `get_rule_stats` returns the same summary.

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

### Notes and tags

Label sessions so you can find them later. In the session header, type in **Add tag** and press Return, or hover over a tag and click × to remove it. **Add Notes** opens a notes editor, and double-clicking the session name renames it. Tags appear in the session list, and the **Tag** menu above the list filters by one. Tags differing only in case are treated as the same tag. Notes and tags are included in session reports, in data exports (`session_tags`) and in MCP `get_session`.

```bash
diorama session tag ses_abc --add baseline --add docs-v2 --remove draft
diorama session note ses_abc "Baseline: steering off"
diorama session rename ses_abc "Docs v2 baseline"
diorama sessions --tag baseline
```

The MCP tool `annotate_session` sets a session's name, notes or tags, and `list_sessions` takes a `tag` filter.

### Session reports

**Export** in a session's header saves the session's audit trail as **Markdown** or **self-contained HTML**, or opens the HTML in your browser. The report has:
- the configuration (mode, folder, steering with its profile version);
- a summary;
- notices;
- each change Diorama made: word-level diff, reason, rules, rewrite-agent attempts and cost, and what Claude did next;
- a table of the results it left unchanged.

```bash
diorama session report ses_123 --format html --output report.html
```

Through MCP the tool is `get_session_report`. Tool results can contain private data (file contents, pages, command output), so review a report before sharing it. The HTML escapes all captured content.

### Exporting data for analysis

**Export Data…** in the Sessions toolbar, or `diorama export`, writes one row per decided tool result as CSV (for spreadsheets) or JSON Lines (for scripts and pandas). Each row has the session, its kind and connection, the profile and version, the tool and its input, the stage, outcome and reason, the matching rules, rewrite attempts, cost, and text sizes. Filter by time, profile, session, trials or rewritten only. The original and rewritten texts are included only if you ask, because they're what your tools returned and can contain private content. Cells that a spreadsheet would run as formulas get a leading `'`.

```bash
diorama export --output decisions.csv
diorama export --format jsonl --days 7 --profile "Docs steer" --rewritten-only --texts --output week.jsonl
```

### Search

The search field on the Sessions screen searches every session, with the best matches first:
- tool results (the originals and Diorama's rewrites);
- tool inputs such as URLs, queries and file paths;
- rewrite reasons;
- Claude's replies (gateway sessions).

All words must match; the last word also matches as a prefix, so results update as you type. Matched words are highlighted. **Only rewritten** narrows the list to results Diorama changed. Clicking a result opens its session with that tool result selected.

```bash
diorama search deprecated api
diorama search example.com --rewritten --session ses_123
```

Through MCP the tool is `search`. The index lives in the same local database. It fills in as sessions run, and on first start after an update it indexes earlier sessions too.

### Anomalies

| Event | Meaning |
|---|---|
| `client-modified` | Claude Code sent different content for a tool result that was already decided (for example, it cleared an old result). Diorama forwards Claude Code's version. |
| `rewrite failed` | The rewrite agent failed, timed out or refused, or there's no key. The original was forwarded and the session is flagged. |
| `replay-integrity` | A stored rewrite could not be loaded. This should not happen. Please report it. |

## Experiments

**From a session:** **Experiment…** in a session's header (or `diorama session experiment <id>`) prefills an experiment from what you just did. The task is the session's first prompt, and the project is its folder. Allowed tools are the tools it used, and the model is the one it ran on. There are two variants: an unmodified control, and the session's steering, with its profile pinned to the exact version the session used (a `pv_…` id) or its session prompt. Notes explain anything inferred or missing, for example when raw capture was off and the task wasn't recorded. You review and edit the form, create the experiment, then estimate and run it as usual. Through MCP the tool is `draft_experiment_from_session`.

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

### Reading the results: differences vs the control

Each run shows **Differences vs control**: for every steered variant and metric, the difference from the control (variant − control) with a 95% interval.

- **Shares** (error rate, heuristic signals, judge verdicts) use Newcombe's score interval and are shown in percentage points.
- **Per-trial means** (turns, duration, tokens, Claude Code cost, calls per tool) use Welch's t-interval, which doesn't assume equal variances.
- An interval that **excludes zero** is highlighted. A chance difference rarely does that, but each metric is checked on its own, so with many metrics a few can by chance.
- Heuristic metrics are marked as such. Like everything else, these are associations under the run's conditions, not proof of cause.

**Pooling runs:** with two or more completed runs, the experiment's **All runs (pooled)** entry combines their trials into one comparison and report (`diorama experiment compare <experiment-id> --pooled`, `report --pooled`, or the MCP `get_run_report` with `experiment_id`). Runs on different days can differ (web pages, Claude Code versions, and each run's own frozen treatments), and the report says so.

**Two trials side by side:** **Compare two trials…** shows turns, duration, cost, rewrites, tool calls and the judge verdict for both, plus a diff of their final answers.

## Settings

`diorama settings show` displays the current values. Change one with `diorama settings set <key> <value>`, where the key is one of:

| Key | Purpose |
|---|---|
| `defaultModel` | Rewrite model used when a session has no profile |
| `retentionDays` | How long raw request/response capture is kept |
| `captureRawBodies` | `true` or `false` |
| `claudePath` | Path to the `claude` executable |
| `ollamaURL` | Ollama server for `ollama:` models (default `http://127.0.0.1:11434`) |
| `dailyBudgetUSD` | Daily cap on rewrite-agent spending, for example `2`; `none` removes it. See "Budget guard". |

### Budget guard

Two optional daily caps limit rewrite-agent spending:

- **Everything:** `diorama settings set dailyBudgetUSD 2`, or **Settings → Daily rewrite budget**. This covers rewrites in interactive sessions (gateway and hook mode) plus paid playground and what-if runs.
- **Per profile:** `"defaults": {"dailyBudgetUSD": 0.5}` in the profile, or **Daily budget for this profile** in the editor. It covers that profile across all its versions.

The day is your local calendar day. Each call is checked before it's made, so one call can go slightly over a cap. When a cap is used up, matching tool results **pass through unchanged** with the reason "not rewritten: … budget is used up". The session is flagged `budget-reached` and shows a warning. The playground and what-if refuse paid runs, and a what-if run is refused up front if its estimate would go over what's left. Free checks keep working. Experiment runs are exempt, because they run against the cost estimate you approved. `diorama spend`, Settings and the menu bar show today's total. The MCP server can read the budget but can't change it.

### Pausing steering

To see what Claude does with the real results, pause steering instead of ending the session or restarting Claude:

- **One session:** **Pause** in the session header, `diorama session pause <id>` (and `resume`), or the MCP tool `set_steering_paused` with a `session_id`.
- **Everywhere:** **Pause All Steering** in the menu bar, **Settings → Steering**, `diorama pause` / `diorama resume`, or `set_steering_paused` without a session.

While paused, tool results reach Claude unchanged with the reason "not rewritten: steering is paused …", and input rules don't change tool calls. Redaction rules keep running, so secrets stay hidden. Results already decided keep their decision (D9), so pausing affects new tool results only. Experiment runs aren't affected. Paused sessions show a **paused** badge; the pause survives daemon restarts.

## Notifications

While Diorama is in the background, it notifies you when:
- **an experiment run finishes** (or is cancelled);
- **the rewrite budget is used up** (at most once a day);
- **rewrites start failing** in a session (at most once per session every 10 minutes).

Clicking a notification opens the run or the session. Choose which ones you want in **Settings → Notifications**, where **Send a test notification** checks that macOS shows them. The first notification asks for permission. If you said no, turn Diorama on in System Settings → Notifications.

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
