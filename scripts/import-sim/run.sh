#!/bin/zsh
# Compiles the real import code (settings files, shared setups and their
# glideball://import links, KensingtonWorks) with a harness, and throws good,
# round-trip and hostile input at it. Fixtures: scripts/import-sim/fixtures.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/glide-import-sim"
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/Config.swift \
  Sources/Glide/AppProfile.swift \
  Sources/Glide/ImportSafety.swift \
  Sources/Glide/SharedSetup.swift \
  Sources/Glide/ImportReview.swift \
  Sources/Glide/KensingtonWorks.swift \
  Sources/Glide/DeviceSupport.swift \
  scripts/import-sim/main.swift
"$OUT" scripts/import-sim/fixtures
