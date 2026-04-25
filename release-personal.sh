#!/usr/bin/env bash
set -e

# Personal release script for Claudes
# Usage: ./release-personal.sh [personal|patch|minor|major|x.y.z|x.y.z-personal.N]
# Default: personal (bumps -personal.N suffix)
#
# Ships personal builds to the mdrichardson/Claudes-personal repo, never upstream.
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

if ! git remote get-url personal-release >/dev/null 2>&1; then
  echo "ERROR: git remote 'personal-release' is not configured."
  echo "       Add it with:"
  echo "         git remote add personal-release https://github.com/mdrichardson/Claudes-personal.git"
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

if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
  echo "ERROR: tag v${VERSION} already exists locally. Aborting before mutation."
  echo "       Pick a different version or delete the existing tag first:"
  echo "         git tag -d v${VERSION}"
  exit 1
fi

# ---- Release steps ----------------------------------------------------------

# Dirty-tree guard above ensures nothing else is staged. package.json is the
# only file we touch here; stage it explicitly below.

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

# Push to the personal-release remote ONLY. Never upstream (paulallington/Claudes)
# and never origin (the public fork at mdrichardson/Claudes — that's for upstream PRs).
if ! git push personal-release personal/main; then
  echo ""
  echo "ERROR: push of personal/main to personal-release failed."
  echo "       The commit and tag v${VERSION} are already on your local personal/main."
  echo "       Do NOT re-run this script (it would bump the version AGAIN)."
  echo "       Once the push issue is resolved, run manually:"
  echo "         git push personal-release personal/main"
  echo "         git push personal-release v${VERSION}"
  exit 1
fi
if ! git push personal-release "v${VERSION}"; then
  echo ""
  echo "ERROR: tag push failed, but personal/main pushed."
  echo "       Run manually: git push personal-release v${VERSION}"
  exit 1
fi
echo "==> Pushed personal/main and v${VERSION} to personal-release"

echo ""
echo "==> Tag v${VERSION} pushed to mdrichardson/Claudes-personal."
echo ""
echo "    To publish the Windows installer to the fork's GitHub Release, run:"
echo "      npm run dist:win -- -c.publish.owner=mdrichardson -c.publish.repo=Claudes-personal --publish always"
echo ""
echo "    (Requires GH_TOKEN env var with write access to mdrichardson/Claudes-personal.)"
echo ""
echo "    Alternatively, if a release workflow exists on the fork, it will build"
echo "    automatically when the tag is pushed. Watch:"
echo "      https://github.com/mdrichardson/Claudes-personal/actions"
echo ""
echo "    Release URL: https://github.com/mdrichardson/Claudes-personal/releases/tag/v${VERSION}"
