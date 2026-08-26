# LiteSpace Local Workspaces Core, Web, and UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the lightweight iPad workspace shell, Web runtime, Swift advisory path, diagnostics, bottom terminal, and fail-closed Ready/port gate.

**Architecture:** Keep all deterministic policies in the Foundation-only `LiteSpaceCore` target. Put coordinated Files access, WebKit smoke checks, the authenticated loopback server, and adaptive SwiftUI presentation in the iOS app target. `WorkspaceController` is the sole lifecycle owner and feeds every asynchronous result through a generation-checked reducer; the UI may only read `publishedPort` from a current `ReadyPortLease`.

**Tech Stack:** Swift 6, Foundation, SwiftUI, WebKit, Crypto SHA-256, SwiftNIO/NIOHTTP1, SwiftTerm, XCTest, the existing portable SwiftPM runner.

**Spec:** `docs/superpowers/specs/2026-08-26-litespace-local-workspaces-design.md`

## Global Constraints

- Preserve the existing Local/SSH flows and all security-scoped file-access behavior.
- Never bind a preview listener to `0.0.0.0`, `::`, a LAN address, Bonjour, or a fixed port. Bind only `127.0.0.1:0`.
- Never persist source, filenames, full paths, commands, stdout/stderr, URLs, secrets, IPs, host fingerprints, or package content.
- Keep one active document, one runtime, one listener, one preview, and one gate generation.
- Withdraw `publishedPort` before processing edits, root changes, provider changes, lifecycle changes, runtime exit, or health expiry.
- Keep Core portable: no UIKit, WebKit, Network, NIO, or Crypto imports under `Sources/LiteSpaceCore`.
- Do not add Node/npm, shell execution, `Process`, `NSTask`, `dlopen`, SFTP, Docker, VM, background keepalive, unrestricted sockets, telemetry, or remote crash reporting.
- Do not use bulk deletion or cleanup commands in implementation scripts.

---

## Task 1: Add Project Classification and Inventory Limits

**Files:**

- Create: `Sources/LiteSpaceCore/Workspace/WorkspaceKind.swift`
- Create: `Sources/LiteSpaceCore/Workspace/WorkspaceClassifier.swift`
- Create: `Sources/LiteSpaceCore/Workspace/WorkspaceInventoryPolicy.swift`
- Create: `Tests/LiteSpaceCoreTests/WorkspaceClassifierTests.swift`
- Create: `Tests/LiteSpaceCoreTests/WorkspaceInventoryPolicyTests.swift`
- Modify: `Tests/TestRunner/main.swift`

- [ ] Write failing XCTest and portable-runner cases for standalone Swift, Python, static Web, `package.json` without `index.html` as `nodeRequired`, conflicting supported strong indicators as ambiguous, static `index.html` plus `package.json` as Web, unsupported projects, excluded paths, credential-like names, symlink entries, 1,000 entries, 20 MiB source total, and 5 MiB single-file limits.
- [ ] Run `LITESPACE_ENABLE_SWIFTPM_XCTESTS=1 swift test --filter 'Workspace(Classifier|InventoryPolicy)Tests'` and record the expected compile failure because the types do not exist.
- [ ] Add these public Core contracts exactly:

```swift
public enum WorkspaceKind: String, Codable, CaseIterable, Sendable {
    case web, python, swift, nodeRequired, unsupported, ambiguous
}

public enum WorkspaceIndicator: String, Hashable, Sendable {
    case packageSwift, swiftSource, pyproject, requirements, pythonSource
    case indexHTML, packageJSON
}

public struct WorkspaceInventoryEntry: Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int
    public let isDirectory: Bool
    public let isRegularFile: Bool
    public let isSymbolicLink: Bool
}

public struct WorkspaceClassification: Equatable, Sendable {
    public let kind: WorkspaceKind
    public let candidates: Set<WorkspaceKind>
    public let indicators: Set<WorkspaceIndicator>
}
```

