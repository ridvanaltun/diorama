#!/bin/zsh
# Cuts a release: bumps the version, stamps CHANGELOG.md, runs the tests, commits, tags and
# pushes. Pushing the tag starts .github/workflows/release.yml, which builds and publishes.
#
# Usage: scripts/release.sh 1.2.0 [--skip-tests] [--no-push]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
shift || true
SKIP_TESTS=false
PUSH=true
for a in "$@"; do
  case "$a" in
    --skip-tests) SKIP_TESTS=true ;;
    --no-push) PUSH=false ;;
    *) echo "unknown option $a"; exit 64 ;;
  esac
done

if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' ]]; then
  echo "usage: scripts/release.sh MAJOR.MINOR.PATCH[-prerelease] [--skip-tests] [--no-push]"
  exit 64
fi
TAG="v$VERSION"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

[[ "$BRANCH" == "main" ]] || { echo "✗ releases are cut from main (current: $BRANCH)"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ working tree is not clean"; exit 1; }
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "✗ main is not in sync with origin/main"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" > /dev/null && { echo "✗ tag $TAG already exists"; exit 1; }
grep -q '^## Unreleased' CHANGELOG.md || { echo "✗ CHANGELOG.md has no '## Unreleased' section"; exit 1; }
awk '/^## Unreleased/{f=1;next} /^## /{f=0} f && /[^[:space:]]/{c++} END{exit c>0?0:1}' CHANGELOG.md \
  || { echo "✗ the '## Unreleased' section in CHANGELOG.md is empty"; exit 1; }

# GitHub lists an invalid workflow file by its path instead of its name: refuse to tag then.
if command -v gh > /dev/null; then
  gh workflow list --json name --jq '.[].name' 2> /dev/null | grep -qx "Release" \
    || { echo "✗ GitHub doesn't recognize the Release workflow (invalid .github/workflows/release.yml?)"; exit 1; }
fi

echo "▸ Releasing $TAG"
sed -i '' "s/public static let current = \".*\"/public static let current = \"$VERSION\"/" Sources/DioramaCore/Models.swift
TODAY="$(date +%Y-%m-%d)"
# Stamp the Unreleased section and open a fresh one above it.
awk -v v="$VERSION" -v d="$TODAY" '
  !done && /^## Unreleased/ { print "## Unreleased\n"; print "## " v " — " d; done = 1; next }
  { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

if [[ "$SKIP_TESTS" != "true" ]]; then
  echo "▸ Running tests"
  swift test 2>&1 | tail -3
fi

git add Sources/DioramaCore/Models.swift CHANGELOG.md
git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "Diorama $VERSION"
echo "✓ committed and tagged $TAG"

if [[ "$PUSH" == "true" ]]; then
  git push -q origin main "$TAG"
  echo "✓ pushed — the Release workflow is building $TAG"
  echo "  follow: gh run watch \$(gh run list --workflow Release --limit 1 --json databaseId --jq '.[0].databaseId')"
else
  echo "  not pushed; run: git push origin main $TAG"
fi
