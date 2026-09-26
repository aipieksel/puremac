#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
check_build="$(mktemp -d "${TMPDIR:-/tmp}/puremac-preview-order.XXXXXX")"
trap 'rm -rf "$check_build"' EXIT
swiftc -whole-module-optimization -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  PureMac/Models/SpaceTableModels.swift PureMac/Services/SpaceTableScanner.swift \
  PureMac/Services/Subprocess.swift PureMac/Logic/Utilities/ScanUtilities.swift \
  PureMac/Services/SpaceTableIndexStore.swift PureMac/ViewModels/SpaceTableViewModel.swift \
  PureMac/Logic/Scanning/Conditions.swift PureMac/Logic/Scanning/StringNormalization.swift \
  PureMac/Logic/Scanning/Locations.swift scripts/performance/PreviewOrderingChecks.swift \
  -o "$check_build/checks"
"$check_build/checks"
