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

for required_path in \
    Package.swift \
    project.yml \
    LiteTerm.xcodeproj/project.pbxproj \
    LiteTerm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
    LiteTerm/Resources/Info.plist \
    LiteTerm/Resources/PrivacyInfo.xcprivacy \
    THIRD_PARTY_NOTICES.md \
    Tests/LiteTermCoreTests/AcceptanceFlowTests.swift
do
    test -f "$required_path" || fail "missing $required_path"
done
pass "required project files exist"

./scripts/run-core-tests.sh
pass "actual LiteTermCore custom runner executed"

if test "${LITETERM_COMPILE_STANDARD_TESTS:-1}" = 1; then
    swift test
    pass "standard Swift test targets compile"
else
    printf 'SKIP: standard Swift test compilation disabled by LITETERM_COMPILE_STANDARD_TESTS=0\n'
fi

/usr/bin/plutil -lint \
    LiteTerm.xcodeproj/project.pbxproj \
    LiteTerm/Resources/Info.plist \
    LiteTerm/Resources/PrivacyInfo.xcprivacy >/dev/null
pass "PBX project, Info.plist, and privacy manifest parse"

/usr/bin/ruby <<'RUBY'
require "json"
require "open3"
require "yaml"

def assert(condition, message)
  abort("FAIL: #{message}") unless condition
end

project = YAML.safe_load(File.read("project.yml"), aliases: true)
assert(project.dig("options", "deploymentTarget", "iOS") == "17.0", "iPadOS deployment target must be 17.0")
assert(project.dig("settings", "base", "TARGETED_DEVICE_FAMILY") == "2", "global device family must be iPad only")
%w[LiteTermCore LiteTerm LiteTermCoreTests LiteTermSSHTests LiteTermUITests].each do |target|
  assert(project.dig("targets", target, "settings", "base", "TARGETED_DEVICE_FAMILY") == "2", "#{target} must target iPad only")
end

expected_direct_pins = {
  "SwiftTerm" => "dd2fb8ac5b861e7bf617c872895e338f38165648",
  "SwiftNIOSSH" => "3ec281496f28a3b6581afd946b759e2642f5cd8d",
  "SwiftNIOTransportServices" => "67787bb645a5e67d2edcdfbe48a216cc549222d5",
  "SwiftNIO" => "0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b",
  "SwiftCrypto" => "47d3869a7291f085c1fb9fb1e6d3b97a793f45c6"
}
expected_direct_pins.each do |name, revision|
  assert(project.dig("packages", name, "revision") == revision, "#{name} project pin changed")
end

assert(project.dig("targets", "LiteTermCoreTests", "sources") == ["Tests/LiteTermCoreTests"], "Core test target source membership changed")
assert(project.dig("targets", "LiteTermSSHTests", "sources") == ["Tests/LiteTermSSHTests"], "SSH test target source membership changed")
assert(project.dig("targets", "LiteTermUITests", "sources") == ["LiteTermUITests"], "UI test target source membership changed")

