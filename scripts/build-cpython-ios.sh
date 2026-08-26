#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache_root=${LITESPACE_CPYTHON_CACHE_ROOT:-"$project_root/.cache/cpython"}
artifact_base=${LITESPACE_CPYTHON_ARTIFACT_ROOT:-"$project_root/.artifacts/cpython"}
source_root="$cache_root/Python-3.14.7"
artifact_root="$artifact_base/3.14.7"
metadata="$project_root/Vendor/CPython/source.json"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

developer_dir=$(xcode-select -p 2>/dev/null || true)
test -n "$developer_dir" || fail "Xcode developer directory is unavailable"
case "$developer_dir" in
    */CommandLineTools) fail "full Xcode is required for the iOS framework" ;;
esac
xcodebuild -version >/dev/null 2>&1 || fail "full Xcode is not active"
xcrun --sdk iphoneos --show-sdk-build-version >/dev/null 2>&1 \
    || fail "the iPhoneOS SDK is unavailable"
xcrun --sdk iphonesimulator --show-sdk-build-version >/dev/null 2>&1 \
    || fail "the iPhoneSimulator SDK is unavailable"

test -f "$source_root/.litespace-source.json" || fail "run fetch-cpython-source.sh first"
/usr/bin/cmp -s "$metadata" "$source_root/.litespace-source.json" \
    || fail "CPython source fingerprint mismatch"
test ! -e "$artifact_root" || fail "versioned CPython artifact directory already exists"

(
    cd "$source_root"
    /usr/bin/python3 Apple build iOS
)

set -- "$source_root"/cross-build/dist/*.tar.gz
test "$#" -eq 1 && test -f "$1" || fail "expected exactly one upstream iOS artifact archive"
/bin/mkdir -p "$artifact_root"
/usr/bin/tar -xzf "$1" -C "$artifact_root"

xcframework=$(/usr/bin/find "$artifact_root" -type d -name Python.xcframework -print | /usr/bin/head -n 1)
test -n "$xcframework" || fail "Python.xcframework is missing from the upstream artifact"

slices=$(/usr/bin/plutil -convert json -o - "$xcframework/Info.plist" \
    | /usr/bin/ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("AvailableLibraries").map { |item| item.fetch("LibraryIdentifier") }.sort')
test "$slices" = "ios-arm64
ios-arm64_x86_64-simulator" || fail "Python.xcframework slices do not match the reviewed set"

xcode_version=$(xcodebuild -version | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/[[:space:]]*$//')
iphoneos_build=$(xcrun --sdk iphoneos --show-sdk-build-version)
simulator_build=$(xcrun --sdk iphonesimulator --show-sdk-build-version)

/usr/bin/ruby -rjson -rdigest -e '
  root, output, xcode_version, iphoneos, simulator = ARGV
  files = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select do |path|
    File.file?(path) && File.basename(path) != "artifact-manifest.json"
  end.map do |path|
    relative = path.delete_prefix(root + "/")
    {"path" => relative, "bytes" => File.size(path), "sha256" => Digest::SHA256.file(path).hexdigest}
  end.sort_by { |entry| entry.fetch("path") }
  tree = Digest::SHA256.new
  files.each { |entry| tree.update(entry.fetch("path")); tree.update("\0"); tree.update(entry.fetch("sha256")); tree.update("\n") }
  manifest = {
    "schema_version" => 1,
    "version" => "3.14.7",
    "source_url" => "https://www.python.org/ftp/python/3.14.7/Python-3.14.7.tgz",
    "source_sha256" => "62859805f6fdf25e2bcbf3fa3217801e1996887ca33e6a2af80674bdfa2dbe07",
    "tag_commit" => "823f0323ee6ec1402088b73bce1a38473cac36dc",
    "build_command" => ["python3", "Apple", "build", "iOS"],
    "xcode_version" => xcode_version,
    "sdk_builds" => {"iphoneos" => iphoneos, "iphonesimulator" => simulator},
    "slices" => ["ios-arm64", "ios-arm64_x86_64-simulator"],
    "tree_sha256" => tree.hexdigest,
    "files" => files
  }
  File.write(output, JSON.pretty_generate(manifest) + "\n")
' "$artifact_root" "$artifact_root/artifact-manifest.json" "$xcode_version" "$iphoneos_build" "$simulator_build"

"$project_root/scripts/verify-cpython-artifact.sh" "$artifact_root/artifact-manifest.json"
printf 'PASS: built auditable CPython iOS artifact\n'
