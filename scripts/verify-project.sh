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

if command -v rg >/dev/null 2>&1; then
    if rg -n '\blocalGeneration\b' LiteTerm/Features/Terminal/TerminalSessionCoordinator.swift; then
        fail "app coordinator contains the removed localGeneration identifier"
    fi
else
    if /usr/bin/grep -n 'localGeneration' LiteTerm/Features/Terminal/TerminalSessionCoordinator.swift; then
        fail "app coordinator contains the removed localGeneration identifier"
    fi
fi
pass "known removed app-state identifiers are absent"

for required_path in \
    Package.swift \
    project.yml \
    LiteTerm.xcodeproj/project.pbxproj \
    LiteTerm.xcodeproj/xcshareddata/xcschemes/LiteTerm.xcscheme \
    LiteTerm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
    LiteTerm/Resources/Info.plist \
    LiteTerm/Resources/PrivacyInfo.xcprivacy \
    Sources/LiteTermCore/Resources/PrivacyInfo.xcprivacy \
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
    LiteTerm/Resources/PrivacyInfo.xcprivacy \
    Sources/LiteTermCore/Resources/PrivacyInfo.xcprivacy >/dev/null
pass "PBX project, Info.plist, and both privacy manifests parse"

/usr/bin/ruby <<'RUBY'
require "json"
require "open3"
require "rexml/document"
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
assert(
  project.dig("schemes", "LiteTerm", "test", "targets") == %w[LiteTermCoreTests LiteTermSSHTests LiteTermUITests],
  "shared scheme test-target membership changed"
)

scheme = REXML::Document.new(File.read("LiteTerm.xcodeproj/xcshareddata/xcschemes/LiteTerm.xcscheme"))
scheme_test_targets = REXML::XPath.match(scheme, "//TestAction/Testables/TestableReference/BuildableReference").map do |element|
  element.attributes["BlueprintName"]
end
assert(
  scheme_test_targets == %w[LiteTermCoreTests LiteTermSSHTests LiteTermUITests],
  "generated shared scheme does not build all test targets"
)

def explicit_resource_paths(project, target_name)
  project.dig("targets", target_name, "sources").each_with_object([]) do |entry, paths|
    paths << entry["path"] if entry.is_a?(Hash) && entry["buildPhase"] == "resources"
  end
end

assert(
  explicit_resource_paths(project, "LiteTermCore") == ["Sources/LiteTermCore/Resources/PrivacyInfo.xcprivacy"],
  "Core privacy manifest must be the framework's explicit resource"
)
assert(
  explicit_resource_paths(project, "LiteTerm").include?("LiteTerm/Resources/PrivacyInfo.xcprivacy"),
  "app privacy manifest must be the app's explicit resource"
)

package_json, package_status = Open3.capture2("swift", "package", "dump-package")
assert(package_status.success?, "Swift package model dump failed")
package = JSON.parse(package_json)
core_package_target = package.fetch("targets").find { |target| target["name"] == "LiteTermCore" }
assert(core_package_target, "LiteTermCore Swift package target missing")
assert(
  core_package_target.fetch("resources") == [{"path" => "Resources/PrivacyInfo.xcprivacy", "rule" => {"process" => {}}}],
  "LiteTermCore Swift package privacy resource declaration changed"
)

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
  "NSPrivacyAccessedAPICategoryFileTimestamp" => ["C617.1", "3B52.1"]
}
assert(accessed == expected_accessed, "required-reason API declarations changed")

core_privacy_json, core_privacy_status = Open3.capture2(
  "/usr/bin/plutil", "-convert", "json", "-o", "-", "Sources/LiteTermCore/Resources/PrivacyInfo.xcprivacy"
)
assert(core_privacy_status.success?, "Core privacy manifest JSON conversion failed")
core_privacy = JSON.parse(core_privacy_json)
assert(core_privacy["NSPrivacyTracking"] == false, "Core privacy tracking must be false")
assert(core_privacy["NSPrivacyTrackingDomains"] == [], "Core tracking domains must be empty")
assert(core_privacy["NSPrivacyCollectedDataTypes"] == [], "Core collected data types must be empty")
core_accessed = core_privacy.fetch("NSPrivacyAccessedAPITypes").to_h do |entry|
  [entry.fetch("NSPrivacyAccessedAPIType"), entry.fetch("NSPrivacyAccessedAPITypeReasons")]
end
assert(
  core_accessed == {"NSPrivacyAccessedAPICategoryFileTimestamp" => ["C617.1", "3B52.1"]},
  "Core privacy manifest must declare only its FileTimestamp reasons"
)

pbx_json, pbx_status = Open3.capture2("/usr/bin/plutil", "-convert", "json", "-o", "-", "LiteTerm.xcodeproj/project.pbxproj")
assert(pbx_status.success?, "PBX project JSON conversion failed")
pbx = JSON.parse(pbx_json)
objects = pbx.fetch("objects")
def resource_refs(objects, target_name)
  _target_id, target = objects.find do |_id, object|
    object["isa"] == "PBXNativeTarget" && object["name"] == target_name
  end
  assert(target, "#{target_name} native target missing")
  phase_ids = target.fetch("buildPhases").select { |id| objects.dig(id, "isa") == "PBXResourcesBuildPhase" }
  phase_ids.flat_map { |id| objects.fetch(id).fetch("files", []) }.each_with_object([]) do |build_file_id, refs|
    file_ref_id = objects.dig(build_file_id, "fileRef")
    file_ref = file_ref_id && objects[file_ref_id]
    refs << [file_ref_id, file_ref["path"] || file_ref["name"]] if file_ref
  end
end

