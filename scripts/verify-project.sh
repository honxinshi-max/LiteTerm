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
    if rg -n '\blocalGeneration\b' LiteSpace/Features/Terminal/TerminalSessionCoordinator.swift; then
        fail "app coordinator contains the removed localGeneration identifier"
    fi
else
    if /usr/bin/grep -n 'localGeneration' LiteSpace/Features/Terminal/TerminalSessionCoordinator.swift; then
        fail "app coordinator contains the removed localGeneration identifier"
    fi
fi
pass "known removed app-state identifiers are absent"

./scripts/verify-brand-identity.sh

for required_path in \
    Package.swift \
    project.yml \
    LiteSpace.xcodeproj/project.pbxproj \
    LiteSpace.xcodeproj/xcshareddata/xcschemes/LiteSpace.xcscheme \
    LiteSpace.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
    LiteSpace/Resources/Info.plist \
    LiteSpace/Resources/PrivacyInfo.xcprivacy \
    LiteSpace/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json \
    LiteSpace/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png \
    Sources/LiteSpaceCore/Resources/PrivacyInfo.xcprivacy \
    THIRD_PARTY_NOTICES.md \
    docs/product-scope.md \
    docs/verification/local-workspaces-acceptance.md \
    docs/verification/local-workspaces-ipad.md \
    docs/verification/local-workspaces-privacy.md \
    docs/verification/local-workspaces-verification.md \
    docs/verification/python-runtime.md \
    Vendor/CPython/source.json \
    Vendor/CPython/README.md \
    LiteSpacePythonBridge/include/LiteSpacePythonBridge.h \
    LiteSpacePythonBridge/LiteSpacePythonBridge.m \
    Sources/LiteSpaceCore/Workspace/WorkspaceKind.swift \
    Sources/LiteSpaceCore/Workspace/WorkspaceClassifier.swift \
    Sources/LiteSpaceCore/Workspace/WorkspaceGateReducer.swift \
    Sources/LiteSpaceCore/Workspace/ReadyPortLeasePolicy.swift \
    Sources/LiteSpaceCore/Workspace/BoundedRuntimeOutput.swift \
    LiteSpace/Features/Workspace/WorkspaceController.swift \
    LiteSpace/Features/Workspace/Runtime/LoopbackPreviewServer.swift \
    LiteSpace/Features/Workspace/Runtime/WebWorkspaceRunner.swift \
    LiteSpace/Features/Workspace/Runtime/PythonWorkspaceRunner.swift \
    LiteSpace/Features/Workspace/Runtime/SwiftWorkspaceAdvisor.swift \
    scripts/verify-cpython-artifact.sh \
    scripts/verify-brand-identity.sh \
    scripts/verify-local-workspaces.sh \
    scripts/verify-workspace-privacy.sh \
    Tests/Fixtures/Workspace/WebPassing/index.html \
    Tests/Fixtures/Workspace/WebFailing/index.html \
    Tests/Fixtures/Workspace/PythonScript/main.py \
    Tests/Fixtures/Workspace/PythonWSGI/main.py \
    Tests/Fixtures/Workspace/PythonFailing/main.py \
    Tests/Fixtures/Workspace/SwiftCheck/Package.swift \
    Tests/Fixtures/Workspace/SwiftCheck/Sources/main.swift \
    Tests/LiteSpaceCoreTests/AcceptanceFlowTests.swift \
    Tests/SSHIntegrationRunner/Package.swift \
    Tests/SSHIntegrationRunner/Package.resolved \
    Tests/SSHIntegrationRunner/main.swift \
    Tests/SSHIntegrationRunner/SSHAuthenticationDelegate.swift \
    Tests/SSHIntegrationRunner/SSHClient.swift \
    Tests/SSHIntegrationRunner/SSHClientConfiguration.swift \
    Tests/SSHIntegrationRunner/SSHHostKeyValidator.swift \
    Tests/SSHIntegrationRunner/SSHTerminalHandler.swift \
    scripts/run-ssh-integration-tests.sh
do
    test -f "$required_path" || fail "missing $required_path"
done
pass "required project files exist"

./scripts/verify-cpython-artifact.sh
pass "pinned CPython source metadata verified"

core_output=$(./scripts/run-core-tests.sh)
printf '%s\n' "$core_output"
printf '%s\n' "$core_output" | /usr/bin/grep -q '^PASS: 52 LiteSpaceCore checks$' \
    || fail "portable runner did not execute the reviewed 52-check workspace suite"