- [ ] Implement `WorkspaceClassifier.classify(relativePaths:)` with deterministic root-relative matching: one supported strong-indicator family selects that kind, two or more supported families produce session-level ambiguity, and `package.json` is `nodeRequired` only when no runnable static `index.html` or other supported family is present.
- [ ] Implement `WorkspaceInventoryPolicy.evaluate(_:)` so `.git`, `.svn`, build/cache folders, hidden entries, credential-like files, binaries, and symlinks are excluded; return accepted entries plus typed, non-sensitive rejection reasons.
- [ ] Run the focused XCTest command and `scripts/run-core-tests.sh`; verify all new cases pass.
- [ ] Commit with `git add Sources/LiteSpaceCore/Workspace Tests/LiteSpaceCoreTests Tests/TestRunner/main.swift && git commit -m "feat: classify bounded local workspaces"`.

## Task 2: Add Profiles, Snapshots, Problems, and Bounded Output

**Files:**

- Create: `Sources/LiteSpaceCore/Workspace/WorkspaceProfile.swift`
- Create: `Sources/LiteSpaceCore/Workspace/WorkspaceSnapshot.swift`
- Create: `Sources/LiteSpaceCore/Workspace/WorkspaceProblem.swift`
- Create: `Sources/LiteSpaceCore/Workspace/BoundedRuntimeOutput.swift`
- Create: `Sources/LiteSpaceCore/Workspace/RuntimeResourceBudget.swift`
- Create: `Tests/LiteSpaceCoreTests/WorkspaceSnapshotTests.swift`
- Create: `Tests/LiteSpaceCoreTests/WorkspaceProblemTests.swift`
- Create: `Tests/LiteSpaceCoreTests/BoundedRuntimeOutputTests.swift`
- Modify: `Tests/TestRunner/main.swift`

- [ ] Write failing cases for normalized relative entrypoints and health paths, manifest order independence, digest changes, root-relative problem display, non-sensitive persistence projection, 2,000-line/2-MiB output truncation, and the approved candidate resource budgets.
- [ ] Run the focused tests and record the expected missing-type failure.
- [ ] Add these contracts:

```swift
public struct WorkspaceProfile: Codable, Equatable, Sendable {
    public var kind: WorkspaceKind
    public var entrypoint: String?
    public var testConvention: WorkspaceTestConvention
    public var healthPath: String
}

public struct WorkspaceSnapshotEntry: Equatable, Sendable {
    public let relativePath: String
    public let byteCount: Int
    public let modifiedAtNanoseconds: Int64
    public let sha256: Data
}

public struct WorkspaceSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let entries: [WorkspaceSnapshotEntry]
    public let manifestSHA256: Data
}

public struct WorkspaceProblem: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let stage: WorkspaceStage
    public let severity: WorkspaceProblemSeverity
    public let category: WorkspaceProblemCategory
    public let relativePath: String?
    public let line: Int?
    public let column: Int?
    public let message: String
    public var persistenceProjection: WorkspaceProblemProjection { get }
}
```

- [ ] Implement path normalizers that reject absolute paths, `..`, backslashes, URL schemes, query/fragment syntax for health paths, and credential-like entries.
- [ ] Implement `BoundedRuntimeOutput` as a value type that accounts UTF-8 bytes, drops oldest complete lines, caps at 2,000 lines and 2 MiB, and emits one in-memory truncation marker.
- [ ] Implement `RuntimeResourceBudget.iPadCandidate` with idle 90 MiB, Web 160 MiB, Python 180 MiB, health body 256 KiB, and zero active runtime in background.
- [ ] Run the focused tests and portable runner.
- [ ] Commit with `git add Sources/LiteSpaceCore/Workspace Tests/LiteSpaceCoreTests Tests/TestRunner/main.swift && git commit -m "feat: model private workspace snapshots"`.

