#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
metadata="$project_root/Vendor/CPython/source.json"
cache_root=${LITESPACE_CPYTHON_CACHE_ROOT:-"$project_root/.cache/cpython"}
archive="$cache_root/Python-3.14.7.tgz"
source_root="$cache_root/Python-3.14.7"
marker="$source_root/.litespace-source.json"
expected_sha=62859805f6fdf25e2bcbf3fa3217801e1996887ca33e6a2af80674bdfa2dbe07
source_url=https://www.python.org/ftp/python/3.14.7/Python-3.14.7.tgz

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

"$project_root/scripts/verify-cpython-artifact.sh"
mkdir -p "$cache_root"

if test -f "$archive"; then
    actual_sha=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
    test "$actual_sha" = "$expected_sha" || fail "cached CPython archive hash mismatch"
else
    partial="$cache_root/Python-3.14.7.tgz.partial.$$"
    test ! -e "$partial" || fail "download staging file already exists"
    /usr/bin/curl --fail --location --silent --show-error "$source_url" --output "$partial"
    actual_sha=$(/usr/bin/shasum -a 256 "$partial" | /usr/bin/awk '{print $1}')
    test "$actual_sha" = "$expected_sha" || fail "downloaded CPython archive hash mismatch"
    /bin/mv "$partial" "$archive"
fi

if test -d "$source_root"; then
    test -f "$marker" || fail "existing CPython source directory is unverified"
    /usr/bin/cmp -s "$metadata" "$marker" || fail "existing CPython source fingerprint differs"
    printf 'PASS: verified CPython source cache already exists\n'
    exit 0
fi

/bin/mkdir "$source_root"
/usr/bin/tar -xzf "$archive" -C "$source_root" --strip-components 1
/bin/cp "$metadata" "$marker"
printf 'PASS: fetched and verified official CPython source\n'
