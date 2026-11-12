#!/bin/zsh
# Compiles the real command registry, glideball:// parser and status.json
# writer with a fake app, and throws good, bad and hostile URLs at them
# (including glideball://import links to shared setups).
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/glide-command-sim"
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/Commands.swift \
  Sources/Glide/ExternalControl.swift \
  Sources/Glide/StatusFile.swift \
  Sources/Glide/Config.swift \
  Sources/Glide/AppProfile.swift \
  Sources/Glide/ImportSafety.swift \
  Sources/Glide/SharedSetup.swift \
  scripts/command-sim/main.swift
"$OUT"
