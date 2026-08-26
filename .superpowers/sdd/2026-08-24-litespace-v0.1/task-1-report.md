# Task 1 Report: Standalone project and bounded terminal primitives

## Implementation

- Created the standalone Swift package and XcodeGen specification. The package exposes a Foundation-only `LiteSpaceCore` library; no app, UI, network, or SSH dependency is reachable from that target.
- Implemented `TerminalHistory` as a fixed-capacity ring buffer. It defaults to 2,000 lines, drops the oldest entry at capacity, clears deterministically, and treats a non-positive limit as zero capacity.
- Implemented `ControlKeyEncoder.encode(_:)` for ASCII `@` through `_`, uppercasing ASCII letters before applying `value & 0x1F`. Unsupported and non-ASCII scalars return `nil`.
- Generated `LiteSpace.xcodeproj` with XcodeGen 2.45.4. It declares `LiteSpaceCore`, `LiteSpace`, `LiteSpaceCoreTests`, and `LiteSpaceUITests`; dependencies are `LiteSpace -> LiteSpaceCore`, `LiteSpaceCoreTests -> LiteSpaceCore`, and `LiteSpaceUITests -> LiteSpace`.

## Tests and results

| Check | Result |
| --- | --- |
| `swift test --filter 'TerminalHistoryTests|ControlKeyEncoderTests'` | Exit 0; the SwiftPM test target compiles cleanly. |
| `swift test` | Exit 0; the full package test target compiles cleanly. |
| `swift run LiteSpaceCoreTestRunner` | Exit 0; printed `PASS: 6 LiteSpaceCore terminal primitive checks`. This executes bounded-history, clear, zero-limit, Ctrl-C, Ctrl-[, ASCII uppercasing, and unsupported-character behavior. |
| XcodeGen 2.45.4 generation | Exit 0; created `LiteSpace.xcodeproj`. |
| Structural project check | `project.pbxproj` contains all four native targets and the three required `PBXTargetDependency` edges. |
| Foundation-only check | No imports of SwiftUI, UIKit, Security, SwiftTerm, Network, NIO, or NIOSSH appear under `Sources/LiteSpaceCore`. |

## RED/GREEN evidence

1. RED: after writing `TerminalHistoryTests` and `ControlKeyEncoderTests`, the required focused `swift test` command failed with `cannot find 'TerminalHistory' in scope` and `cannot find 'ControlKeyEncoder' in scope`.
2. GREEN: after adding the ring buffer and encoder, the package compiled cleanly and the package-local runner executed all six terminal primitive checks successfully.

The initial command-line-toolchain investigation also found that this Mac lacks `XCTest.swiftmodule` and full-Xcode platform metadata. Its Swift Testing helper loads test metadata but does not execute it, while `swift test --enable-xctest` exits before running because `xcrun --show-sdk-platform-path` is unsupported by Command Line Tools alone. The package therefore keeps standard XCTest source tests for the generated Xcode project and adds a package-local runner for actual behavioral execution on this Mac.

## Files changed

- `.gitignore`, `Package.swift`, `project.yml`, and generated `LiteSpace.xcodeproj/`.
- `Sources/LiteSpaceCore/LiteSpaceCore.swift`, `Sources/LiteSpaceCore/Terminal/TerminalHistory.swift`, and `Sources/LiteSpaceCore/Terminal/ControlKeyEncoder.swift`.
- `Tests/LiteSpaceCoreTests/TerminalHistoryTests.swift` and `Tests/LiteSpaceCoreTests/ControlKeyEncoderTests.swift`.
- `Tests/TestSupport/XCTest.swift` (package-only compatibility surface for the incomplete CLT environment) and `Tests/TestRunner/main.swift` (actual six-check runner).

## Self-review

- The core target contains only deterministic data/byte primitives and does not retain terminal transcripts beyond its configured ring capacity.
- The ring-buffer replacement sequence is O(1); `lines` preserves chronological order.
- The encoder cannot emit bytes for scalar values outside ASCII control-combination range.
- No secret, network, file-system, UIKit, SwiftUI, or third-party runtime code was added.

## Concerns

- Full Xcode is unavailable, so `xcodebuild -list -project LiteSpace.xcodeproj` cannot run; project validation is structural only. iPad compilation and UI test execution remain a later full-Xcode gate.
- The package-local runner is a necessary environment adaptation, not a substitute for normal XCTest execution under full Xcode. Revalidate the two XCTest files with full Xcode before promoting this candidate beyond the current development slice.

## Fix Round 1

### Changes

- Clamped every `TerminalHistory` requested limit to `0...2_000` using the private `maximumLineCount` constant. Requests such as `10_000` cannot allocate or retain more than 2,000 lines.
- Added the oversized-limit regression to both `Tests/LiteSpaceCoreTests/TerminalHistoryTests.swift` and the actually executable `Tests/TestRunner/main.swift`.
- Set `TARGETED_DEVICE_FAMILY: "2"` globally and on the `LiteSpace` XcodeGen application target (the latter prevents XcodeGen's application preset from restoring `1,2`).
- Added `INFOPLIST_KEY_UISupportedInterfaceOrientations~ipad` with portrait, portrait upside down, landscape left, and landscape right; regenerated `LiteSpace.xcodeproj` using XcodeGen 2.45.4.

### Covering tests and results

- `testOversizedLimitClampsToTwoThousandNewestLines` appends `"0"` through `"2000"` to `TerminalHistory(limit: 10_000)` and asserts count `2_000`, first line `"1"`, and final line `"2000"`.
- `swift run LiteSpaceCoreTestRunner` exits 0 after the fix and prints `PASS: 7 LiteSpaceCore terminal primitive checks`.
- `swift test --filter 'TerminalHistoryTests|ControlKeyEncoderTests'` exits 0 and `swift test` exits 0 (both compile the SwiftPM test target cleanly on this CLT-only host).
- Structural scan of `LiteSpace.xcodeproj/project.pbxproj` verifies the app Debug and Release configurations each have `TARGETED_DEVICE_FAMILY = 2;` and the exact four iPad orientation values under `INFOPLIST_KEY_UISupportedInterfaceOrientations~ipad`.

### TDD RED/GREEN evidence

1. RED: after adding the oversized-limit regression but before changing production code, `swift run LiteSpaceCoreTestRunner` exited 1 with `FAIL: oversized history limit is capped at 2,000 lines` and `FAIL: oversized history drops its oldest line`.
2. GREEN: after replacing `max(0, limit)` with `min(max(0, limit), Self.maximumLineCount)`, the runner exited 0 and all seven behavioral checks passed.
