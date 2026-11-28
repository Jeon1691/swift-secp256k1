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
#   iOS and a tvOS Simulator when those slices are archived, catching a slice that links but misbehaves.
# Exit: 0 pass · 1 detected defect or usage · tool failures keep their own code.
set -euo pipefail

XCFRAMEWORK=$(cd "${1:?usage: $0 <path-to-P256K.xcframework> <platform>...}" && pwd)
shift
ROOT=$(cd "$(dirname "$0")/.." && pwd)

WORKDIR=$(mktemp -d)
# Only simulators that were Shutdown when picked; any other state may belong to someone else.
booted_sims=()
cleanup() {
    local sim
    # ${a[@]+...} keeps an empty array legal under set -u on bash 3.2 (macOS /bin/bash).
    for sim in ${booted_sims[@]+"${booted_sims[@]}"}; do
        xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true
    done
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

# testName Xcode gives xctest's own process errors — a runner that never connected, crashed while bootstrapping or
# couldn't launch — the bundle's only marker of a run no test judged; update if Xcode renames it.
xctest_fault_name='^xctest( \([0-9]+\))? encountered an error$'

# build-for-testing proves a simulator slice links, not that it runs; no eligible device fails the gate.
# Newest runtime whose major.minor ≤ the active SDK's (never one for a newer Xcode than the pin), compared
# numerically; single-device-type runtimes are skipped by type count because their IDs can look general (iOS-27-1).
run_simulator_leg() {
    local dest=$1 platform=$2 sdk_name=$3 prefix=$4
    local sdk rescan sims pick sim state label result attempt rc summary
    command -v jq >/dev/null || die "jq is required to select and judge the simulator runs"
    sdk=$(xcrun --sdk "$sdk_name" --show-sdk-version)
    for rescan in 0 1; do
        sims=$(xcrun simctl list --json)
        pick=$(jq -r --arg sdk "$sdk" --arg platform "$platform" --arg prefix "$prefix" '
            def ver: split(".") | map(tonumber);
            def major_minor: (. + [0, 0])[:2];
            ($sdk | ver | major_minor) as $cap | .devices as $devices
            | [.runtimes[] as $r
               | select($r.platform == $platform and $r.isAvailable and ($r.supportedDeviceTypes | length) > 1)
               | ($r.version | ver) as $v | select(($v | major_minor) <= $cap)
               | ($devices[$r.identifier] // [])[] | select(.isAvailable and (.name | startswith($prefix)))
               | {v: $v, version: $r.version, udid, state: (.state | gsub(" "; "_")), name}]
            | max_by(.v) // empty | "\(.udid) \(.state) \(.name), \($platform) \(.version)"' <<<"$sims") || pick=''
        [[ -z "$pick" && $rescan == 0 ]] || break
        # A runtime whose disk image CoreSimulator is re-staging drops out of `simctl list` until it is remounted.
        echo "warning: no eligible $prefix simulator listed; rescanning runtime images once" >&2
        xcrun simctl runtime scan-and-mount >&2 || true
    done
    if [[ -z "$pick" ]]; then
        echo "$platform runtimes and devices simctl reported:" >&2
        jq -r --arg platform "$platform" 'def err: if .availabilityError then " (\(.availabilityError))" else "" end;
            def rt: ltrimstr("com.apple.CoreSimulator.SimRuntime.");
            [(.runtimes[]? | select(.platform == $platform)
              | "  runtime \(.identifier | rt) \(.version) available=\(.isAvailable) device_types=\(.supportedDeviceTypes | length)\(err)"),
             (.devices // {} | to_entries[] | select(.key | contains("SimRuntime.\($platform)-")) | (.key | rt) as $rt
              | .value[] | "  device \($rt) \(.name) \(.state) available=\(.isAvailable)\(err)")]
            | if length == 0 then "  (none)" else .[] end' <<<"$sims" >&2 || true
        die "$dest slice archived but no available $prefix simulator on any $platform runtime ≤ the $sdk SDK"
    fi
    read -r sim state label <<<"$pick"
    if [[ "$state" == Shutdown ]]; then
        booted_sims+=("$sim")
    fi
    echo "consumer test: $dest ($label)"

    # -collect-test-diagnostics never: skip the simulator sysdiagnose a failing test otherwise waits on.
    result="$WORKDIR/$platform-simulator.xcresult"
    for attempt in 1 2; do
        rm -rf "$result"
        rc=0
        xcodebuild test-without-building -scheme "$scheme" -destination "platform=$dest,id=$sim" -derivedDataPath "$WORKDIR/dd" -resultBundlePath "$result" -collect-test-diagnostics never -quiet || rc=$?

        # The bundle is the only record of failure text: -quiet hides it and $WORKDIR is deleted on exit.
        summary=$(xcrun xcresulttool get test-results summary --path "$result" --compact) || {
            echo "warning: could not read the $dest result bundle summary" >&2
            summary='{}'
        }
        ((rc != 0)) || break
        jq -r '.testFailures[]? | "failure: \(.testName // "?"): \(.failureText // "" | gsub("\n"; "\n    "))"' <<<"$summary" >&2 || true
        # A failed run that no test judged is a simulator fault seen on fresh CI VMs, not a verdict: retry it once, but
        # only when every recorded failure is xctest's own, so a real test failure can't be retried into a pass.
        if ((attempt == 1)) && jq -e --arg fault "$xctest_fault_name" '(.passedTests // 0) == 0 and all(.testFailures[]?; .testName // "" | test($fault))' <<<"$summary" >/dev/null; then
            echo "warning: $dest test run failed before any test reported a result; retrying once" >&2
        else
            echo "error: $dest consumer test failed (xcodebuild exit $rc)" >&2
            exit "$rc"
        fi
    done

    # xcodebuild exits 0 when no Swift Testing test ran, so require ≥1 passing test from the bundle.
    jq -e '.result == "Passed" and .passedTests > 0 and .failedTests == 0' <<<"$summary" >/dev/null ||
        die "$dest run reported no passing test: $(jq -c '{result, totalTestCount, passedTests, failedTests}' <<<"$summary")"
    echo "consumer test: $dest passed $(jq -r '.passedTests' <<<"$summary") test(s)"
    # Free a simulator this leg booted before the next leg boots its own; the trap still covers failure exits.
    if [[ "$state" == Shutdown ]]; then
        xcrun simctl shutdown "$sim" >/dev/null 2>&1 || true
    fi
}

# archive destination | simctl platform | SDK name | device name prefix
simulator_legs=(
    "iOS Simulator|iOS|iphonesimulator|iPhone"
    "tvOS Simulator|tvOS|appletvsimulator|Apple TV"
)
for leg in "${simulator_legs[@]}"; do
    IFS='|' read -r dest platform sdk_name prefix <<<"$leg"
    if [[ " $* " == *" $dest "* ]]; then
        run_simulator_leg "$dest" "$platform" "$sdk_name" "$prefix"
    fi
done

echo "verified: ${#bins[@]} binaries — exports allowlisted, consumer builds passed, consumer tests ran"
