# Auditable CPython iOS input

LiteTerm's Python candidate is built from the official CPython 3.14.7 source archive. The reviewed URL, archive SHA-256, release tag commit, upstream build command, and required iOS slices are locked in `source.json`.

The XCFramework is intentionally not committed. Run `scripts/fetch-cpython-source.sh` and then `scripts/build-cpython-ios.sh` on a Mac with a full stable Xcode installation and iOS Simulator platform. The build script refuses Command Line Tools-only environments, never invokes the upstream clean target, never replaces an existing cache/artifact directory, and emits a path-free hash manifest beside the artifact.

The upstream 3.14.7 instructions use `python3 Apple build iOS`; older drafts that refer to `Platforms/Apple/build-apple-framework.py` are not applicable to this source release. CPython describes iOS as tier 3 and explicitly requires full Xcode. Its orchestrator downloads reviewed binary prerequisites during the build, so the produced manifest and physical-iPad validation remain release gates; source metadata alone does not prove a distributable runtime.

Runtime policy is fail-closed: if the verified framework, narrow bridge, simulator checks, or physical-iPad memory/lifecycle checks are absent, LiteTerm recognizes Python source but reports that the reviewed runtime is unavailable. It must not silently fall back to a host interpreter, remote execution, subprocess, or downloaded executable code.

Licensing: CPython is distributed under the Python Software Foundation License Version 2 and bundled historical licenses. A release containing the framework must include the exact `LICENSE` file from this pinned archive in the app notices. The current repository does not distribute a CPython binary.
