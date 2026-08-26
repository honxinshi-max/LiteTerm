# LiteSpace Local Workspaces Verification and GitHub Release Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the approved Web/Python/Swift behavior and privacy boundary, then publish only verified source and evidence to GitHub and make it visible from the repository default branch.

**Architecture:** Treat portable Core, iOS simulator, physical iPad, privacy/static checks, and GitHub visibility as separate evidence gates. The unified verifier aggregates results without converting unavailable environments into passes. Publication occurs only after the feature branch is clean and every acceptance item is either passed or explicitly named as an external/open boundary.

**Tech Stack:** SwiftPM, XCTest, Xcode/iOS simulator, physical iPad/XCTest metrics, shell validation, Git, GitHub CLI.

**Spec:** `docs/superpowers/specs/2026-08-26-litespace-local-workspaces-design.md`

## Global Constraints

- Publish no source archive, terminal transcript, absolute path, bookmark, credential, token, host/IP, SSH fingerprint, or user project fixture.
- Test fixtures must be synthetic and repository-owned.
- A structural/static pass is not a WebKit runtime pass, Python runtime pass, physical-iPad memory pass, archive privacy pass, or App Store approval.
- Do not merge or claim default-branch visibility until GitHub independently reports the merged commit on the default branch.
- Do not use bulk deletion or destructive Git commands.

---

## Task 1: Make Verification Requirements Executable

**Files:**

- Modify: `scripts/verify-project.sh`
- Create: `scripts/verify-local-workspaces.sh`
- Create: `scripts/verify-workspace-privacy.sh`
- Create: `Tests/Fixtures/Workspace/WebPassing/index.html`
- Create: `Tests/Fixtures/Workspace/WebFailing/index.html`
- Create: `Tests/Fixtures/Workspace/PythonScript/main.py`
- Create: `Tests/Fixtures/Workspace/PythonWSGI/main.py`
- Create: `Tests/Fixtures/Workspace/PythonFailing/main.py`
- Create: `Tests/Fixtures/Workspace/SwiftCheck/Package.swift`
- Create: `Tests/Fixtures/Workspace/SwiftCheck/Sources/main.swift`

- [x] First make the current verifier fail on missing workspace types, exact shell command set, NIOHTTP1 linkage, CPython pin, privacy assertions, and updated portable check count.
- [x] Replace the obsolete `PythonKit|JavaScriptCore|NodeRuntime` blanket rule with precise forbidden patterns for Node/npm runtime, shell/process spawning, unrestricted sockets, wildcard/LAN/Bonjour preview binding, background keepalive, telemetry, and secret/output persistence.
- [x] Require the approved Core contracts, Ready invariant tests, static Web and Swift support, CPython source metadata, audit hook, bounded output, health policy, and lifecycle invalidation.
- [x] Make `verify-local-workspaces.sh` run portable checks first, then full-Xcode build/test only when full Xcode is selected, then artifact/simulator Python checks only when the verified XCFramework exists.
- [x] Use `PASS`, `FAIL`, `OPEN`, and `SKIP` accurately; a missing required tool in a claimed environment is `FAIL`, while a genuinely absent named environment is `OPEN`.
- [x] Run the scripts and commit with `git add scripts Tests/Fixtures && git commit -m "test: unify local workspace verification"`.

## Task 2: Run Portable and Simulator Evidence Gates

**Files:**

- Create: `docs/verification/local-workspaces-verification.md`

