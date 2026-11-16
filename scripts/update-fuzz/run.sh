#!/bin/zsh
# Throws hostile input at Glideball's updater (Sources/Glide/UpdateChecker.swift), offline:
# malformed, huge and deeply nested release lists, odd and downgrading versions, zips with
# path traversal, links, bombs and truncation, apps with the wrong version, identifier,
# signature or a tampered file, and the install helper's script with awkward folder names.
# The real parsing, unpacking and signature code runs against fixtures in a temp folder.
# Nothing touches the network, and nothing is installed or launched (the install script
# runs against a fake `open`).
#   scripts/update-fuzz/run.sh          the fixed cases and a short random run (~30 s)
#   scripts/update-fuzz/run.sh --deep   a few minutes of random mutations (seed printed;
#                                       --seed N repeats one; --budget SECONDS is the hard limit)
set -e
cd "$(dirname "$0")/../.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/glide-update-fuzz.XXXXXX")
OUT="$WORK/fuzz"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/UpdateChecker.swift \
  Sources/Glide/SiteLinks.swift \
  scripts/update-fuzz/stubs.swift \
  scripts/update-fuzz/main.swift
set +e
"$OUT" --helper-dir "$PWD/scripts/update-fuzz" "$@"
code=$?
if (( code > 128 )); then
  echo "FAIL: the fuzzer crashed (signal $((code - 128)))."
fi
exit $code
