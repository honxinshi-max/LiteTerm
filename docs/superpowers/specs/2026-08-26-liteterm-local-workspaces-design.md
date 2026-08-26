# LiteTerm Local Workspaces Design Specification

## Status

- Design date: 2026-08-26.
- Product role: producer path.
- Approved direction: an iPad-native, lightweight workspace rather than a remote Mac or cloud Codespace.
- Runtime boundary: local Web and Python execution; Swift editing and lightweight diagnostics with explicit Swift Playgrounds handoff.
- Publication boundary: implementation may be published only after the named verification gates pass. A portable check is not a release pass.

## Product and role positioning

`role_positioning_card`

- Producer: the LiteTerm owner and developer.
- Target user: an iPad user who wants to inspect, edit, check, test, and preview a small project without depending on a Mac or cloud runtime during the session.
- Target job: select a folder, open and edit a source file, run a bounded verification pipeline, understand failures, and open a local preview only after the checked source version is healthy.
- Value trigger: the user can complete the full edit -> check -> test -> start -> health -> preview loop in one foreground session while the app remains within its resource budgets.
- Feedback loop: internal acceptance records may contain only runtime kind, normalized gate state/category, duration, bounded counters, RSS, and pass/fail. Source, file content, filenames, full paths, commands, stdout, stderr, credentials, network destinations, and preview secrets are prohibited.
- Decision boundary: a `Ready` result proves only that the specified gate passed for one source snapshot. It is not proof that the program has no defects under every input or environment.

## Product principles

1. `Lite` is a release gate, not branding. LiteTerm must not become a Linux emulator, container host, or full desktop IDE.
2. Local execution is real. Unsupported capabilities produce an explicit diagnostic instead of a simulated success state.
3. No ready port before readiness. The port address is absent until every required gate succeeds for the current source snapshot.
4. Privacy is architectural. User code and output stay on device unless the user explicitly invokes an existing outbound feature such as SSH or export.
5. Foreground only. Runtime, health probe, listener, and preview work stop when the app leaves the foreground.
6. One active unit. At most one open editor document, one runtime, one preview, and one published port lease are retained.

## Scope

### Included

- Adaptive iPad workspace UI with file browser, single-document editor, preview, and a bottom tool drawer.
- Automatic recognition of Web, Python, and Swift workspaces.
- Local HTML/CSS/JavaScript checking, testing, serving, and WebKit preview.
- Local embedded-Python checking, testing, execution, and a constrained HTTP service contract.
- Swift editing, lightweight lexical/structural diagnostics, and export/open-in handoff to Swift Playgrounds.
- Unified Problems and Ports panels.
- A generation-bound readiness state machine and loopback-only ephemeral preview server.
- Bounded output, file scanning, health checks, runtime lifetime, and memory acceptance targets.
- On-device privacy controls and tests that fail closed.

### Excluded

- Node.js, npm/pnpm package installation, native Node add-ons, Docker, virtual machines, Linux emulation, JIT engines, or downloaded executable modules.
- A local Swift compiler, Swift Package Manager, debugger, or claim of Swift execution inside LiteTerm.
- Background servers, background health checking, LAN/public port exposure, Bonjour discovery, cloud sync, analytics, or remote crash-content upload.
- Automatic modification of a selected project, including generating manifests, tests, lockfiles, or configuration files.
- A claim that a passing gate makes a program universally error-free.

## User experience

### Layout

- Landscape: a collapsible file browser on the left, the editor in the center, an on-demand preview on the right, and a resizable bottom tool drawer.
- Portrait: the file browser becomes a navigation sheet; editor and preview occupy the main area; the bottom drawer remains reachable.
- Bottom tool tabs are `Terminal`, `Problems`, and `Ports`.
- Only one source file is retained as an editable document. Selecting another file commits or discards the current edit through the existing explicit-save contract.

### Main actions

- `Check`: inspect and validate the current source snapshot without starting a service.
- `Run`: execute the complete applicable gate. It does not skip failed stages; Swift offers `Check` and Playgrounds handoff instead of a false local Run action.
- `Stop`: withdraw any ready port, close the listener, stop the runtime, discard the preview, and return to `Idle`.
- `Open Preview`: available only in `Ready` and opens the authenticated loopback URL inside LiteTerm.
- `Open in Swift Playgrounds`: available for a recognized Swift workspace and performs an explicit user-driven Files/share handoff.

