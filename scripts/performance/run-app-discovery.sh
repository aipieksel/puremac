#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_build="$(mktemp -d "${TMPDIR:-/tmp}/puremac-discovery-check.XXXXXX")"
trap 'rm -rf "$check_build"' EXIT
swiftc -parse-as-library \
  "$project_root/PureMac/Logic/Scanning/AppInfoFetcher.swift" \
  "$project_root/scripts/performance/AppDiscoveryChecks.swift" \
  -o "$check_build/app-discovery-checks"
"$check_build/app-discovery-checks"
