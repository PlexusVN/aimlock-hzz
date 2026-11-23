#!/bin/bash
# A temporary UIKit app uses the real background and navigation helper. No
# production authentication, device identity, backend or protected files run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${VIDEO_BACKGROUND_CHECK_OUTPUT:-${RUNNER_TEMP:-/tmp}/aimlock-video-native-check}"
mkdir -p "$OUT"
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/aimlock-video-harness.XXXXXX")"
APP="$WORK/NativeVideoCheck.app"
mkdir -p "$APP/Backgrounds"
DEVICE_ID=""
cleanup() {
  local result=$?
  if [[ -n "$DEVICE_ID" ]]; then
    python3 "$ROOT/ReleaseTools/simulator_cleanup.py" "$DEVICE_ID" \
      --report "$OUT/cleanup-report.json" || true
  fi
  return "$result"
}
trap cleanup EXIT
python3 - "$ROOT" "$WORK" "$APP" <<'PY'
from pathlib import Path
import sys, plistlib, shutil, hashlib, json
root, work, app = map(Path, sys.argv[1:])
design = (root/'ThreeOneOSFive/views/DesignSystem.swift').read_text()
start = design.index('// NavigationStack can retain an opaque UIKit hosting/transition surface')
end = design.index('struct GamingPressButtonStyle:', start)
(work/'ActualNavigationSurface.swift').write_text('import SwiftUI\nimport UIKit\n'+design[start:end])
shutil.copyfile(root/'ThreeOneOSFive/views/VideoBackground.swift', work/'ActualVideoBackground.swift')
feature = (root/'ThreeOneOSFive/helpers/FeaturePatchService.swift').read_text()
thumbnail = feature.split('// BEGIN FEATURE THUMBNAIL DECODER',1)[1].split('// END FEATURE THUMBNAIL DECODER',1)[0]
(work/'ActualThumbnailDecoder.swift').write_text('import Foundation\nimport UIKit\nimport ImageIO\n'+thumbnail)
for source in (root/'ThreeOneOSFive/Resources/Backgrounds').iterdir():
    if source.suffix in {'.mp4', '.png'}: shutil.copyfile(source, app/'Backgrounds'/source.name)
info = {'CFBundleIdentifier':'site.aimlockhzz.VideoBackgroundCheck', 'CFBundleExecutable':'NativeVideoCheck',
        'CFBundleName':'NativeVideoCheck','CFBundleDisplayName':'Native Video Check',
        'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','CFBundlePackageType':'APPL',
        'LSRequiresIPhoneOS':True,'MinimumOSVersion':'16.0','UIDeviceFamily':[1],
        'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait'], 'UILaunchScreen':{}}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
evidence={'production_video_sha256':hashlib.sha256((work/'ActualVideoBackground.swift').read_bytes()).hexdigest(),
          'production_thumbnail_decoder_sha256':hashlib.sha256(thumbnail.encode()).hexdigest(),
          'production_navigation_helper_sha256':hashlib.sha256(design[start:end].encode()).hexdigest(),
          'scope':'Copied production player source and exact navigation helper; AppTheme color is the only visual dependency stub.'}
(work/'source-evidence.json').write_text(json.dumps(evidence,indent=2))
PY
ARCH="$(uname -m)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library \
  -target "$ARCH-apple-ios16.0-simulator" -sdk "$SDK" \
  "$WORK/ActualVideoBackground.swift" "$WORK/ActualNavigationSurface.swift" "$WORK/ActualThumbnailDecoder.swift" \
  "$ROOT/Tests/VideoBackgroundSimulatorCheck.swift" -o "$APP/NativeVideoCheck"
codesign --force --sign - "$APP"
RUNTIME="$(xcrun simctl list runtimes available -j | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]; assert a,"No iOS simulator runtime"; print(sorted(a,key=lambda x:tuple(map(int,x["version"].split("."))))[-1]["identifier"])')"
TYPE="$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; a=[x for x in json.load(sys.stdin)["devicetypes"] if x["name"].startswith("iPhone 16 Pro")]; assert a,"iPhone 16 Pro simulator unavailable"; print(a[0]["identifier"])')"
DEVICE_ID="$(xcrun simctl create "AimlockVideoCheck-$$" "$TYPE" "$RUNTIME")"
echo "[native-video-check] Booting isolated iPhone simulator"
xcrun simctl boot "$DEVICE_ID"
xcrun simctl bootstatus "$DEVICE_ID" -b
xcrun simctl ui "$DEVICE_ID" appearance dark
xcrun simctl status_bar "$DEVICE_ID" override --time 09:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
xcrun simctl install "$DEVICE_ID" "$APP"
DATA="$(xcrun simctl get_app_container "$DEVICE_ID" site.aimlockhzz.VideoBackgroundCheck data)"
xcrun simctl launch --terminate-running-process "$DEVICE_ID" site.aimlockhzz.VideoBackgroundCheck
python3 - "$DEVICE_ID" "$DATA/Documents" "$OUT" <<'PY'
from pathlib import Path
import sys, json, time, subprocess, shutil
device, documents, output = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
deadline = time.monotonic()+300
seen=set()
while time.monotonic() < deadline:
    path=documents/'report.json'
    if path.exists():
        try: report=json.loads(path.read_text())
        except (json.JSONDecodeError,FileNotFoundError): time.sleep(.2); continue
        pending=report.get('pendingCapture')
        if pending and pending not in seen:
            subprocess.run(['xcrun','simctl','io',device,'screenshot',str(output/(pending+'.png'))],check=True)
            seen.add(pending); (documents/('ack-'+pending)).write_text('captured')
        if report.get('result') in {'PASS','FAIL'}:
            shutil.copyfile(path,output/'report.json')
            print(json.dumps({k:report.get(k) for k in ['result','wraps','decodedFrames','playerCount','failures','captures']},indent=2))
            if report['result']!='PASS': raise SystemExit('Native playback check failed')
            break
    time.sleep(.2)
else:
    if (documents/'report.json').exists(): shutil.copyfile(documents/'report.json',output/'report.json')
    raise SystemExit('Timed out waiting for native simulator check')
PY
cp "$WORK/source-evidence.json" "$OUT/source-evidence.json"
swiftc "$ROOT/Tests/VideoBackgroundScreenshotCheck.swift" -o "$WORK/screenshot-check"
"$WORK/screenshot-check" "$OUT"
echo "[native-video-check] PASS: real AVFoundation loops and settled NavigationStack rendering"
