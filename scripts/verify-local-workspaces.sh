#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

core_output=$(./scripts/run-core-tests.sh)
printf '%s\n' "$core_output"
printf '%s\n' "$core_output" | /usr/bin/grep -q '^PASS: 52 LiteSpaceCore checks$' \
    || fail "portable local-workspace suite did not run all 52 reviewed checks"
pass "portable local-workspace behavior suite"

swift build
pass "portable Swift package build"

./scripts/verify-cpython-artifact.sh
pass "pinned CPython source contract"

./scripts/verify-workspace-privacy.sh
pass "workspace privacy and capability boundary"

developer_dir=$(xcode-select -p 2>/dev/null || true)
full_xcode=false
if test -n "$developer_dir" \
    && ! printf '%s\n' "$developer_dir" | /usr/bin/grep -q '/CommandLineTools$' \
    && xcodebuild -version >/dev/null 2>&1
then
    full_xcode=true
fi

if test "$full_xcode" = true; then
    if ! xcodebuild \
        -project LiteSpace.xcodeproj \
        -scheme LiteSpace \
        -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
        -disableAutomaticPackageResolution \
        -onlyUsePackageVersionsFromResolvedFile \
        test
    then
        fail "full-Xcode local-workspace simulator suite"
    fi
    pass "full-Xcode local-workspace simulator suite"
else
    printf 'OPEN: full Xcode and the named iPad simulator are unavailable; iOS build, WebKit, UI, and simulator Python execution are not passed.\n'
fi

artifact_manifest=.artifacts/cpython/3.14.7/artifact-manifest.json
if test -f "$artifact_manifest"; then
    ./scripts/verify-cpython-artifact.sh "$artifact_manifest"
    pass "CPython XCFramework artifact manifest"
    if test "$full_xcode" != true; then
        printf 'SKIP: the verified CPython artifact exists, but simulator bridge execution requires full Xcode.\n'
    fi
else
    printf 'OPEN: the reviewed CPython iOS XCFramework is absent; Python execution remains capability-gated.\n'
    printf 'SKIP: Python bridge, script, unittest, WSGI, cancellation, and restart execution require that verified artifact and an iOS simulator.\n'
fi

printf 'OPEN: physical-iPad RSS, repeated lifecycle, background teardown, archive privacy, signing, and App Review remain separate external gates.\n'
printf 'PASS: local workspace verifier completed without promoting OPEN or SKIP gates.\n'
