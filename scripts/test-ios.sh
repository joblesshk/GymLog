#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
xcodegen generate --spec "$repo_root/GymLog/project.yml"
if [[ -n "${GYMLOG_SIMULATOR_ID:-}" ]]; then
    simulator_id="$GYMLOG_SIMULATOR_ID"
else
    simulator_id="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); devices=[v for k,vs in d["devices"].items() if "iOS" in k for v in vs if "iPhone" in v["name"] and v.get("isAvailable",False)]; print(next((v["udid"] for v in devices if v["state"]=="Booted"), devices[0]["udid"] if devices else ""))')"
fi
if [[ -z "$simulator_id" ]]; then
    echo 'Install an iPhone Simulator runtime in Xcode before testing.' >&2
    exit 1
fi
xcodebuild -project "$repo_root/GymLog/GymLog.xcodeproj" -scheme GymLogKitTests \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "${GYMLOG_DERIVED_DATA:-/tmp/gymlog-tests}" \
    CODE_SIGNING_ALLOWED=NO test
xcodebuild -project "$repo_root/GymLog/GymLog.xcodeproj" -scheme GymLog \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${GYMLOG_DERIVED_DATA:-/tmp/gymlog-tests}" \
    CODE_SIGNING_ALLOWED=NO build
