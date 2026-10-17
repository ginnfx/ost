#!/bin/bash
# Ship a release: commit everything, push, tag, watch the multi-platform CI,
# and publish the drafted GitHub Release (macOS dmg + iOS ipa + Windows
# zip/setup.exe/msix + Linux tar.gz/AppImage, x86_64 + arm64 where offered).
#
# Uses the tag-triggered .github/workflows/release.yml — the release itself is
# built entirely in CI, so this script only commits, tags, and publishes.
#
# Usage:
#   ./scripts/ship.sh "commit message"          # patch bump → v0.2.1-style tag
#   ./scripts/ship.sh -m "commit message"       # minor bump (new features)
#   ./scripts/ship.sh -M "commit message"       # major bump
#
# Requirements: gh CLI authenticated (gh auth status), git remote origin.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

BUMP=patch
case "${1:-}" in
  -m) BUMP=minor; shift ;;
  -M) BUMP=major; shift ;;
esac
MESSAGE="${1:-}"
if [ -z "$MESSAGE" ]; then
  echo "usage: ./scripts/ship.sh [-m|-M] \"commit message\"" >&2
  exit 1
fi

# auth sanity up front so failures are immediate, not after CI waits
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not authenticated (gh auth login)" >&2; exit 1; }

# 1) bump VERSION
OLD_VERSION="$(cat VERSION | tr -d '[:space:]')"
MAJOR=0 MINOR=0 PATCH=0
IFS=. read -r MAJOR MINOR PATCH <<< "$OLD_VERSION"
case "$BUMP" in
  patch) PATCH=$((PATCH + 1)) ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
esac
NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
printf '%s\n' "$NEW_VERSION" > VERSION
echo "VERSION ${OLD_VERSION} → ${NEW_VERSION}"

# 2) commit everything working-tree-wide (VERSION included), push
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git add -A
git commit -m "$MESSAGE (ship v$NEW_VERSION)" --allow-empty
git push origin "$BRANCH"
TAG="v$NEW_VERSION"

# 3) tag and push; the tag walk starts the release workflow
git tag -f "$TAG" -m "Release $TAG"
git push origin -f "$TAG"
echo "--- release run starting for $TAG"

# 4) wait for the run to appear, then watch it to completion
sleep 5
RUN_ID=""
for _ in $(seq 1 12); do
  RUN_ID="$(gh run list --workflow=release -L5 --json displayTitle,databaseId,headBranch \
    --jq ".[] | select(.headBranch == \"$TAG\") | .databaseId" | head -1 || true)"
  [ -n "$RUN_ID" ] && break
  sleep 5
done
if [ -z "$RUN_ID" ]; then
  echo "ERROR: could not find the release run for $TAG — check https://$(gh repo view --json url -q .url | sed 's|https://||')/actions" >&2
  exit 1
fi

echo "watching run id $RUN_ID (this can take 20–40 minutes)…"
gh run watch "$RUN_ID" --exit-status --interval 30

# 5) publish the draft created by the workflow
gh release edit "$TAG" --draft=false --title "$TAG"
gh release view "$TAG" --json url -q .url
