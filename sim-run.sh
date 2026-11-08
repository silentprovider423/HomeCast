#!/bin/bash
# Baut die App und startet sie im eigenen Simulator, angemeldet per API-Schlüssel (kein Passwort-Tippen).
# Zugang aus einer gitignorten Datei:  .test-account  mit HOMECAST_SERVER=… und HOMECAST_API_KEY=…
#   SIM="HomeCast Test" ./sim-run.sh          (HOMECAST_DEMO=1 ./sim-run.sh für Demodaten)
set -euo pipefail
cd "$(dirname "$0")"
SIM="${SIM:-HomeCast Test}"
UDID=$(xcrun simctl list devices -j | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next(x['udid'] for v in d.values() for x in v if x['name']=='$SIM'))")
[ -f .test-account ] && set -a && source .test-account && set +a
xcodegen generate -q
xcodebuild -project HomeCast.xcodeproj -scheme HomeCast -destination "id=$UDID" -derivedDataPath build -quiet build 2>&1 | grep -E "error:" || true
APP=build/Build/Products/Debug-iphonesimulator/HomeCast.app
test -d "$APP"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
SIMCTL_CHILD_HOMECAST_SERVER="${HOMECAST_SERVER:-}" SIMCTL_CHILD_HOMECAST_API_KEY="${HOMECAST_API_KEY:-}" \
SIMCTL_CHILD_HOMECAST_DEMO="${HOMECAST_DEMO:-}" SIMCTL_CHILD_HOMECAST_DEMO_PLAYER="${HOMECAST_DEMO_PLAYER:-}" \
SIMCTL_CHILD_HOMECAST_RESET="${HOMECAST_RESET:-}" SIMCTL_CHILD_HOMECAST_AUTOPLAY="${HOMECAST_AUTOPLAY:-}" \
  xcrun simctl launch --terminate-running-process "$UDID" org.homeroll.homecast >/dev/null
echo "gestartet auf $SIM ($UDID)"
