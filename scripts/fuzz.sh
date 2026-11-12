#!/bin/zsh
# The long fuzz run: what scripts/check.sh does in seconds, for as long as you like.
# Never runs the real app; everything is the real code against fakes and temp folders.
#
#   scripts/fuzz.sh                 10 minutes of engine fuzzing, the deep file fuzz,
#                                   and a minute of the engine's threads
#   scripts/fuzz.sh --minutes 60    an hour of engine fuzzing instead
#   scripts/fuzz.sh --tsan          also everything under the thread sanitizer (slow build)
#
# Logs go to build/fuzz/; a failure prints its seed and a minimized list of events
# (replay one with scripts/engine-fuzz/run.sh --seed N --events 20000, or
# FUZZ_TRACE=1 in front for a play-by-play). Exits 1 if anything failed.
setopt pipe_fail no_unset
ROOT=${0:A:h:h}
cd "$ROOT"
MINUTES=10
TSAN=0
while (( $# )); do
  case $1 in
    --minutes) MINUTES=$2; shift ;;
    --tsan) TSAN=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "unknown option: $1"; exit 64 ;;
  esac
  shift
done
OUT=build/fuzz
mkdir -p $OUT
rc=0
started=$SECONDS

step() {
  local name=$1; shift
  print "▸ $name"
  if "$@" >$OUT/$name.log 2>&1; then
    print "  ✓ $(tail -1 $OUT/$name.log)"
  else
    rc=1
    print "  ✗ FAILED — $OUT/$name.log:"
    grep -A40 "✗" $OUT/$name.log | head -60 | sed 's/^/    /'
  fi
}

step engine-fuzz scripts/engine-fuzz/run.sh --seeds 1-200 --events 20000 --minutes $MINUTES
step engine-threads scripts/engine-fuzz/run.sh --threads --seconds 60
step file-fuzz scripts/file-fuzz/run.sh --deep
(( TSAN )) && step sanitize scripts/sanitize.sh thread

print "done in $(( (SECONDS - started) / 60 )) min: $([[ $rc == 0 ]] && print 'all rules held' || print 'FAILURES above')"
exit $rc
