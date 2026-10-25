# Release process

Every step that publishes something or uses Apple credentials is done by a maintainer.

1. **Version:** update `DioramaVersion.current` in `Sources/DioramaCore/Models.swift` and `CHANGELOG.md`.
2. **Verify:** run `swift test`. The contract tests need the `claude` CLI and use only mocks. Then run `./scripts/bundle-app.sh` and `./scripts/demo-screenshots.sh`, which refreshes the screenshots.
3. **Optional live smoke test** (costs usage, and needs the maintainer's own accounts):
   - `diorama key set`
   - `diorama run --profile <p>` on a small task
   - check the timeline, and that `cache read` stays high on replayed turns
4. **Sign and notarize.** This needs an Apple Developer ID.

   ```bash
   SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" BUNDLE_ID=io.github.<owner>.Diorama ./scripts/bundle-app.sh
   xcrun notarytool submit dist/Diorama-<version>.zip --keychain-profile <profile> --wait
   xcrun stapler staple dist/Diorama.app
   ditto -c -k --keepParent dist/Diorama.app dist/Diorama-<version>.zip
   shasum -a 256 dist/Diorama-<version>.zip
   ```

5. **GitHub release:** tag `v<version>`, upload the zip and its `.sha256`, and paste the changelog section.
6. **Homebrew:** update `packaging/homebrew/diorama.rb` (version and sha256) and submit it to a tap.

**Before the first public release:**
- Run a trademark and name search for "Diorama" in software.
- Choose the final bundle identifier and GitHub owner.
- Enable GitHub Security Advisories.