pass "actual LiteSpaceCore custom runner executed"

./scripts/run-ssh-integration-tests.sh
pass "real loopback SSH integration runner executed"

swift build
pass "portable LiteSpaceCore package builds"
printf 'OPEN/SKIP: standard XCTest is not enabled in the default Command Line Tools package; use the documented explicit real-XCTest opt-in or the full-Xcode scheme.\n'

/usr/bin/plutil -lint \
    LiteSpace.xcodeproj/project.pbxproj \
    LiteSpace/Resources/Info.plist \
    LiteSpace/Resources/PrivacyInfo.xcprivacy \
    Sources/LiteSpaceCore/Resources/PrivacyInfo.xcprivacy >/dev/null
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
%w[LiteSpacePythonBridge LiteSpaceCore LiteSpace LiteSpaceCoreTests LiteSpaceSSHTests LiteSpacePythonBridgeTests LiteSpaceUITests].each do |target|
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

assert(project.dig("targets", "LiteSpaceCoreTests", "sources") == ["Tests/LiteSpaceCoreTests"], "Core test target source membership changed")
assert(project.dig("targets", "LiteSpaceSSHTests", "sources") == ["Tests/LiteSpaceSSHTests"], "SSH test target source membership changed")
assert(project.dig("targets", "LiteSpaceUITests", "sources") == ["LiteSpaceUITests"], "UI test target source membership changed")
assert(
  project.dig("schemes", "LiteSpace", "test", "targets") == %w[LiteSpaceCoreTests LiteSpaceSSHTests LiteSpacePythonBridgeTests LiteSpaceUITests],
  "shared scheme test-target membership changed"
)

scheme = REXML::Document.new(File.read("LiteSpace.xcodeproj/xcshareddata/xcschemes/LiteSpace.xcscheme"))
scheme_test_targets = REXML::XPath.match(scheme, "//TestAction/Testables/TestableReference/BuildableReference").map do |element|
  element.attributes["BlueprintName"]
end
assert(
  scheme_test_targets == %w[LiteSpaceCoreTests LiteSpaceSSHTests LiteSpacePythonBridgeTests LiteSpaceUITests],
  "generated shared scheme does not build all test targets"
)

def explicit_resource_paths(project, target_name)
  project.dig("targets", target_name, "sources").each_with_object([]) do |entry, paths|
    paths << entry["path"] if entry.is_a?(Hash) && entry["buildPhase"] == "resources"
  end
end

assert(
  explicit_resource_paths(project, "LiteSpaceCore") == ["Sources/LiteSpaceCore/Resources/PrivacyInfo.xcprivacy"],
  "Core privacy manifest must be the framework's explicit resource"
)
assert(
  explicit_resource_paths(project, "LiteSpace").include?("LiteSpace/Resources/PrivacyInfo.xcprivacy"),
  "app privacy manifest must be the app's explicit resource"
)

package_json, package_status = Open3.capture2("swift", "package", "dump-package")
assert(package_status.success?, "Swift package model dump failed")
package = JSON.parse(package_json)
core_package_target = package.fetch("targets").find { |target| target["name"] == "LiteSpaceCore" }
assert(core_package_target, "LiteSpaceCore Swift package target missing")
assert(
  core_package_target.fetch("resources") == [{"path" => "Resources/PrivacyInfo.xcprivacy", "rule" => {"process" => {}}}],
  "LiteSpaceCore Swift package privacy resource declaration changed"
)
workspace_support_target = package.fetch("targets").find { |target| target["name"] == "LiteSpaceWorkspaceSupport" }
assert(workspace_support_target, "LiteSpaceWorkspaceSupport Swift package target missing")
workspace_support_products = workspace_support_target.fetch("dependencies").map do |dependency|
  dependency["product"]&.first
end.compact
assert(workspace_support_products.include?("NIOHTTP1"), "workspace support target must link NIOHTTP1")
default_package_target_names = package.fetch("targets").map { |target| target.fetch("name") }
assert(!default_package_target_names.include?("XCTest"), "default package must not contain a fake XCTest target")
assert(!default_package_target_names.include?("LiteSpaceCoreTests"), "default package must not expose XCTest without explicit opt-in")

