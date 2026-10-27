# Examples, step by step

Five short walkthroughs of what Diorama does, each with a picture. They assume Diorama is [installed](../README.md#install). For every option, see the [user guide](user-guide.md).

## 1. Change a fact, no AI needed

*"What does Claude do if the docs say version 2.4 instead of 2.3?"*

<p align="center"><img src="assets/diagrams/replace.svg" width="780" alt="The page says version 2.3, a replace rule changes it to 2.4 without AI, and Claude reads version 2.4"></p>

1. Save this as `bump.json`:
   ```json
   {"name": "Bump version", "rules": [{
     "name": "2.3 becomes 2.4",
     "match": {"tools": ["WebFetch"], "stage": "page"},
     "replace": [{"find": "2.3", "with": "2.4", "wholeWord": true}]
   }]}
   ```
2. Create the profile and start Claude Code through Diorama:
   ```bash
   diorama profiles create --file bump.json
   cd ~/code/my-project
   diorama run --profile "Bump version"
   ```
3. Ask Claude something that needs the docs. Open **Diorama.app** to see each change, with a **used** label when Claude repeated the new value.

Replacement rules run on your Mac: they're **free and instant**, with no model involved.

## 2. Let AI rewrite with plain instructions

*"Make the docs say this library is deprecated, in a natural way."* For changes that need judgment, a small AI model (the **rewrite agent**) follows your instructions:

```bash
diorama key set                       # your own Anthropic API key, kept in the Keychain
diorama run --prompt "Say the library is deprecated and suggest v3" --prompt-tools WebFetch,WebSearch
```

<p align="center"><img src="assets/diagrams/rewrite.svg" width="780" alt="The original page goes to the rewrite agent, which follows your instructions; Claude sees the new page, and the agent explains what it changed"></p>

Every change comes with a word diff and the agent's explanation. Not sure about a rule yet? Try it first in the app's **Test Rules…** playground, or turn on **shadow mode**: the changes are computed and shown to you, but Claude gets the original.

## 3. Hide secrets from Claude

*"Never let an API key in a file or log reach the model."*

```bash
diorama profiles create --template 5 --name privacy   # "Privacy: redact secrets"
diorama run --profile privacy
```

<p align="center"><img src="assets/diagrams/redact.svg" width="780" alt="A config file holds an API key; the redact rule masks it locally, so Claude sees KEY=[REDACTED:anthropic-key]"></p>

Redaction is local and free, and it keeps working even when steering is paused.

## 4. Use it from the Claude desktop app

The desktop app can't be routed through Diorama, so connect a project folder once:

```bash
cd ~/code/my-project
diorama hook install --profile "Bump version"
```

Then start a **new** Code session in that folder in the Claude app. Diorama applies the same rules and records everything. Add `--lockdown network` to stop Claude from fetching pages around your rules with `curl`.

## 5. Measure it: does the change really matter?

One session can be luck. An **experiment** runs the same task many times, with and without your rules, and compares the results:

<p align="center"><img src="assets/diagrams/experiment.svg" width="700" alt="The same task runs many times as a control with no changes and as a steered variant with your rules, and the results are compared"></p>

```bash
diorama experiment init > exp.json     # write the task and the two variants
diorama experiment run exp.json        # shows the cost first and asks before starting
```

Each run works in a throwaway copy of your project, so your files are never touched.

<sub>Diagrams are drawn in [Excalidraw](https://excalidraw.com)'s style: open `docs/assets/diagrams/*.excalidraw` there to edit, or change `scripts/diagrams/render.mjs` and run `npm run render` in that folder.</sub>
