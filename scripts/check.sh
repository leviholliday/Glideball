#!/bin/zsh
# Every check that should pass before Glideball ships, in one command. Never
# runs the real app: the app checks use the sandboxed --self-test and
# --render-ui modes (Sources/Glide/Sandbox/).
#
#   scripts/check.sh            all of it (a few minutes)
#   scripts/check.sh -v         also show each step's output as it runs
#
# Steps (each one's output goes to build/check/<step>.log):
#   build        swift build -c release
#   scroll-sim   scripts/scroll-sim/run.sh       the scroll engine, on synthetic ticks
#   backup-sim   scripts/backup-sim/run.sh       backup retention over 18 months
#   command-sim  scripts/command-sim/run.sh      glideball:// URLs, good and hostile, and status.json
#   gesture-sim  scripts/gesture-sim/run.sh      gesture buttons, including unplug/pause mid-gesture
#   device-sim   scripts/device-sim/run.sh       per-display speed, connection types, battery notices
#   l10n         scripts/l10n/check.py           every translation complete, no repeated keys
#   website      the website's function tests    (npm ci first if website/node_modules is missing)
#   admin        the admin site's tests          its proxy against the real admin function, its pages and policy
#   site         build_pages.py + check_site.py  in a copy of website/, so nothing here changes
#   self-test    scripts/self-test.sh            the real launch path, sandboxed, twice
#   render-ui    every screen drawn once         all pictures made, none blank
#
# Prints a pass/fail line per step and a summary; exits 1 if anything failed.
setopt pipe_fail no_unset
ROOT=${0:A:h:h}
cd "$ROOT"

VERBOSE=0
for arg in "$@"; do
  case $arg in
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "unknown option: $arg"; exit 64 ;;
  esac
