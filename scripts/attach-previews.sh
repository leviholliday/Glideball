#!/bin/zsh
# Attaches the Linux and Windows preview builds to a GitHub release.
#   scripts/attach-previews.sh v2.8.1
# Downloads the newest passing Linux and Windows CI artifacts and uploads them under stable names, which the website's
# /download/linux and /download/windows links (website/netlify.toml) point at.
set -euo pipefail
cd "${0:A:h:h}"
TAG=${1:?usage: scripts/attach-previews.sh <tag>}
REPO=leviholliday/glideball
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# CI only runs when linux/ or windows/ change, so use each workflow's newest run
# on main (waiting for it if it's still going); it must have passed.
for wf in linux.yml windows.yml; do
  print "==> Newest $wf build on main"
  id=$(gh run list --repo $REPO --workflow $wf --branch main --event push --limit 1 --json databaseId -q '.[0].databaseId')
  [[ -n $id ]] || { print -u2 "error: no $wf runs on main yet"; exit 1; }
  gh run watch "$id" --repo $REPO --exit-status >/dev/null || { print -u2 "error: $wf run $id failed — not attaching"; exit 1; }
  gh run download "$id" --repo $REPO --dir "$WORK/$wf"
done

typeset -A names=(
  'glideball-linux-*.tar.gz'   Glideball-Linux-Preview.tar.gz
  'glideball_*_all.deb'        Glideball-Linux-Preview.deb
  'Glideball-Setup-x64.exe'    Glideball-Windows-Preview-Setup-x64.exe
  'Glideball-Setup-arm64.exe'  Glideball-Windows-Preview-Setup-arm64.exe
  'Glideball-win-x64.zip'      Glideball-Windows-Preview-x64.zip
  'Glideball-win-arm64.zip'    Glideball-Windows-Preview-arm64.zip
)
mkdir -p "$WORK/out"
for pattern target in "${(@kv)names}"; do
  src=( $WORK/**/${~pattern}(N.) )
  (( ${#src} )) || { print -u2 "error: no file matching $pattern in the CI artifacts"; exit 1; }
  cp "${src[1]}" "$WORK/out/$target"
done
print "==> Uploading previews to $TAG"
gh release upload "$TAG" "$WORK"/out/* --repo $REPO --clobber
print "✓ Linux & Windows previews attached to $TAG"
