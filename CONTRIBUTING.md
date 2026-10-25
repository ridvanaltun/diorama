# Contributing to Diorama

Thanks for helping! Diorama is a macOS-only Swift project.

## Build and test

```bash
swift build                       # all targets
swift test                        # unit, integration and contract tests
./scripts/bundle-app.sh           # dist/Diorama.app (ad-hoc signed)
swift run DioramaApp              # run the app from source
```

- **Contract tests** (`Tests/DioramaContractTests`) run the real `claude` CLI against an in-process daemon and a scripted fake model. They use a temporary HOME and a dummy key, so they need no account and cost nothing. They're skipped when `claude` isn't installed; set `DIORAMA_CLAUDE=/path/to/claude` to choose a binary.
- **No test may call the real Anthropic API.** Use `MockUpstream`, `ScriptedModel` and `ScriptedRewriteProvider` from `Tests/DioramaTestSupport`.
- `./scripts/demo-screenshots.sh` regenerates the screenshots in `docs/assets` (needs `node` and `claude`; no account).

## Layout

| Path | What |
|---|---|
| `Sources/DioramaJSON` | Byte-offset JSON index and splice editor (never re-serializes proxied bodies) |
| `Sources/DioramaCore` | Shared models, the control-API types, diff, statistics, pricing |
| `Sources/DioramaStore` | SQLite (system libsqlite3), migrations, blob store |
| `Sources/DioramaEngine` | Rules, rewrite providers, the frozen-decision engine |
| `Sources/DioramaGateway` | SwiftNIO gateway, control API, daemon composition |
| `Sources/DioramaRunner` | Experiment runner, analysis, reports |
| `Sources/DioramaClient` | Typed control-API client shared by the CLI and the app |
| `Sources/dioramad`, `Sources/diorama`, `Sources/DioramaApp` | Executables |

## Ground rules

- Read `docs/architecture.md` and `docs/decisions.md` first. The core invariants are D9 (frozen decisions, replayed byte-for-byte) and D10 (splice, never re-serialize).
- Never log or persist credentials. Never use Claude Code's credentials for Diorama's own calls.
- Forward unknown headers and body fields unchanged; don't keep allow-lists of known fields.
- Record consequential design changes in `docs/decisions.md`.
- Keep the UI honest: experiment views must keep facts and heuristics separate and must not use causal language.
