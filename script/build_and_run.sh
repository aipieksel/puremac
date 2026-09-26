#!/bin/bash
# Local, host-architecture build using Command Line Tools; no release publishing.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mode="${1:---verify}"
case "$mode" in --build|--install|--verify|run) ;; *) echo 'Usage: script/build_and_run.sh [--build|--install|--verify]'; exit 2;; esac
mkdir -p _work/local-app
run="$(mktemp -d "$root/_work/local-app/build.XXXXXX")"
app="$run/PureMac.app"
vendor="$root/_work/local-app/vendor"
mkdir -p "$vendor" "$app/Contents/"{MacOS,Resources,Frameworks}
if [[ ! -d "$vendor/Sparkle.framework" ]]; then
  archive="$vendor/Sparkle-2.9.4.tar.xz"
  curl -fL 'https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-2.9.4.tar.xz' -o "$archive"
  echo "ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9  $archive" | shasum -a 256 -c -
  tar -xf "$archive" -C "$vendor" ./Sparkle.framework
fi
codesign --verify --deep --strict "$vendor/Sparkle.framework"
ditto "$vendor/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
python3 - "$run" <<'PY'
import hashlib,json,pathlib,plistlib,re,shutil,sys
root=pathlib.Path.cwd(); run=pathlib.Path(sys.argv[1]); app=run/'PureMac.app/Contents'
sources=sorted(root.glob('PureMac/**/*.swift'))
(run/'sources.txt').write_text('\n'.join(json.dumps(str(p)) for p in sources))
(run/'source-hashes.json').write_text(json.dumps({str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},indent=2))
settings=(root/'project.yml').read_text()
value=lambda key: re.search(r'^\s*'+key+r': "([^"]+)"',settings,re.M).group(1)
info=plistlib.loads((root/'PureMac/Info.plist').read_bytes())
values={'EXECUTABLE_NAME':'PureMac','PRODUCT_BUNDLE_IDENTIFIER':value('PRODUCT_BUNDLE_IDENTIFIER'),'MARKETING_VERSION':value('MARKETING_VERSION'),'CURRENT_PROJECT_VERSION':value('CURRENT_PROJECT_VERSION'),'MACOSX_DEPLOYMENT_TARGET':value('MACOSX_DEPLOYMENT_TARGET')}
for k,v in info.items():
 if isinstance(v,str):
  for name,replacement in values.items(): v=v.replace('$('+name+')',replacement)
  info[k]=v
info.update(CFBundleIconFile='AppIcon',NSPrincipalClass='NSApplication',PureMacBuildFlavor='Local optimized Command Line Tools build')
(app/'Info.plist').write_bytes(plistlib.dumps(info))
for folder in (root/'PureMac').glob('*.lproj'): shutil.copytree(folder,app/'Resources'/folder.name)
icons=run/'AppIcon.iconset';icons.mkdir()
for p in (root/'PureMac/Assets.xcassets/AppIcon.appiconset').glob('*.png'):
 name=re.sub(r'icon_(\d+)',lambda m:f'icon_{m[1]}x{m[1]}',p.name)
 shutil.copy2(p,icons/name)
shutil.copy2(root/'LICENSE',app/'Resources/LICENSE.txt')
PY
iconutil -c icns "$run/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
echo "Building optimized $(uname -m) app; log: $run/build.log"
if ! xcrun swiftc -O -whole-module-optimization -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macosx13.0" -module-name PureMac \
  -F "$vendor" -framework Sparkle @"$run/sources.txt" \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app/Contents/MacOS/PureMac" >"$run/build.log" 2>&1; then
  tail -60 "$run/build.log"; exit 1
fi
# Ad-hoc signing by default. Never read the machine keychain for a personal
# Apple Development identity. Set PUREMAC_SIGN_IDENTITY explicitly to sign.
identity="${PUREMAC_SIGN_IDENTITY:--}"
codesign --force --sign "$identity" --timestamp=none --entitlements PureMac/PureMac.entitlements "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
ditto -c -k --keepParent "$app" "$run/PureMac-local.zip"
printf '%s\n' "$run" > _work/local-app/latest-build.txt
echo "Packaged: $run/PureMac-local.zip"
[[ "$mode" == --build ]] && exit 0
launch="$app"
if [[ "$mode" == --install ]]; then
  # Finish and verify the replacement before touching the running installation.
  staged="/Applications/.PureMac-stage-$(basename "$run").app"
  ditto "$app" "$staged"
  codesign --verify --deep --strict "$staged"
  if pgrep -x PureMac >/dev/null; then
    pkill -TERM -x PureMac
    for attempt in {1..50}; do pgrep -x PureMac >/dev/null || break; sleep 0.2; done
    if pgrep -x PureMac >/dev/null; then echo 'PureMac did not quit; installation left unchanged.'; exit 1; fi
  fi
  if [[ -e /Applications/PureMac.app ]]; then
    mv /Applications/PureMac.app "$run/Previous-PureMac.app"
    echo "Previous app preserved: $run/Previous-PureMac.app"
  fi
  if ! mv "$staged" /Applications/PureMac.app; then
    [[ ! -e "$run/Previous-PureMac.app" ]] || mv "$run/Previous-PureMac.app" /Applications/PureMac.app
    exit 1
  fi
  launch=/Applications/PureMac.app
else
  pkill -TERM -x PureMac >/dev/null 2>&1 || true
fi
open -n "$launch"
sleep 3
pgrep -x PureMac >/dev/null
echo "Launched: $launch"
