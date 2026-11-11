#!/bin/zsh
# Compiles the real command registry, glideball:// parser and status.json
# writer with a fake app, and throws good, bad and hostile URLs at them.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/glide-command-sim"
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/Commands.swift \
  Sources/Glide/ExternalControl.swift \
  Sources/Glide/StatusFile.swift \
  Sources/Glide/Config.swift \
  Sources/Glide/AppProfile.swift \
  scripts/command-sim/main.swift
"$OUT"
