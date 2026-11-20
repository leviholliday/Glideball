#!/bin/zsh
# "Allow AI apps": compiles the real answering code (AIApps.swift), the real
# socket (AIAppsSocket.swift) and the real MCP helper (AIAppsHelper.swift) with a
# fake Glideball, and plays a fake AI app against them: good, malformed,
# oversized, deeply nested, flooding and out-of-window messages. The socket is
# made in a temp folder, never in Application Support, and no AI app is involved.
# If .build/release/Glide exists it also runs that as `--mcp` (the handshake and
# the tool list only, which never reach for a running Glideball).
set -e
cd "$(dirname "$0")/../.."
OUT="${TMPDIR:-/tmp}/glide-mcp-sim"
swiftc -O -swift-version 5 -o "$OUT" \
  Sources/Glide/Config.swift \
  Sources/Glide/AppProfile.swift \
  Sources/Glide/ImportSafety.swift \
  Sources/Glide/SharedSetup.swift \
  Sources/Glide/ImportReview.swift \
  Sources/Glide/SetupCode.swift \
  Sources/Glide/SetupCodeReader.swift \
  Sources/Glide/AIReference.swift \
  Sources/Glide/KensingtonWorks.swift \
  Sources/Glide/DeviceSupport.swift \
  Sources/Glide/DisplayTracking.swift \
  Sources/Glide/ExternalControl.swift \
  Sources/Glide/Commands.swift \
  Sources/Glide/AIApps.swift \
  Sources/Glide/AIAppsSocket.swift \
  Sources/Glide/AIAppsHelper.swift \
  scripts/mcp-sim/main.swift
"$OUT"
