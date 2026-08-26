#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
metadata="$project_root/Vendor/CPython/source.json"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

test -f "$metadata" || fail "CPython source metadata is missing"

/usr/bin/ruby -rjson -rdigest -e '
  expected = {
    "schema_version" => 1,
    "version" => "3.14.7",
    "source_url" => "https://www.python.org/ftp/python/3.14.7/Python-3.14.7.tgz",
    "source_sha256" => "62859805f6fdf25e2bcbf3fa3217801e1996887ca33e6a2af80674bdfa2dbe07",
    "tag" => "v3.14.7",
    "tag_commit" => "823f0323ee6ec1402088b73bce1a38473cac36dc",
    "build_command" => ["python3", "Apple", "build", "iOS"],
    "required_slices" => ["ios-arm64", "ios-arm64_x86_64-simulator"]
  }
  actual = JSON.parse(File.read(ARGV.fetch(0)))
  abort("FAIL: CPython source metadata changed") unless actual == expected
' "$metadata"

if test "$#" -eq 0; then
    printf 'PASS: pinned CPython source metadata\n'
    exit 0
fi

test "$#" -eq 1 || fail "usage: verify-cpython-artifact.sh [artifact-manifest.json]"
manifest="$1"
test -f "$manifest" || fail "artifact manifest is missing"

/usr/bin/ruby -rjson -rdigest -e '
  manifest_path = ARGV.fetch(0)
  manifest = JSON.parse(File.read(manifest_path))
  abort("FAIL: artifact version mismatch") unless manifest["version"] == "3.14.7"
  abort("FAIL: artifact source hash mismatch") unless manifest["source_sha256"] == "62859805f6fdf25e2bcbf3fa3217801e1996887ca33e6a2af80674bdfa2dbe07"
  abort("FAIL: artifact commit mismatch") unless manifest["tag_commit"] == "823f0323ee6ec1402088b73bce1a38473cac36dc"
  expected = ["ios-arm64", "ios-arm64_x86_64-simulator"]
  abort("FAIL: artifact slices mismatch") unless manifest["slices"] == expected
  abort("FAIL: artifact tree hash is invalid") unless manifest["tree_sha256"].is_a?(String) && manifest["tree_sha256"].match?(/\A[0-9a-f]{64}\z/)
  files = manifest["files"]
  abort("FAIL: artifact file inventory is empty") unless files.is_a?(Array) && !files.empty?
  files.each do |entry|
    abort("FAIL: artifact path is not relative") if entry["path"].start_with?("/") || entry["path"].include?("..")
    abort("FAIL: artifact file hash is invalid") unless entry["sha256"].match?(/\A[0-9a-f]{64}\z/)
    path = File.join(File.dirname(manifest_path), entry.fetch("path"))
    abort("FAIL: artifact file is missing") unless File.file?(path)
    abort("FAIL: artifact file size mismatch") unless File.size(path) == entry.fetch("bytes")
    abort("FAIL: artifact file digest mismatch") unless Digest::SHA256.file(path).hexdigest == entry.fetch("sha256")
  end
  tree = Digest::SHA256.new
  files.sort_by { |entry| entry.fetch("path") }.each do |entry|
    tree.update(entry.fetch("path")); tree.update("\0"); tree.update(entry.fetch("sha256")); tree.update("\n")
  end
  abort("FAIL: artifact tree digest mismatch") unless tree.hexdigest == manifest.fetch("tree_sha256")
' "$manifest"

printf 'PASS: pinned CPython artifact manifest\n'
