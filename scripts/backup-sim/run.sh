#!/bin/zsh
# Runs a year and a half of simulated use through the real BackupStore and
# checks the retention rules (daily for 2 weeks, monthly for a year).
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/glide-backup-sim"
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/BackupStore.swift \
  Sources/Glide/Config.swift \
  Sources/Glide/AppProfile.swift \
  scripts/backup-sim/main.swift
"$OUT"
