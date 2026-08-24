# Task 2 — Root-contained Local Lite Shell

## Status

Implemented and committed the Foundation-only local shell slice on `feat/liteterm-v0-1`.

## Implementation

- Added exact-command `ShellCommand` and deterministic quoted-token parser: `pwd`, `ls`, `cd`, `cat`, `mkdir`, `touch`, `cp`, `mv`, `rm`, `clear`, `edit` only.
- Added workspace-virtual path resolution. It resolves existing symlinks component-by-component before component-aware root containment, including a symlink followed by a nonexistent leaf.
- Added single-item local file operations. Reads and edits enforce `5 * 1024 * 1024` bytes; `rm` rejects the root and every directory, then removes one file only.
- Added actor-isolated `LocalShell.execute(_:) async`, returning output, directory/editor handoff, clear request, and the reserved optional deletion-confirmation field. No subprocesses or Unix-shell expansion are used.
- Extended the package-local runner so Task 2 behavior executes against UUID-named temporary fixtures, not merely XCTest source compilation.

## RED → GREEN evidence

1. Parser RED: `swift test --filter ShellCommandParserTests` failed with missing `ShellCommandParser` / `ShellCommandParserError`; GREEN passed after parser implementation and runner passed.
2. Resolver RED: `swift test --filter WorkspacePathResolverTests` failed with missing `WorkspacePathResolver` / error type; GREEN after resolver implementation. The runner then exposed a real symlink-nonexistent-leaf escape, which was repaired with component-by-component link processing.
3. Local shell RED: `swift test --filter LocalShellTests` failed with missing `LocalShell`; GREEN after file-system and actor implementation. The runner exposed a macOS `/var` versus `/private/var` canonicalization mismatch; the resolver was repaired to use a component stack rather than Foundation's path-mutating deletion.

## Verification

- `swift test` — passed (package build/test target completed).
- `swift run LiteTermCoreTestRunner` — `PASS: 14 LiteTermCore checks`.
- `git diff --check` — passed.
- Static scan for forbidden subprocess/runtime/SFTP/forwarding terms in `Sources`, `Tests`, `Package.swift`, and `project.yml` — no matches.

## Files

- `Sources/LiteTermCore/LocalShell/{ShellCommand,ShellCommandParser,WorkspacePathResolver,LocalFileSystem,LocalShell}.swift`
- `Tests/LiteTermCoreTests/{ShellCommandParserTests,WorkspacePathResolverTests,LocalShellTests}.swift`
- `Tests/TestRunner/main.swift`
- `Tests/TestSupport/XCTest.swift`

## Self-review and concerns

- All test fixtures are isolated temporary directories. No cleanup performs recursive or bulk deletion; the only deletion under test is one fixture file through `rm`.
- `deletionConfirmationRequest` remains intentionally `nil` for command-line single-file deletion; V0.1 rejects all directory deletion. UI-triggered/non-command-line confirmation remains app-layer work.
- `xcodegen` is not installed (`xcodegen: command not found`), so `LiteTerm.xcodeproj` could not be regenerated. Its current generated PBX project therefore does not yet list this slice's files. Install/provide XcodeGen, run `xcodegen generate`, and inspect the resulting project diff before Xcode app/test builds.
