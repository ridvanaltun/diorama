# Gateway proof of concept (throwaway)

This is the Node code used on 2026-10-25 to check that the gateway approach works. Results are in [docs/poc-findings.md](../../docs/poc-findings.md). It is **not** product code, and Diorama itself is Swift.

- `gateway.mjs`: a pass-through gateway that rewrites WebFetch/WebSearch `tool_result` blocks and replays them from a cache keyed by `tool_use_id`. The mode is set with `MODE=stable|unstable`.
- `mock-upstream.mjs`: a scripted fake Messages API. It lets you inspect Claude Code's requests without an account.
- `usage.py`: summarizes cache usage per request from a log directory.

## Mock run (no account needed)
```bash
PORT=8788 node mock-upstream.mjs &
PORT=8787 UPSTREAM=http://127.0.0.1:8788 LOG_DIR=logs-mock node gateway.mjs &
ANTHROPIC_BASE_URL=http://127.0.0.1:8787 ANTHROPIC_API_KEY=sk-ant-dummy \
  claude -p "Fetch example.com and example.org and compare their headings." \
  --allowedTools WebFetch --settings '{"skipWebFetchPreflight":true}'
```

The logs contain full request bodies, including your environment and system prompt. Keep them out of git.