- [x] Run `swift build`, `scripts/run-core-tests.sh`, and `LITESPACE_ENABLE_SWIFTPM_XCTESTS=1 swift test`; capture only aggregate pass/fail counts and tool versions.
- [ ] With full Xcode selected, run `xcodebuild -project LiteSpace.xcodeproj -scheme LiteSpace -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' -onlyUsePackageVersionsFromResolvedFile test`.
- [ ] Run authenticated Web and Python WSGI loopback integration tests, and prove unauthenticated/nonloopback access fails.
- [ ] Run UI tests for both orientations, file browser, editor save invalidation, terminal command routing, Problems, Ports hidden before Ready, port shown at Ready, port withdrawn after edit/stop/background, and Swift handoff.
- [x] Record exact passed and open gates in `docs/verification/local-workspaces-verification.md`; do not paste project source or runtime output.
- [x] Commit with `git add docs/verification/local-workspaces-verification.md && git commit -m "docs: record workspace simulator verification"`.

## Task 3: Run Physical-iPad and Privacy Gates

**Files:**

- Create: `docs/verification/local-workspaces-ipad.md`
- Create: `docs/verification/local-workspaces-privacy.md`

- [ ] Install a development build on the available physical iPad and run cold start, idle, Web Ready, Python compile/test/script, Python WSGI Ready, edit invalidation, stop, background, resume, and memory-pressure scenarios.
- [ ] Record only device class, OS/build version, aggregate RSS, duration, count, state, and category; omit device name, UDID, local paths, project content, IP, port secret, and user identity.
- [ ] Confirm idle/Web/Python candidate memory thresholds, bounded output, zero active runtime in background, and prompt listener/runtime teardown.
- [ ] Inspect the app archive privacy report and bundled notices; verify no collected-data declaration, no tracking domain, no telemetry SDK, and no unreviewed Python package.
- [x] If no physical iPad or signing profile is available, mark this gate `OPEN` and keep any affected runtime capability disabled; do not substitute the Mac measurement.
- [x] Commit only sanitized aggregate evidence with `git add docs/verification/local-workspaces-ipad.md docs/verification/local-workspaces-privacy.md && git commit -m "docs: record iPad workspace boundaries"`.

## Task 4: Final Requirement-by-Requirement Review

**Files:**

- Create: `docs/verification/local-workspaces-acceptance.md`
- Modify: `README.md`
- Modify: `docs/product-scope.md`

- [x] Map all 12 acceptance items in the approved spec to concrete test names and evidence files.
- [x] Confirm Web is locally runnable, Python is locally runnable only when the verified runtime artifact/device gate is enabled, Swift is check/handoff only, and Node/npm remains unsupported.
- [x] Confirm `Checked` and `Completed` never publish a port, and only a current healthy live service reaches `Ready`.
- [x] Confirm README/UI language says “lightweight local workspace” and does not promise GitHub Codespaces parity, full package compatibility, or local Swift compilation.
- [x] Run `scripts/verify-project.sh`, `scripts/verify-local-workspaces.sh`, `scripts/verify-workspace-privacy.sh`, `git diff --check`, and `git status --short`.
- [x] Request code review through `superpowers:requesting-code-review`, apply valid findings, rerun affected verification, then use `superpowers:verification-before-completion` before any completion claim.
- [x] Commit with `git add README.md docs && git commit -m "docs: close workspace acceptance review"`.

## Task 5: Publish and Verify the GitHub Default Branch

**Files:**

- No new product files; Git/GitHub state only.

- [x] Verify branch cleanliness, commit graph, remote URL, active GitHub account, and that no generated CPython framework, build output, runtime output, absolute path, or secret is tracked.
- [ ] Push `feat/litespace-local-workspaces` to `origin` and verify the remote branch SHA matches local HEAD.
- [ ] Create a pull request whose body lists verified gates and open boundaries without user/private project data.
- [ ] Inspect required checks and review results; fix failures in scoped commits and rerun the affected gate.
- [ ] Merge only after required checks pass and every non-pass boundary is clearly acceptable under the approved realistic scope.
- [ ] Fetch/read remote state, verify GitHub reports the PR merged, verify the repository default branch contains the merge commit, and compare the remote tree for the implementation paths.
- [ ] Report the PR URL, default-branch commit, verified gates, and remaining external boundaries; do not claim App Store/device approval unless actually observed.
