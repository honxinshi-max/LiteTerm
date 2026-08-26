# LiteSpace Identity Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the complete tracked project identity with `LiteSpace`, verify the result, and publish it to the current GitHub branch.

**Architecture:** Treat the product name as a cross-cutting build interface. Rename paths first in Git, then mechanically migrate textual identifiers, and finish by running a dedicated zero-residual identity gate plus the existing portable project gate.

**Tech Stack:** Swift 6, SwiftPM, Xcode project files, XcodeGen YAML, Objective-C/C bridge, shell verification, Git/GitHub.

**Spec:** `docs/superpowers/specs/2026-08-26-litespace-identity-migration-design.md`

## Global Constraints

- Preserve all source files and directories through Git-aware moves; perform no deletion.
- Preserve behavior and pinned dependency revisions.
- Do not rename the external GitHub repository.
- Keep release-only gates explicitly open unless fresh evidence closes them.

---

### Task 1: Add the identity acceptance gate

**Files:**
- Create: `scripts/verify-brand-identity.sh`
- Modify: `scripts/verify-project.sh`

**Interfaces:**
- Consumes: repository paths and text files.
- Produces: a nonzero exit when legacy identity remains and a zero exit only for a consistent `LiteSpace` tree.

- [x] Add required-path and zero-residual checks.
- [x] Run the standalone check before migration and confirm it fails on legacy paths/text.
- [x] Integrate the check into the unified verifier after the migration is green.

### Task 2: Rename paths and identifiers

**Files:**
- Rename: app, Xcode project/scheme, core, bridge, UI-test, test-suite, plan/spec, and historical task-report paths containing the legacy identity.
- Modify: all tracked textual references found by the identity gate.

**Interfaces:**
- Consumes: existing target/module/path contracts.
- Produces: equivalent `LiteSpace` contracts across SwiftPM, Xcode, C/Objective-C, scripts, tests, and documentation.

- [x] Move each legacy-named tracked path with Git history preserved.
- [x] Replace exact title-case, lowercase, and uppercase identifiers.
- [x] Review bundle, Keychain, persistence, HTTP, environment-variable, and documentation changes for internal consistency.

### Task 3: Verify and publish

**Files:**
- Verify: the complete changed tree.

**Interfaces:**
- Consumes: migrated repository state.
- Produces: portable verification evidence and a remote commit on the current branch.

- [x] Run the identity gate and confirm zero residuals.
- [x] Run the full project verifier serially in the environment that permits SwiftPM.
- [x] Run `git diff --check`, plist parsing, status, and diff review.
- [ ] Commit the migration, push the current branch, and compare local/remote commit IDs.
