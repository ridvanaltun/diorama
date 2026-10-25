# Proof-of-concept findings (2026-10-25)

**Setup:** a throwaway Node gateway and a scripted mock upstream (in [`spikes/gateway-poc/`](../spikes/gateway-poc/)), the Claude Code CLI **v2.1.296**, the default model `claude-opus-5-5`, and a claude.ai Max sign-in. The test task was: "WebFetch example.com and example.org, report the headings."

The stand-in "rewrite" was deterministic: it replaced `Example Domain` with `Morph Test Domain` and added a visible marker line.

## Results

| # | Question | Result | Evidence |
|---|---|---|---|
| 1 | Can a gateway at `ANTHROPIC_BASE_URL` see and rewrite `tool_result` blocks? | ✅ Yes. WebFetch results arrive as `{type:"tool_result", tool_use_id, content:"<string>"}`, and the tool name is found through the matching `tool_use` in the previous assistant message. | Mock run: the model echoed the rewritten content |
| 2 | Does the real API accept rewritten history? | ✅ Yes. Every request returned 200, including requests with thinking blocks in the history. | 4 real runs |
| 3 | Does stable replay keep the prompt cache warm? | ✅ Yes. In sequential runs the replay turns read about 37,700 tokens from cache and wrote only 130–240 new ones. | `logs-stable`: `read=37745 write=242` on the replay turn |
| 4 | Is the cache miss on the first turn after tool results caused by Diorama? | ❌ No. The control run with no rewriting misses on the same turn. Claude Code changes its `tools` list and an environment system message between the first and second main request. | Control diff: `tools equal: False`, `msg 1 equal: False` |
| 5 | What happens if a rewrite isn't replayed consistently? | ⚠️ **No error. It silently corrupts the experiment.** The model saw the original on the replay turn and reported the first page's real heading next to the second page's rewritten one. | `logs-unstable`: `skipped-replay`, still a 200 |
| 6 | Does Claude notice crude rewrites? | ⚠️ Yes, every time. It quoted the marker, compared the result with its prior knowledge, and in one run tried to `curl` the page to verify it. That attempt wasn't approved. | Run transcripts |
| 7 | Are request bodies compressed? | Not when sent to a custom base URL (`content-encoding` absent). The gateway still handles compression. | Gateway audit logs |
| 8 | Is session identity available? | ✅ `x-claude-code-session-id` appears on every request. `x-claude-code-request-class` (`main`, `auxiliary`, …) appears with `CLAUDE_CODE_GATEWAY_HINT_HEADERS=1`. | Gateway audit logs |
| 9 | Does Claude Code keep a path in the base URL? | ✅ `ANTHROPIC_BASE_URL=http://127.0.0.1:8799/s/tok123` produced `POST /s/tok123/v1/messages?beta=true` | Path-logging server |
| 10 | How does Claude Code treat a gateway 401? | It retried 9 times. Rejections must carry `x-should-retry: false`. | Path-logging server |
| 11 | Is WebFetch's extraction call visible? | ✅ It's a separate `auxiliary` request whose user message contains `Web page content: --- … ---`. This makes a future "pre-extraction mode" possible without a certificate authority. | Captured request 002 |
| 12 | What other structure is in the request? | Mid-conversation `role:"system"` messages, `cache_control` on the last system message, and top-level `context_management`, `output_config`, `thinking:{type:adaptive, display:omitted}`. Rewrites must leave all of this untouched, which is why requests are edited by byte splicing (decision D10). | Captured requests |

## Cost
Each run used about **$0.62 of notional usage**, most of it writing Claude Code's roughly 35,000-token system prompt into the cache. That cost is fixed per run, whatever the task size, so experiment estimates must include it.

## Practical notes
- The standalone CLI needs `USER` and `LOGNAME` in its environment to reach the macOS Keychain. Without them it reports "Not logged in" even when signed in. The experiment runner must keep these when it builds a trial's environment.
- macOS has no `timeout` command, so the runner implements its own timeouts.

## Verified later by automated contract tests (real Claude Code CLI 2.1.296, mock model)
- **`--settings '{"env":…}'` takes precedence over `env.ANTHROPIC_BASE_URL` in `~/.claude/settings.json`.** Diorama doesn't modify that file.
- **Tool-result shapes:**
  - Read on a text file, Bash and Grep return a **string**.
  - Read on an image returns **blocks** containing an `image` block.
  - A refused tool call returns an `is_error` result.
- **Base-URL path prefix and hint headers:** both work as designed.
- **Network lockdown:** `--settings` `permissions.deny` refuses `Bash(curl:*)`.

## Still unverified (needs a live session or account)
- WebSearch and MCP result shapes through a real model.
- Whether Claude Code clears or edits old tool results itself in very long sessions. Diorama detects this case (`client-modified`) either way.
- The preserved-thinking check on an account created on or after 2026-08-31, where it is enforced, with stable replay.
