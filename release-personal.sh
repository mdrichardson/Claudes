#!/usr/bin/env bash
set -e

# Personal release script for Claudes
# Usage: ./release-personal.sh [personal|patch|minor|major|x.y.z|x.y.z-personal.N]
# Default: personal (bumps -personal.N suffix)
#
# Ships personal builds to the mdrichardson/Claudes fork, never upstream.
# This script lives ONLY on the personal/main branch.
#
# Version scheme: X.Y.Z-personal.N
#   - Avoids colliding with upstream tags on paulallington/Claudes
#   - `personal` bumps N (or starts at .1 if missing)
#   - `patch|minor|major` strip the suffix, bump the numeric part, reset to -personal.1
#   - Explicit x.y.z or x.y.z-personal.N is used as-is

# ---- Safety guards ----------------------------------------------------------

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "personal/main" ]; then
  echo "ERROR: release-personal.sh must be run from the 'personal/main' branch."
  echo "       Current branch: ${BRANCH}"
  echo "       Run: git checkout personal/main"
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree has uncommitted changes."
  echo "       Commit or stash changes first, then rerun."
  exit 1
fi

if ! git remote get-url mdrichardson >/dev/null 2>&1; then
  echo "ERROR: git remote 'mdrichardson' is not configured."
  echo "       Add it with:"
  echo "         git remote add mdrichardson https://github.com/mdrichardson/Claudes.git"
  exit 1
fi

# ---- Version computation ----------------------------------------------------

CURRENT=$(node -p "require('./package.json').version")
ARG="${1:-personal}"

# Split CURRENT into BASE (X.Y.Z) and PERSONAL_N (integer or empty).
if echo "$CURRENT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+-personal\.[0-9]+$'; then
  BASE="${CURRENT%-personal.*}"
  PERSONAL_N="${CURRENT##*-personal.}"
elif echo "$CURRENT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  BASE="$CURRENT"
  PERSONAL_N=""
else
  echo "ERROR: current package.json version '${CURRENT}' is not of the form X.Y.Z or X.Y.Z-personal.N"
  exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$BASE"

case "$ARG" in
  personal)
    if [ -z "$PERSONAL_N" ]; then
      VERSION="${BASE}-personal.1"
    else
      VERSION="${BASE}-personal.$((PERSONAL_N + 1))"
    fi
    ;;
  major)
    VERSION="$((MAJOR + 1)).0.0-personal.1"
    ;;
  minor)
    VERSION="${MAJOR}.$((MINOR + 1)).0-personal.1"
    ;;
  patch)
    VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))-personal.1"
    ;;
  *)
    if echo "$ARG" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-personal\.[0-9]+)?$'; then
      VERSION="$ARG"
    else
      echo "Usage: ./release-personal.sh [personal|patch|minor|major|x.y.z|x.y.z-personal.N]"
      echo "Current version: ${CURRENT}"
      exit 1
    fi
    ;;
esac

echo "==> Personal release: Claudes v${VERSION} (was v${CURRENT})"

# ---- Release steps ----------------------------------------------------------

# Stage any outstanding changes (guard above means there should be none, but
# mirror release.sh's defensive pattern in case the guard is ever relaxed).
CHANGES=$(git status --porcelain)
if [ -n "$CHANGES" ]; then
  echo "==> Staging outstanding changes..."
  git add -A
fi

# Update version in package.json (preserves trailing newline).
node -e "
  const pkg = require('./package.json');
  pkg.version = '${VERSION}';
  require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"
git add package.json
echo "==> Updated package.json to v${VERSION}"

# Commit and tag.
git commit -m "v${VERSION}"
git tag "v${VERSION}"
echo "==> Committed and tagged v${VERSION}"

# Push to the mdrichardson fork ONLY. Never origin (paulallington/Claudes).
git push mdrichardson personal/main
git push mdrichardson "v${VERSION}"
echo "==> Pushed personal/main and v${VERSION} to mdrichardson"

echo ""
echo "==> Tag v${VERSION} pushed to mdrichardson/Claudes."
echo ""
echo "    To publish the Windows installer to the fork's GitHub Release, run:"
echo "      npm run dist:win -- -c.publish.owner=mdrichardson -c.publish.repo=Claudes --publish always"
echo ""
echo "    (Requires GH_TOKEN env var with write access to mdrichardson/Claudes.)"
echo ""
echo "    Alternatively, if a release workflow exists on the fork, it will build"
echo "    automatically when the tag is pushed. Watch:"
echo "      https://github.com/mdrichardson/Claudes/actions"
echo ""
echo "    Release URL: https://github.com/mdrichardson/Claudes/releases/tag/v${VERSION}"
