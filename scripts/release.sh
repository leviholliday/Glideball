#!/bin/zsh
# Cuts a Glide release and publishes it on GitHub.
#
#   scripts/release.sh 1.1 "Release notes text"
#   scripts/release.sh --dry-run 1.1 "Release notes text"
#   scripts/release.sh --prerelease 2.4-beta.1 "Release notes text"
#   scripts/release.sh --verify v2.4-beta.1        only check an already-published release
#
# What it does, in order:
#   1. Preflight: clean git tree, on a branch, tag unused, gh logged in.
#      Then scripts/check.sh (build, simulators, translations, website tests,
#      the sandboxed self-test and render-ui): any failure stops the release.
#      --skip-checks skips it, with a loud warning.
#   2. Version:   CFBundleShortVersionString = <version>, CFBundleVersion + 1
#                 in Resources/Info.plist.
#   3. Build:     swift build -c release for Apple silicon and Intel, merge
#                 them with lipo into one universal binary, then assemble and sign
#                 release/Glide.app the same way build.sh does (without
#                 installing or launching it). Keep the two in sync.
#   4. Package:   release/Glide.zip via ditto, and print its SHA-256.
#   5. Publish:   commit "Release v<version>", tag v<version>, push both, and
#                 create the GitHub release with Glide.zip attached.
#   6. Verify:    download the published Glideball.zip and Glide.zip from
#                 GitHub into a temp folder; each app must pass
#                 codesign --verify --deep --strict, satisfy the pinned
#                 requirement installed copies check updates against
#                 (RELEASE_REQ below), and carry the tagged version. If not, it
#                 says so loudly and exits 1 (the release is already public).
#
# Prereleases (--prerelease, or --beta) go only to people in Glide's Beta
# program: the GitHub release is marked as a prerelease, which the website's
# "latest" download links and normal users' update checks skip. Their version
# must look like one — 2.4-beta.1 or 2.4-rc.1 — and a version that looks like
# one must be released with --prerelease, so a beta can't reach everyone by
# accident. CFBundleShortVersionString gets the same string ("2.4-beta.1"):
# macOS only treats it as display text (it's CFBundleVersion, the build
# number, that must keep increasing), and the update checker requires the
# downloaded app's CFBundleShortVersionString to equal the tag exactly.
#
# --dry-run runs steps 1-4 (a missing gh login is only a warning), then puts
# Info.plist back: nothing is committed, tagged, pushed, or published.
# If anything fails before the commit, Info.plist is restored automatically;
# if something fails after it, the script prints how to finish or undo.
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"

BUNDLE_ID=com.leviholliday.glide
# The requirement every installed copy pins when it checks an update (UpdateChecker.swift):
# this identifier and this certificate leaf (the "Glide Local Signing" certificate).
RELEASE_REQ='=identifier "com.leviholliday.glide" and certificate leaf = H"a729ea121c1117802453b860d127d1b07804ac32"'
SIGN_NAME="Glide Local Signing"
PLIST=Resources/Info.plist
ICON=Resources/AppIcon.icns
ICON_CLASSIC=Resources/AppIconClassic.icns
BIN_ARM=.build/release/Glide
BIN_X86=.build/x86/release/Glide
BIN=release/Glide-universal
OUT=release
APP=$OUT/Glideball.app
ZIP=$OUT/Glideball.zip
# Glide 2.7.1 and earlier look for Glide.zip holding Glide.app; attach that too so
# they can update (the new app renames itself to Glideball.app on first launch).
LEGACY_ZIP=$OUT/Glide.zip
# The same zip as Glideball.zip, under a second name: the in-app updater downloads this one,
# and the website's download counter skips it, so the count is people and not updates.
UPDATE_ZIP=$OUT/Glideball-update.zip
PLISTBUDDY=/usr/libexec/PlistBuddy

