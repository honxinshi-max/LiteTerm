# Local workspaces verification

Date: 2026-08-26

## Outcome

The Web, Python, Swift, terminal, diagnostics, and Ready-port contracts pass the repository's portable candidate gates. This is not an iOS release pass. The current Mac has Apple Command Line Tools only, so full-Xcode compilation, iPad Simulator execution, WebKit/UI automation, and embedded-CPython execution remain open.

No source, filename, full path, command, runtime output, credential, network destination, port, or preview secret is retained in this record.

## Environment

- macOS 26.5 build 25F71.
- Apple Swift 6.3.2 targeting arm64 macOS.
- Active developer directory: Apple Command Line Tools.
- Full Xcode: unavailable.
- iOS Simulator: unavailable under the active developer directory.
- Verified feature-branch checkpoint before this record: `a719fd2c50f9901089592f4d8421fe232c94342c`.

## Evidence gates

| Gate | Status | Evidence | Boundary |
| --- | --- | --- | --- |
| Portable workspace behavior | PASS | `scripts/run-core-tests.sh` reported 52 reviewed checks. | Foundation/macOS-compatible behavior plus the real local services compiled into the portable support target; not an iOS XCTest pass. |
| Synthetic project fixtures | PASS | Repository-owned Web passing/failing, Python script/WSGI/failing, and Swift package fixtures passed real inventory/classification; Web failure blocked a missing local resource and Swift remained check-only. | Python fixtures prove recognition and fail-closed routing while the runtime artifact is absent; they do not prove CPython execution. |
| Portable package build | PASS | `swift build` exited 0 from the pinned graph. | Not an iOS target or App archive build. |
| Ready/port invariant | PASS | The portable reducer, real loopback server, health probe, and controller checks prove no published port before the third current health success and immediate withdrawal on edit/invalidity. | Simulator/background/device lifecycle still requires full Xcode and a device. |
| Authenticated loopback Web service | PASS | A real ephemeral `127.0.0.1` listener served authenticated requests; unauthenticated requests received no project content; the verifier rejects wildcard, LAN, and Bonjour declarations. | WebKit smoke/UI execution on iOS is open. |
| Python source and artifact contract | PASS | Exact CPython 3.14.7 source URL, SHA-256, tag commit, build command, and required slices passed `verify-cpython-artifact.sh`. | The XCFramework artifact is absent, so this is source-lineage evidence only. |
| Python capability gate and WSGI envelopes | PASS | Missing-artifact routing, audit/import policy primitives, bounded request/response envelopes, header validation, and app-owned-listener ownership passed portable checks. | CPython compile, unittest, script, WSGI-callable execution, cancellation, finalization, and restart are SKIP until a verified artifact and simulator exist. |
| Swift diagnostics boundary | PASS | Swift fixture and advisor checks label the result `Lightweight diagnostics`, expose an explicit Playgrounds handoff, and publish no port. | No local Swift compilation claim. |
| Privacy/static capability scan | PASS | `scripts/verify-workspace-privacy.sh` found no unreviewed process, dynamic-loading, background, cloud, telemetry, public-listener, content-logging, host-path, or tracked-artifact capability. | Archive privacy report and App Store questionnaire remain open. |
| Existing SSH loopback regression | PASS | `scripts/verify-project.sh` retained the real SwiftNIO SSH integration pass. | External OpenSSH and physical-iPad SSH remain separate V0.1 gates. |
| SwiftPM XCTest opt-in | OPEN | `LITETERM_ENABLE_SWIFTPM_XCTESTS=1 swift test --disable-sandbox` reached the real test target and failed because this Command Line Tools installation has no `XCTest` module. | Re-run with full Xcode selected; this open environment is not converted into a pass. |
| Full-Xcode iOS build and simulator suite | OPEN | `xcodebuild` is unavailable with the active Command Line Tools developer directory. | Must compile all targets and execute the named iPad Simulator tests from the resolved package graph. |
| UI and WebKit runtime acceptance | OPEN | No iOS Simulator is available. | Landscape/portrait, keyboard, editor, Terminal/Problems/Ports, preview, mutation invalidation, VoiceOver, and Swift handoff UI are unexecuted. |

## Commands and results

| Command | Result |
| --- | --- |
| `./scripts/run-core-tests.sh` | PASS, 52 checks |
| `swift build` | PASS |
| `./scripts/verify-workspace-privacy.sh` | PASS |
| `./scripts/verify-local-workspaces.sh` | PASS with named OPEN/SKIP gates |
| `./scripts/verify-project.sh` | PASS portable candidate; not a release pass |
| `LITETERM_ENABLE_SWIFTPM_XCTESTS=1 swift test --disable-sandbox` | OPEN environment: `XCTest` module unavailable |

## Next evidence

1. Install and select full Xcode with the required iOS Simulator runtime.
2. Build the reviewed CPython iOS XCFramework and verify its per-file manifest.
3. Run the complete scheme on the named iPad Simulator, including UI, WebKit, Python bridge, script, unittest, WSGI, cancellation, and restart cases.
4. Keep physical-iPad resource, archive privacy, signing, and App Review evidence in their separate gates.