resolved = JSON.parse(File.read("LiteTerm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
expected_resolved = {
  "swift-argument-parser" => "6a52f3251125d74daf04fcbd5e6f08a75d074382",
  "swift-asn1" => "a9a5efd40eaf558a2bcd48d64b1d1646be686008",
  "swift-atomics" => "0442cb5a3f98ab802acb777929fdb446bda11a34",
  "swift-collections" => "a0cb0954ecb21e4e31b0070e6ed5674e8556685a",
  "swift-crypto" => "47d3869a7291f085c1fb9fb1e6d3b97a793f45c6",
  "swift-nio" => "0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b",
  "swift-nio-ssh" => "3ec281496f28a3b6581afd946b759e2642f5cd8d",
  "swift-nio-transport-services" => "67787bb645a5e67d2edcdfbe48a216cc549222d5",
  "swift-system" => "869129b7bf4ecc57b97d0193ad29690ca2134750",
  "swiftterm" => "dd2fb8ac5b861e7bf617c872895e338f38165648"
}
actual_resolved = resolved.fetch("pins").to_h { |pin| [pin.fetch("identity"), pin.dig("state", "revision")] }
assert(actual_resolved == expected_resolved, "Package.resolved does not match the reviewed exact graph")

info_json, info_status = Open3.capture2("/usr/bin/plutil", "-convert", "json", "-o", "-", "LiteTerm/Resources/Info.plist")
assert(info_status.success?, "Info.plist JSON conversion failed")
info = JSON.parse(info_json)
expected_orientations = %w[
  UIInterfaceOrientationPortrait
  UIInterfaceOrientationPortraitUpsideDown
  UIInterfaceOrientationLandscapeLeft
  UIInterfaceOrientationLandscapeRight
]
assert(info["UISupportedInterfaceOrientations~ipad"] == expected_orientations, "iPad orientations changed")
expected_lan_copy = "LiteTerm uses your local network only when you connect to an SSH host you chose, such as a Mac on your LAN."
assert(info["NSLocalNetworkUsageDescription"] == expected_lan_copy, "local-network explanation changed")
assert(!info.key?("NSBonjourServices"), "Bonjour services must not be declared without discovery")

privacy_json, privacy_status = Open3.capture2("/usr/bin/plutil", "-convert", "json", "-o", "-", "LiteTerm/Resources/PrivacyInfo.xcprivacy")
assert(privacy_status.success?, "privacy manifest JSON conversion failed")
privacy = JSON.parse(privacy_json)
assert(privacy["NSPrivacyTracking"] == false, "privacy tracking must be false")
assert(privacy["NSPrivacyTrackingDomains"] == [], "tracking domains must be empty")
assert(privacy["NSPrivacyCollectedDataTypes"] == [], "collected data types must be empty")
accessed = privacy.fetch("NSPrivacyAccessedAPITypes").to_h do |entry|
  [entry.fetch("NSPrivacyAccessedAPIType"), entry.fetch("NSPrivacyAccessedAPITypeReasons")]
end
expected_accessed = {
  "NSPrivacyAccessedAPICategoryUserDefaults" => ["CA92.1"],
  "NSPrivacyAccessedAPICategoryFileTimestamp" => ["3B52.1"]
}
assert(accessed == expected_accessed, "required-reason API declarations changed")

pbx_json, pbx_status = Open3.capture2("/usr/bin/plutil", "-convert", "json", "-o", "-", "LiteTerm.xcodeproj/project.pbxproj")
assert(pbx_status.success?, "PBX project JSON conversion failed")
pbx = JSON.parse(pbx_json)
objects = pbx.fetch("objects")
target_id, target = objects.find { |_id, object| object["isa"] == "PBXNativeTarget" && object["name"] == "LiteTerm" }
assert(target_id && target, "LiteTerm native target missing")
resource_phase_ids = target.fetch("buildPhases").select { |id| objects.dig(id, "isa") == "PBXResourcesBuildPhase" }
resource_file_ids = resource_phase_ids.flat_map { |id| objects.fetch(id).fetch("files", []) }
resource_paths = resource_file_ids.map do |build_file_id|
  file_ref_id = objects.dig(build_file_id, "fileRef")
  file_ref = file_ref_id && objects[file_ref_id]
  file_ref && (file_ref["path"] || file_ref["name"])
end.compact
assert(resource_paths.include?("PrivacyInfo.xcprivacy"), "privacy manifest is not in LiteTerm resources")
assert(resource_paths.include?("THIRD_PARTY_NOTICES.md"), "third-party notices are not in LiteTerm resources")
target_names = objects.values.select { |object| object["isa"] == "PBXNativeTarget" }.map { |object| object["name"] }
%w[LiteTermCoreTests LiteTermSSHTests LiteTermUITests].each do |name|
  assert(target_names.include?(name), "#{name} generated target missing")
end
RUBY
pass "project model, pins, targets, resources, orientations, local-network copy, and privacy declarations match"

if rg -n -i \
    'SFTP|port[[:space:]_-]*forward|Docker|VirtualMachine|PythonKit|JavaScriptCore|NodeRuntime|background[[:space:]_-]*keepalive|UIBackgroundModes|NSBonjourServices|CKContainer|CloudKit|Process[[:space:]]*\(|NSTask\b|dlopen[[:space:]]*\(' \
    LiteTerm Sources Package.swift project.yml LiteTerm.xcodeproj/project.pbxproj
then
    fail "forbidden V0.1 product addition found in production/project scope"
fi
pass "production/project scope contains no forbidden product additions"

if rg -n -i \
    '"(password|privateKey|private_key|passphrase|secret|token)"[[:space:]]*[,\]]|CodingKeys[^\n]*(password|privateKey|passphrase|secret|token)' \
    Sources/LiteTermCore/Hosts/SSHHost.swift \
    Sources/LiteTermCore/Hosts/HostRepository.swift \
    LiteTerm/Features/FileAccess/FolderAuthorizationStore.swift
then
    fail "secret-bearing persisted field found in host/bookmark metadata scope"
fi
pass "host/bookmark persisted-field scope contains no secret-bearing key"

test -z "$(git remote)" || fail "a Git remote is configured"
pass "no Git remote is configured"

if xcodebuild -version >/dev/null 2>&1; then
    pass "full Xcode is selected"
    printf 'OPEN: physical-iPad, live-SSH, RSS, archive privacy report, and App Store review gates still require their named environments.\n'
else
    printf 'OPEN/SKIP: full Xcode is not selected; app build, simulator/device tests, archive privacy report, RSS, live SSH, and App Store review are not passed.\n'
fi

printf 'PORTABLE CANDIDATE CHECKS COMPLETE: this is not a release pass.\n'