done

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' DIM=$'\e[2m' RESET=$'\e[0m'
else
  BOLD='' RED='' GREEN='' YELLOW='' DIM='' RESET=''
fi

LOGS=build/check
rm -rf "$LOGS"; mkdir -p "$LOGS"
typeset -a passed failed skipped notes
started=$SECONDS

# run <name> <description> <command…>: runs it, logs it, records the result.
run() {
  local name=$1 what=$2; shift 2
  local log="$LOGS/$name.log" t0=$SECONDS rc
  printf '%s▸ %-11s%s %s%s%s\n' "$BOLD" "$name" "$RESET" "$DIM" "$what" "$RESET"
  if (( VERBOSE )); then
    "$@" 2>&1 | tee "$log"; rc=$?
  else
    "$@" >"$log" 2>&1; rc=$?
  fi
  local secs=$(( SECONDS - t0 ))
  if (( rc == 0 )); then
    passed+=("$name")
    printf '  %s✓ passed%s %s(%ds)%s\n' "$GREEN" "$RESET" "$DIM" "$secs" "$RESET"
  else
    failed+=("$name")
    printf '  %s✗ FAILED%s (exit %d, %ds) — last lines of %s:\n' "$RED" "$RESET" "$rc" "$secs" "$log"
    tail -n 15 "$log" | sed 's/^/      /'
  fi
  return $rc
}

skip() { skipped+=("$1"); printf '%s▸ %-11s%s %sskipped: %s%s\n' "$BOLD" "$1" "$RESET" "$YELLOW" "$2" "$RESET"; }

# ---------------------------------------------------------------- steps

run build "swift build -c release" swift build -c release
built=$?

run scroll-sim "scroll engine simulator" scripts/scroll-sim/run.sh
run backup-sim "backup retention simulator" scripts/backup-sim/run.sh
run command-sim "glideball:// URLs and status.json, good and hostile" scripts/command-sim/run.sh
run gesture-sim "gesture buttons: scripted, hostile and random events" scripts/gesture-sim/run.sh
run device-sim "per-display speed, connection types, low-battery notices" scripts/device-sim/run.sh
run l10n "translations: complete, no repeated keys" python3 scripts/l10n/check.py

website_tests() (   # a subshell: the cd stays in here
  cd website
  if [[ ! -d node_modules ]]; then
    print "website/node_modules is missing; running npm ci"
    npm ci --no-audit --no-fund || return 1
  fi
  # Every tests/*.test.mjs (usage, stats, and any added later), each in its own process.
  npm run -s test || return 1
)
admin_tests() (
  cd website
  [[ -d node_modules ]] || npm ci --no-audit --no-fund || return 1
  node --check ../admin-site/netlify/edge-functions/admin-proxy.js || return 1
  npm run -s test:admin || return 1
)
if command -v npm >/dev/null; then
  run website "website function tests (npm)" website_tests
  run admin "admin site: proxy, pages, policy (admin-site/)" admin_tests
else
  failed+=(website admin); print "${RED}✗ website, admin: npm isn't installed${RESET}"
fi

# Builds the pages in a copy, so a check never changes committed files. If the
# copy differs from what's committed, the pages are only out of date: a note.
site_check() {
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/glideball-site.XXXXXX") || return 1
  mkdir -p "$tmp/scripts"
  cp scripts/build_pages.py scripts/check_site.py scripts/releases-cache.json "$tmp/scripts/"
  rsync -a --exclude node_modules --exclude .netlify website/ "$tmp/website/" || return 1
  python3 "$tmp/scripts/build_pages.py" || { rm -rf "$tmp"; return 1; }
  python3 "$tmp/scripts/check_site.py" || { rm -rf "$tmp"; return 1; }
  local stale
  stale=$(diff -rq --exclude node_modules --exclude .netlify website "$tmp/website" 2>/dev/null | wc -l | tr -d ' ')
  rm -rf "$tmp"
  if (( stale > 0 )); then
    print "note: $stale file(s) in website/ differ from a fresh build_pages.py (new releases in the changelog?)"
    print "STALE"
  fi
}
run site "website pages build and every link checks out" site_check
grep -q '^STALE$' "$LOGS/site.log" 2>/dev/null \
  && notes+=("website/ is behind a fresh build_pages.py (usually just the changelog): run python3 scripts/build_pages.py and commit")

if (( built == 0 )); then
  run self-test "the launch path, sandboxed (first launch and returning user)" scripts/self-test.sh --no-build

  render_smoke() {
    local out=build/check/screens
    scripts/render-ui.sh "$out" --no-build --appearance dark --scale 1 || return 1
    # Every picture the manifest lists exists and isn't empty; every screen has one.
    python3 - "$out" <<'PY' || return 1
import json, os, sys
out = sys.argv[1]
m = json.load(open(os.path.join(out, "manifest.json")))
pics = m["pictures"]
missing = [p["file"] for p in pics if not os.path.getsize(os.path.join(out, p["file"])) > 0] if pics else ["(none)"]
pngs = [f for f in os.listdir(out) if f.endswith(".png")]
if missing or len(pngs) != len(pics):
    sys.exit(f"render-ui smoke: {len(pics)} in the manifest, {len(pngs)} PNGs, missing/empty: {missing}")
print(f"render-ui smoke: {len(pics)} pictures, all present and non-blank")
PY
  }
  run render-ui "every screen drawn offscreen, none blank" render_smoke
else
  skip self-test "the build failed"
  skip render-ui "the build failed"
  failed+=(self-test render-ui)
fi

# ---------------------------------------------------------------- summary

total=$(( SECONDS - started ))
print ""
print "${BOLD}Summary${RESET} ($(( total / 60 ))m $(( total % 60 ))s; logs in $LOGS/)"
for n in $passed; do print "  ${GREEN}✓${RESET} $n"; done
for n in $failed; do print "  ${RED}✗${RESET} $n"; done
for n in $notes; do print "  ${YELLOW}note:${RESET} $n"; done
if (( ${#failed} )); then
  print "\n${RED}${BOLD}CHECKS FAILED${RESET} (${#failed}): ${(j:, :)${(u)failed}}"
  exit 1
fi
print "\n${GREEN}${BOLD}ALL CHECKS PASSED${RESET}"
