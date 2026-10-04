#!/bin/zsh
# Ships a Glide update end to end:
#   1. scripts/release.sh  — universal build, sign, zip, tag, GitHub release
#   2. Netlify             — redeploy the website (its download links always
#                            point at the newest release)
#   3. Installs the new build on this Mac
#
# Usage: scripts/ship.sh 2.1 "What's new in this version"
# Everyone running Glide sees the new version in its top bar within a day and installs it in one click.
set -euo pipefail
cd "$(dirname "$0")/.."

NETLIFY_SITE="749c72a7-7049-463e-8555-48263ed392ec"   # glide-trackball.netlify.app

[[ $# -eq 2 ]] || { print -u2 "usage: scripts/ship.sh <version> \"<release notes>\""; exit 64; }
command -v netlify >/dev/null || { print -u2 "error: the Netlify CLI isn't installed (brew install netlify-cli)"; exit 1; }
# (`netlify status` fails in folders not linked to a site, so ask the API instead.)
netlify api getCurrentUser >/dev/null 2>&1 || { print -u2 "error: not logged in to Netlify — run: netlify login"; exit 1; }
[[ $2 != "What's new in this version" ]] || { print -u2 "error: write real release notes — people see them in the update menu"; exit 64; }

last_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [[ -n $last_tag ]] && [[ -z $(git log --oneline "$last_tag"..HEAD -- Sources Resources Package.swift) ]]; then
  print -u2 "error: nothing in the app has changed since $last_tag — commit your changes first"
  print -u2 "       (website-only changes: scripts/deploy-site.sh)"
  exit 1
fi

scripts/release.sh "$1" "$2"

print "\n==> Deploying the website"
scripts/deploy-site.sh "Glide $1"

print "\n==> Installing Glide $1 on this Mac"
./build.sh | tail -1

print "\n✓ Glide $1 is out:"
print "  Release:  https://github.com/leviholliday/glide/releases/tag/v$1"
print "  Website:  https://glide-trackball.netlify.app"