# ---------------------------------------------------------------- output

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' CYAN=$'\e[36m' RESET=$'\e[0m'
else
  BOLD='' RED='' GREEN='' YELLOW='' CYAN='' RESET=''
fi

step() { printf '\n%s==>%s %s%s%s\n' "$CYAN" "$RESET" "$BOLD" "$*" "$RESET"; }
info() { printf '    %s\n' "$@"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$1" >&2; shift; (( $# )) && printf '         %s\n' "$@" >&2; return 0; }
die()  { printf '%serror:%s %s\n' "$RED" "$RESET" "$1" >&2; shift; (( $# )) && printf '       %s\n' "$@" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/release.sh [--dry-run] [--prerelease] <version> "<release notes>"

  <version>         Marketing version, e.g. 1.1 or 1.2.3 (a leading "v" is ignored);
                    a prerelease adds -beta.N or -rc.N, e.g. 2.4-beta.1
  <release notes>   Text for the GitHub release

Options:
  -n, --dry-run     Bump, build, sign, and zip release/Glide.zip, then stop:
                    no commit, tag, push, or GitHub release. Info.plist is put back.
  -p, --prerelease  Publish as a GitHub prerelease: only Beta program members are
      --beta        offered it. Required for, and only for, -beta.N / -rc.N versions.
      --skip-checks Don't run scripts/check.sh first (prints a loud warning)
      --verify      Only verify an already-published release: scripts/release.sh --verify v2.4
  -h, --help        Show this help
EOF
}

# ---------------------------------------------------------------- verifying a release

# verify_release <tag> [local zip] [expected SHA-256 of Glideball.zip]: step 6.
# Downloads the release's zips (or checks just the given zip, as Glideball.zip,
# for testing) into a temp folder.
verify_release() {
  local tag=$1 local_zip=${2:-} want_sha=${3:-} version=${1#v} tmp failures=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/glideball-verify.XXXXXX")
  local -a assets
  if [[ -n $local_zip ]]; then
    cp "$local_zip" "$tmp/Glideball.zip"
    assets=(Glideball.zip:Glideball.app)
  else
    assets=(Glideball.zip:Glideball.app Glide.zip:Glide.app)
    local attempt
    for attempt in 1 2 3 4 5; do   # a fresh release can take a moment to be downloadable
      gh release download "$tag" --pattern Glideball.zip --pattern Glide.zip --dir "$tmp" --clobber 2>/dev/null && break
      info "Not downloadable yet; trying again in 5 s ($attempt/5)"
      sleep 5
    done
  fi
  verdict() {   # verdict <ok?> <text>
    if (( $1 == 0 )); then printf '    %s✓%s %s\n' "$GREEN" "$RESET" "$2"
    else printf '    %s✗ %s%s\n' "$RED" "$2" "$RESET"; failures=$(( failures + 1 )); fi
  }
  local pair zip name dir app got ok
  for pair in $assets; do
    zip=${pair%%:*} name=${pair#*:} dir="$tmp/${zip%.zip}"
    info "$zip"
    if [[ ! -s $tmp/$zip ]]; then verdict 1 "$zip couldn't be downloaded from release $tag"; continue; fi
    if [[ $zip == Glideball.zip && -n $want_sha ]]; then
      got=$(shasum -a 256 "$tmp/$zip" | awk '{print $1}')
      if [[ $got == "$want_sha" ]]; then ok=0; else ok=1; fi
      verdict $ok "the same bytes that were uploaded (SHA-256 ${got[1,12]}…)"
    fi
    mkdir -p "$dir"
    if ! ditto -x -k "$tmp/$zip" "$dir" 2>/dev/null; then verdict 1 "$zip doesn't unzip"; continue; fi
    app="$dir/$name"
    if [[ ! -d $app ]]; then verdict 1 "$zip has no $name inside"; continue; fi
    # (Each test is an `if` so a failure is reported, not an exit under set -e.)
    if codesign --verify --deep --strict "$app" 2>/dev/null; then ok=0; else ok=1; fi
    verdict $ok "codesign --verify --deep --strict"
    if codesign --verify --strict -R "$RELEASE_REQ" "$app" 2>/dev/null; then ok=0; else ok=1; fi
    verdict $ok "satisfies the pinned requirement (identifier $BUNDLE_ID, certificate leaf A729EA12…AC32)"
    got=$($PLISTBUDDY -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist" 2>/dev/null || true)
    if [[ $got == "$BUNDLE_ID" ]]; then ok=0; else ok=1; fi
    verdict $ok "bundle identifier is $BUNDLE_ID (got ${got:-nothing})"
    got=$($PLISTBUDDY -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist" 2>/dev/null || true)
    if [[ $got == "$version" ]]; then ok=0; else ok=1; fi
    verdict $ok "version is $version, matching tag $tag (got ${got:-nothing})"
  done
  rm -rf "$tmp"
  if (( failures )); then
    printf '\n%s%s' "$RED" "$BOLD"
    printf '  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
    printf '  !!  RELEASE %s FAILED VERIFICATION (%d problem(s) above)\n' "$tag" "$failures"
    printf '  !!  Installed copies would refuse it, or it is broken. Pull it now:\n'
    printf '  !!      gh release edit %s --draft\n' "$tag"
    printf '  !!  then fix the problem and release again.\n'
    printf '  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
    printf '%s\n' "$RESET"
    return 1
  fi
  info "${GREEN}Verified: what GitHub serves for $tag is signed, pinned, and version $version.${RESET}"
}

# ---------------------------------------------------------------- arguments

DRY_RUN=0
PRERELEASE=0
SKIP_CHECKS=0
VERIFY_ONLY=0
VERIFY_ZIP=''   # testing the verifier: --verify-zip=FILE checks a local zip instead of downloading
typeset -a positional
only_positional=0
for arg in "$@"; do
  if (( only_positional )); then positional+=("$arg"); continue; fi
  case $arg in
    -n|--dry-run) DRY_RUN=1 ;;
    --skip-checks) SKIP_CHECKS=1 ;;
    --verify)     VERIFY_ONLY=1 ;;
    --verify-zip=*) VERIFY_ONLY=1; VERIFY_ZIP=${arg#--verify-zip=} ;;
    -p|--prerelease|--beta) PRERELEASE=1 ;;
    -h|--help)    usage; exit 0 ;;
    --)           only_positional=1 ;;
    -*)           usage >&2; die "unknown option: $arg" ;;
    *)            positional+=("$arg") ;;
  esac
done

if (( VERIFY_ONLY )); then
  (( ${#positional} == 1 )) || die "--verify takes one tag, e.g. scripts/release.sh --verify v2.4-beta.1"
  [[ -n $VERIFY_ZIP ]] || command -v gh >/dev/null || die "gh (GitHub CLI) is not installed"
  step "Verifying release ${positional[1]}"
  if verify_release "v${positional[1]#v}" "$VERIFY_ZIP"; then exit 0; else exit 1; fi
fi

if (( ${#positional} != 2 )); then
  usage >&2
  die "expected a version and release notes (got ${#positional} argument(s))"
fi

VERSION=${positional[1]#v}
NOTES=${positional[2]}
FULL_NOTES=$NOTES   # NOTES plus the download footer, built once the zip exists
TAG="v$VERSION"

[[ $VERSION =~ '^[0-9]+(\.[0-9]+){1,2}(-(beta|rc)\.[1-9][0-9]*)?$' ]] \
  || die "invalid version '${positional[1]}'" \
         "Use numbers separated by dots, e.g. 1.1 or 1.2.3; a prerelease adds -beta.N or -rc.N, e.g. 2.4-beta.1."
[[ -n ${NOTES//[[:space:]]/} ]] || die "release notes are empty"

if [[ $VERSION == *-* ]]; then
  (( PRERELEASE )) || die "$VERSION is a prerelease version, but --prerelease wasn't given" \
    "Add --prerelease so only Beta program members get it, or release a plain version like ${VERSION%%-*}."
else
  (( ! PRERELEASE )) || die "--prerelease needs a prerelease version, e.g. $VERSION-beta.1" \
    "Glide tells betas apart from final releases by the version: 2.4-beta.1 comes before 2.4."
fi

# "2.4-beta.1" → "2.4 beta 1", the way Glide shows it.
DISPLAY_VERSION=${${VERSION/-beta./ beta }/-rc./ RC }

# ---------------------------------------------------------------- cleanup

PLIST_DIRTY=0      # Info.plist holds an uncommitted version bump
STAGE=preflight    # how far the irreversible part has got
REMOTE='' MERGE_REF=''

gh_command() {
  print -r -- "gh release create $TAG $ZIP $UPDATE_ZIP $LEGACY_ZIP --title ${(qq):-Glideball $DISPLAY_VERSION} --notes ${(qq)FULL_NOTES} --verify-tag${PRERELEASE_FLAG:+ $PRERELEASE_FLAG}"
}
PRERELEASE_FLAG=''
(( PRERELEASE )) && PRERELEASE_FLAG=--prerelease

# Is version $1 lower than $2? Knows that 2.4-beta.1 < 2.4-beta.2 < 2.4-rc.1 < 2.4,
# the order Glide's update checker uses (zsh's is-at-least puts 2.4-beta.1 after 2.4).
version_lt() {
  local a=${1%%-*} b=${2%%-*}
  local pa=${1#$a} pb=${2#$b}               # "" or "-beta.1"
  is-at-least "$a" "$b" || return 1         # numbers: $2 is lower
  is-at-least "$b" "$a" || return 0         # numbers: $1 is lower
  [[ -z $pa ]] && return 1                  # same numbers: a final release is never lower
  [[ -z $pb ]] && return 0                  # …and a prerelease is lower than its release
  local -A rank=(alpha 0 beta 1 rc 2)
  local sa=${${pa#-}%%.*} sb=${${pb#-}%%.*}
  local ra=${rank[$sa]:-0} rb=${rank[$sb]:-0}
  (( ra != rb )) && { (( ra < rb )); return }
  (( ${pa##*.} < ${pb##*.} ))
}

on_exit() {
  local rc=$?
  if (( PLIST_DIRTY )); then
    if git checkout -- "$PLIST" 2>/dev/null; then
      (( rc == 0 )) || warn "restored $PLIST to its committed version"
    else
      warn "could not restore $PLIST" "Run: git checkout -- $PLIST"
    fi
  fi
  (( rc == 0 )) && return 0
  case $STAGE in
    committed)
      warn "the release commit was made locally, but nothing was tagged or pushed." \
           "Undo it with:  git reset --keep HEAD~1" ;;
    tagged)
      warn "the release commit and tag $TAG exist locally; nothing reached $REMOTE." \
           "Fix the problem, then finish with:" \
           "  git push $REMOTE HEAD:$MERGE_REF && git push $REMOTE refs/tags/$TAG" \
           "  $(gh_command)" \
           "Or undo with:  git tag -d $TAG && git reset --keep HEAD~1" ;;
    pushed_branch)
      warn "the release commit is pushed, but tag $TAG is not." \
           "Finish with:" \
           "  git push $REMOTE refs/tags/$TAG" \
           "  $(gh_command)" ;;
    pushed)
      warn "commit and tag $TAG are pushed, but the GitHub release was not created." \
           "Finish with:" \
           "  $(gh_command)" ;;
  esac
  return 0
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- 1. preflight

step "Checking the repository"

for tool in git swift codesign ditto shasum security xattr awk; do
  command -v $tool >/dev/null || die "'$tool' not found" "Install the Xcode Command Line Tools: xcode-select --install"
done
[[ -x $PLISTBUDDY ]] || die "$PLISTBUDDY not found"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$ROOT is not a git repository"

BRANCH=$(git symbolic-ref --quiet --short HEAD) \
  || die "HEAD is detached" "Check out the branch you release from (e.g. git switch main) and rerun."

dirty=$(git status --porcelain)
if [[ -n $dirty ]]; then
  print -r -- "$dirty" | head -n 15 | sed 's/^/       /' >&2 || true
  die "the working tree is not clean (see above)" \
      "Commit or stash these first: the build compiles whatever is on disk, including" \
      "untracked files, and the release must match the commit it is tagged on."
fi

for f in "$PLIST" "$ICON" "$ICON_CLASSIC" Package.swift; do
  [[ -f $f ]] || die "$f is missing"
done

git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists locally"

# Missing translations don't stop a release (that text shows in English), but say so.
if command -v python3 >/dev/null && ! python3 scripts/l10n/check.py --quiet >/dev/null 2>&1; then
  warn "some translations are missing or broken" "Run scripts/l10n/check.py to see which; untranslated text shows in English."
fi

if (( DRY_RUN )); then
  if ! command -v gh >/dev/null; then
    warn "gh is not installed; a real release needs it (brew install gh)"
  elif ! gh auth status >/dev/null 2>&1; then
    warn "gh is not logged in; a real release needs it (gh auth login)"
  fi
  REMOTE=$(git config --get "branch.$BRANCH.remote" || true)
  MERGE_REF=$(git config --get "branch.$BRANCH.merge" || true)
  [[ -n $REMOTE ]] || warn "branch $BRANCH has no upstream; a real release needs one (git push -u origin $BRANCH)"
else
  command -v gh >/dev/null || die "gh (GitHub CLI) is not installed" "Install it with: brew install gh"
  gh auth status >/dev/null 2>&1 || die "gh is not logged in to GitHub" "Run: gh auth login"

  REMOTE=$(git config --get "branch.$BRANCH.remote" || true)
  MERGE_REF=$(git config --get "branch.$BRANCH.merge" || true)
  [[ -n $REMOTE && -n $MERGE_REF ]] \
    || die "branch $BRANCH has no upstream to push to" "Set one with: git push -u origin $BRANCH"

  gh repo view >/dev/null 2>&1 \
    || die "gh can't find the GitHub repository for this checkout" "Check 'git remote -v' and 'gh repo view'."

  info "Fetching $REMOTE…"
  git fetch --quiet --tags "$REMOTE" || die "git fetch $REMOTE failed (offline?)"
  behind=$(git rev-list --count "HEAD..$REMOTE/${MERGE_REF#refs/heads/}" 2>/dev/null || echo 0)
  (( behind == 0 )) || die "$BRANCH is $behind commit(s) behind $REMOTE" "Pull first: git pull --rebase"

  git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$TAG" >/dev/null 2>&1 \
    && die "tag $TAG already exists on $REMOTE"
  gh release view "$TAG" >/dev/null 2>&1 && die "a GitHub release named $TAG already exists"
fi

CUR_VERSION=$($PLISTBUDDY -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null) \
  || die "can't read CFBundleShortVersionString from $PLIST"
CUR_BUILD=$($PLISTBUDDY -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null) \
  || die "can't read CFBundleVersion from $PLIST"
[[ $CUR_BUILD == <-> ]] || die "CFBundleVersion in $PLIST is '$CUR_BUILD', not a whole number"
NEW_BUILD=$(( CUR_BUILD + 1 ))

autoload -Uz is-at-least
if [[ $VERSION == "$CUR_VERSION" ]]; then
  warn "$PLIST already says $VERSION; only the build number will change"
elif version_lt "$VERSION" "$CUR_VERSION"; then
  warn "$VERSION is lower than the current version $CUR_VERSION"
fi

info "Branch:   $BRANCH${REMOTE:+ → $REMOTE}"
info "Version:  $CUR_VERSION ($CUR_BUILD) → $VERSION ($NEW_BUILD)"
info "Tag:      $TAG"
(( PRERELEASE )) && info "Kind:     prerelease (Beta program only)"
(( DRY_RUN )) && info "Mode:     dry run (no commit, tag, push, or release)"

# ---------------------------------------------------------------- 1b. checks

if (( SKIP_CHECKS )); then
  printf '\n%s%s' "$YELLOW" "$BOLD" >&2
  printf '  ######################################################################\n' >&2
  printf '  ##  --skip-checks: scripts/check.sh was NOT run.                    ##\n' >&2
  printf '  ##  Nothing proves this build launches, renders, or passes its      ##\n' >&2
  printf '  ##  simulators and translation checks. Releasing anyway.            ##\n' >&2
  printf '  ######################################################################\n' >&2
  printf '%s\n' "$RESET" >&2
elif [[ ${GLIDEBALL_CHECKED_COMMIT:-} == "$(git rev-parse HEAD)" ]]; then
  step "Checks already passed for this commit (scripts/ship.sh ran scripts/check.sh)"
else
  step "Running scripts/check.sh (build, simulators, translations, website, self-test, render-ui)"
  scripts/check.sh || die "scripts/check.sh failed, so nothing was released" \
    "Each step's log is in build/check/. Fix the problem and rerun;" \
    "--skip-checks releases without them (don't, unless you know why they fail)."
fi

# ---------------------------------------------------------------- 2. version

step "Setting version $VERSION ($NEW_BUILD) in $PLIST"
PLIST_DIRTY=1
$PLISTBUDDY -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST" \
  || die "PlistBuddy could not update $PLIST"

# ---------------------------------------------------------------- 3. build

step "Building for Apple silicon (swift build -c release)"
swift build -c release || die "swift build failed; see the compiler output above"
[[ -x $BIN_ARM ]] || die "the build finished but $BIN_ARM is missing"
step "Building for Intel (cross-compiling x86_64)"
swift build -c release --triple x86_64-apple-macosx26.0 --scratch-path .build/x86 \
  || die "the Intel build failed; see the compiler output above"
[[ -x $BIN_X86 ]] || die "the Intel build finished but $BIN_X86 is missing"
mkdir -p release
lipo -create "$BIN_ARM" "$BIN_X86" -output "$BIN" || die "lipo couldn't merge the two builds"
lipo -info "$BIN"

step "Assembling $APP"
rm -rf "$APP" "$ZIP" "$LEGACY_ZIP" "$UPDATE_ZIP" "$OUT/legacy"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Glide"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp "$ICON_CLASSIC" "$APP/Contents/Resources/AppIconClassic.icns" || die "couldn't copy $ICON_CLASSIC (./build.sh --icon makes it)"
cp Resources/IntroMusic.m4a "$APP/Contents/Resources/"   # scripts/make-intro-music.py
cp Resources/Sounds/*.caf "$APP/Contents/Resources/" || die "couldn't copy the interface sounds (scripts/make-sounds.py)"
lprojs=(Resources/*.lproj(N))   # translations (scripts/l10n) — copied before signing so the seal covers them
(( ${#lprojs} )) || die "no Resources/*.lproj translations found"
cp -R "${lprojs[@]}" "$APP/Contents/Resources/" || die "couldn't copy the translations"
info "Languages: ${(j:, :)${lprojs:t:r}}"
xattr -cr "$APP"   # stray extended attributes make codesign refuse the bundle

# Same identity lookup as build.sh: the local "Glide Local Signing" certificate
# keeps users' Accessibility / Input Monitoring grants valid across updates.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk '/Glide Local Signing/ {print $2; exit}' || true)
if [[ -n $IDENTITY ]]; then
  info "Signing with \"$SIGN_NAME\" ($IDENTITY)"
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" \
    || die "codesign failed" "If macOS asked for keychain access, choose Always Allow and rerun."
elif (( DRY_RUN )); then
  warn "'$SIGN_NAME' certificate not found; this dry run uses an ad-hoc signature" \
       "A real release stops here: an ad-hoc build can't be updated to by any installed copy."
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" || die "ad-hoc codesign failed"
else
  die "'$SIGN_NAME' certificate not found in the keychain" \
      "An ad-hoc signed build can't be installed over any existing copy: the updater pins this certificate." \
      "Restore the signing identity (e.g. from the .p12 backup) and rerun."
fi
codesign --verify --strict "$APP" || die "the signature on $APP does not verify"
if codesign --verify --strict -R "$RELEASE_REQ" "$APP" 2>/dev/null; then
  info "Signature satisfies the pinned update requirement"
elif (( DRY_RUN )); then
  warn "$APP does not satisfy the pinned update requirement (identifier $BUNDLE_ID, certificate leaf A729EA12…AC32)" \
       "Fine for a dry run without the signing certificate; a real release would stop here."
else
  die "$APP does not satisfy the pinned update requirement" \
      "Required: identifier $BUNDLE_ID and certificate leaf A729EA121C1117802453B860D127D1B07804AC32." \
      "Installed copies would refuse this update. Check the signing identity in the keychain."
fi

built=$($PLISTBUDDY -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[[ $built == "$VERSION" ]] || die "$APP reports version $built, expected $VERSION"

# ---------------------------------------------------------------- 4. package

step "Packaging $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP" || die "ditto could not create $ZIP"
cp "$ZIP" "$UPDATE_ZIP" || die "could not copy $ZIP to $UPDATE_ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
SIZE=$(du -h "$ZIP" | awk '{print $1}')
mkdir -p "$OUT/legacy" && ditto "$APP" "$OUT/legacy/Glide.app"
ditto -c -k --sequesterRsrc --keepParent "$OUT/legacy/Glide.app" "$LEGACY_ZIP" || die "ditto could not create $LEGACY_ZIP"
rm -rf "$OUT/legacy"
info "Size:     $SIZE"
info "SHA-256:  $SHA"

FULL_NOTES="$NOTES

---
**Download \`Glideball.zip\`.** (\`Glide.zip\` is only for Glide 2.7.1 and older.)
First launch: https://glideball.netlify.app/#install
Glideball.zip SHA-256: \`$SHA\`"

if (( DRY_RUN )); then
  git checkout -- "$PLIST" || die "could not restore $PLIST" "Run: git checkout -- $PLIST"
  PLIST_DIRTY=0
  step "${GREEN}Dry run complete${RESET}"
  info "Built $ZIP for Glide $VERSION ($NEW_BUILD); $PLIST is back to $CUR_VERSION ($CUR_BUILD)." \
       "A real run would now:" \
       "  git commit -m \"Release $TAG\" -- $PLIST" \
       "  git tag -a $TAG -m \"Glide $VERSION\"" \
       "  git push ${REMOTE:-<remote>} HEAD:${MERGE_REF:-refs/heads/$BRANCH}" \
       "  git push ${REMOTE:-<remote>} refs/tags/$TAG" \
       "  $(gh_command)"
  exit 0
fi

# ---------------------------------------------------------------- 5. publish

step "Committing and tagging $TAG"
git commit --quiet -m "Release $TAG" -- "$PLIST" || die "git commit failed"
PLIST_DIRTY=0
STAGE=committed
git tag -a "$TAG" -m "Glideball $VERSION" || die "git tag $TAG failed"
STAGE=tagged
info "$(git log -1 --format='%h %s')"

step "Pushing to $REMOTE"
git push "$REMOTE" "HEAD:$MERGE_REF" || die "git push failed"
STAGE=pushed_branch
git push "$REMOTE" "refs/tags/$TAG" || die "pushing tag $TAG failed"
STAGE=pushed

step "Creating GitHub release $TAG"
typeset -a gh_flags
(( PRERELEASE )) && gh_flags=(--prerelease)
gh release create "$TAG" "$ZIP" "$UPDATE_ZIP" "$LEGACY_ZIP" --title "Glideball $DISPLAY_VERSION" --notes "$FULL_NOTES" --verify-tag "${gh_flags[@]}" \
  || die "gh release create failed"
STAGE=done

step "${GREEN}Released Glideball $DISPLAY_VERSION ($NEW_BUILD)${RESET}${PRERELEASE_FLAG:+ as a prerelease}"
info "Asset:    $ZIP ($SIZE)" \
     "SHA-256:  $SHA"

# ---------------------------------------------------------------- 6. verify

step "Verifying what GitHub now serves for $TAG"
verify_release "$TAG" "" "$SHA" || exit 1
