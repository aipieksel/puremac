#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_build="$(mktemp -d "${TMPDIR:-/tmp}/puremac-performance.XXXXXX")"
trap 'rm -rf "$check_build"' EXIT
cd "$project_root"
check_arch="$(uname -m)"

compile_and_run() {
  local name="$1"
  shift
  swiftc -O -parse-as-library -target "$check_arch-apple-macosx13.0" \
    -module-cache-path "$check_build/module-cache" \
    "$@" -o "$check_build/$name"
  "$check_build/$name"
}

# Let swiftc and the fixtures use the same explicitly selected temporary volume.
export TMPDIR="$check_build/"

compile_and_run normalization \
  PureMac/Logic/Scanning/StringNormalization.swift \
  scripts/performance/NormalizationBenchmark.swift

compile_and_run cancellation \
  PureMac/Models/SpaceTableModels.swift \
  PureMac/Services/SpaceTableScanner.swift \
  PureMac/Services/Subprocess.swift \
  PureMac/Logic/Utilities/ScanUtilities.swift \
  scripts/performance/IndexCancellationChecks.swift

compile_and_run publication \
  PureMac/Models/SpaceTableModels.swift \
  PureMac/Services/SpaceTableScanner.swift \
  PureMac/Services/Subprocess.swift \
  PureMac/Logic/Utilities/ScanUtilities.swift \
  PureMac/Services/SpaceTableIndexStore.swift \
  PureMac/ViewModels/SpaceTableViewModel.swift \
  PureMac/Logic/Scanning/Conditions.swift \
  PureMac/Logic/Scanning/StringNormalization.swift \
  PureMac/Logic/Scanning/Locations.swift \
  scripts/performance/IndexPublicationBenchmark.swift

compile_and_run discovery \
  PureMac/Logic/Scanning/AppInfoFetcher.swift \
  scripts/performance/AppDiscoveryChecks.swift

compile_and_run pipe-patterns scripts/performance/ProcessPipeChecks.swift

compile_and_run space-table \
  PureMac/Models/SpaceTableModels.swift \
  PureMac/Services/SpaceTableScanner.swift \
  PureMac/Services/Subprocess.swift \
  PureMac/Logic/Utilities/ScanUtilities.swift \
  scripts/performance/SpaceTableBenchmark.swift

compile_and_run subprocess \
  PureMac/Services/Subprocess.swift \
  PureMac/Services/SpaceTableScanner.swift \
  PureMac/Models/SpaceTableModels.swift \
  PureMac/Logic/Utilities/ScanUtilities.swift \
  scripts/performance/SubprocessChecks.swift

"$project_root/scripts/performance/run-implementation.sh"

"$project_root/scripts/performance/run-preview-ordering.sh"

"$project_root/scripts/performance/run-space-table-latency.sh"