## Task 3: Implement the Fail-Closed Gate Reducer

**Files:**

- Create: `Sources/LiteSpaceCore/Workspace/WorkspaceGateReducer.swift`
- Create: `Sources/LiteSpaceCore/Workspace/ReadyPortLeasePolicy.swift`
- Create: `Tests/LiteSpaceCoreTests/WorkspaceGateReducerTests.swift`
- Create: `Tests/LiteSpaceCoreTests/ReadyPortLeasePolicyTests.swift`
- Modify: `Tests/TestRunner/main.swift`

- [ ] Write failing tests covering every allowed transition, every rejected transition, stale-generation events, check-only Swift, non-service Python completion, three consecutive health successes, timeout/failure, runtime exit, edit invalidation, background invalidation, root replacement, and listener mismatch.
- [ ] Assert the invariant after every test event: `publishedPort != nil` if and only if state is Ready, lease generation equals current generation, listener/runtime identities match, and the health lease is unexpired.
- [ ] Add these contracts:

```swift
public enum WorkspaceGateState: Equatable, Sendable {
    case idle, inspecting, checking, checked, testing, starting
    case completed, healthChecking(successes: Int)
    case ready(ReadyPortLease)
    case failed(WorkspaceFailureCategory), stopping
}

public enum WorkspaceGateEvent: Equatable, Sendable {
    case inspectionPassed, checkPassed, checkOnlyCompleted, testsPassed
    case serviceStarted(port: Int, listenerID: UUID, runtimeID: UUID, secretHandle: UUID)
    case scriptCompleted, healthSucceeded(expiresAt: Date)
    case healthFailed(WorkspaceFailureCategory), runtimeExited
    case stopRequested, stopped
}

public struct ReadyPortLease: Equatable, Sendable {
    public let generation: UInt64
    public let port: Int
    public let listenerID: UUID
    public let runtimeID: UUID
    public let secretHandle: UUID
    public let healthExpiresAt: Date
}

public struct WorkspaceGateReducer: Sendable {
    public private(set) var generation: UInt64
    public private(set) var state: WorkspaceGateState
    public var publishedPort: Int? { get }
    public mutating func begin() -> UInt64
    public mutating func reduce(_ event: WorkspaceGateEvent, generation: UInt64, now: Date) -> Bool
    public mutating func invalidate() -> UInt64
}
```

- [ ] Keep pending port/listener/runtime/secret data private to the reducer until the third consecutive current-generation health success creates the lease.
- [ ] Make `ReadyPortLeasePolicy.isPublishable(...)` validate the whole invariant; never let UI infer readiness from an open socket alone.
- [ ] Run focused XCTest, the portable runner, and `swift build`.
- [ ] Commit with `git add Sources/LiteSpaceCore/Workspace Tests/LiteSpaceCoreTests Tests/TestRunner/main.swift && git commit -m "feat: gate workspace ports on readiness"`.

## Task 4: Add Workspace Commands Without Weakening the Local Shell

**Files:**

- Modify: `Sources/LiteSpaceCore/LocalShell/ShellCommand.swift`
- Modify: `Sources/LiteSpaceCore/LocalShell/ShellCommandParser.swift`
- Modify: `Sources/LiteSpaceCore/LocalShell/LocalShell.swift`
- Modify: `Tests/LiteSpaceCoreTests/ShellCommandParserTests.swift`
- Modify: `Tests/LiteSpaceCoreTests/LocalShellTests.swift`
- Modify: `Tests/TestRunner/main.swift`
- Modify: `LiteSpace/Features/Terminal/TerminalSessionCoordinator.swift`