### Terminal contract

The existing Local Shell remains bounded and does not become a Unix process launcher. It adds product commands that call app-owned services:

```text
workspace  check  test  run  stop  problems  ports
```

- Runtime stdout and stderr are displayed in the bottom Terminal through a bounded in-memory stream.
- Runtime output is never appended to a file or analytics event.
- Existing touch shortcuts and the 2,000-line terminal scrollback remain.
- `run` invokes the same readiness pipeline as the UI. It cannot bypass checks or make a port visible early.

## Workspace recognition

Recognition examines a bounded, root-contained inventory and returns evidence with the classification.

Priority rules:

1. `Package.swift` or one or more `.swift` files -> Swift.
2. `pyproject.toml`, `requirements.txt`, or one or more `.py` files -> Python.
3. `index.html` -> Web.
4. `package.json` without a runnable static `index.html` -> recognized as Node-required and therefore unsupported locally.
5. Conflicting strong indicators -> ambiguous; the user chooses a profile for the session. LiteTerm does not persist that choice into the project.

Inventory limits:

- At most 1,000 entries and 20 MiB of gate-relevant source are inspected.
- Hidden files, package caches, VCS internals, build output, binary files, credentials, and symbolic-link escapes are excluded.
- Files larger than 5 MiB are not opened in the editor or checker.
- A limit violation is a visible gate failure, not a truncated success.

The app stores only a local `WorkspaceProfile` next to its existing bookmark metadata. It contains the selected runtime kind, relative entrypoint, relative test convention, health path, and non-sensitive limits. It must not contain source, output, credentials, or an absolute path.

## Readiness state machine

### States

```text
Idle
  -> Inspecting
  -> Checking
      -> Checked                         (Check-only or Swift)
      -> Testing
          -> Starting
              -> Completed               (non-service Python)
              -> HealthChecking
                  -> Ready               (Web or Python WSGI)
Ready/Checked/Completed/Failed
  -> Stopping
      -> Idle
```

`Checked` is the successful terminal state for Check-only and Swift diagnostics. `Completed` is the successful terminal state for a non-service Python script; it never owns a port. Web and Python service profiles continue to `HealthChecking` and `Ready`.

Any active stage may transition to `Failed`. `Failed`, `Checked`, and `Completed` can transition only to a new `Inspecting` generation or `Stopping`.

### Source generation

- Each run captures an opaque source generation and a bounded snapshot manifest.
- The manifest covers every gate-relevant file using root-relative identity, size, modification metadata, and SHA-256 content hash.
- Editor saves, Files Provider changes, root changes, lifecycle changes, or a mismatch observed while serving invalidate the generation.
- Invalidation first withdraws the port lease and closes the listener, then publishes the new failed/idle UI state.
- A result from an older asynchronous generation is ignored and cannot publish a port or diagnostic over the current generation.

### Hard invariant

```text
publishedPort != nil  if and only if
state == Ready
and readyGeneration == currentGeneration
and listener is active
and runtime is alive
and health lease is valid
```

`Checked` and `Completed` always have `publishedPort == nil`. This invariant belongs in `LiteTermCore` as a reducer contract and is exercised through unit, integration, and UI tests.

## Gate stages

### 1. Inspecting

- Reauthorize and coordinate the selected folder.
- Build the bounded root-contained inventory.
- Reject symbolic-link escape, missing entrypoint, ambiguous classification, unsupported runtime requirements, or exceeded limits.
- Create the source snapshot manifest without logging filenames or content.

### 2. Checking

Web:

- Validate HTML structure sufficiently to identify referenced local scripts, styles, and entry resources.
- Reject missing root-contained local assets and blocked resource types.
- Parse classic JavaScript without executing application code; module scripts are validated by the isolated WebKit smoke stage.

Python:

- Compile every gate-relevant `.py` file using embedded CPython `compile()` without executing it.
- Reject syntax errors with root-relative file, line, and column shown only in the local Problems panel.
- Reject imports that require native extension modules outside the reviewed bundle.

Swift:

- Perform lightweight lexical and structural checks for malformed strings/comments, unmatched delimiters, conflict markers, and invalid file encoding.
- Label the result `Lightweight diagnostics`, never `Compiled` or `Build passed`.
- Swift has no `Starting`, `HealthChecking`, `Ready`, or port publication path inside LiteTerm.

### 3. Testing

