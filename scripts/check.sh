#!/bin/bash
# Builds and runs the checks (Tests/Checks.swift) against all sources except the app entry point.
# Works only in temporary folders; never touches the real home folder or Docker.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh >/dev/null
FLAGS=(-O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0")
[[ -f build/clt-overlay.yaml ]] && FLAGS+=(-vfsoverlay build/clt-overlay.yaml -Xcc -ivfsoverlay -Xcc build/clt-overlay.yaml)

SOURCES=()
for file in Sources/ClearHub/*.swift; do
  [[ "$file" == */ClearHubApp.swift ]] || SOURCES+=("$file")
done
swiftc "${FLAGS[@]}" -module-name ClearHub -o build/ClearHubChecks "${SOURCES[@]}" Tests/Checks.swift
build/ClearHubChecks