opt_in_package_json, opt_in_package_status = Open3.capture2(
  {"LITESPACE_ENABLE_SWIFTPM_XCTESTS" => "1"},
  "swift", "package", "dump-package"
)
assert(opt_in_package_status.success?, "opt-in Swift package model dump failed")
opt_in_package = JSON.parse(opt_in_package_json)
opt_in_target_names = opt_in_package.fetch("targets").map { |target| target.fetch("name") }
assert(opt_in_target_names.include?("LiteSpaceCoreTests"), "explicit real-XCTest opt-in target is missing")
assert(!opt_in_target_names.include?("XCTest"), "opt-in package must use the toolchain XCTest rather than a fake target")

app_icon_contents = JSON.parse(File.read("LiteSpace/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"))
assert(
  app_icon_contents == {
    "images" => [{
      "filename" => "AppIcon-1024.png",
      "idiom" => "universal",
      "platform" => "ios",
      "size" => "1024x1024"
    }],
    "info" => {"author" => "xcode", "version" => 1}
  },
  "AppIcon Contents.json must map the single iOS 1024 image"
)
app_icon_png = File.binread("LiteSpace/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
assert(app_icon_png.byteslice(0, 8) == "\x89PNG\r\n\x1A\n".b, "AppIcon image must have a PNG signature")
assert(app_icon_png.byteslice(12, 4) == "IHDR", "AppIcon PNG must begin with IHDR")
width, height = app_icon_png.byteslice(16, 8).unpack("NN")
assert([width, height] == [1024, 1024], "AppIcon PNG dimensions must be 1024x1024")
assert(![4, 6].include?(app_icon_png.getbyte(25)), "AppIcon PNG must not contain an alpha channel")
assert(app_icon_png.bytesize.between?(1024, 1_048_576), "AppIcon PNG byte size is unreasonable")

resolved = JSON.parse(File.read("LiteSpace.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
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

integration_resolved = JSON.parse(File.read("Tests/SSHIntegrationRunner/Package.resolved"))
integration_actual_resolved = integration_resolved.fetch("pins").to_h do |pin|
  [pin.fetch("identity"), pin.dig("state", "revision")]
end
integration_expected_resolved = expected_resolved.reject do |identity, _revision|
  %w[swift-argument-parser swiftterm].include?(identity)
end
assert(
  integration_actual_resolved == integration_expected_resolved,
  "SSH integration Package.resolved does not match the reviewed transport graph"
)

integration_source_links = {
  "SSHAuthenticationDelegate.swift" => "../../LiteSpace/Features/SSH/SSHAuthenticationDelegate.swift",
  "SSHClient.swift" => "../../LiteSpace/Features/SSH/SSHClient.swift",
  "SSHClientConfiguration.swift" => "../../LiteSpace/Features/SSH/SSHClientConfiguration.swift",
  "SSHHostKeyValidator.swift" => "../../LiteSpace/Features/SSH/SSHHostKeyValidator.swift",
  "SSHTerminalHandler.swift" => "../../LiteSpace/Features/SSH/SSHTerminalHandler.swift"
}
integration_source_links.each do |name, expected_target|
  path = File.join("Tests/SSHIntegrationRunner", name)
  assert(File.symlink?(path), "#{path} must be a symlink to the reviewed production source")
  assert(File.readlink(path) == expected_target, "#{path} symlink target changed")
end

info_json, info_status = Open3.capture2("/usr/bin/plutil", "-convert", "json", "-o", "-", "LiteSpace/Resources/Info.plist")
assert(info_status.success?, "Info.plist JSON conversion failed")
info = JSON.parse(info_json)
expected_orientations = %w[
  UIInterfaceOrientationPortrait
  UIInterfaceOrientationPortraitUpsideDown
  UIInterfaceOrientationLandscapeLeft
  UIInterfaceOrientationLandscapeRight
]
assert(info["UISupportedInterfaceOrientations~ipad"] == expected_orientations, "iPad orientations changed")
expected_lan_copy = "LiteSpace uses your local network only when you connect to an SSH host you chose, such as a Mac on your LAN."
assert(info["NSLocalNetworkUsageDescription"] == expected_lan_copy, "local-network explanation changed")
assert(!info.key?("NSBonjourServices"), "Bonjour services must not be declared without discovery")

privacy_json, privacy_status = Open3.capture2("/usr/bin/plutil", "-convert", "json", "-o", "-", "LiteSpace/Resources/PrivacyInfo.xcprivacy")
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
  "/usr/bin/plutil", "-convert", "json", "-o", "-", "Sources/LiteSpaceCore/Resources/PrivacyInfo.xcprivacy"
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

pbx_json, pbx_status = Open3.capture2("/usr/bin/plutil", "-convert", "json", "-o", "-", "LiteSpace.xcodeproj/project.pbxproj")
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

app_resource_refs = resource_refs(objects, "LiteSpace")
core_resource_refs = resource_refs(objects, "LiteSpaceCore")
app_privacy_refs = app_resource_refs.select { |_id, path| path == "PrivacyInfo.xcprivacy" }
core_privacy_refs = core_resource_refs.select { |_id, path| path == "PrivacyInfo.xcprivacy" }
assert(app_privacy_refs.length == 1, "app target must contain exactly one privacy manifest resource")
assert(core_privacy_refs.length == 1, "Core target must contain exactly one privacy manifest resource")
assert(app_privacy_refs.first.first != core_privacy_refs.first.first, "app and Core targets must use distinct privacy manifest file references")
assert(app_resource_refs.any? { |_id, path| path == "THIRD_PARTY_NOTICES.md" }, "third-party notices are not in LiteSpace resources")
assert(app_resource_refs.any? { |_id, path| path == "Assets.xcassets" }, "app asset catalog is not in LiteSpace resources")
_app_target_id, app_target = objects.find do |_id, object|
  object["isa"] == "PBXNativeTarget" && object["name"] == "LiteSpace"
end
app_configuration_ids = objects.fetch(app_target.fetch("buildConfigurationList")).fetch("buildConfigurations")
app_configurations = app_configuration_ids.map { |id| objects.fetch(id).fetch("buildSettings") }
assert(
  app_configurations.all? { |settings| settings["ASSETCATALOG_COMPILER_APPICON_NAME"] == "AppIcon" },
  "all LiteSpace build configurations must select the AppIcon set"
)
target_names = objects.values.select { |object| object["isa"] == "PBXNativeTarget" }.map { |object| object["name"] }
%w[LiteSpacePythonBridge LiteSpaceCoreTests LiteSpaceSSHTests LiteSpacePythonBridgeTests LiteSpaceUITests].each do |name|
  assert(target_names.include?(name), "#{name} generated target missing")
end

app_dependencies = project.dig("targets", "LiteSpace", "dependencies")
assert(
  app_dependencies.include?({"target" => "LiteSpacePythonBridge"}),
  "LiteSpace app target must link the Python bridge capability gate"
)
assert(
  app_dependencies.include?({"package" => "SwiftNIO", "product" => "NIOHTTP1"}),
  "LiteSpace app target must link NIOHTTP1 for the app-owned loopback listener"
)
RUBY
pass "project model, pins, targets, AppIcon, distinct privacy resources, orientations, local-network copy, and privacy declarations match"

./scripts/verify-workspace-privacy.sh
pass "local workspace privacy and capability boundary verifier executed"

python_bridge_log_matches=$(rg -n 'NSLog|os_log|fprintf|printf|puts' LiteSpacePythonBridge || true)
if test -n "$python_bridge_log_matches"; then
    printf '%s\n' "$python_bridge_log_matches"
    fail "Python bridge must not log source, paths, output, or runtime details"
fi
pass "Python bridge contains no logging sink"

test "$(rg -n 'return false;' LiteSpacePythonBridge/LiteSpacePythonBridge.m | wc -l | tr -d ' ')" -ge 1 \
    || fail "unverified Python bridge must remain capability-gated"
pass "unverified Python bridge remains fail-closed"

supplemental_secret_pattern='"(password|privateKey|private_key|passphrase|secret|token)"'
if command -v rg >/dev/null 2>&1; then
    secret_matches=$(rg -n -i "$supplemental_secret_pattern" Sources/LiteSpaceCore/Hosts/SSHHost.swift Sources/LiteSpaceCore/Hosts/HostRepository.swift LiteSpace/Features/FileAccess/FolderAuthorizationStore.swift || true)
else
    secret_matches=$(/usr/bin/grep -E -n -i "$supplemental_secret_pattern" Sources/LiteSpaceCore/Hosts/SSHHost.swift Sources/LiteSpaceCore/Hosts/HostRepository.swift LiteSpace/Features/FileAccess/FolderAuthorizationStore.swift || true)
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
    derived_data=$(mktemp -d "${TMPDIR:-/tmp}/LiteSpace-Verify-DerivedData.XXXXXX")
    tracked_status_before=$(git status --porcelain=v1 --untracked-files=no)
    working_diff_before=$(git diff --no-ext-diff)
    staged_diff_before=$(git diff --cached --no-ext-diff)
    xcodebuild \
        -project LiteSpace.xcodeproj \
        -scheme LiteSpace \
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