Web:

- Start a non-published loopback listener protected by the run secret.
- Load the source in an isolated, non-visible WebKit view with non-loopback network access blocked.
- Capture resource failures, JavaScript exceptions, unhandled promise rejections, and page-load failure.
- Run a project test file only when a supported local convention is present; the built-in smoke load remains mandatory.

Python:

- Run `unittest` discovery when supported tests are present.
- Run a mandatory isolated smoke import of the configured entrypoint without publishing a port or granting socket access.
- For a service profile, require an importable PEP 3333 WSGI callable named `application` before Starting.
- Apply a bytecode/instruction timeout and reject unsupported native modules or external network access.

Test absence is reported as `No project tests; built-in smoke only`. It does not silently claim user-test coverage. A configured test failure blocks all later stages.

### 4. Starting

- For a service profile, allocate an ephemeral listener using `127.0.0.1:0`; the assigned address remains private to the current run.
- Generate a cryptographically random 128-bit run secret for that service listener.
- For Web, the app-owned server serves only allowlisted files from the captured snapshot.
- A probe-only Web listener used during Testing is closed before Starting; the run receives a fresh listener and secret.
- For a Python service, the app-owned server adapts bounded HTTP requests to the exported WSGI `application` callable on the dedicated runtime executor. Python code never binds or receives the listening socket.
- A non-service Python script executes on the dedicated runtime executor and ends in `Completed`; it never enters HealthChecking or receives a port.
- Listener allocation does not publish a port to the UI.

### 5. HealthChecking

- Probe the configured normalized relative HTTP health path on loopback; reject an absolute URL, authority, traversal, or redirect outside the current authenticated listener.
- Require three consecutive successful responses within a bounded window.
- A successful response is HTTP 200-399, bounded in size, from the current run secret and source generation.
- A runtime exit, timeout, mutation, redirect outside loopback, oversized response, or failed probe closes the listener and produces a local Problem.

### 6. Ready

- Atomically create a `ReadyPortLease` containing only generation, loopback port, health expiry, and run-secret handle.
- The Ports panel may now show `127.0.0.1:<port>` and `Open Preview`.
- The secret is never displayed, copied to analytics, or written to disk. The preview URL uses an authenticated initial request and an HttpOnly, SameSite-strict run cookie for relative assets.
- Ongoing bounded health checks retain the lease. Any failed check withdraws it before updating the UI.

## Runtime architecture

### LiteTermCore

Foundation-only components:

- `WorkspaceClassifier`
- `WorkspaceInventoryPolicy`
- `WorkspaceSnapshot`
- `WorkspaceGateReducer`
- `WorkspaceProblem`
- `BoundedRuntimeOutput`
- `ReadyPortLeasePolicy`
- `RuntimeResourceBudget`

Core describes contracts and state. It does not import SwiftUI, WebKit, JavaScriptCore, Python, Network, NIO, or NIOTransportServices.

### App target

- `WorkspaceController`: orchestrates one generation and lifecycle cancellation.
- `WorkspaceFileBrowser`: bounded coordinated file inventory and selection.
- `CodeEditorScreen`: single-document editor and local problem markers.
- `WebWorkspaceRunner`: WebKit smoke test, exception capture, and preview lifecycle.
- `PythonWorkspaceRunner`: official embedded CPython bridge on one dedicated executor.
- `SwiftWorkspaceAdvisor`: lightweight diagnostics and user-driven Playgrounds handoff.
- `LoopbackPreviewServer`: NIOTransportServices HTTP listener bound to loopback.
- `HealthProbe`: bounded loopback-only readiness and ongoing lease checks.

The runners conform to an app-owned protocol. Their outputs are normalized events; they never mutate gate state or publish a port directly.

## Python boundary

- Build CPython from a reviewed, pinned official source revision into an XCFramework. Do not accept an opaque third-party binary.
- Include only the reviewed standard-library subset and pure-Python packages explicitly named in the dependency and license manifests.
- Disable subprocess, multiprocessing, dynamic native-module loading, shell execution, arbitrary package installation, and all user-code socket operations.
- Install a native audit hook before user code. It rejects socket operations and access outside the current execution root plus reviewed read-only runtime resources.
- Python HTTP projects expose a PEP 3333 WSGI callable named `application`. LiteTerm owns HTTP parsing, loopback binding, authentication, response limits, and connection lifetime.
- Replace `stdin`, `stdout`, and `stderr` with bounded app bridges.
- Run preflight, tests, script execution, and each WSGI request with an instruction/deadline guard. Because iOS cannot terminate an arbitrary subprocess, native extensions are prohibited and any stop-timeout is a failed physical-device safety gate.
- Finalization/restart and memory reclamation must be measured on a physical iPad. The design does not assume that all allocator pages return immediately.

