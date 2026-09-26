#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
verify_root="$project_root/_work/performance-verification"
framework_root="$verify_root/vendor"
[[ -d "$framework_root/Sparkle.framework/Headers" ]] || { echo "Extract official Sparkle 2.9.4 into $framework_root first."; exit 1; }
run_root="$(mktemp -d "$verify_root/run.XXXXXX")"
export TMPDIR="$verify_root/tmp/"
export PUREMAC_VERIFY_OUTPUT="$run_root"
app_bundle="$run_root/NativeVerification.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Frameworks" "$app_bundle/Contents/Resources" "$run_root/fixtures/Transaction.app/Contents/MacOS"
cp -R "$framework_root/Sparkle.framework" "$app_bundle/Contents/Frameworks/"
cp -R PureMac/*.lproj "$app_bundle/Contents/Resources/"
python3 - "$run_root" "$app_bundle" <<'PY'
from pathlib import Path
import json,plistlib,sys
run=Path(sys.argv[1]); app=Path(sys.argv[2])
entry=run/'AppEntry.swift'; entry.write_text(Path('PureMac/PureMacApp.swift').read_text().replace('@main\n',''))
sources=[str(p) for p in sorted(Path('PureMac').rglob('*.swift')) if p.name!='PureMacApp.swift']+[str(entry),'scripts/performance/NativeVerification.swift']
(run/'sources.txt').write_text('\n'.join(json.dumps(p) for p in sources))
info=dict(CFBundleExecutable='NativeVerification',CFBundleIdentifier='com.puremac.performance-verification',CFBundleName='PureMac Performance Verification',CFBundlePackageType='APPL',LSMinimumSystemVersion='13.0',NSPrincipalClass='NSApplication',LSUIElement=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
fixture=run/'fixtures/Transaction.app'
(fixture/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='fixture',CFBundleIdentifier='fixture.transaction',CFBundleName='Transaction',CFBundlePackageType='APPL',CFBundleDevelopmentRegion='en')))
for language in ['zz','xx','en']:
 folder=fixture/f'Contents/Resources/{language}.lproj';folder.mkdir(parents=True);(folder/'strings').write_bytes(b'x'*4096)
(run/'fixture.c').write_text('#include <stdio.h>\nint main(void) { puts("fixture-ok"); return 0; }\n')
PY
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 "$run_root/fixture.c" -o "$run_root/fixtures/Transaction.app/Contents/MacOS/fixture"
codesign --force --sign - "$run_root/fixtures/Transaction.app"
swiftc -whole-module-optimization -parse-as-library -target "$(uname -m)-apple-macosx13.0" -F "$framework_root" -framework Sparkle @"$run_root/sources.txt" -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$app_bundle/Contents/MacOS/NativeVerification"
codesign --force --deep --sign - "$app_bundle"
# Launch only the dedicated fixture app. Never stop or replace installed PureMac.
open -n -g -W "$app_bundle" --env "PUREMAC_VERIFY_OUTPUT=$run_root"
cat "$run_root/native-result.txt"
echo "Evidence: $run_root"
[[ "$(head -c 4 "$run_root/native-result.txt")" == PASS ]]
