# OpenCode proof of concept (throwaway)

Node code used on 2026-11-07 to check how OpenCode 2.1.4 talks to an Anthropic endpoint, before adding `diorama run --agent opencode` (see D47 in [docs/decisions.md](../../docs/decisions.md)). It is **not** product code.

- `mock-upstream.mjs`: a scripted fake Messages API. With OpenCode's `read` tool it reads `TARGET_FILE`, then answers with every `tool_result` it received ("what the model saw"). With `SHELL_COMMAND` set it runs that in OpenCode's `shell` tool instead. Requests are logged to `LOG_DIR`, with credentials redacted.

Findings:
- `providers.anthropic.settings.baseURL = http://host/s/<token>/v1` sends requests to `/s/<token>/v1/messages?beta=true`. Bodies are ordinary Messages API requests: lowercase tool names (`read`, `shell`, `webfetch`, `websearch`, …), string `tool_result` content with `cache_control`.
- Headers include `x-opencode-session-id` and `user-agent: opencode/…`. A title request with no tools follows the first turn.
- `OPENCODE_CONFIG_CONTENT` wins over a project's `.opencode/opencode.json`.
- `--standalone` is required: the shared background service otherwise makes the model calls. It goes after `run`/`mini`.
- A server plugin's `tool.execute.after` hook can replace `event.result.content`, and the model sees the change (`event.id` is the `tool_use_id`).
- `opencode run --format json` prints `step_start`, `tool_use`, `text`, `step_finish` and `error` events, one JSON object per line, each with a `part.messageID`. It doesn't always print a message's `step_start` or the last `step_finish`, and retries after a connection error repeat the same message id. A persistent 4xx prints an `error` event and exits 1. The task can come on stdin.
- Credentials live in the data folder (`opencode.db`); an empty `XDG_CONFIG_HOME` only drops configuration. `OPENCODE_DISABLE_MODELS_FETCH=1` works offline. Denied tools are removed from the model's tool list.
- Concurrent `--standalone` starts on a fresh data folder race its migrations; later ones can fail with "database is locked" (in the server log, `XDG_DATA_HOME/opencode/log/opencode.log`). `opencode session list --standalone` creates the database without touching the shared service.

## Mock run (no account needed)
Isolate OpenCode's data with `XDG_*` variables so your own sessions and service aren't touched:

```bash
PORT=8788 LOG_DIR=logs TARGET_FILE=$PWD/facts.txt node mock-upstream.mjs &
XDG_CONFIG_HOME=/tmp/oc/config XDG_DATA_HOME=/tmp/oc/data XDG_STATE_HOME=/tmp/oc/state XDG_CACHE_HOME=/tmp/oc/cache \
ANTHROPIC_API_KEY=sk-ant-dummy \
OPENCODE_CONFIG_CONTENT='{"providers":{"anthropic":{"settings":{"baseURL":"http://127.0.0.1:8788/s/TOKEN/v1"}}}}' \
  opencode run --standalone --auto -m anthropic/claude-sonnet-4-5 "Read facts.txt"
```

The logs contain full request bodies, including OpenCode's system prompt. Keep them out of git.