## Web boundary

- Use system WebKit/JavaScriptCore; do not bundle a Node-compatible runtime.
- Do not expose an unrestricted native message bridge to user JavaScript.
- Error capture uses a minimal isolated content-world bridge with bounded, normalized fields.
- Block non-loopback loads, popups, downloads, external navigation, camera, microphone, geolocation, and persistent website data.
- Use an ephemeral website data store and destroy the preview/smoke views on stop or background.
- The preview server rejects hidden files, credentials, unsupported MIME types, path traversal, stale identities, missing run authentication, and requests for a superseded generation.

## Privacy and security contract

### Data minimization

- No analytics SDK, remote telemetry, advertising identifier, tracking domain, or remote crash-content service.
- No source, file content, filename, full path, command, stdout, stderr, credential, host fingerprint, IP address, URL, preview secret, or package content in persistent logs.
- Debug logs may contain only opaque generation IDs, runtime kind, normalized state/category, bounded counts, durations, and non-secret resource totals.
- Problems and runtime output live in bounded memory and are discarded on workspace close, stop, or background.
- Export or share occurs only after an explicit user action through a system sheet.

### Network

- Local runtimes default to no network egress.
- The only automatically opened socket is an app-owned loopback listener and its app-owned loopback health/preview connections. User Python and JavaScript receive no socket capability.
- The listener is never bound to `0.0.0.0`, `::`, a LAN address, Bonjour, or a public interface.
- Existing user-initiated SSH remains a separate product mode and is never invoked by a local workspace run.

### Preview authentication

- Every run uses a new random secret held only in memory.
- A request without current run authentication receives no project content.
- The Ports panel displays the port, not the secret.
- Backgrounding, editing, root change, runtime exit, health failure, or Stop closes all accepted connections and invalidates the secret.

### App Store boundary

- All user-provided executable source must remain visible and editable in the app.
- Downloaded executable code and native extensions are prohibited.
- App Review approval remains an external release gate even when code and privacy checks pass.

## Resource budgets

Candidate thresholds, to be proven on the target physical iPad:

| State | Maximum steady RSS |
| --- | ---: |
| Idle foreground | 90 MiB |
| Web check/run/preview | 160 MiB |
| Python check/run/service | 180 MiB |

Additional hard limits:

- Active workspace/runtime/preview/port lease: one each.
- Editor file: 5 MiB.
- Gate inventory: 1,000 entries and 20 MiB relevant source.
- Terminal scrollback: 2,000 lines.
- Runtime stdout + stderr: 2,000 lines or 2 MiB, whichever occurs first.
- Health response body: 256 KiB.
- Health attempts: three consecutive successes within 5 seconds.
- Background state: zero active runtime tasks, listeners, accepted preview connections, health probes, or output growth.

Exceeding a limit fails the run or release gate; it is not reported as a successful truncated check.

## Error model

`WorkspaceProblem` contains:

- generation;
- stage;
- normalized category;
- severity;
- optional root-relative locator shown only in the local UI;
- bounded human-readable message;
- bounded recovery action.

Persistent diagnostics retain none of the optional locator or message. The UI can group failures by `Inspect`, `Check`, `Test`, `Start`, `Health`, `Runtime`, `Resource`, `Privacy`, and `Unsupported`.

On failure:

1. Withdraw the ready lease.
2. Close listener and accepted channels.
3. Stop/detach runtime work and preview.
4. Publish the local Problem and retain bounded terminal output.
5. Require a new generation to rerun.

## Verification strategy

### Portable Core verification

- Classification evidence and ambiguity.
- Inventory/path/size limits and symbolic-link escape.
- Every allowed and rejected state transition.
- Stale-generation result rejection.
- The `publishedPort iff Ready` invariant.
- `Checked` and `Completed` success with no port.
- Edit, root, lifecycle, crash, and health invalidation.
- Output/problem bounds and privacy-safe persistence projection.
- Web, Python, Swift, Node-required, unsupported, and mixed-project fixtures.

