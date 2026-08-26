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

command -v rg >/dev/null 2>&1 || fail "ripgrep is required for the privacy verifier"

production_scope='LiteTerm Sources LiteTermPythonBridge Package.swift project.yml LiteTerm.xcodeproj/project.pbxproj'
forbidden_pattern='NodeRuntime|PythonKit|NSTask([^[:alnum:]_]|$)|UIBackgroundModes|beginBackgroundTask|NSBonjourServices|CKContainer|CloudKit|Firebase|Crashlytics|Sentry|TelemetryClient|AnalyticsSDK'
forbidden_api_pattern='(^|[^[:alnum:]_.])(posix_spawn|popen|system|fork|execv|execve|execvp|dlopen)[[:space:]]*\('
process_pattern='(^|[^[:alnum:]_])(Foundation[.])?Process[[:space:]]*\('
forbidden_matches=$(rg -n "$forbidden_pattern" $production_scope || true)
forbidden_api_matches=$(rg -n "$forbidden_api_pattern" $production_scope || true)
process_matches=$(rg -n "$process_pattern" $production_scope || true)
if test -n "$forbidden_matches$forbidden_api_matches$process_matches"; then
    printf '%s\n' "$forbidden_matches"
    printf '%s\n' "$forbidden_api_matches"
    printf '%s\n' "$process_matches"
    fail "unreviewed process, runtime, background, cloud, or telemetry capability found"
fi
pass "no unreviewed process, runtime, background, cloud, or telemetry capability"

listener=LiteTerm/Features/Workspace/Runtime/LoopbackPreviewServer.swift
test "$(rg -n -F '.bind(host: "127.0.0.1", port: 0)' "$listener" | wc -l | tr -d ' ')" = 1 \
    || fail "workspace preview must bind exactly once to 127.0.0.1:0"
listener_scope='LiteTerm/Features/Workspace LiteTerm/Resources/Info.plist project.yml LiteTerm.xcodeproj/project.pbxproj'
listener_matches=$(rg -n '0[.]0[.]0[.]0|\[::\]|host:[[:space:]]*nil|NSBonjourServices' $listener_scope || true)
if test -n "$listener_matches"; then
    printf '%s\n' "$listener_matches"
    fail "non-loopback, wildcard, or Bonjour listener declaration found"
fi
pass "workspace listener is ephemeral loopback-only with no Bonjour declaration"

logging_matches=$(rg -n 'NSLog|os_log|Logger[[:space:]]*\(|print[[:space:]]*\(' LiteTerm/Features/Workspace LiteTermPythonBridge || true)
if test -n "$logging_matches"; then
    printf '%s\n' "$logging_matches"
    fail "workspace or Python bridge contains a content-capable logging sink"
fi
pass "workspace and Python bridge contain no content-capable logging sink"

persistence_files=$(rg -l 'UserDefaults|defaults[.]set' LiteTerm/Features/Workspace || true)
test "$persistence_files" = 'LiteTerm/Features/Workspace/WorkspaceProfileStore.swift' \
    || fail "workspace persistence expanded beyond the reviewed non-sensitive profile store"
port_disclosure=$(rg -n -i 'secret|token|cookie|authentication' LiteTerm/Features/Workspace/WorkspacePortsPanel.swift || true)
if test -n "$port_disclosure"; then
    printf '%s\n' "$port_disclosure"
    fail "Ports UI references authentication material"
fi
pass "workspace persistence and Ports UI retain the reviewed data-minimization boundary"

absolute_project_paths=$(rg -n '/Users/|/private/var/' LiteTerm.xcodeproj/project.pbxproj LiteTerm.xcodeproj/xcshareddata/xcschemes/LiteTerm.xcscheme || true)
if test -n "$absolute_project_paths"; then
    printf '%s\n' "$absolute_project_paths"
    fail "generated Xcode project contains a host absolute path"
fi

tracked_artifacts=$(git ls-files .build DerivedData build .cache/cpython .artifacts/cpython)
if test -n "$tracked_artifacts"; then
    printf '%s\n' "$tracked_artifacts"
    fail "generated build or CPython artifact content is tracked"
fi
pass "generated project and tracked tree contain no host path or generated runtime artifact"

/usr/bin/ruby -rjson -e '
  %w[
    LiteTerm/Resources/PrivacyInfo.xcprivacy
    Sources/LiteTermCore/Resources/PrivacyInfo.xcprivacy
  ].each do |path|
    json = IO.popen(["/usr/bin/plutil", "-convert", "json", "-o", "-", path], &:read)
    manifest = JSON.parse(json)
    abort("FAIL: privacy tracking enabled") unless manifest["NSPrivacyTracking"] == false
    abort("FAIL: privacy tracking domains declared") unless manifest["NSPrivacyTrackingDomains"] == []
    abort("FAIL: collected data types declared") unless manifest["NSPrivacyCollectedDataTypes"] == []
  end
'
pass "privacy manifests declare no tracking, tracking domains, or collected data types"
