#!/usr/bin/env bash
# Runs the addon listing matching checks in Tests/Matching.
# They need only SportsMatching.swift and two helpers from SportsGuide.swift (GuideText and
# TeamNames), so they build with plain swiftc on macOS or Linux, without Xcode or the app.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Copy the two helpers out of SportsGuide.swift: each runs from its declaration to the
# first closing brace at the start of a line.
{
  echo "import Foundation"
  for name in GuideText TeamNames; do
    block=$(awk -v start="^enum $name \\\\{" '$0 ~ start {on=1} on {print} on && /^}/ {exit}' Sources/Services/SportsGuide.swift)
    if [ -z "$block" ]; then
      echo "Couldn't find enum $name in Sources/Services/SportsGuide.swift" >&2
      exit 1
    fi
    printf '\n%s\n' "$block"
  done
} > "$work/Helpers.swift"

swiftc -O -o "$work/matching" \
  Sources/Services/SportsMatching.swift "$work/Helpers.swift" Tests/Matching/main.swift
"$work/matching"
