# Local workspaces privacy and archive gate

Date: 2026-08-26

## Outcome

Source-level privacy and capability checks are **PASS**. Archive-level privacy, signing, distribution questionnaire, export compliance, and App Review are **OPEN** because full Xcode and a signed Release Archive are unavailable.

## Verified source-level evidence

| Check | Status | Evidence boundary |
| --- | --- | --- |
| Tracking and collection declarations | PASS | App and Core privacy manifests declare no tracking, tracking domains, or collected data types. Required-reason API declarations remain explicit. This proves manifest source content, not the merged archive report. |
| Telemetry and content logging | PASS | Static verification rejects reviewed telemetry/crash SDK names and content-capable logging sinks in workspace and Python bridge code. |
| Runtime capabilities | PASS | Static verification rejects unreviewed process/shell spawning, dynamic loading, background keepalive, cloud containers, Bonjour, wildcard/LAN listeners, and Node/Python wrapper runtimes. |
| Loopback listener | PASS | The source and real portable integration bind one ephemeral `127.0.0.1` listener; the verifier rejects public/wildcard declarations. |
| Workspace persistence | PASS | Workspace persistence is confined to the reviewed profile store keyed by an opaque digest. Problems and runtime output remain bounded in memory and have privacy-safe persistence projections. |
| Ports disclosure | PASS | The Ports UI does not reference authentication material; the run secret remains private and in memory. |
| Host paths and generated artifacts | PASS | Generated Xcode files contain no host absolute path; no build, cache, or CPython artifact content is tracked. |
| Third-party notices | PASS | The notice inventory covers the pinned Swift graph and the CPython 3.14.7 source candidate; no CPython binary is committed. |

## Open archive and distribution evidence

| Gate | Status | Required evidence |
| --- | --- | --- |
| Release Archive contents | OPEN | Inspect the signed archive for merged privacy manifests, required-reason APIs, bundled notices/licenses, executable content, embedded frameworks, and unexpected SDKs. |
| CPython bundle inventory | OPEN | Verify the exact XCFramework manifest and bundle the matching upstream license; confirm no unreviewed native extension or package is present. |
| Code signing and entitlements | OPEN | Confirm the signed product has only reviewed entitlements and contains no background or public-network capability expansion. |
| App Store Connect privacy questionnaire | OPEN | Complete against the observed archive and product behavior; do not infer answers solely from source scans. |
| Export compliance | OPEN | Review the final cryptography/export classification for the signed distribution. |
| App Review | OPEN | Approval of the visible/editable user-code workflow is external and cannot be inferred from engineering checks. |

## Data-minimization rule for later evidence

Retain only runtime kind, normalized gate state/category, duration, bounded counters, aggregate RSS, and pass/fail. Do not record source, file content, filename, full path, command, stdout, stderr, credential, host fingerprint, user identity, network destination, IP address, port secret, or package content.
