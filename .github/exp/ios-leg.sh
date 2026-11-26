#!/usr/bin/env bash
# TEMPORARY fork-only experiment: one iOS Simulator leg per fresh VM, to compare
# the runner-connection hang across conditions. Not for upstream.
#   exp/ios-leg.sh <xcframework> <cond>   cond: baseline | preboot | xcode272
# Prints one "RESULT ..." line; always exits 0 so every job reports.
set -uo pipefail
XCF=$1 COND=$2
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d); C="$W/consumer"; mkdir -p "$C/Tests"
cp "$ROOT/Scripts/XCFrameworkTest/Package.swift" "$C/Package.swift"
cp -R "$ROOT/Tests/XCFrameworkTests" "$C/Tests/XCFrameworkTests"
ln -s "$XCF" "$C/P256K.xcframework"
cd "$C" || exit 0
export SWIFT_FORCE_MODULE_LOADING=only-interface
SCHEME=swift-secp256k1-xcframework-consumer-Package
# Hold the runtime at the release pin's SDK in every condition, so xcode272 varies only the toolchain.
CAP=27.0

xcodebuild build-for-testing -scheme "$SCHEME" -destination "generic/platform=iOS Simulator" -derivedDataPath "$W/dd" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO -quiet || { echo "RESULT cond=$COND build=failed"; exit 0; }

# Same selector as Scripts/verify-p256k-xcframework.sh.
pick=$(xcrun simctl list --json | jq -r --arg sdk "$CAP" '
    def ver: split(".") | map(tonumber);
    def major_minor: (. + [0, 0])[:2];
    ($sdk | ver | major_minor) as $cap | .devices as $devices
    | [.runtimes[] as $r
       | select($r.platform == "iOS" and $r.isAvailable and ($r.supportedDeviceTypes | length) > 1)
       | ($r.version | ver) as $v | select(($v | major_minor) <= $cap)
       | ($devices[$r.identifier] // [])[] | select(.isAvailable and (.name | startswith("iPhone")))
       | {v: $v, version: $r.version, udid, name}]
    | max_by(.v) // empty | "\(.udid) \(.name), iOS \(.version)"')
[[ -n "$pick" ]] || { echo "RESULT cond=$COND pick=none"; exit 0; }
read -r sim label <<<"$pick"
echo "picked: $label ($sim)"

boot_wait=0
if [[ $COND == preboot ]]; then
    t=$(date +%s)
    xcrun simctl boot "$sim"; xcrun simctl bootstatus "$sim" -b > "$W/bootstatus.log" 2>&1
    boot_wait=$(( $(date +%s) - t ))
fi

attempt() { # attempt <n> -> sets rc, secs, wait, bless, hung, passed
    local log="$W/test-$1.log" res="$W/r-$1.xcresult" t
    t=$(date +%s)
    xcodebuild test-without-building -scheme "$SCHEME" -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$W/dd" -resultBundlePath "$res" -collect-test-diagnostics never > "$log" 2>&1
    rc=$?; secs=$(( $(date +%s) - t ))
    wait=$(grep -oE '[0-9.]+ elapsed -- Testing started completed' "$log" | head -1 | cut -d' ' -f1)
    bless=$(grep -c 'bless service hub' "$log"); hung=$(grep -c 'hung before establishing connection' "$log")
    passed=$(xcrun xcresulttool get test-results summary --path "$res" --compact 2>/dev/null | jq -r '.passedTests // "?"')
    grep -E 'bless service hub|hung before|Testing started completed' "$log" | cut -c1-220 | head -8
}
attempt 1
line="RESULT cond=$COND boot_wait=${boot_wait}s rc=$rc passed=$passed secs=$secs wait=${wait:-?}s bless=$bless hung=$hung"
if (( hung > 0 )); then
    attempt 2   # does a single retry recover a runner-connection hang?
    line="$line retry_rc=$rc retry_passed=$passed retry_secs=$secs retry_bless=$bless retry_hung=$hung"
fi
echo "$line"
exit 0
