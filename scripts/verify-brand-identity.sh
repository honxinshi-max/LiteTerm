#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

legacy_name="Lite"
legacy_name="${legacy_name}Term"

path_hits="$(
    find . \
        -path './.git' -prune -o \
        -type d \( -name '.build' -o -name 'DerivedData' \) -prune -o \
        -print \
        | LC_ALL=C sort \
        | rg -i "$legacy_name" || true
)"

if [ -n "$path_hits" ]; then
    echo "FAIL: legacy identity remains in repository paths:" >&2
    printf '%s\n' "$path_hits" >&2
    exit 1
fi

link_hits="$(
    find . \
        -path './.git' -prune -o \
        -type d \( -name '.build' -o -name 'DerivedData' \) -prune -o \
        -type l -exec sh -c '
            for link_path do
                printf "%s -> %s\n" "$link_path" "$(readlink "$link_path")"
            done
        ' sh {} + \
        | rg -i "$legacy_name" || true
)"

if [ -n "$link_hits" ]; then
    echo "FAIL: legacy identity remains in symbolic-link targets:" >&2
    printf '%s\n' "$link_hits" >&2
    exit 1
fi

content_hits="$(
    rg -n -i --hidden \
        --glob '!.git/**' \
        --glob '!**/.build/**' \
        --glob '!**/DerivedData/**' \
        "$legacy_name" . || true
)"

if [ -n "$content_hits" ]; then
    echo "FAIL: legacy identity remains in repository text:" >&2
    printf '%s\n' "$content_hits" >&2
    exit 1
fi

required_paths='LiteSpace.xcodeproj/project.pbxproj
LiteSpace.xcodeproj/xcshareddata/xcschemes/LiteSpace.xcscheme
LiteSpace/App/LiteSpaceApp.swift
LiteSpace/App/LiteSpaceRootScreen.swift
LiteSpace/Resources/LiteSpace.entitlements
LiteSpacePythonBridge/LiteSpacePythonBridge.m
LiteSpacePythonBridge/include/LiteSpacePythonBridge.h
LiteSpaceUITests/LiteSpaceSmokeUITests.swift
Sources/LiteSpaceCore/LiteSpaceCore.swift
Tests/LiteSpaceCoreTests
Tests/LiteSpacePythonBridgeTests/LiteSpacePythonBridgeTests.swift
Tests/LiteSpaceSSHTests'

printf '%s\n' "$required_paths" | while IFS= read -r required_path; do
    if [ ! -e "$required_path" ]; then
        echo "FAIL: required LiteSpace path is missing: $required_path" >&2
        exit 1
    fi
done

rg -q 'name: "LiteSpace"' Package.swift
rg -q '^name: LiteSpace$' project.yml
rg -q '<string>LiteSpace</string>' LiteSpace/Resources/Info.plist

echo "PASS: LiteSpace identity is consistent across repository paths and text"
