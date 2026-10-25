<p align="center"><img src="docs/assets/icon.png" width="128" alt="Diorama icon"></p>

# Diorama

> Stage what your coding agent sees. Measure what it does.

Diorama is an open-source macOS tool for **studying how Claude Code reacts to the information it receives**. Sessions you start through Diorama run behind a local gateway. A separate rewrite agent, guided by your own rules, can change selected **tool results** (web pages, search results, file reads, command output, MCP results) before the model sees them. Every change is recorded with:
- the original and the rewritten content, with a diff
- the rule version and prompt that applied
- the rewrite agent's explanation
- what Claude did next

Diorama also runs **A/B experiments**: repeated headless Claude Code trials in isolated copies of a project, comparing an unmodified control against steered variants. Results show observed facts separately from heuristic interpretations.

Diorama is a research and experimentation tool. It only affects Claude Code sessions you start through it, and it never changes your Claude Code settings files. It is an independent project, not affiliated with or endorsed by Anthropic.

![Session timeline](docs/assets/screenshot-sessions.png)

## How it works

```
diorama run ──▶ claude (your terminal)
                  │ ANTHROPIC_BASE_URL=http://127.0.0.1:47821/s/<session-token>
                  ▼
             dioramad  (local daemon: gateway · rewrite engine · SQLite · experiment runner)
                  │ forwards every request unchanged, except tool_result content your rules rewrite
                  ▼
           api.anthropic.com   (with Claude Code's own credentials, passed through)
```

- **Precise:** Diorama edits outgoing requests by splicing bytes. Only the text of matching `tool_result` blocks changes, and every other byte is forwarded exactly. Responses stream back unbuffered.
- **Reproducible:** the first decision for each tool result is frozen and replayed byte-for-byte on every later turn. The model's history stays consistent and the prompt cache stays warm.
- **Separate credentials:** the rewrite agent uses **your own Anthropic API key**, stored in the macOS Keychain, behind a pluggable provider interface. It never reuses Claude Code's credentials.

## Requirements

- macOS 15 or later (Apple Silicon or Intel)
- [Claude Code](https://code.claude.com) CLI 2.1 or later (tested with 2.1.296)
- An Anthropic API key for the rewrite agent (only needed when rules are active)
- To build from source: Xcode 16 or later / Swift 6

## Install

**From a release:** download `Diorama-<version>.zip`, unzip it, move `Diorama.app` to `/Applications`, and link the CLI:

```bash
sudo ln -sf /Applications/Diorama.app/Contents/Helpers/diorama /usr/local/bin/diorama
```

**From source:**

```bash
git clone https://github.com/<owner>/diorama.git && cd diorama
./scripts/bundle-app.sh          # builds dist/Diorama.app (ad-hoc signed)
```

## Quick start

```bash
diorama key set                                   # store the rewrite agent's API key in the Keychain
diorama doctor                                    # check Claude Code, key, daemon and database
diorama profiles templates                        # list starting points
diorama profiles create --template 1 --name web   # create a profile (versioned global rules)

cd ~/code/my-project
diorama run --profile web                         # Claude Code, routed through Diorama
diorama run --prompt "Say the library is deprecated" --prompt-tools WebFetch,WebSearch
```

Open **Diorama.app** to watch the live timeline. You can also inspect sessions from the terminal:

```bash
diorama sessions
diorama session show <session-id>
diorama session decision <tool_use_id>            # original, rewrite, diff, rules, explanation, follow-up
```

### Experiments

```bash
diorama experiment init > exp.json                # edit task, project, variants, trials
diorama experiment run exp.json                   # shows a cost estimate and asks before starting
diorama experiment report <run-id> --format md --output report.md
```

Each trial runs `claude -p` in an APFS clone of your project, so your files are never touched. Variants are interleaved by blocked randomization, and each trial records a manifest: Claude Code version, arguments, rule versions, prompt versions, project snapshot, seed, and order. By default, identical tool results reuse one rewrite across trials ("frozen treatment"), so you measure Claude's response to a single treatment.

## Documentation

- [User guide](docs/user-guide.md): sessions, rules, prompts, experiments, the app
- [Security and privacy](docs/security.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Architecture](docs/architecture.md) · [Decisions](docs/decisions.md) · [Requirements](docs/requirements.md)
- [Proof of concept and compatibility findings](docs/poc-findings.md)
- [Release process](docs/release.md) · [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)

## Responsible use

Diorama exists to research agent behavior on your own machine, with your own sessions. Use it only to steer Claude Code sessions you start and control, and don't use it to deceive other people about what an agent produced. Rewritten tool results can lead Claude Code to wrong conclusions or wrong code. Treat any session run with active rules as an experiment, not as normal development work.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
