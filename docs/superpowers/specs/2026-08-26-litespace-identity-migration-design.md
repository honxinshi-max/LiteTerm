# LiteSpace Identity Migration Design

## Role positioning

- Role: producer.
- Target users: iPad users and GitHub collaborators who need one consistent product, module, build, and documentation identity.
- User task: clone, open, build, test, and recognize the project without encountering mixed legacy/current names.
- Feedback loop: portable verification, Xcode project parsing, path/content residual scanning, and remote branch visibility.

## Goal

Migrate the complete tracked project identity to `LiteSpace` while preserving the current terminal, SSH, local-workspace, privacy, and resource behavior.

## Scope

- Rename every tracked path component that carries the legacy product identity.
- Rename Swift package, module, target, scheme, test, bridge, executable, class, environment-variable, HTTP-boundary, persistence-namespace, bundle, Keychain, and user-facing identifiers.
- Update generated Xcode project references, scripts, fixtures, documentation, verification records, and the machine-readable role card.
- Add a repeatable identity verifier that rejects legacy names in tracked/workspace paths or text.
- Push the completed commit to the current tracked GitHub branch.

## Boundaries

- No source file or directory is deleted.
- The GitHub repository itself is not renamed; that is a separate external administration action.
- Existing behavior and dependency revisions remain unchanged.
- Portable verification is required; full Xcode, Simulator, physical-device, external-SSH, archive, and App Store gates remain independent.

## Acceptance

1. The identity verifier finds no legacy name in repository paths or text outside Git internals and build caches.
2. The expected `LiteSpace` app, project, scheme, core, bridge, UI-test, and test-suite paths exist.
3. The full existing project verifier exits successfully after the migration.
4. `git diff --check` and plist parsing succeed.
5. The migration commit is visible on the current remote branch.
