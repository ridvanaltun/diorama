# Troubleshooting

Start with `diorama doctor`. It checks the daemon, Claude Code, the rewrite key, the database, storage, and user settings that could interfere. It also flags configuration that quietly changes what Diorama does:
- steering paused everywhere;
- the daily budget nearly or fully used;
- folder defaults pointing at missing profiles or folders;
- failing rule tests;
- hook installs from before input rules existed;
- profiles in shadow or review mode.

The same checks appear in **Settings → Diagnostics**. The daemon's log is in `~/Library/Application Support/Diorama/logs/dioramad.log`, and `diorama daemon logs` shows the end of it.

| Symptom | Cause / fix |
|---|---|
| `The Diorama daemon did not start` | Read the log. The usual cause is another daemon for the same data folder ("already running"). Run `diorama daemon stop` and retry. |
| Ports 47821–47841 are all in use | The daemon tries 21 ports. Free one, or set `DIORAMA_HOME` to separate installs. Each install records its port in `daemon.json`. |
| Claude Code reports `Unknown or expired Diorama session` (403) | The session token isn't in this data folder, for example because the data was reset. Start a new session with `diorama run`. |
| Every matching tool result is `failed: No Anthropic API key…` | Run `diorama key set`. Until then results pass through unchanged and the session is flagged. |
| Rewrites fail with `HTTP 401` | The rewrite key is invalid or revoked. Set it again. Claude Code's own credentials are unaffected. |
| Rewrites fail with `refused (category …)` | The rewrite model declined the instructions. Rephrase the rule, or choose another model for it. |
| `invalid: find text was not found verbatim` | The agent's edit didn't match the original text. Diorama has already retried once. Make the instructions more specific, or choose a stronger model with `model` on the rule. |
| Hook mode: a Claude desktop session doesn't appear in Diorama | Hooks load when a session starts: open a **new** Code session in that folder. Check `diorama hook status` or `diorama hook list` (they warn if the installed path no longer exists, for example after moving the app) and `~/Library/Application Support/Diorama/logs/hook.log`. |
| Hook mode: a tool result is `unchanged` with "can't read this … output shape" | Hook mode only rewrites known text fields (see the user guide). Use `diorama run` for full coverage. |
| MCP: Claude doesn't list Diorama's tools | Claude Code: run `claude mcp list` and check `diorama`; re-run `diorama mcp install --claude-code` if the app moved. Claude desktop: quit and reopen it after `--claude-desktop`. The server starts the daemon itself when needed. |
| Results are `unchanged` with "not rewritten: … budget is used up" | A daily cap was reached (`diorama spend`). Raise it with `diorama settings set dailyBudgetUSD …` or in the profile's defaults, or wait until midnight. |
| `client-modified` anomalies | Claude Code changed an older tool result itself (for example, cleared it to save context). Expected in long sessions; Diorama forwards Claude Code's version. |
| Claude Code prints *"We're changing auto mode to no longer charge for classifier requests… this session isn't eligible because your requests go through 127.0.0.1:…"* | This appears in auto mode, mainly for API-key users, whenever a custom base URL is set. Diorama forwards headers, body fields (including `safeguards`), responses and tool-use IDs unchanged, as Anthropic's gateway guide requires. Per Claude Code's docs, Pro, Max and Team plans don't see the notice. To silence it, set `CLAUDE_CODE_AUTO_MODE_SERVER=0` in the session. |
| `/fast` reports fast mode unavailable in a routed session | Claude Code's fast-mode check goes directly to `api.anthropic.com` and doesn't support custom base URLs. Unrelated to Diorama's routing. |
| Remote Control is unavailable in a routed session | Claude Code disables Remote Control whenever `ANTHROPIC_BASE_URL` points at a non-Anthropic host. Expected. |
| A session resumed with plain `claude --resume` behaves differently | Outside Diorama, Claude sees the **original** tool results. Accounts subject to preserved-thinking enforcement may also get history-mismatch errors, or lose their thinking blocks. Resume routed sessions through Diorama: `diorama run -- --resume <id>`. |
| An experiment trial `failed: claude exited … without a result` | Look in `runs/<run>/<trial>/stderr.txt`. Common causes are a missing permission for a tool the task needs (add it to `allowedTools`), or Claude Code not signed in for headless use. |
| Trials are `invalid` | A rewrite failed during the trial, so it didn't receive the treatment. Fix the rewrite problem and run again. |
| The app shows "Daemon unavailable" | Click Retry. The app starts `Contents/Helpers/dioramad` itself. If you moved the app, run `diorama daemon stop` once so a daemon from the old location doesn't linger. |
| Disk usage grows | Lower `retentionDays`, turn off `captureRawBodies`, or click "Apply retention now" in the app (`POST /api/v1/maintenance/retention`). |
| A database integrity problem is detected | Diorama moves the damaged file to `diorama.corrupt-<time>.sqlite`, starts a new database, and reports it in `doctor`. |
| A Keychain prompt appears after updating Diorama | macOS asks again when the binary reading the key changes. With an ad-hoc signed build this happens on every rebuild. Choose "Always Allow", or use `DIORAMA_ANTHROPIC_API_KEY`. |