app_resource_refs = resource_refs(objects, "LiteTerm")
core_resource_refs = resource_refs(objects, "LiteTermCore")
app_privacy_refs = app_resource_refs.select { |_id, path| path == "PrivacyInfo.xcprivacy" }
core_privacy_refs = core_resource_refs.select { |_id, path| path == "PrivacyInfo.xcprivacy" }
assert(app_privacy_refs.length == 1, "app target must contain exactly one privacy manifest resource")
assert(core_privacy_refs.length == 1, "Core target must contain exactly one privacy manifest resource")
assert(app_privacy_refs.first.first != core_privacy_refs.first.first, "app and Core targets must use distinct privacy manifest file references")
assert(app_resource_refs.any? { |_id, path| path == "THIRD_PARTY_NOTICES.md" }, "third-party notices are not in LiteTerm resources")
target_names = objects.values.select { |object| object["isa"] == "PBXNativeTarget" }.map { |object| object["name"] }
%w[LiteTermCoreTests LiteTermSSHTests LiteTermUITests].each do |name|
  assert(target_names.include?(name), "#{name} generated target missing")
end
RUBY
pass "project model, pins, targets, distinct privacy resources, orientations, local-network copy, and privacy declarations match"

forbidden_pattern='SFTP|port[[:space:]_-]*forward|Docker|VirtualMachine|PythonKit|JavaScriptCore|NodeRuntime|background[[:space:]_-]*keepalive|UIBackgroundModes|NSBonjourServices|CKContainer|CloudKit|NSTask([^[:alnum:]_]|$)|dlopen[[:space:]]*\('
process_pattern='(^|[^[:alnum:]_])(Foundation[.])?Process[[:space:]]*\('
if command -v rg >/dev/null 2>&1; then
    forbidden_matches=$(rg -n -i "$forbidden_pattern" LiteTerm Sources Package.swift project.yml LiteTerm.xcodeproj/project.pbxproj || true)
    process_matches=$(rg -n "$process_pattern" LiteTerm Sources Package.swift project.yml LiteTerm.xcodeproj/project.pbxproj || true)
else
    forbidden_matches=$(/usr/bin/grep -R -E -n -i "$forbidden_pattern" LiteTerm Sources Package.swift project.yml LiteTerm.xcodeproj/project.pbxproj || true)
    process_matches=$(/usr/bin/grep -R -E -n "$process_pattern" LiteTerm Sources Package.swift project.yml LiteTerm.xcodeproj/project.pbxproj || true)
fi
if test -n "$forbidden_matches$process_matches"; then
    printf '%s\n' "$forbidden_matches"
    printf '%s\n' "$process_matches"
    fail "forbidden V0.1 product addition found in production/project scope"
fi
pass "production/project scope contains no forbidden product additions"

supplemental_secret_pattern='"(password|privateKey|private_key|passphrase|secret|token)"'
if command -v rg >/dev/null 2>&1; then
    secret_matches=$(rg -n -i "$supplemental_secret_pattern" Sources/LiteTermCore/Hosts/SSHHost.swift Sources/LiteTermCore/Hosts/HostRepository.swift LiteTerm/Features/FileAccess/FolderAuthorizationStore.swift || true)
else
    secret_matches=$(/usr/bin/grep -E -n -i "$supplemental_secret_pattern" Sources/LiteTermCore/Hosts/SSHHost.swift Sources/LiteTermCore/Hosts/HostRepository.swift LiteTerm/Features/FileAccess/FolderAuthorizationStore.swift || true)
fi
if test -n "$secret_matches"; then
    printf '%s\n' "$secret_matches"
    fail "supplemental static scan found a secret-bearing serialized-key literal"
fi
pass "behavioral Core runner exact-key check passed; supplemental persisted-key literal scan found no match"

configured_remotes=$(git remote)
if test -z "$configured_remotes"; then
    printf 'INFO: no Git remote is currently configured; a remote is optional.\n'
else
    printf 'INFO: Git remote names: %s\n' "$configured_remotes"
fi

if xcodebuild -version >/dev/null 2>&1 && ! xcode-select -p | /usr/bin/grep -q '/CommandLineTools$'; then
    derived_data=$(mktemp -d "${TMPDIR:-/tmp}/LiteTerm-Verify-DerivedData.XXXXXX")
    tracked_status_before=$(git status --porcelain=v1 --untracked-files=no)
    working_diff_before=$(git diff --no-ext-diff)
    staged_diff_before=$(git diff --cached --no-ext-diff)
    xcodebuild \
        -project LiteTerm.xcodeproj \
        -scheme LiteTerm \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$derived_data" \
        -disableAutomaticPackageResolution \
        -onlyUsePackageVersionsFromResolvedFile \
        CODE_SIGNING_ALLOWED=NO \
        build-for-testing
    tracked_status_after=$(git status --porcelain=v1 --untracked-files=no)
    working_diff_after=$(git diff --no-ext-diff)
    staged_diff_after=$(git diff --cached --no-ext-diff)
    test "$tracked_status_before" = "$tracked_status_after" || fail "full-Xcode build changed tracked status"
    test "$working_diff_before" = "$working_diff_after" || fail "full-Xcode build changed the tracked working diff"
    test "$staged_diff_before" = "$staged_diff_after" || fail "full-Xcode build changed the staged diff"
    pass "full-Xcode build left tracked and staged source state unchanged"
    pass "full-Xcode iOS Simulator build-for-testing"
    printf 'OPEN: simulator test execution, physical-iPad, live-SSH, RSS, archive privacy report, and App Store review still require their named environments.\n'
else
    printf 'OPEN/SKIP: full Xcode is not selected; app build, simulator/device tests, archive privacy report, RSS, live SSH, and App Store review are not passed.\n'
fi

printf 'PORTABLE CANDIDATE CHECKS COMPLETE: this is not a release pass.\n'
