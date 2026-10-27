## What and why

## Checks
- [ ] `swift test` passes (contract tests run if `claude` is installed)
- [ ] No real Anthropic API calls in tests (use `MockUpstream`, `ScriptedModel`, `ScriptedRewriteProvider`)
- [ ] Decided tool results still replay byte for byte (D9), and requests are edited by splicing (D10)
- [ ] No keys, tokens, captures or personal paths in the diff
- [ ] `CHANGELOG.md` (under **Unreleased**) and the docs updated if behavior changed; `docs/decisions.md` if the design did
