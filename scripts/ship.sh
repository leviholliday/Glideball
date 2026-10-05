#!/bin/zsh
# Ships a Glideball update end to end:
#   1. scripts/release.sh  — universal build, sign, zip, tag, GitHub release
#   2. Netlify             — redeploy the website (its download links always
#                            point at the newest release)
#   3. Installs the new build on this Mac
#
# Usage: scripts/ship.sh 2.1 "What's new in this version"
#        scripts/ship.sh 2.4-beta.1 "What's new in this beta" --beta
# Everyone running Glideball sees the new version in its top bar within a day and installs it in one click.
# A beta (--beta or --prerelease) is a GitHub prerelease: only Glideball's Beta program sees it,
# and the website — which always offers the newest full release — isn't redeployed.
set -euo pipefail
cd "$(dirname "$0")/.."

NETLIFY_SITE="749c72a7-7049-463e-8555-48263ed392ec"   # glideball.netlify.app

usage() { print -u2 "usage: scripts/ship.sh <version> \"<release notes>\" [--beta]"; exit 64; }

BETA=0
typeset -a positional
for arg in "$@"; do
  case $arg in
    --beta|--prerelease) BETA=1 ;;
    -*)                  print -u2 "error: unknown option: $arg"; usage ;;
    *)                   positional+=("$arg") ;;
  esac
done
(( ${#positional} == 2 )) || usage
VERSION=${positional[1]} NOTES=${positional[2]}

# release.sh checks this too, but fail before anything else happens.
if [[ ${VERSION#v} == *-* ]] && (( ! BETA )); then
  print -u2 "error: $VERSION is a prerelease version — add --beta so only Beta program members get it"; exit 64
fi
if (( BETA )) && [[ ${VERSION#v} != *-* ]]; then
  print -u2 "error: --beta needs a prerelease version, e.g. ${VERSION#v}-beta.1"; exit 64
fi

if (( ! BETA )); then
  command -v netlify >/dev/null || { print -u2 "error: the Netlify CLI isn't installed (brew install netlify-cli)"; exit 1; }
  # (`netlify status` fails in folders not linked to a site, so ask the API instead.)
  netlify api getCurrentUser >/dev/null 2>&1 || { print -u2 "error: not logged in to Netlify — run: netlify login"; exit 1; }
fi
[[ $NOTES != "What's new in this version" && $NOTES != "What's new in this beta" ]] \
  || { print -u2 "error: write real release notes — people see them in the update menu"; exit 64; }

last_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [[ -n $last_tag ]] && [[ -z $(git log --oneline "$last_tag"..HEAD -- Sources Resources Package.swift) ]]; then
  print -u2 "error: nothing in the app has changed since $last_tag — commit your changes first"
  print -u2 "       (website-only changes: scripts/deploy-site.sh)"
  exit 1
fi

if (( BETA )); then
  scripts/release.sh --prerelease "$VERSION" "$NOTES"
  print "\n==> Skipping the website (it offers the newest full release, not betas)"
else
  scripts/release.sh "$VERSION" "$NOTES"
  print "\n==> Updating the Homebrew cask"
  scripts/update-cask.sh "$VERSION" || print -u2 "warning: cask not updated — rerun: scripts/update-cask.sh $VERSION"
  print "\n==> Deploying the website"
  scripts/deploy-site.sh "Glideball $VERSION"
fi

print "\n==> Attaching the Linux & Windows previews (waits for CI)"
scripts/attach-previews.sh "v${VERSION#v}" || print -u2 "warning: previews not attached — rerun: scripts/attach-previews.sh v${VERSION#v}"

print "\n==> Installing Glideball $VERSION on this Mac"
./build.sh | tail -1

if (( BETA )); then
  print "\n✓ Glideball $VERSION is out to the Beta program:"
  print "  Release:  https://github.com/leviholliday/glideball/releases/tag/v${VERSION#v}"
else
  print "\n✓ Glideball $VERSION is out:"
  print "  Release:  https://github.com/leviholliday/glideball/releases/tag/v${VERSION#v}"
  print "  Website:  https://glideball.netlify.app"
fi
