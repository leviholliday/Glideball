#!/bin/zsh
# Compiles the real gesture decision code (Gestures.swift) and the settings model
# with a harness that wires them up the way Engine.swift does, then throws
# scripted and random button and ball events at them, hostile ones included.
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/glide-gesture-sim"
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/Gestures.swift \
  Sources/Glide/Config.swift \
  Sources/Glide/AppProfile.swift \
  Sources/Glide/ImportSafety.swift \
  scripts/gesture-sim/main.swift
"$OUT"
