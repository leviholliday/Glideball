#!/bin/zsh
# Compiles the real per-display speed code (DisplayTracking.swift), the battery and
# connection rules (DeviceBattery.swift) and the settings model with a harness, and
# checks them: which display the pointer is on and what that costs, the speed
# precedence, displays coming and going, connection types and low-battery notices.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/glide-device-sim"
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/DisplayTracking.swift \
  Sources/Glide/DeviceBattery.swift \
  Sources/Glide/Config.swift \
  Sources/Glide/AppProfile.swift \
  scripts/device-sim/main.swift
"$OUT"
