#!/usr/bin/env bash
# Builds dist/glideball-linux-<version>.tar.gz (extract, then run ./install.sh).
set -euo pipefail
export COPYFILE_DISABLE=1   # no macOS ._ files in the tarball
cd "$(dirname "$0")"
VERSION="$(python3 -c 'import glideball; print(glideball.__version__)')"
NAME="glideball-linux-$VERSION"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME" dist
cp -R glideball bin packaging install.sh uninstall.sh README.md "$STAGE/$NAME/"
find "$STAGE/$NAME" -name '__pycache__' -prune -exec rm -rf {} +
tar -C "$STAGE" -czf "dist/$NAME.tar.gz" "$NAME"
echo "dist/$NAME.tar.gz"
