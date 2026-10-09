#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH="${1:?Usage: direct-simulator.sh WATCH_SIM_ID PHONE_SIM_ID}"
PHONE="${2:?Supply paired phone simulator ID}"
WORK="${DOTWATCH_WORK_DIR:-$ROOT/work/direct-watch-simulator}"
DURATION="${DOTWATCH_PROBE_DURATION:-15}"
MODE="${DOTWATCH_PROBE_MODE:-normal}"
PLATFORM="${DOTWATCH_PROBE_PLATFORM:-watch}"
ENTRY="${DOTWATCH_PROBE_ENTRY:-siri}"
if [[ "$ENTRY" != siri && "$ENTRY" != widget ]]; then echo "Entry must be siri or widget" >&2; exit 2; fi
ENTRY_FLAG=--siri-probe
if [ "$ENTRY" != siri ]; then ENTRY_FLAG=--widget-probe; fi
if [ "$PLATFORM" = phone ]; then
  DEVICE="$PHONE"; SCHEME=DotWatchPhone; SDK=iphonesimulator; BUNDLE="${DOTWATCH_BUNDLE_ID:-com.example.dotwatch}"; DEST="platform=iOS Simulator,id=$PHONE"
else
  DEVICE="$WATCH"; SCHEME=DotWatchWatch; SDK=watchsimulator; BUNDLE="${DOTWATCH_BUNDLE_ID:-com.example.dotwatch}.watchkitapp"; DEST="platform=watchOS Simulator,id=$WATCH"
fi
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
PYTHON="${DOTWATCH_TEST_PYTHON:-$WORK/venv/bin/python}"
if [ ! -x "$PYTHON" ]; then
  python3.13 -m venv "$WORK/venv"
  "$PYTHON" -m pip -q install --only-binary=:all: aiortc==1.15.0 numpy==2.5.3 >"$WORK/dependencies.log" 2>&1
fi
BUILD_DIR="${DOTWATCH_BUILD_DIR:-$WORK/build}"
if [ "${DOTWATCH_SKIP_BUILD:-0}" != 1 ]; then
bash "$ROOT/Tools/build-neteq.sh"
CONFIG_ARGS=()
if [ -n "${DOTWATCH_CONFIG:-}" ]; then CONFIG_ARGS=(--config "$DOTWATCH_CONFIG"); fi
python3 "$ROOT/Tools/configure.py" "${CONFIG_ARGS[@]}"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" >"$WORK/generate.log" 2>&1
xcodebuild -project "$ROOT/DotWatch.xcodeproj" -scheme "$SCHEME" -destination "$DEST" -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO build >"$WORK/build.log" 2>&1
fi
xcrun simctl terminate "$PHONE" "${DOTWATCH_BUNDLE_ID:-com.example.dotwatch}" >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE" "$BUILD_DIR/Build/Products/Debug-$SDK/$SCHEME.app"
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)"
PROBE="$CONTAINER/Documents/DirectProbe"
mkdir -p "$PROBE"
rm -f "$PROBE/offer.sdp" "$PROBE/answer.sdp" "$PROBE/done" "$PROBE/stopped" "$PROBE/watch-result.json" "$PROBE/peer-result.json" "$PROBE/ready-for-widget"
"$PYTHON" "$ROOT/Tools/direct-peer.py" "$PROBE" "$DURATION" "$MODE" >"$WORK/peer.log" 2>&1 &
PEER_PID=$!
cleanup() {
  kill "$PEER_PID" >/dev/null 2>&1 || true
  xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl launch --terminate-running-process --console-pty "$DEVICE" "$BUNDLE" --direct-probe --simulated-audio --without-watch-callkit "$ENTRY_FLAG" --probe-duration "$DURATION" >"$WORK/watch.log" 2>&1 &
for ((n=0;n<DURATION+240;n++)); do
  if [ -f "$PROBE/done" ]; then break; fi
  sleep 1
done
if [ ! -f "$PROBE/done" ]; then
  echo "Simulator probe timed out before completing ($ENTRY entry)." >&2
  exit 1
fi
wait "$PEER_PID"
"$PYTHON" - "$PROBE" "$WORK" "$MODE" "$PLATFORM" "$DURATION" "$ENTRY" <<'PY'
import json,pathlib,sys
p,w=map(pathlib.Path,sys.argv[1:3]); mode,platform=sys.argv[3:5]; duration=int(sys.argv[5]); entry=sys.argv[6]
a=json.loads((p/'watch-result.json').read_text()); b=json.loads((p/'peer-result.json').read_text())
if mode in ('disconnect', 'blackhole'):
 assert not a['connected'] and a['error'], a
 assert b['disconnectAt'] and b['finishedAt']-b['disconnectAt']<35, b
else:
 assert a['connected'] and not a['error'], a
 assert b['frames']>(duration-3)*40, b
assert a['receivedPackets']>100 and a['decodedPeak']>1000, a
assert b['frames']>100 and b['peak']>1000 and b['channel'], b
assert b['secondPeaks'].get('7',10000)<100 and b['secondPeaks'].get('8',10000)<100, b
assert b['secondPeaks'].get('2',0)>1000 and b['secondPeaks'].get('12',0)>1000, b
assert (p/'stopped').exists(), 'Cloud cleanup not requested'
result={'device':platform,'call':a,'peer':b,'audioHardwareUsed':False,'callKitSubstituted':True,'appIntentInvoked':entry=='siri','entry':entry,'mode':mode,'duration':duration}
(w/'result.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result))
PY
