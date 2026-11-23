#!/usr/bin/env bash
# verify-p256k-xcframework.sh <P256K.xcframework> <platform>...
# Gates the artifact that ships; <platform>... is the pipeline's archive
# list (generic/platform= names) and the slice count must match it.
# Why each check exists: AGENTS.md, "XCFramework toolchain pins".
#   unsigned: no slice may carry _CodeSignature — an archive-time signature is
#   invalidated by -create-xcframework (CODE_SIGNING_ALLOWED=NO, Release.xcconfig).
#   exports: only _$s* and _P256KVersion* may be global, tripwiring exported-symbols.txt.
#   consumers: Tests/XCFrameworkTests runs on macOS and builds+links for each platform
#   against only the shipped interfaces (no libsecp256k1 module) — catches a leaked C
#   import, a hollow or missing slice, and a missing standard arch — then runs on an
#   iOS Simulator when that slice is archived, catching a slice that links but misbehaves.
# Exit: 0 pass · 1 detected defect or usage · tool failures keep their own code.
set -euo pipefail

XCFRAMEWORK=$(cd "${1:?usage: $0 <path-to-P256K.xcframework> <platform>...}" && pwd)
shift
ROOT=$(cd "$(dirname "$0")/.." && pwd)

WORKDIR=$(mktemp -d)
# Set only when the picked iOS Simulator was fully shut down, i.e. this script
# is the one booting it; a device that is booted, booting or shutting down for
# someone else is left alone.
booted_sim=''
cleanup() {
    [[ -z "$booted_sim" ]] || xcrun simctl shutdown "$booted_sim" >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

die() {
    echo "error: $*" >&2
    exit 1
}

bins=("$XCFRAMEWORK"/*/P256K.framework/P256K)
((${#bins[@]} == $#)) || die "platform list names $# platform(s) but the artifact ships ${#bins[@]} slice(s) — argument drifted from what was archived"

# Signatures live at _CodeSignature (iOS-style) or Versions/A/_CodeSignature (macOS-style);
# compgen prints the offending paths as evidence before die.
if compgen -G "$XCFRAMEWORK/*/P256K.framework/_CodeSignature" ||
    compgen -G "$XCFRAMEWORK/*/P256K.framework/Versions/A/_CodeSignature"; then
    die "slice carries a code signature — the artifact should ship unsigned"
fi

# nm -A prefixes each symbol with its file and arch, naming the slice it leaked from.
syms=$(nm -gUjA -arch all "${bins[@]}")

if grep -Ev '^$|: (_\$s|_P256KVersion(Number|String)$)' <<<"$syms"; then
    die "non-allowlisted exports (listed above)"
fi

# Stage the CI-only consumer package: manifest, the real test suite, and the artifact at the path the manifest expects.
CONSUMER="$WORKDIR/consumer"
mkdir -p "$CONSUMER/Tests"
cp "$ROOT/Scripts/XCFrameworkTest/Package.swift" "$CONSUMER/Package.swift"
cp -R "$ROOT/Tests/XCFrameworkTests" "$CONSUMER/Tests/XCFrameworkTests"
ln -s "$XCFRAMEWORK" "$CONSUMER/P256K.xcframework"
cd "$CONSUMER"
export SWIFT_FORCE_MODULE_LOADING=only-interface

# SwiftPM's scheme for Scripts/XCFrameworkTest/Package.swift (name: + "-Package").
scheme=swift-secp256k1-xcframework-consumer-Package

echo "consumer test: macOS (swift test)"
swift test

for dest in "$@"; do
    echo "consumer build: $dest"
    xcodebuild build-for-testing -scheme "$scheme" -destination "generic/platform=$dest" -derivedDataPath "$WORKDIR/dd" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO -quiet
done

# A generic-destination build proves the simulator slice links, not that it
# runs; execute the suite on a concrete iOS Simulator so the shipped binary's
# code is actually exercised off macOS. Fail-closed: an archived iOS Simulator
# slice with no iPhone simulator to run it on is a runner defect, not a skip.
# Device choice: an available iPhone on the newest available iOS runtime that
# has one, capped at the active iphonesimulator SDK so a runtime installed for
# a newer Xcode than the pinned one is never picked. Versions order as full
# integer arrays (27.10 > 27.9, 27.2.1 > 27.2); the cap compares major.minor
# only, since the SDK names no patch level — so SDK 27.0 admits a 27.0.1
# runtime, and "27" equals "27.0". Runtimes supporting a single
# device type (e.g. iOS-27-2-iPhone19-4) are device-specific builds, not the
# general runtime for that version, and are skipped. Names drift per Xcode, so
# no device is named.
if [[ " $* " == *" iOS Simulator "* ]]; then
    command -v jq >/dev/null || die "jq is required to select and judge the iOS Simulator run"
    sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
    pick=$(xcrun simctl list --json | jq -r --arg sdk "$sdk" '
        def ver: split(".") | map(tonumber);
        def major_minor: (. + [0, 0])[:2];
        ($sdk | ver | major_minor) as $cap | .devices as $devices
        | [.runtimes[] as $r
           | select($r.platform == "iOS" and $r.isAvailable and ($r.supportedDeviceTypes | length) > 1)
           | ($r.version | ver) as $v | select(($v | major_minor) <= $cap)
           | ($devices[$r.identifier] // [])[] | select(.isAvailable and (.name | startswith("iPhone")))
           | {v: $v, version: $r.version, udid, state: (.state | gsub(" "; "_")), name}]
        | max_by(.v) // empty | "\(.udid) \(.state) \(.name), iOS \(.version)"')
    [[ -n "$pick" ]] || die "iOS Simulator slice archived but no available iPhone simulator on an iOS runtime ≤ the $sdk SDK"
    read -r sim state label <<<"$pick"
    if [[ "$state" == Shutdown ]]; then
        booted_sim=$sim
    fi
    echo "consumer test: iOS Simulator ($label)"

    # -collect-test-diagnostics never: on a test failure xcodebuild otherwise
    # sysdiagnoses the simulator before reporting, bounded by a 600 s timeout
    # (observed: ~30 s extra on Xcode 27.2, the full 600 s once on 27.1) — the
    # failure is already in the log and the bundle.
    result="$WORKDIR/ios-simulator.xcresult"
    rc=0
    xcodebuild test-without-building -scheme "$scheme" -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$WORKDIR/dd" -resultBundlePath "$result" -collect-test-diagnostics never -quiet || rc=$?

    # The result bundle is the source of truth on both paths: -quiet keeps the
    # #expect text out of the log, and the bundle is deleted with $WORKDIR.
    # An unreadable bundle keeps xcresulttool's own error on stderr and falls
    # back to {}, which can never satisfy the pass check below.
    summary=$(xcrun xcresulttool get test-results summary --path "$result" --compact) || {
        echo "warning: could not read the iOS Simulator result bundle summary" >&2
        summary='{}'
    }
    if ((rc != 0)); then
        jq -r '.testFailures[]? | "failure: \(.testName // "?"): \(.failureText // "" | gsub("\n"; "\n    "))"' <<<"$summary" >&2 || true
        echo "error: iOS Simulator consumer test failed (xcodebuild exit $rc)" >&2
        exit "$rc"
    fi

    # xcodebuild exits 0 even when no Swift Testing test ran (its own tally
    # counts only XCTest), so the pass is asserted from the bundle: Passed, at
    # least one test executed, none failed.
    jq -e '.result == "Passed" and .passedTests > 0 and .failedTests == 0' <<<"$summary" >/dev/null ||
        die "iOS Simulator run reported no passing test: $(jq -c '{result, totalTestCount, passedTests, failedTests}' <<<"$summary")"
    echo "consumer test: iOS Simulator passed $(jq -r '.passedTests' <<<"$summary") test(s)"
fi

echo "verified: ${#bins[@]} binaries — exports allowlisted, consumer builds passed, consumer tests ran"
