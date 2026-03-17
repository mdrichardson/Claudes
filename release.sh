#!/usr/bin/env bash
set -e

# Release script for Claudes
# Usage: ./release.sh <version>
# Example: ./release.sh 2.1.0

VERSION="$1"

if [ -z "$VERSION" ]; then
  echo "Usage: ./release.sh <version>"
  echo "Example: ./release.sh 2.1.0"
  exit 1
fi

# Validate version format
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Error: Version must be in semver format (e.g. 2.1.0)"
  exit 1
fi

echo "==> Releasing Claudes v${VERSION}"

# Update version in package.json
node -e "
  const pkg = require('./package.json');
  pkg.version = '${VERSION}';
  require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"
echo "==> Updated package.json to v${VERSION}"

# Commit and tag
git add package.json
git commit -m "v${VERSION}"
git tag "v${VERSION}"
echo "==> Committed and tagged v${VERSION}"

# Push
git push
git push --tags
echo "==> Pushed to origin"

# Build installer
echo "==> Building installer..."
npx electron-builder --win
echo "==> Build complete"

# Create GitHub release and upload artifacts
INSTALLER="dist/Claudes Setup ${VERSION}.exe"
BLOCKMAP="dist/Claudes Setup ${VERSION}.exe.blockmap"
LATEST_YML="dist/latest.yml"

echo "==> Creating GitHub release v${VERSION}..."
gh release create "v${VERSION}" \
  --title "Claudes v${VERSION}" \
  --generate-notes \
  "$INSTALLER" \
  "$BLOCKMAP" \
  "$LATEST_YML"

echo ""
echo "==> Released Claudes v${VERSION}"
echo "    https://github.com/paulallington/Claudes/releases/tag/v${VERSION}"
