#!/bin/zsh
# Throws hostile input at Glideball's updater (Sources/Glide/UpdateChecker.swift), offline:
# malformed, huge and deeply nested release lists, odd and downgrading versions, zips with
# path traversal, links, bombs and truncation, apps with the wrong version, identifier,
# signature or a tampered file, and the install helper's script with awkward folder names.
# The real parsing, unpacking and signature code runs against fixtures in a temp folder.
# Nothing touches the network, and nothing is installed or launched (the install script
# runs against a fake `open`). Automatic updates (Sources/Glide/AutoUpdate.swift): the safe-moment
# decision, the bookkeeping, and the real updater staging, replacing and dropping a download
# against a stub server, with a stand-in for the restart.
#   scripts/update-fuzz/run.sh          the fixed cases and a short random run (~30 s)
#   scripts/update-fuzz/run.sh --deep   a few minutes of random mutations (seed printed;
#                                       --seed N repeats one; --budget SECONDS is the hard limit)
#   scripts/update-fuzz/run.sh --live   NOT offline, not in check.sh: fetches GitHub's real release list, downloads the
#                                       newest prerelease's Glideball-update.zip through startDownload on URLSession.shared,
#                                       prepare()s it against /Applications/Glideball.app's designated requirement (read
#                                       only), prints each stage, and deletes the temp folder. Installs and launches nothing.
set -e
cd "$(dirname "$0")/../.."
WORK=$(mktemp -d "${TMPDIR:-/tmp}/glide-update-fuzz.XXXXXX")
OUT="$WORK/fuzz"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/UpdateChecker.swift \
  Sources/Glide/AutoUpdate.swift \
  Sources/Glide/Telemetry.swift \
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