### Local integration verification

- Bind a real NIOTransportServices listener to `127.0.0.1:0` and obtain the assigned port.
- Prove unauthenticated requests receive no project content.
- Prove no port is published during inspect/check/test/start/health or on every failure path.
- Prove three health successes publish one lease.
- Prove mutation, crash, Stop, and background close the listener and revoke the lease.
- Prove traversal, hidden-file, credential-file, stale-identity, oversized-response, and non-loopback requests fail closed.

### Full Xcode and simulator verification

- App and all test targets compile from the pinned graph.
- Web workspace check, smoke test, ready port, preview, JavaScript failure, and mutation invalidation.
- Embedded CPython build, syntax failure, test failure, script completion without a port, runtime output, constrained WSGI service, socket denial, timeout, stop, and restart.
- Swift recognition, diagnostics labeling, and Playgrounds handoff UI.
- Landscape, portrait, keyboard, editor, bottom drawer, Problems, Ports, and VoiceOver identifiers.
- Privacy manifest, required-reason APIs, third-party notices, and archive content review.

### Physical-iPad verification

- Idle, Web, Python, stop, and background RSS against the stated thresholds.
- Thirty repeated start/stop cycles without monotonic retained-memory growth.
- Python runaway-loop deadline and stop behavior.
- Foreground/background listener teardown and clean recovery.
- Sixty-minute foreground Web and Python service stability runs.
- No non-loopback traffic during automated local-workspace acceptance.
- Complete touch-only edit -> gate -> preview -> edit invalidation -> rerun flow.

### Publication verification

- Unified verification script passes serially.
- Full Xcode, simulator, physical iPad, privacy archive, and App Review gates are reported individually; no narrow check promotes another gate.
- Commit and push the validated feature branch, create a PR, merge only after required checks, then verify the actual GitHub default-branch tree and relevant file hashes.

## Required project changes

- Add the Core workspace contracts and tests.
- Add the workspace UI, runners, preview server, health probe, and app tests.
- Extend Local Shell with app-owned workspace commands without `Process` or `NSTask`.
- Add a pinned official CPython build/integration path, license notices, and privacy review artifacts.
- Update `project.yml`, the generated Xcode project, package/resource manifests, UI tests, README, and acceptance documentation.
- Replace the V0.1 blanket runtime-forbidden scan with a V0.2 allowlist that permits only the reviewed Web/Python implementation while continuing to reject Node, Docker, VM, subprocess, dynamic loading, background keepalive, LAN/public binding, analytics, and secret-bearing persistence.
- Update `docs/drx/role_positioning_card.yaml` to the approved local-workspace producer path.

## Acceptance criteria

1. Web, Python, and Swift workspaces are recognized with evidence; Node-required projects are explicitly unsupported.
2. The adaptive UI provides file navigation, one-document editing, bottom Terminal/Problems/Ports, and on-demand preview.
3. Web execution and embedded-Python script/WSGI execution are real and independently verified on iPad; Swift is never mislabeled as locally compiled.
4. Every stage and failure category is observable locally without persisting private content.
5. A port address is absent before `Ready` and on every failed, stale, stopped, crashed, backgrounded, or mutated state.
6. A healthy current Web or Python WSGI generation publishes exactly one authenticated app-owned loopback port and in-app preview; Swift and non-service Python never publish one.
7. Local runtime network egress, path escape, native plug-ins, subprocesses, downloaded executable code, and public/LAN listener binding fail closed.
8. Resource limits and physical-iPad RSS thresholds pass without monotonic start/stop growth.
9. Source, content, filenames, paths, commands, output, credentials, and preview secrets never enter analytics or persistent logs.
10. Portable, Full Xcode, simulator, physical-iPad, privacy archive, and App Review evidence remain distinct.
11. Documentation states all unsupported and unverified boundaries.
12. The validated implementation is visible on the GitHub default branch after merge.

## Known open gates before implementation

- The current Mac has Swift Command Line Tools but not an active full Xcode installation. Simulator, iOS target compilation, archive inspection, and physical-device deployment cannot be claimed until full Xcode is installed and selected.
- The official CPython XCFramework revision, build recipe, size, licenses, and reproducible hashes must be selected and verified during implementation planning.
- Physical-iPad RSS and stop/restart behavior are unmeasured.
- App Review acceptance of the final executable-code workflow is external and unproven.
