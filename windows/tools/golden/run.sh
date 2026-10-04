#!/bin/zsh
# Regenerates the Windows tests' golden data from the real Mac sources (needs macOS + swiftc).
set -e
cd "$(dirname "$0")/../../.."
OUT="${TMPDIR:-/tmp}/glide-golden"
mkdir -p windows/tests/Glideball.Core.Tests/Data
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/SmoothScroller.swift \
  Sources/Glide/Config.swift \
  Sources/Glide/Telemetry.swift \
  Sources/Glide/Diagnostics.swift \
  Sources/Glide/AppProfile.swift \
  windows/tools/golden/main.swift
"$OUT" windows/tests/Glideball.Core.Tests/Data
