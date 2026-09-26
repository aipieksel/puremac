#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
check_build="$(mktemp -d "${TMPDIR:-/tmp}/puremac-implementation.XXXXXX")"
trap 'rm -rf "$check_build"' EXIT
export TMPDIR="$check_build/"
# Compile production sources intact; only replace the app entry point with the
# fixture entry point. AppState startup is disabled and all mutations use fixtures.
python3 - "$check_build" <<'PY'
from pathlib import Path
import sys
build=Path(sys.argv[1])
entry=build/'AppEntry.swift'
entry.write_text(Path('PureMac/PureMacApp.swift').read_text().replace('@main\n',''))
sources=[str(p) for p in sorted(Path('PureMac').rglob('*.swift')) if p.name != 'PureMacApp.swift']
# Response files require quoted paths for the external volume's spaces.
import json
(build/'sources.txt').write_text('\n'.join(json.dumps(p) for p in sources+[str(entry),'scripts/performance/ImplementationChecks.swift']))
PY
swiftc -whole-module-optimization -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  @"$check_build/sources.txt" -o "$check_build/implementation-checks"
"$check_build/implementation-checks"