- [ ] Extend failing parser/runner tests for exactly `workspace`, `check`, `test`, `run`, `stop`, `problems`, and `ports`, all with zero arguments and no arbitrary command tail.
- [ ] Add `WorkspaceShellAction` cases `showStatus`, `check`, `test`, `run`, `stop`, `showProblems`, and `showPorts`; add `workspaceAction: WorkspaceShellAction?` to `ShellExecution`.
- [ ] Return only a typed action from `LocalShell`; do not execute runtimes or files from the parser layer.
- [ ] Add `onWorkspaceAction: ((WorkspaceShellAction) -> Void)?` to `TerminalSessionCoordinator` and dispatch only after its existing local mode/generation guards pass.
- [ ] Format action results through a separate callback that accepts already-sanitized summary lines; do not persist terminal output.
- [ ] Run parser, shell, runner, and existing terminal flow tests.
- [ ] Commit with `git add Sources/LiteSpaceCore/LocalShell Tests LiteSpace/Features/Terminal/TerminalSessionCoordinator.swift && git commit -m "feat: route typed workspace terminal commands"`.

## Task 5: Build Coordinated Inventory and Snapshot Services

**Files:**

- Create: `LiteSpace/Features/Workspace/WorkspaceInventoryService.swift`
- Create: `LiteSpace/Features/Workspace/WorkspaceSnapshotService.swift`
- Create: `LiteSpace/Features/Workspace/WorkspaceProfileStore.swift`
- Create: `Tests/LiteSpaceSSHTests/WorkspaceFileServiceTests.swift`
- Modify: `project.yml`

- [ ] Write app-target tests using temporary roots and injected file coordination for ordered enumeration, exclusions, symlink escape rejection, provider error mapping, coordinated SHA-256 reads, edit invalidation, and profile persistence without sensitive fields.
- [ ] Implement enumeration with `NSFileCoordinator` and `FileManager` resource keys; stop immediately once count or byte limits fail.
- [ ] Compute each accepted source digest with `Crypto.SHA256`, then compute a sorted manifest digest from relative path, size, modified time, and content digest.
- [ ] Store `WorkspaceProfile` under app-owned preferences keyed by an opaque hash of the bookmark/root identity; never use a path or filename as a preferences key.
- [ ] Run `swift build`, portable Core tests, and app tests when full Xcode is available.
- [ ] Commit with `git add LiteSpace/Features/Workspace Tests/LiteSpaceSSHTests project.yml && git commit -m "feat: inspect coordinated workspace snapshots"`.

## Task 6: Add the Authenticated Loopback Server and Health Probe

**Files:**

- Create: `LiteSpace/Features/Workspace/Runtime/LoopbackPreviewServer.swift`
- Create: `LiteSpace/Features/Workspace/Runtime/LoopbackHTTPHandler.swift`
- Create: `LiteSpace/Features/Workspace/Runtime/PreviewRequest.swift`
- Create: `LiteSpace/Features/Workspace/Runtime/PreviewResponse.swift`
- Create: `LiteSpace/Features/Workspace/Runtime/HealthProbe.swift`
- Create: `Tests/LiteSpaceSSHTests/LoopbackPreviewServerTests.swift`
- Modify: `project.yml`
- Modify: `LiteSpace.xcodeproj/project.pbxproj`

- [ ] Add failing app tests for `127.0.0.1:0`, port range, 128-bit random secret, unauthenticated 404, secret-prefixed bootstrap URL, HttpOnly/SameSite=Strict cookie, traversal/dotfile/credential denial, 256-KiB response bound, three 200–399 probes in five seconds, and listener closure on failure.
- [ ] Add the existing pinned SwiftNIO `NIOHTTP1` product to the app target without changing the SwiftNIO revision.
- [ ] Implement `LoopbackPreviewServer.start(generation:source:) async throws -> LoopbackServerLease`; the lease stores port and secret only in memory and exposes `authenticatedBootstrapURL` to the preview controller, never the Ports panel.
- [ ] Validate `Host`, secret header/cookie, generation, normalized path, and the active source before serving bytes; answer invalid requests with a bodyless 404.
- [ ] Implement `HealthProbe.awaitReady(lease:path:budget:)` with a monotonic five-second deadline, three consecutive bounded responses, cancellation, and no redirects off loopback.
- [ ] Run app tests on an iOS simulator when available; otherwise compile static Core and mark this exact test environment open.
- [ ] Commit with `git add LiteSpace/Features/Workspace/Runtime Tests/LiteSpaceSSHTests project.yml LiteSpace.xcodeproj/project.pbxproj && git commit -m "feat: serve authenticated loopback previews"`.

