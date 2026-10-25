# Release process

Releases are built and published by GitHub Actions (`.github/workflows/release.yml`) on the self-hosted macOS runner.

## Cutting a release

1. **Record changes.** Add them to the `## Unreleased` section of `CHANGELOG.md` as you work. That section becomes the release notes.
2. **Release:**

   ```bash
   scripts/release.sh 1.1.0          # or 1.1.0-beta.1 for a prerelease
   ```

   The script checks that you're on `main`, in sync with `origin`, with a clean tree, and that `Unreleased` isn't empty. It then:
   - sets `DioramaVersion.current`;
   - turns `Unreleased` into `1.1.0 — <date>` and opens a new empty `Unreleased`;
   - runs `swift test`;
   - commits `Release v1.1.0`, tags `v1.1.0`, and pushes both.

3. **The tag starts the Release workflow,** which:
   - checks that the tag matches the version in the source;
   - runs `swift test`;
   - builds and signs `Diorama.app` (`scripts/bundle-app.sh`), and notarizes it if credentials are configured;
   - generates the release notes and a Homebrew cask (`scripts/release-notes.sh`);
   - publishes a GitHub Release with three assets: `Diorama-<v>.zip`, `Diorama-<v>.zip.sha256` and `diorama.rb`.

   Versions with a `-` suffix are published as prereleases.

Follow the run with:

```bash
gh run watch $(gh run list --workflow Release --limit 1 --json databaseId --jq '.[0].databaseId')
```

**Trying it without a tag:** run the workflow manually (Actions → Release → *Run workflow*, or `gh workflow run Release`). It builds the current `main` and creates a **draft** release for the source version. If you later run `scripts/release.sh` for that same version, the workflow publishes that draft.

## Signing and notarization

Without secrets, releases are **ad-hoc signed**, and the release notes tell users how to get past Gatekeeper. To produce signed, notarized builds, add these repository secrets:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | `base64 -i DeveloperID.p12` of your "Developer ID Application" certificate and key |
| `DEVELOPER_ID_P12_PASSWORD` | The .p12 password |
| `DEVELOPER_ID_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | Apple ID, team ID and an app-specific password for `notarytool` |

Optionally, set the repository **variable** `BUNDLE_ID` (default `io.github.diorama.Diorama`). The certificate is imported into a temporary keychain on the runner, which is deleted after the job.

## Homebrew

Each release includes `diorama.rb`, a cask pinned to that release's zip and checksum. Copy it into your tap (`Casks/diorama.rb`). For a private repository, users need access to the release assets.

## Going public

**Name check (2026-10-25, web search, not legal advice).** "Diorama" is crowded in software:
- **A pending US word-mark application, DIORAMA,** by Bratte Ltd. (filed 2023-10-25, intent to use). It's in Class 042: online software for creating and editing visual and multimedia content with generative AI.
- **Older marks:** DIORAMA, from Visual Modeling Inc. (a data-visualization program feature), and DIORAMA DESIGNER (registered 2003, renewed).
- **Products:** Diorama by Litho (an AR filmmaking app), Diorama Worlds (VR), and "dioramas", an open-source framework for 3D websites.

Diorama's use (a developer research tool for AI agents) is a different market. Even so, the pending Class 042 application is close enough that you should check the USPTO (and EUIPO, if relevant) status, or consider a more distinctive name, before a public launch. Renaming touches the binaries, bundle ID, data folder and docs.

**Checklist:**
1. Resolve the name question above, then set the `BUNDLE_ID` repository variable.
2. Make the repository public. CI and Release then switch to GitHub's free hosted `macos-26` runner automatically (`runs-on` checks `github.event.repository.private`).
3. **Remove the self-hosted runner** from the repository (Settings → Actions → Runners), and on the Mac run `cd ~/actions-runner && ./svc.sh uninstall`. A self-hosted runner on a public repository would let anyone's pull request run code on your Mac.
4. Enable private vulnerability reporting (Settings → Security). `SECURITY.md` points reporters there.
5. Without an Apple Developer ID, releases stay ad-hoc signed, and the release notes include the Gatekeeper instructions.
