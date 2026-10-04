#!/bin/zsh
# Ships a Glide update end to end:
#   1. scripts/release.sh  — universal build, sign, zip, tag, GitHub release
#   2. Netlify             — redeploy the website (its download links always
#                            point at the newest release)
#   3. Installs the new build on this Mac
#
# Usage: scripts/ship.sh 2.1 "What's new in this version"
# Everyone running Glide sees "Update 2.1" within a day and installs it in one click.
set -euo pipefail
cd "$(dirname "$0")/.."

NETLIFY_SITE="749c72a7-7049-463e-8555-48263ed392ec"   # glide-trackball.netlify.app

[[ $# -eq 2 ]] || { print -u2 "usage: scripts/ship.sh <version> \"<release notes>\""; exit 64; }
command -v netlify >/dev/null || { print -u2 "error: the Netlify CLI isn't installed (brew install netlify-cli)"; exit 1; }
netlify status >/dev/null 2>&1 || { print -u2 "error: not logged in to Netlify — run: netlify login"; exit 1; }

scripts/release.sh "$1" "$2"

print "\n==> Deploying the website"
netlify deploy --prod --dir website --site "$NETLIFY_SITE" --message "Glide $1" | grep -E "Production URL|Deploy is live" || true

print "\n==> Installing Glide $1 on this Mac"
./build.sh | tail -1

print "\n✓ Glide $1 is out:"
print "  Release:  https://github.com/leviholliday/glide/releases/tag/v$1"
print "  Website:  https://glide-trackball.netlify.app"
