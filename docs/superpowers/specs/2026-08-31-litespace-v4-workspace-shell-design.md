# LiteSpace V4 Workspace Shell Design

Date: 2026-08-31
Status: proposed design, implementation gated on review
Branch: `feat/litespace-v4-workspace-shell`

## 1. Context

LiteSpace is no longer only a terminal. The current `main` branch already contains a lightweight local workspace, a native editor, bounded local shell commands, SSH host management, interactive `xterm-256color` SSH sessions, file authorization, preview/runtime gates, and portable verification. PR #2 hardened SSH lifecycle behavior and PR #3 added the local workspace candidate.

The next milestone should therefore avoid rebuilding existing features. Its purpose is to make **Workspace the product center** and turn Terminal, Files, Editor, and SSH into tools attached to a workspace session.

The product principle remains:

> **Small Core, Large Reach.** LiteSpace stays lightweight on iPad; heavy runtimes and development tools remain on explicitly connected remote Mac/Linux environments.

“V4” is the product milestone name used in the current design discussion. It does not imply that the repository’s candidate/release semver must jump from the current V0.2 candidate directly to 4.0.

## 2. Goals

V4 has four goals:

1. **Workspace-first home and navigation** — opening LiteSpace should present durable workspaces and their state, rather than treating Terminal as the root experience.
2. **Workspace-bound editor/files/terminal/SSH context** — tools should open with the workspace’s selected root, recent document, host association, and session metadata.
3. **Terminal compatibility hardening** — Codex, Vim, tmux-style TUIs, UTF-8/Chinese text, resize, and ANSI/VT100 character-set transitions must not corrupt the display or control flow.
4. **Safe session restoration** — restore user-visible workspace state after navigation/relaunch without pretending iPadOS can keep arbitrary processes or SSH sockets alive in the background.

## 3. Non-goals

V4 does not add:

- AI orchestration or embedded Codex/Hermes runtimes
- plugin marketplace
- team collaboration
- Docker, VM, or full local Linux
- arbitrary local process execution
- complex GitHub PR UI
- cloud account synchronization
- unrestricted SFTP/file mirroring
- a promise that SSH survives iPadOS suspension

Existing local Web/Python/Swift capability gates remain unchanged unless a V4 change is required to preserve workspace/session correctness.

## 4. Architecture

### 4.1 Workspace becomes the composition root

Introduce a durable `WorkspaceProfile` that contains only user-selected, safe-to-persist metadata:

- stable workspace ID
- display name
- authorized root bookmark reference / local Documents root identity
- optional preferred SSH host ID
- last selected tool (`files`, `editor`, `terminal`, `ssh`)
- last selected relative file path when safe to restore
- presentation metadata such as last-opened timestamp

It must **not** persist terminal output, passwords, private keys, temporary preview authentication material, runtime source snapshots, or active socket/process state.

A `WorkspaceSessionCoordinator` owns the foreground session state for one selected workspace and coordinates:

- authorized file access
- editor draft lifecycle
- local shell current directory/history view
- SSH connection state
- terminal presentation
- preview/runtime teardown

The coordinator does not merge these subsystems into one implementation. Existing module boundaries remain intact.

### 4.2 Home / workspace switcher

The app root becomes a workspace-oriented surface:

- recent/saved workspaces
- Create/Open Workspace
- concise state badges (local, preferred host configured, last tool)
- explicit access to Hosts/Settings without requiring an active terminal

Opening a workspace restores only safe presentation state. If the security-scoped bookmark is stale or inaccessible, the workspace opens in a repair state and asks the user to re-authorize the directory rather than silently broadening access.

### 4.3 Workspace tool shell

Inside a workspace, use a stable tool container with the existing tools:

- Files
- Editor
- Terminal
- SSH
- Problems/Ports when the local workspace runtime supports them

Switching tools must not silently discard an unsaved editor draft. Existing draft guards remain authoritative.

Local Terminal starts from the workspace root/current authorized directory. SSH starts from the workspace’s preferred host when configured, but connecting remains an explicit user action.

### 4.4 Editor scope

V4 builds on the existing native editor rather than introducing a second editor engine.

Required additions are limited to lightweight usability:

- line numbers
- search/find and replace
- basic syntax coloring for the already-supported text/code formats when implementable without a heavy parser/runtime
- preserve existing size/resource limits

No semantic completion, LSP, compiler embedding, or VS Code parity is added.

### 4.5 Terminal compatibility hardening

The existing SwiftTerm-backed terminal remains the renderer. V4 focuses on integration correctness and regression coverage rather than creating a custom terminal emulator.

Required compatibility checks include:

- UTF-8 and Chinese output/input round trips
- resize propagation to remote PTY
- `Esc`, `Tab`, arrows, `Ctrl+C`, `Ctrl+Z`, and modifier actions
- alternate-screen entry/exit where supported by SwiftTerm
- ANSI SGR reset behavior
- DEC Special Graphics G0 transitions, especially `ESC ( 0` followed by `ESC ( B`
- terminal reset restores the default character-set state

A specific regression fixture must cover the previously observed corruption where normal ASCII was rendered as DEC line-drawing glyphs. Minimum reproduction:

