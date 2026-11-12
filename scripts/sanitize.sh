#!/bin/zsh
# Builds Glideball and the engine fuzzer with a sanitizer and runs what can run
# safely: the sandboxed self-test (both launches) and the engine fuzzer, including
# its multi-threaded mode. Never runs the real app.
#
#   scripts/sanitize.sh            thread sanitizer (data races between the input
#                                  thread, the key queue, the UI and background queues)
#   scripts/sanitize.sh address    address sanitizer (memory errors)
#
# Reports land in build/sanitize/<kind>-*.log; the script prints how many warnings
# each run had and exits 1 if any did. Needs a few GB free (its own build folder).
setopt pipe_fail no_unset
ROOT=${0:A:h:h}
cd "$ROOT"
KIND=${1:-thread}
case $KIND in thread|address) ;; *) print -u2 "usage: $0 [thread|address]"; exit 64 ;; esac
OUT=build/sanitize
mkdir -p $OUT
rc=0

print "▸ swift build --sanitize $KIND (debug, .build-$KIND)"
swift build -c debug --sanitize $KIND --build-path .build-$KIND >$OUT/$KIND-build.log 2>&1 \
  || { tail -20 $OUT/$KIND-build.log; exit 1; }
EXE=$(scripts/sandbox-app.sh .build-$KIND/debug/Glide)

export TSAN_OPTIONS="halt_on_error=0 second_deadlock_stack=1"
export ASAN_OPTIONS="halt_on_error=0 detect_leaks=0"
for mode in first returning; do
  log=$OUT/$KIND-self-test-$mode.log
  args=(--self-test --timeout 240)   # sanitized debug builds run several times slower
  [[ $mode == returning ]] && args+=(--returning)
  # perl's alarm: an outside limit in case the app's own watchdog can't fire (sanitized builds are slow).
  perl -e 'alarm shift; exec @ARGV' 300 "$EXE" $args >$log 2>&1 || { print "  self-test ($mode) failed, see $log"; rc=1; }
done

flag=--tsan; [[ $KIND == address ]] && flag=--asan
scripts/engine-fuzz/run.sh $flag --threads --seconds 20 >$OUT/$KIND-engine-threads.log 2>&1 || { print "  engine threads failed"; rc=1; }
scripts/engine-fuzz/run.sh $flag --seeds 1-20 --events 5000 >$OUT/$KIND-engine-fuzz.log 2>&1 || { print "  engine fuzz failed"; rc=1; }

for log in $OUT/$KIND-*.log; do
  [[ $log == *-build.log ]] && continue
  n=$(grep -c "WARNING: ThreadSanitizer\|ERROR: AddressSanitizer" $log)
  printf '  %-45s %s warnings\n' ${log:t} $n
  (( n > 0 )) && rc=1
done
exit $rc
