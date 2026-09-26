#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
build="$(mktemp -d "${TMPDIR:-/tmp}/puremac-latency.XXXXXX")"
trap 'rm -rf "$build"' EXIT
view_model="${1:-PureMac/ViewModels/SpaceTableViewModel.swift}"
swiftc -O -whole-module-optimization -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  PureMac/Models/SpaceTableModels.swift PureMac/Services/SpaceTableScanner.swift \
  PureMac/Services/Subprocess.swift PureMac/Logic/Utilities/ScanUtilities.swift \
  PureMac/Services/SpaceTableIndexStore.swift "$view_model" \
  PureMac/Logic/Scanning/Conditions.swift PureMac/Logic/Scanning/StringNormalization.swift \
  PureMac/Logic/Scanning/Locations.swift scripts/performance/SpaceTableLatencyChecks.swift \
  -o "$build/checks"
"$build/checks"
