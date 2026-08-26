# LiteSpace product scope

Date: 2026-08-26

## `role_positioning_card`

- Role: producer.
- Target user: an iPad user who wants a lightweight, on-device edit, check, test, and preview loop while retaining LiteSpace's local-file and SSH workflows.
- Target job: authorize a folder, edit one source file, understand bounded diagnostics, run only supported project types, and open a preview only after the current source generation is healthy.
- Value trigger: Inspect -> Check -> Test -> Start -> Health completes in one foreground session before one authenticated loopback port becomes visible.
- Observable feedback loop: runtime kind, normalized state/failure category, bounded duration/counters, aggregate RSS, port-lease outcome, and acceptance result. Source, content, filenames, full paths, commands, output, credentials, destinations, and preview secrets are prohibited from retained evidence.
- Decision boundary: `Ready` proves only the reviewed gate for one source generation. It is not universal correctness, physical-iPad acceptance, privacy-archive approval, App Review approval, or GitHub Codespaces parity.

The machine-readable version is [`docs/drx/role_positioning_card.yaml`](drx/role_positioning_card.yaml).

## Product promise

LiteSpace is an iPad-first lightweight terminal and local workspace. It keeps the existing bounded Local Shell and SSH terminal, and adds one foreground-only workspace for small, user-visible projects. The UI provides a file browser, one-document editor, Check/Test/Run/Stop, preview, and bottom Terminal/Problems/Ports surfaces.

The workspace commands are typed application actions. They do not launch a Unix shell, arbitrary process, project script, package manager, downloaded executable, or background service.

## Current candidate capability

| Workspace | Current behavior | Candidate evidence | Unclosed boundary |
| --- | --- | --- | --- |
| Static Web | Root-contained HTML/CSS/classic-JavaScript validation, real authenticated loopback serving, health gate, Ready port, and invalidation. | Portable 52-check suite and real local loopback integration PASS. | iOS WebKit smoke/UI, Simulator, physical iPad, and archive gates OPEN. |
| Python script | Recognizes projects, validates a fixed profile, and fails closed when the verified runtime artifact is absent. Successful non-service execution would end at `Completed` without a port. | Source pin, capability policy, request/response envelopes, and missing-artifact behavior PASS. | CPython XCFramework, compile/unittest/script execution, Simulator, device cancellation/restart/RSS OPEN; execution remains disabled. |
| Python WSGI | App-owned HTTP and bounded WSGI adapter; Python never owns the listener. | Portable adapter, privacy, resource, and capability checks PASS. | Real embedded-CPython callable execution on Simulator/device OPEN; no Python Ready port is claimed. |
| Swift | Encoding, conflict-marker, string/comment, and delimiter diagnostics labeled `Lightweight diagnostics`; explicit Swift Playgrounds handoff. | Portable fixture/advisor checks PASS. | No local compile, SwiftPM, debugger, run, service, or Ready port. |
| Node-required | `package.json` without a runnable static `index.html` is recognized and rejected locally. | Classifier checks PASS. | Node/npm are intentionally unsupported. |

## Readiness and port contract

`workspace`, `check`, `test`, `run`, `stop`, `problems`, and `ports` all route through the same `WorkspaceController`.

A port exists if and only if the current source generation is `Ready`, the runtime and listener are live, and the health lease is valid. Web or an enabled Python WSGI profile must complete Inspect -> Check -> Test -> Start and three consecutive authenticated health successes within five seconds. `Checked`, non-service Python `Completed`, Swift, every failure, stale callback, editor save, observed Files Provider mutation, root change, Stop, runtime exit, health failure, and background state have no published port.

Listeners bind only an ephemeral `127.0.0.1:0` address. A new 128-bit in-memory authentication value is created per run and never appears in Ports, persistence, analytics, or evidence.

## Privacy and resource boundary

- Persist only a non-sensitive `WorkspaceProfile` under an opaque root digest. Problems, source snapshots, runtime output, port leases, and run authentication remain bounded in memory.
- No analytics, remote telemetry, cloud sync, public/LAN listener, Bonjour, background runtime, or user-code network egress.
- Inventory: 1,000 entries and 20 MiB relevant source; one editable file up to 5 MiB.
- Runtime output: 2,000 lines or 2 MiB; health response: 256 KiB.
- One active editor/runtime/preview/port lease; zero active runtime work in background.
- Candidate steady-RSS ceilings: 90 MiB idle, 160 MiB Web, 180 MiB Python. These remain OPEN until physical-iPad measurement.

## Explicit exclusions

- GitHub Codespaces or desktop-IDE equivalence; full Unix/Linux; arbitrary shell; local Swift compilation/debugging.
- Node/npm, local Git, package installation, native extensions, downloaded executable code, Docker, virtual machines, JIT runtimes, Codex, Hermes, or AI models.
- GitHub account integration, SFTP, port forwarding, LAN/public exposure, Bonjour, cloud sync, collaboration, or background servers.
- Automatic project mutation, generated manifests/tests/lockfiles, or a claim that a passing gate makes a program universally error-free.

## Evidence and release state

Portable behavior, package build, real loopback Web, SSH loopback regression, project structure, CPython source lineage, and source-level privacy checks are PASS. Full Xcode, iPad Simulator, verified CPython binary/runtime, physical iPad, external OpenSSH, signed Release Archive, privacy questionnaire, export review, and App Review are independent OPEN gates. See [`docs/verification/local-workspaces-acceptance.md`](verification/local-workspaces-acceptance.md) for the requirement map.
