#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
benchmark_build="$(mktemp -d "${TMPDIR:-/tmp}/puremac-benchmark.XXXXXX")"
trap 'rm -rf "$benchmark_build"' EXIT
scanner_source="${1:-$project_root/PureMac/Services/SpaceTableScanner.swift}"
swiftc -O -parse-as-library \
  "$project_root/PureMac/Models/SpaceTableModels.swift" \
  "$scanner_source" \
  "$project_root/PureMac/Services/Subprocess.swift" \
  "$project_root/PureMac/Logic/Utilities/ScanUtilities.swift" \
  "$project_root/scripts/performance/SpaceTableBenchmark.swift" \
  -o "$benchmark_build/space-table-benchmark"
"$benchmark_build/space-table-benchmark"
