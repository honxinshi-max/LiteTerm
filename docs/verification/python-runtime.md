# Embedded Python verification status

Date: 2026-08-26

## Outcome

The Python project classifier, immutable snapshot input, pinned official CPython metadata, no-overwrite fetch/build recipes, fail-closed C bridge surface, import/audit policy primitives, controller capability gate, and app-owned WSGI request/response envelopes are present.

Python execution is **disabled in the current build**. This Mac has only Apple Command Line Tools. CPython 3.14.7's own iOS instructions require a full Xcode installation and an iOS Simulator platform, so no XCFramework was built, linked, or represented as verified.

## Verified here

- `scripts/verify-cpython-artifact.sh`: PASS for the exact source metadata.
- `scripts/fetch-cpython-source.sh`: PASS against an already downloaded official archive with SHA-256 `62859805f6fdf25e2bcbf3fa3217801e1996887ca33e6a2af80674bdfa2dbe07`.
- `scripts/build-cpython-ios.sh`: expected FAIL before build with `full Xcode is required for the iOS framework`.
- Portable runner: Python capability, policy, controller, and WSGI envelope checks are included in the current PASS total.
- Missing artifact behavior: recognized Python workspaces end in a typed unsupported failure with no compilation claim and no port.

## Open release gates

- Build the official 3.14.7 device/simulator XCFramework with full Xcode and emit/verify its per-file manifest.
- Replace the unavailable bridge implementation with the reviewed CPython initialization, native audit hook, bounded I/O, cancellation/deadline, compile, unittest, script, and WSGI calls.
- Run bridge/runner/controller tests on an iPad simulator.
- Measure idle, compile, unittest, script, WSGI, stop, background, memory-pressure, and relaunch behavior on a physical iPad; candidate ceilings remain 90 MiB idle and 180 MiB Python.
- Confirm stop-timeout behavior, runtime reclamation, archive privacy contents, code signing, and App Review acceptability.

Until every open gate passes, Python remains unavailable at runtime. The Web and Swift paths do not depend on the Python artifact.
