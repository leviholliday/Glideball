#!/bin/zsh
# Throws hostile files at everything Glideball reads back (settings import,
# shared setups and their links, KensingtonWorks' settings, backups, sync,
# daily totals, the milestone ledger, crash reports, update lists) using the
# real decoding, merging and restoring code, in a temp folder.
#   scripts/file-fuzz/run.sh          the fixed cases and a short random run (~10 s)
#   scripts/file-fuzz/run.sh --deep   every fixed case, then 3 minutes of random mutations (seed
#                                     printed; --seed N repeats one); prints progress
# A watchdog stops the run, naming the case, if nothing finishes for 30 s or the whole run
# passes its budget (5 minutes quick, 25 deep; --budget SECONDS changes it). Generated files
# are capped at 20,000 nodes / 1 MB / 2 s each.
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
  Sources/Glide/ImportSafety.swift \
  Sources/Glide/SharedSetup.swift \
  Sources/Glide/SharingName.swift \
  Sources/Glide/KensingtonWorks.swift \
  Sources/Glide/ImportReview.swift \
  Sources/Glide/DeviceSupport.swift \
  scripts/file-fuzz/stubs.swift \
  scripts/file-fuzz/main.swift
set +e
"$OUT" "$@"
code=$?
if (( code > 128 )); then
  echo "FAIL: the fuzzer crashed (signal $((code - 128))). FUZZ_TRACE=1 $0 $* names each case as it starts."
fi
exit $code
