#!/usr/bin/env bash
# TEMPORARY fork-only experiment: why the tvOS 27.0 runtime drops out of
# `simctl list` mid-job, and which step (wait / scan-and-mount / direct boot)
# brings it back. Not for upstream. Prints one "RESULT ..." line; exits 0.
#   exp/tvos-runtime.sh <xcframework>
set -uo pipefail
XCF=$1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d); C="$W/consumer"; mkdir -p "$C/Tests"
cp "$ROOT/Scripts/XCFrameworkTest/Package.swift" "$C/Package.swift"
cp -R "$ROOT/Tests/XCFrameworkTests" "$C/Tests/XCFrameworkTests"
ln -s "$XCF" "$C/P256K.xcframework"
cd "$C" || exit 0
export SWIFT_FORCE_MODULE_LOADING=only-interface
SCHEME=swift-secp256k1-xcframework-consumer-Package
TV_RT=com.apple.CoreSimulator.SimRuntime.tvOS-27-0
BOOT_LIMIT=300   # seconds; bootstatus can wait forever on an unmounted runtime

listed() { xcrun simctl list runtimes -j | jq -r '[.runtimes[] | select(.platform == "tvOS") | .version] | join(",")'; }
images() { xcrun simctl runtime list -j | jq -r '[.[] | select(.platformIdentifier == "com.apple.platform.appletvsimulator") | "\(.version):\(.state):mounted=\(.mountPath != null)"] | join(",")'; }
snap() { echo "SNAP $(date -u +%H:%M:%S) $1 listed=[$(listed)] images=[$(images)]"; }
tv_listed() { [[ ",$(listed)," == *",27.0,"* ]]; }
# with_limit <secs> <cmd...>: run cmd, kill it after secs; returns its status (or 124 on timeout)
with_limit() {
    local secs=$1; shift
    "$@" & local pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local dog=$!
    wait "$pid"; local rc=$?
    kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
    return $rc
}

( while :; do snap mon; sleep 20; done ) > "$W/mon.log" 2>&1 & MON=$!
snap start
for d in "iOS Simulator" "tvOS Simulator"; do
    xcodebuild build-for-testing -scheme "$SCHEME" -destination "generic/platform=$d" -derivedDataPath "$W/dd" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO -quiet || { echo "RESULT build=failed:$d"; exit 0; }
done
snap after-build

ios=$(xcrun simctl list devices -j | jq -r '.devices["com.apple.CoreSimulator.SimRuntime.iOS-27-0"][]? | select(.isAvailable and (.name | startswith("iPhone"))) | .udid' | tail -1)
t=$(date +%s)
xcodebuild test-without-building -scheme "$SCHEME" -destination "platform=iOS Simulator,id=$ios" -derivedDataPath "$W/dd" -resultBundlePath "$W/ios.xcresult" -collect-test-diagnostics never > "$W/ios.log" 2>&1
ios_rc=$?; ios_secs=$(( $(date +%s) - t ))
ios_passed=$(xcrun xcresulttool get test-results summary --path "$W/ios.xcresult" --compact 2>/dev/null | jq -r '.passedTests // "?"')
ios_early=$(grep -c 'Early unexpected exit' "$W/ios.log"); ios_hung=$(grep -c 'hung before establishing connection' "$W/ios.log")
grep -E 'Early unexpected exit|hung before|bootstrapping' "$W/ios.log" | cut -c1-240 | head -4
snap after-ios
xcrun simctl shutdown "$ios" >/dev/null 2>&1
snap after-ios-shutdown

missing=no recovered=n/a
if ! tv_listed; then
    missing=yes recovered=never
    sleep 30; snap wait30
    if tv_listed; then recovered=wait30; else
        t=$(date +%s); xcrun simctl runtime scan-and-mount; echo "scan-and-mount rc=$? secs=$(( $(date +%s) - t ))"
        snap after-scan
        if tv_listed; then recovered=scan; fi
    fi
fi
tv=$(xcrun simctl list devices -j | jq -r --arg rt "$TV_RT" '.devices[$rt][]? | select(.isAvailable and (.name | startswith("Apple TV"))) | .udid' | tail -1)
if [[ $recovered == never && -n $tv ]]; then
    t=$(date +%s); xcrun simctl boot "$tv"; boot_rc=$?
    with_limit "$BOOT_LIMIT" xcrun simctl bootstatus "$tv" -b > "$W/tv-boot.log" 2>&1; echo "direct boot rc=$boot_rc bootstatus rc=$? secs=$(( $(date +%s) - t ))"
    snap after-boot
    if tv_listed; then recovered=boot; fi
fi
tv_rc=skip tv_passed=skip
if [[ -n $tv ]]; then
    xcodebuild test-without-building -scheme "$SCHEME" -destination "platform=tvOS Simulator,id=$tv" -derivedDataPath "$W/dd" -resultBundlePath "$W/tv.xcresult" -collect-test-diagnostics never > "$W/tv.log" 2>&1
    tv_rc=$?
    tv_passed=$(xcrun xcresulttool get test-results summary --path "$W/tv.xcresult" --compact 2>/dev/null | jq -r '.passedTests // "?"')
    [[ $tv_rc == 0 ]] || grep -E 'error|failed' "$W/tv.log" | cut -c1-240 | head -4
fi
snap end
kill "$MON" 2>/dev/null
echo "--- monitor (changes only)"; awk '{k=$4" "$5} k!=prev {print; prev=k}' "$W/mon.log"
echo "RESULT image=${ImageVersion:-?} ios_rc=$ios_rc ios_passed=$ios_passed ios_secs=$ios_secs ios_early=$ios_early ios_hung=$ios_hung tv27_missing=$missing recovered=$recovered tv_rc=$tv_rc tv_passed=$tv_passed"
exit 0
