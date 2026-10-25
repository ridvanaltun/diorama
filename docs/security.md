# Security and privacy

## What leaves your Mac

| Traffic | Destination | Credentials |
|---|---|---|
| Claude Code's own API requests (routed sessions) | `api.anthropic.com`, Claude Code's normal destination | Claude Code's own (OAuth or API key), forwarded unchanged and never stored |
| Rewrite-agent requests (only when a rule matches) | `api.anthropic.com` | **Your Diorama API key** from the Keychain |

Diorama has no telemetry, analytics or update checks. Captured data stays local.

A rewrite request contains the matching tool result, the tool's name and input, and the rule instructions. If a rule opts in, it also contains the session's first user message. Don't write rules that send content you're not willing to process with your API key.

## Local attack surface

- **Loopback only.** The gateway and control API bind to `127.0.0.1` and are never exposed on the network.
- **Session tokens.** Each routed session gets a random 128-bit token in its URL path. The database stores only its SHA-256 hash. Unknown tokens get `403` with `x-should-retry: false`. The token is visible in the Claude Code process's arguments and environment to processes running as your user.
- **Control API.** Requests need a bearer token from `daemon.json`, a mode-0600 file in a mode-0700 folder, compared in constant time. Any process running as your user can read that file. This is equivalent to the protection of a Unix socket owned by your user.
- **Browser protection.** Requests with an `Origin` header, or a `Host` other than `127.0.0.1`, `localhost` or `::1`, are rejected. This blocks DNS-rebinding and cross-site requests from web pages.
- **File permissions.** The daemon runs with `umask 077`. Its database, write-ahead log, blobs, logs and run folders are readable only by your user.
- **Credentials.** `Authorization`, `x-api-key`, `cookie` and `set-cookie` headers are redacted before anything is written. The rewrite key lives only in the Keychain (or in `DIORAMA_ANTHROPIC_API_KEY`, if you choose that), and the app and CLI show only its last four characters.
- **Limits.** Request bodies over 128 MB are rejected with `413`. The JSON scanner is iterative, so deeply nested input can't exhaust the stack.

## Captured data is sensitive

Raw capture, on by default, stores full request and response bodies. These include your prompts, your code, files Claude read, and Claude Code's system prompt. They are kept for `retentionDays` (14 by default) and then deleted. Decision records (originals and rewrites) are kept until you delete the data directory. To stop raw capture, run `diorama settings set captureRawBodies false`.

## Experiments run code

Trials run `claude -p` with the permissions you configure (`allowedTools`, `permissionMode`). They run in throwaway clones of your project, but anything Claude does through Bash or MCP has the same reach as a normal Claude Code run. Use the narrowest tool permissions that work, and avoid `bypassPermissions` unless the project is disposable.

## Rewritten tool results

A steered session deliberately gives Claude Code altered information, and Claude may write code or draw conclusions based on it. Use steered sessions for experiments, not for work you will ship. `--lockdown network` blocks shell network tools, so Claude can't easily bypass rewrites with `curl`. It's a convenience for experiments, not a security boundary.

## Reporting vulnerabilities

Please report security issues privately through GitHub Security Advisories on the repository. Don't open public issues for them.