```sh
printf '\033(0qqqqqq\033(B NORMAL-TEXT\n'
```

Expected result: the first segment may render as line drawing while `NORMAL-TEXT` renders as normal ASCII. The fixture should also verify subsequent UTF-8 Chinese text is unaffected.

If the bug is inside the pinned SwiftTerm version rather than LiteSpace integration, the implementation must prefer a pinned upstream fix or minimal, well-isolated compatibility shim over forking/reimplementing the terminal parser.

### 4.6 Session restoration model

V4 distinguishes three layers explicitly:

1. **Durable profile state** — workspace identity, root authorization reference, preferred host, last tool, safe recent path.
2. **Foreground in-memory state** — editor selection, local terminal view/history, current SSH presentation, Problems/Ports.
3. **Non-restorable runtime state** — active SSH socket/PTY, local preview listener, transient authentication material, running local runtime.

On app relaunch or after iPadOS has suspended/terminated the app:

- restore the workspace and last tool
- restore safe local navigation state
- show the previous remote host as disconnected/reconnectable
- never claim that an old SSH process is still live unless the connection actually remains valid
- local preview/runtime must follow the existing background teardown rules and restart only via explicit user action

This avoids fake persistence while making the UI feel continuous.

## 5. Data and security boundaries

- Passwords, generated SSH private keys, and trusted host-key material remain in Keychain.
- Workspace profiles may reference host IDs but never copy host secrets.
- Security-scoped bookmarks remain the only mechanism for durable external folder access.
- Restored relative paths must be re-resolved beneath the authorized root and revalidated against path traversal/symlink replacement protections.
- No terminal transcript or command output is persisted by default.
- No new analytics, telemetry, tracking, cloud sync, or background capability is introduced.
- A disconnected restored SSH card must never expose stale sensitive terminal output as proof of a live session.

## 6. Resource limits

Existing hard limits remain the default contract. V4 must not materially regress the current lightweight targets.

New durable metadata should remain small: workspace profiles are metadata only, with an intended order of kilobytes per workspace, not cached project contents.

The implementation must not create one live `WorkspaceSessionCoordinator` per saved workspace. Only the selected foreground workspace may own active runtime/session objects; saved workspaces are inert profiles.

## 7. Error handling

- Stale folder authorization → repair/re-authorize state; no implicit fallback to unrelated external directories.
- Missing/deleted recent file → clear only that recent-file reference and keep the workspace usable.
- Missing preferred SSH host → retain workspace, show host association as unavailable, allow selecting a replacement.
- SSH disconnect → preserve workspace UI, mark session disconnected, offer explicit reconnect.
- Terminal parser/renderer exception or malformed output → fail the session visibly without changing stored workspace/file data.
- Unsaved editor draft → existing explicit keep/discard flow remains mandatory before destructive navigation.

## 8. Testing and acceptance

### 8.1 Portable/Core tests

Add tests for:

- workspace profile encoding/decoding without secrets
- last-tool and recent-path restoration
- stale/missing workspace references
- path revalidation on restore
- preferred-host reference removal/replacement
- only one active session coordinator policy

### 8.2 Terminal regression tests

Where possible at the integration layer, cover:

- DEC graphics enter/exit regression
- UTF-8 Chinese after charset reset
- control-key byte sequences
- resize forwarding
- remote normal EOF vs transport loss behavior remains intact

### 8.3 UI acceptance

The V4 milestone is accepted only when this flow works on iPad Simulator and, before release claims, physical iPad:

1. Launch LiteSpace to Workspace Home.
2. Create/open an authorized local workspace.
3. Open a text/code file, edit it, search it, and save it.
4. Open Local Terminal and confirm it is rooted in the workspace.
5. Switch to SSH, select the workspace’s preferred host, connect explicitly, and run commands.
6. Run a TUI/terminal compatibility probe including DEC graphics reset and UTF-8 Chinese.
7. Switch among Files/Editor/Terminal/SSH without losing an unsaved draft or corrupting terminal state.
8. Background/foreground the app and verify existing lifecycle rules.
9. Relaunch the app and restore workspace + last tool while representing SSH truthfully as connected only if it really is.
10. Verify no secrets or terminal transcript were added to workspace persistence.

## 9. Implementation order

1. Introduce `WorkspaceProfile` persistence and migration around the current workspace representation.
2. Add root Workspace Home/switcher and safe restoration coordinator.
3. Bind existing Files/Editor/Local Terminal to selected workspace context.
4. Bind optional preferred SSH host and disconnected restoration semantics.
5. Add editor line numbers/search/basic lightweight highlighting.
6. Add terminal compatibility regression probes and fix only confirmed integration/upstream issues.
7. Extend portable verification and UI acceptance documentation.
8. Run full existing verification to prove V0.1/V0.2 safety/resource boundaries did not regress.

## 10. Success criteria

V4 succeeds when LiteSpace feels like one lightweight iPad development workspace rather than separate terminal/file/SSH screens, while preserving the current security and lightweight constraints.

The user should be able to open one workspace, edit a file, use the local terminal, explicitly connect to a remote SSH host, return to the editor, leave/reopen the app, and recover the workspace context without secret leakage, fake background-process claims, or terminal character corruption.
