# LiteSpace Embedded Python Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an auditable, source-built, memory-bounded CPython runtime for Python scripts, unittest projects, and WSGI services on iPad without shell, subprocess, native package installation, or user-owned sockets.

**Architecture:** Build CPython 3.14.7 from its official source into a local XCFramework, bridge it through a narrow Objective-C/C layer, and make `PythonWorkspaceRunner` the only Swift entry. The app owns HTTP sockets and converts bounded HTTP envelopes to calls of a WSGI `application`; Python never receives a socket or arbitrary host capability.

**Tech Stack:** CPython 3.14.7 official Apple iOS build, C/Objective-C bridge, Swift 6, XCTest, SwiftNIO loopback server, Python standard library `compile`, `unittest`, and WSGI.

**Spec:** `docs/superpowers/specs/2026-08-26-litespace-local-workspaces-design.md`

## Global Constraints

- Official source URL: `https://www.python.org/ftp/python/3.14.7/Python-3.14.7.tgz`.
- Expected source archive SHA-256: `62859805f6fdf25e2bcbf3fa3217801e1996887ca33e6a2af80674bdfa2dbe07`.
- Upstream tag commit: `823f0323ee6ec1402088b73bce1a38473cac36dc` (`v3.14.7^{}`).
- Do not commit an opaque downloaded framework. Keep source pin, build recipe, artifact hash manifest, licenses, and reproducibility evidence in Git.
- Never expose `subprocess`, `multiprocessing`, shell calls, dynamic native extensions, arbitrary `dlopen`, package installation, user sockets, or paths outside the accepted snapshot.
- Curated pure-Python modules may be added only by explicit allowlist and must carry source, revision, hash, and license metadata.
- Stop and discard runtime/output on background, root replacement, edit invalidation, deadline, memory pressure, or gate failure.
- Do not use bulk deletion or cleanup commands in the build script.

---

## Task 1: Add Reproducible CPython Source and Artifact Metadata

**Files:**

- Create: `Vendor/CPython/README.md`
- Create: `Vendor/CPython/source.json`
- Create: `Vendor/CPython/artifact-manifest.example.json`
- Create: `scripts/fetch-cpython-source.sh`
- Create: `scripts/build-cpython-ios.sh`
- Create: `scripts/verify-cpython-artifact.sh`
- Modify: `.gitignore`
- Modify: `THIRD_PARTY_NOTICES.md`

- [ ] Add a failing shell verification that rejects any source version, URL, archive hash, tag commit, or output architecture not matching the pinned metadata.
- [ ] Implement `fetch-cpython-source.sh` to download only the official archive, verify SHA-256 before extraction, extract into a versioned cache directory that must not already contain a different fingerprint, and never delete prior content.
- [ ] Implement `build-cpython-ios.sh` to require full Xcode, call the upstream `python Platforms/Apple/build-apple-framework.py iOS`, avoid cleanup flags, and copy the resulting XCFramework into a versioned ignored artifact directory.
- [ ] Emit an artifact manifest containing CPython version, source URL, source SHA-256, upstream commit, Xcode version, SDK build versions, architectures, per-file hashes, and final XCFramework tree hash; include no username or absolute path.
- [ ] Add PSF/Python license and notices to `THIRD_PARTY_NOTICES.md` and document reproducibility limits.
- [ ] Run the metadata verifier; if full Xcode is absent, record the framework build as open rather than generating a substitute binary.
- [ ] Commit with `git add Vendor/CPython scripts .gitignore THIRD_PARTY_NOTICES.md && git commit -m "build: pin auditable CPython iOS source"`.

## Task 2: Add the Narrow CPython Bridge

**Files:**

- Create: `LiteSpacePythonBridge/include/LiteSpacePythonBridge.h`
- Create: `LiteSpacePythonBridge/LiteSpacePythonBridge.m`
- Create: `LiteSpacePythonBridge/LiteSpacePythonAudit.c`
- Create: `LiteSpacePythonBridge/LiteSpacePythonIO.c`
- Create: `Tests/LiteSpacePythonBridgeTests/LiteSpacePythonBridgeTests.swift`
- Modify: `project.yml`
- Modify: `LiteSpace.xcodeproj/project.pbxproj`

- [ ] Add bridge tests for initialize/finalize, isolated module state, UTF-8 source compilation, bounded stdout/stderr callbacks, exceptions, cancellation/deadline, denied imports, denied path escape, denied subprocess/socket/native-extension operations, and repeat-run cleanup.
- [ ] Expose only opaque runtime/request handles and these bridge operations:

```c
typedef struct LTPythonRuntime LTPythonRuntime;
typedef struct LTPythonRequest LTPythonRequest;

LTPythonRuntime *LTCreatePythonRuntime(const LTPythonConfiguration *configuration,
                                       LTOutputCallback output,
                                       LTProblemCallback problem);
bool LTCompilePythonFile(LTPythonRuntime *, const char *relative_path);
bool LTRunPythonUnittestDiscovery(LTPythonRuntime *, const char *start_relative_path);
bool LTRunPythonScript(LTPythonRuntime *, const char *entrypoint);
bool LTPrepareWSGIApplication(LTPythonRuntime *, const char *entrypoint, const char *name);
bool LTCallWSGIApplication(LTPythonRuntime *, const LTHTTPRequest *, LTHTTPResponse *);
void LTCancelPythonRuntime(LTPythonRuntime *);
void LTDestroyPythonRuntime(LTPythonRuntime *);
```

