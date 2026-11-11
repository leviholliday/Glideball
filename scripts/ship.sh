#!/bin/zsh
# Ships a Glideball update end to end:
#   0. scripts/check.sh    — every check (build, simulators, translations, website
#                            tests, the sandboxed self-test and render-ui); any
#                            failure stops here. --skip-checks skips it, loudly.
#   1. scripts/release.sh  — universal build, sign, zip, tag, GitHub release, then
#                            downloads what GitHub serves and verifies it
#   2. Netlify             — redeploy the website, but only if website/ changed
#                            since the last final release (the download links
#                            follow the newest release without a redeploy);
#                            --no-site skips it
#   3. Does not install it here: update from inside Glideball (Check for Updates…)
#
# Usage: scripts/ship.sh 2.1 "What's new in this version"
#        scripts/ship.sh 2.4-beta.1 "What's new in this beta" --beta
# Everyone running Glideball sees the new version in its top bar within a day and installs it in one click.
# A beta (--beta or --prerelease) is a GitHub prerelease: only Glideball's Beta program sees it,
# and the website — which always offers the newest full release — isn't redeployed.
set -euo pipefail
cd "$(dirname "$0")/.."

NETLIFY_SITE="749c72a7-7049-463e-8555-48263ed392ec"   # glideball.netlify.app

usage() { print -u2 "usage: scripts/ship.sh <version> \"<release notes>\" [--beta] [--no-site] [--skip-checks]"; exit 64; }

BETA=0
NO_SITE=0
SKIP_CHECKS=0
typeset -a positional
for arg in "$@"; do
  case $arg in
    --beta|--prerelease) BETA=1 ;;
    --no-site)           NO_SITE=1 ;;
    --skip-checks)       SKIP_CHECKS=1 ;;
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

# Last FINAL release tag (no "-"): promoting 2.10-beta.N to 2.10 compares against
# the previous final release, not the beta, and the site only cares about finals.
last_final=$(git describe --tags --abbrev=0 --exclude='*-*' 2>/dev/null || true)

SITE_DEPLOY=0
if (( ! BETA )); then
  if (( NO_SITE )); then
    print "note: --no-site given; the website will not be deployed"
  elif [[ -z $last_final ]] || ! git diff --quiet "$last_final" HEAD -- website; then
    SITE_DEPLOY=1
  fi
fi
if (( SITE_DEPLOY )); then
  command -v netlify >/dev/null || { print -u2 "error: the Netlify CLI isn't installed (brew install netlify-cli); or pass --no-site"; exit 1; }
  # (`netlify status` fails in folders not linked to a site, so ask the API instead.)
  netlify api getCurrentUser >/dev/null 2>&1 || { print -u2 "error: not logged in to Netlify — run: netlify login (or pass --no-site)"; exit 1; }
fi
[[ $NOTES != "What's new in this version" && $NOTES != "What's new in this beta" ]] \
  || { print -u2 "error: write real release notes — people see them in the update menu"; exit 64; }

if (( BETA )); then
  last_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
else
  last_tag=$last_final
fi
if [[ -n $last_tag ]] && [[ -z $(git log --oneline "$last_tag"..HEAD -- Sources Resources Package.swift) ]]; then
  print -u2 "error: nothing in the app has changed since $last_tag — commit your changes first"
  print -u2 "       (website-only changes: scripts/deploy-site.sh)"
  exit 1
fi

# The checks, before anything is built for real. release.sh runs them too
# unless told this commit already passed (or --skip-checks is passed on).
typeset -a release_flags
if (( SKIP_CHECKS )); then
  release_flags+=(--skip-checks)   # release.sh prints the loud warning
else
  [[ -z $(git status --porcelain) ]] || { print -u2 "error: the working tree is not clean — commit first (release.sh would refuse)"; exit 1; }
  print "==> Running scripts/check.sh"
  scripts/check.sh || { print -u2 "\nerror: scripts/check.sh failed, so nothing was shipped (logs: build/check/; --skip-checks to override)"; exit 1; }
  export GLIDEBALL_CHECKED_COMMIT=$(git rev-parse HEAD)
fi

if (( BETA )); then
  scripts/release.sh "${release_flags[@]}" --prerelease "$VERSION" "$NOTES"
  print "\n==> Skipping the website (it offers the newest full release, not betas)"
else
  scripts/release.sh "${release_flags[@]}" "$VERSION" "$NOTES"
  print "\n==> Updating the Homebrew cask"
  scripts/update-cask.sh "$VERSION" || print -u2 "warning: cask not updated — rerun: scripts/update-cask.sh $VERSION"
  if (( SITE_DEPLOY )); then
    print "\n==> Deploying the website"
    scripts/deploy-site.sh "Glideball $VERSION" \
      || print -u2 "warning: website not deployed — rerun: scripts/deploy-site.sh \"Glideball $VERSION\""
  elif (( NO_SITE )); then
    print "\n==> Skipping the website (--no-site)"
  else
    print "\n==> Skipping the website (website/ hasn't changed since $last_final)"
  fi
fi

print "\n==> Attaching the Linux & Windows previews (waits for CI)"
scripts/attach-previews.sh "v${VERSION#v}" || print -u2 "warning: previews not attached — rerun: scripts/attach-previews.sh v${VERSION#v}"

# Not installed here on purpose: Levi updates his own copy from inside the app,
# which also tests the update path every release.
print "\n==> Skipping local install (update from inside Glideball: Check for Updates…)"

if (( BETA )); then
  print "\n✓ Glideball $VERSION is out to the Beta program:"
  print "  Release:  https://github.com/leviholliday/glideball/releases/tag/v${VERSION#v}"
else
  print "\n✓ Glideball $VERSION is out:"
  print "  Release:  https://github.com/leviholliday/glideball/releases/tag/v${VERSION#v}"
  if (( SITE_DEPLOY )); then print "  Website:  https://glideball.netlify.app"; fi
fi
