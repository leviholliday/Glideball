#!/bin/zsh
# Proves a build launches, without running the real app: the --self-test mode
# (Sources/Glide/Sandbox/SelfTest.swift) runs the real launch path with nothing
# live, twice — as a brand-new Mac's first launch and as a returning user's —
# in a sandbox copy of the app (scripts/sandbox-app.sh). Exits non-zero if
# either run fails, crashes or takes longer than its 60 s limit (a hang guard).
#
#   scripts/self-test.sh             build (swift build -c release), then test
#   scripts/self-test.sh --no-build  test the binary that's already built
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"

if [[ ${1:-} != --no-build ]]; then
  swift build -c release
fi
EXE=$(scripts/sandbox-app.sh)

rc=0
for mode in "" --returning; do
  # perl's alarm is a second, outside limit in case the app's own watchdog can't fire.
  perl -e 'alarm shift; exec @ARGV' 30 "$EXE" --self-test ${mode:+$mode} || rc=1
done
exit $rc