- [ ] Configure isolated Python initialization with app-supplied `sys.path`, no environment variables, no user site, no bytecode writes, no interactive stdin, and a fixed hash/random seed policy suitable for repeatable checks.
- [ ] Install a native audit hook before user code; allow only accepted snapshot paths and allowlisted imports, and reject subprocess/process creation, socket creation, dynamic extension loading, shell invocation, and writes outside an app-owned ephemeral runtime directory.
- [ ] Replace stdout/stderr/stdin with bounded bridge objects; never call NSLog/print with user content.
- [ ] Add cancellation and deadline checks through tracing/evaluation hooks and fail closed when resource pressure signals are raised.
- [ ] Run bridge tests on an iPad simulator with the locally built artifact; keep them open if the artifact/full Xcode is unavailable.
- [ ] Commit with `git add LiteSpacePythonBridge Tests/LiteSpacePythonBridgeTests project.yml LiteSpace.xcodeproj/project.pbxproj && git commit -m "feat: bridge restricted embedded Python"`.

## Task 3: Implement Python Checking, Tests, and Script Runs

**Files:**

- Create: `LiteSpace/Features/Workspace/Runtime/PythonWorkspaceRunner.swift`
- Create: `LiteSpace/Features/Workspace/Runtime/PythonRuntimeConfiguration.swift`
- Create: `LiteSpace/Features/Workspace/Runtime/PythonProblemMapper.swift`
- Create: `LiteSpace/Features/Workspace/Runtime/PythonRunDisposition.swift`
- Create: `Tests/LiteSpaceSSHTests/PythonWorkspaceRunnerTests.swift`
- Modify: `LiteSpace/Features/Workspace/WorkspaceController.swift`

- [ ] Add runner tests for compiling every accepted `.py`, syntax error mapping, deterministic sorted order, `unittest discover`, a mandatory import smoke check, successful script completion with no port, WSGI discovery, bounded output, cancellation, timeout, and stale generation rejection.
- [ ] Implement `check(snapshot:)` by calling Python `compile()` on every accepted Python file without importing user code.
- [ ] Implement `test(snapshot:)` using the profile test convention, then perform a smoke import with sockets denied; translate exceptions into root-relative `WorkspaceProblem` values.
- [ ] Decide disposition only after tests: an entry module with callable `application` becomes WSGI service; otherwise execute it once as a script and transition to `Completed` with no port.
- [ ] Keep imports restricted to approved standard-library modules, the snapshot, and curated pure-Python packages; report unsupported native imports as typed problems.
- [ ] Connect controller cancellation, memory pressure, backgrounding, root changes, and edits to `LTCancelPythonRuntime` before invalidating the gate.
- [ ] Run runner/controller tests on simulator and all portable Core tests.
- [ ] Commit with `git add LiteSpace/Features/Workspace/Runtime LiteSpace/Features/Workspace/WorkspaceController.swift Tests && git commit -m "feat: run restricted Python projects"`.

## Task 4: Adapt WSGI to the App-Owned Loopback Server

**Files:**

- Create: `LiteSpace/Features/Workspace/Runtime/PythonWSGIAdapter.swift`
- Create: `Tests/LiteSpaceSSHTests/PythonWSGIAdapterTests.swift`
- Modify: `LiteSpace/Features/Workspace/Runtime/LoopbackPreviewServer.swift`
- Modify: `LiteSpace/Features/Workspace/WorkspaceRuntimeProtocol.swift`
- Modify: `LiteSpace/Features/Workspace/WorkspaceController.swift`

- [ ] Add integration tests for GET/HEAD/POST envelopes, bounded request/response bodies, WSGI status/header validation, forbidden hop-by-hop headers, exception mapping, runtime exit, health path, and proof that Python owns no listener.
- [ ] Convert the authenticated NIO request into a bounded value containing method, normalized relative path, query, approved headers, and at most 256 KiB body.
- [ ] Build a WSGI environ without absolute workspace paths, host environment variables, user identity, LAN address, or the run secret; use an in-memory `wsgi.input`.
- [ ] Validate WSGI status and headers, remove hop-by-hop headers, cap response bytes, and marshal the result back to the app-owned listener.
- [ ] Start the listener only after check and test stages pass; send three authenticated health probes before publishing `ReadyPortLease`.
- [ ] Stop listener and Python runtime together on any exception, timeout, failed health check, edit, background, or stale generation.
- [ ] Run WSGI integration and controller tests on simulator.
- [ ] Commit with `git add LiteSpace/Features/Workspace/Runtime LiteSpace/Features/Workspace/WorkspaceController.swift Tests && git commit -m "feat: serve Python WSGI through app loopback"`.

## Task 5: Verify Python Privacy, Resource, and Lifecycle Boundaries

**Files:**

- Create: `Tests/LiteSpaceSSHTests/PythonPrivacyBoundaryTests.swift`
- Create: `Tests/LiteSpaceSSHTests/PythonResourceBoundaryTests.swift`
- Create: `docs/verification/python-runtime.md`
- Modify: `scripts/verify-project.sh`
- Modify: `README.md`
- Modify: `docs/product-scope.md`

- [ ] Add adversarial tests that try path traversal, environment reads, subprocess, multiprocessing, sockets, dynamic extensions, persistence, unlimited output, infinite loop, oversized body, and background continuation.
- [ ] Extend static verification to require the pin/hash/license/audit-hook configuration and to forbid Python logging of source, relative filenames, messages, stdout/stderr, or secrets.
- [ ] Measure idle, compile, test, script, WSGI, stop, and relaunch behavior on a physical iPad; compare against 90/180 MiB candidate thresholds and capture only aggregate RSS/duration/counts.
- [ ] If a physical-iPad result exceeds the candidate threshold, keep Python disabled by runtime capability gate and report the measurement; do not silently raise the threshold.
- [ ] Run all portable, simulator, and device checks available in the environment and record every skipped boundary precisely.
- [ ] Commit with `git add Tests scripts README.md docs && git commit -m "test: verify embedded Python boundaries"`.