## Task 7: Implement the Web Runner and Swift Advisor

**Files:**

- Create: `LiteSpace/Features/Workspace/Runtime/WebWorkspaceRunner.swift`
- Create: `LiteSpace/Features/Workspace/Runtime/WebSmokeWebView.swift`
- Create: `LiteSpace/Features/Workspace/Runtime/WebErrorBridge.swift`
- Create: `LiteSpace/Features/Workspace/Runtime/SwiftWorkspaceAdvisor.swift`
- Create: `Sources/LiteSpaceCore/Workspace/SwiftSourceDiagnostics.swift`
- Create: `Tests/LiteSpaceCoreTests/SwiftSourceDiagnosticsTests.swift`
- Create: `Tests/LiteSpaceSSHTests/WebWorkspaceRunnerTests.swift`
- Modify: `Tests/TestRunner/main.swift`

- [ ] Write failing cases for missing local Web resources, classic JavaScript parse failures, runtime exceptions, unhandled promise rejections, failed local resources, external resource denial, popup/download denial, and Swift UTF-8/conflict-marker/delimiter diagnostics.
- [ ] Implement Web validation against the immutable snapshot; resolve only root-relative or relative local references and reject paths outside the accepted inventory.
- [ ] Configure a nonpersistent hidden `WKWebView`; add a content-rule list that blocks all HTTP(S) and then ignores the block only for the current `http://127.0.0.1:<port>/` origin.
- [ ] Inject exception/rejection capture and the message handler in a named isolated `WKContentWorld`; expose only typed error envelopes with bounded messages.
- [ ] Implement `SwiftWorkspaceAdvisor` as check-only and return an explicit `ShareLink`/document handoff intent for Swift Playgrounds; never label Swift as locally runnable.
- [ ] Run focused Core tests, portable runner, and WebKit simulator tests when available.
- [ ] Commit with `git add Sources/LiteSpaceCore/Workspace LiteSpace/Features/Workspace/Runtime Tests && git commit -m "feat: validate web and swift workspaces"`.

## Task 8: Add the Single-Owner Workspace Controller

**Files:**

- Create: `LiteSpace/Features/Workspace/WorkspaceController.swift`
- Create: `LiteSpace/Features/Workspace/WorkspaceRuntimeProtocol.swift`
- Create: `LiteSpace/Features/Workspace/WorkspacePresentation.swift`
- Create: `Tests/LiteSpaceSSHTests/WorkspaceControllerTests.swift`
- Modify: `LiteSpace/App/AppModel.swift`
- Modify: `LiteSpace/Features/Terminal/TerminalSessionCoordinator.swift`

- [ ] Write controller tests with injected inventory, snapshots, Web, Swift, loopback, health, and clocks for success, every stage failure, stale callbacks, edit invalidation, root replacement, background stop, stop command, runtime exit, and port withdrawal order.
- [ ] Make `WorkspaceController` `@MainActor`, own exactly one task/runtime/listener/preview, and expose only `WorkspacePresentation` fields needed by SwiftUI.
- [ ] Route `check`, `test`, `run`, `stop`, `problems`, `ports`, and status actions through the controller; output only non-sensitive summaries such as state, category, counts, duration, and current published port.
- [ ] Wire `AppModel` root changes so `workspaceController.stopAndInvalidate()` finishes before the terminal installs a new root; do the same before background access is released.
- [ ] Notify the controller after editor saves; invalidate the lease before recalculating the snapshot.
- [ ] Run controller tests and all portable tests.
- [ ] Commit with `git add LiteSpace/Features/Workspace LiteSpace/App/AppModel.swift LiteSpace/Features/Terminal/TerminalSessionCoordinator.swift Tests && git commit -m "feat: coordinate one local workspace runtime"`.

