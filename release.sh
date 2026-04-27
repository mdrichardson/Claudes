#!/usr/bin/env bash
set -e

# Release script for Claudes
# Usage: ./release.sh [major|minor|patch|x.y.z]
# Default: patch
#
# Bumps the version, commits, tags, and pushes to origin (mdrichardson/Claudes).
# GitHub Actions then builds the Windows + macOS installers and creates the release.

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "master" ]; then
  echo "ERROR: release.sh must be run from the 'master' branch."
  echo "       Current branch: ${BRANCH}"
  echo "       Run: git checkout master"
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree has uncommitted changes."
  echo "       Commit or stash changes first, then rerun."
  exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "ERROR: git remote 'origin' is not configured."
  exit 1
fi

CURRENT=$(node -p "require('./package.json').version")
if ! echo "$CURRENT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: current package.json version '${CURRENT}' is not plain semver X.Y.Z."
  exit 1
fi
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

ARG="${1:-patch}"
case "$ARG" in
  major) VERSION="$((MAJOR + 1)).0.0" ;;
  minor) VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
  patch) VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
  *)
    if echo "$ARG" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
      VERSION="$ARG"
    else
      echo "Usage: ./release.sh [major|minor|patch|x.y.z]"
      echo "Current version: ${CURRENT}"
      exit 1
    fi
    ;;
esac

echo "==> Releasing Claudes v${VERSION} (was v${CURRENT})"

if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
  echo "ERROR: tag v${VERSION} already exists locally. Aborting before mutation."
  echo "       Pick a different version or delete the existing tag first:"
  echo "         git tag -d v${VERSION}"
  exit 1
fi

node -e "
  const pkg = require('./package.json');
  pkg.version = '${VERSION}';
  require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"
git add package.json
echo "==> Updated package.json to v${VERSION}"

git commit -m "v${VERSION}"
git tag "v${VERSION}"
echo "==> Committed and tagged v${VERSION}"

if ! git push origin master; then
  echo ""
  echo "ERROR: push of master to origin failed."
  echo "       Commit and tag v${VERSION} are on your local master."
  echo "       Once the push issue is resolved, run manually:"
  echo "         git push origin master"
  echo "         git push origin v${VERSION}"
  exit 1
fi
if ! git push origin "v${VERSION}"; then
  echo ""
  echo "ERROR: tag push failed, but master pushed."
  echo "       Run manually: git push origin v${VERSION}"
  exit 1
fi
echo "==> Pushed master and v${VERSION} to origin"

echo ""
echo "==> Tag v${VERSION} pushed to mdrichardson/Claudes."
echo "    GitHub Actions will build Windows + macOS installers and create the release:"
echo "      https://github.com/mdrichardson/Claudes/actions"
echo "    Release URL: https://github.com/mdrichardson/Claudes/releases/tag/v${VERSION}"
