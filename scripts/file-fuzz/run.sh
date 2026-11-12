#!/bin/zsh
# Throws hostile files at everything Glideball reads back (settings import,
# backups, sync, daily totals, the milestone ledger, crash reports, update
# lists) using the real decoding, merging and restoring code, in a temp folder.
#   scripts/file-fuzz/run.sh          the fixed cases and a short random run (~10 s)
#   scripts/file-fuzz/run.sh --deep   a few minutes of random mutations (seed printed;
#                                     --seed N repeats one)
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/glide-file-fuzz-$$"   # per run: a long run and a check can overlap
trap 'rm -f "$OUT"' EXIT
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/Config.swift \
  Sources/Glide/AppProfile.swift \
  Sources/Glide/BackupStore.swift \
  Sources/Glide/SettingsSync.swift \
  Sources/Glide/CrashReports.swift \
  Sources/Glide/Milestones.swift \
  Sources/Glide/Telemetry.swift \
  Sources/Glide/RandomID.swift \
  Sources/Glide/DeviceBattery.swift \
  scripts/file-fuzz/stubs.swift \
  scripts/file-fuzz/main.swift
set +e
"$OUT" "$@"
code=$?
if (( code > 128 )); then
  echo "FAIL: the fuzzer crashed (signal $((code - 128))). FUZZ_TRACE=1 $0 $* names each case as it starts."
fi
exit $code