## Task 9: Build the Adaptive Workspace UI and Bottom Drawer

**Files:**

- Create: `LiteSpace/App/LiteSpaceRootScreen.swift`
- Create: `LiteSpace/Features/Workspace/WorkspaceScreen.swift`
- Create: `LiteSpace/Features/Workspace/WorkspaceFileBrowser.swift`
- Create: `LiteSpace/Features/Workspace/CodeEditorScreen.swift`
- Create: `LiteSpace/Features/Workspace/WorkspaceBottomDrawer.swift`
- Create: `LiteSpace/Features/Workspace/WorkspaceProblemsPanel.swift`
- Create: `LiteSpace/Features/Workspace/WorkspacePortsPanel.swift`
- Create: `LiteSpace/Features/Workspace/WorkspacePreview.swift`
- Modify: `LiteSpace/App/LiteSpaceApp.swift`
- Modify: `LiteSpace/App/AppModel.swift`
- Modify: `LiteSpace/Features/Editor/TextFileEditor.swift`
- Modify: `LiteSpace/Features/Terminal/TerminalScreen.swift`
- Create: `LiteSpaceUITests/WorkspaceFlowUITests.swift`

- [ ] Add failing UI contracts/accessibility identifiers for Terminal/Workspace surfaces, landscape browser/editor/optional preview, portrait browser sheet, Run/Stop/Check, gate state, Problems, Ports, bottom Terminal, and Swift Playgrounds handoff.
- [ ] Use `TabView` in `LiteSpaceRootScreen` for Terminal and Workspace so the existing terminal remains intact while the Workspace surface embeds the same local terminal session in its bottom drawer.
- [ ] Enforce local mode when Workspace is selected; disconnect SSH through the existing mode transition and keep only one mounted `TerminalViewRepresentable`.
- [ ] In landscape, use a collapsible left browser, center editor, optional right preview; in portrait, use a browser sheet and stacked editor/preview.
- [ ] Show a port row only from `workspaceController.presentation.publishedPort`; show `No verified service port` in all other states. Never render the secret or bootstrap URL in Ports.
- [ ] Reuse coordinated read/write logic in an embedded editor, preserve the 5-MiB cap, and notify the controller after a successful atomic save.
- [ ] Run portable tests; run UI tests on iPad simulator when full Xcode is available.
- [ ] Commit with `git add LiteSpace LiteSpaceUITests && git commit -m "feat: add lightweight iPad workspace UI"`.

## Task 10: Core/Web Checkpoint Verification

**Files:**

- Modify: `README.md`
- Modify: `docs/product-scope.md`
- Create: `docs/verification/local-workspaces-core-web.md`

- [ ] Document supported Web, Python-pending, and Swift behaviors without describing LiteSpace as a full Codespaces or local Xcode replacement.
- [ ] Document that Web Ready requires validation, smoke execution, tests where configured, a live loopback server, and current health lease.
- [ ] Run `swift build`, `scripts/run-core-tests.sh`, `LITESPACE_ENABLE_SWIFTPM_XCTESTS=1 swift test`, and `scripts/verify-project.sh`; record command, outcome, and environment truthfully.
- [ ] Run `git diff --check`, `git status --short`, and a privacy scan for paths, secrets, telemetry, wildcard listeners, Bonjour, unrestricted navigation, and persistence of output.
- [ ] If full Xcode is unavailable, explicitly keep WebKit/server/UI execution as open and do not represent it as passed.
- [ ] Commit with `git add README.md docs && git commit -m "docs: verify local workspace core and web"`.
