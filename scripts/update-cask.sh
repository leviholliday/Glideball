#!/bin/zsh
# Points the Homebrew cask (github.com/leviholliday/homebrew-tap) at a release.
#   scripts/update-cask.sh 2.8.1
# Users then get it with: brew install --cask leviholliday/tap/glideball
set -euo pipefail
VERSION=${1:?usage: scripts/update-cask.sh <version>}
VERSION=${VERSION#v}
URL="https://github.com/leviholliday/glideball/releases/download/v$VERSION/Glideball.zip"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

print "==> Hashing $URL"
SHA=$(curl -fsSL "$URL" | shasum -a 256 | awk '{print $1}')
gh repo clone leviholliday/homebrew-tap "$WORK/tap" -- --quiet
CASK="$WORK/tap/Casks/glideball.rb"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
if git -C "$WORK/tap" diff --quiet; then
  print "Cask already at $VERSION"
  exit 0
fi
git -C "$WORK/tap" commit -qam "Glideball $VERSION"
git -C "$WORK/tap" push -q
print "✓ Homebrew cask updated to $VERSION ($SHA)"
