# Diorama: notes for coding agents

- Build and test with `swift build` and `swift test`; build the app bundle with `./scripts/bundle-app.sh`. Contract tests need the `claude` CLI but no account.
- The product and design live in `docs/`. Read `docs/architecture.md` and `docs/decisions.md` (D1–D36) before changing the gateway, engine or storage. Progress is tracked in `docs/PROGRESS.md`.
- Core invariant: once a `tool_use_id` is decided, every later request carries exactly the same bytes (D9). Requests are edited by byte splicing, never by re-serializing them (D10).
- Never log or persist `Authorization`, `x-api-key` or cookies. Never use Claude Code's credentials for Diorama's own calls.
- Tests must never call the real Anthropic API. Use `Tests/DioramaTestSupport` (MockUpstream, ScriptedModel) and `ScriptedRewriteProvider`.
- On case-insensitive volumes, never put `diorama` next to `Diorama`: the CLI and daemon live in `Contents/Helpers`.
- `spikes/` holds throwaway reference code. Don't build on it.
