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

## Before the first public release

- Run a trademark and name search for "Diorama" in software.
- Choose the final bundle identifier and set the `BUNDLE_ID` variable.
- Enable GitHub Security Advisories, and consider making the repository public. Actions minutes are free for public repositories, but **don't** use the self-hosted runner for a public repository.
- Optional: a live smoke test on your account (`diorama run --profile <p>` on a small task).
