# Security policy

Diorama sits between Claude Code and the model on your Mac, stores what it records locally, and keeps an Anthropic API key in the Keychain. Security problems are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Report it privately through GitHub instead: on the repository's **Security** tab, choose **Report a vulnerability**. Include what you found, how to reproduce it, and what an attacker could do with it, plus the Diorama version (`diorama --version`) and your macOS version. Leave out raw captures or transcripts that contain private code or credentials.

You'll get an answer within a week. Once a fix is ready, it ships in a release and the advisory is published, crediting you unless you'd rather not be named.

## Supported versions

Fixes go into the latest release. Please check that a problem still happens on the newest version before reporting it.

## What's in scope

- The local daemon: the gateway (`127.0.0.1`), its control API and the session tokens that protect them.
- Handling of credentials: Claude Code's credentials are forwarded but never stored or logged; Diorama's own API key stays in the Keychain.
- What's recorded on disk (`~/Library/Application Support/Diorama`) and who can read it.
- The CLI, the app, the Claude Code hooks Diorama installs, and the MCP server.

Not in scope: changing what Claude sees is Diorama's purpose, so a rule that rewrites tool results isn't a vulnerability by itself. Other local software running as your own user is also outside what Diorama can defend against.

More on what Diorama stores and sends: [docs/security.md](docs/security.md).
