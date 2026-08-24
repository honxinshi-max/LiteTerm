# LiteTerm V0.1

LiteTerm is an iPad-first terminal with one active terminal session. Local mode is a fixed, sandboxed file shell; SSH mode is one interactive PTY on a host the user explicitly saves and selects. Compilers, Git, Codex, Hermes, language runtimes, and other heavy tools stay on that remote host.

## Architecture and scope

- `LiteTermCore` is Foundation-only. It owns Local parsing/filesystem containment, bounded terminal state, host metadata, host-key policy, reconnect policy, and Local → SSH → Local flow state.
- The `LiteTerm` app owns SwiftUI/UIKit, SwiftTerm, Files authorization and security-scoped bookmarks, coordinated file access, native editing, Keychain, and SwiftNIO SSH over NIOTransportServices.
- Exactly one terminal mode/session is active. A new SSH connection supersedes the old generation, manual disconnect cancels retry intent, and stale callbacks cannot mutate the current session.
- Local input, each Local input batch, and each in-memory command-history entry are capped at 16 KiB; one reduction emits at most 128 events; command history is capped at 200 entries and 128 KiB total. SwiftTerm scrollback remains capped at 2,000 lines; `cat` and `edit` are capped at 5 MiB; pending SSH output is capped at 8 MiB and delivered to the UI in batches no larger than 64 KiB.
- V0.1 does not include SFTP, port forwarding, plugins, cloud sync, local Unix/process execution, VMs, bundled language runtimes, or background keepalive.

The exact Local command set is `pwd`, `ls`, `cd`, `cat`, `mkdir`, `touch`, `cp`, `mv`, `rm`, `clear`, and `edit`. There are no pipes, redirection, glob expansion, scripts, downloaded commands, or `Process`/`NSTask` execution. Absolute command paths are virtual paths under the selected workspace. `rm` creates a confirmation request showing the exact one-file target and deletes only after the user chooses Delete; cancellation, mode/root changes, and superseding commands invalidate the request. It rejects the workspace root and directories and never removes recursively. `edit` opens the native SwiftUI editor; it does not execute an editor binary. Local Up/Down navigates the bounded command history.

Files access is limited to App Documents and a directory the user explicitly chooses with the system folder picker. External access uses one security-scoped bookmark and coordinated file operations. If replacement and restoration of an external scope both fail, the authorization store and terminal root reconcile to App Documents, expose the error, and require re-selection.

The app privacy manifest declares app-only UserDefaults reason `CA92.1` and FileTimestamp reasons `C617.1` plus `3B52.1`. The separate `LiteTermCore` framework manifest declares only the two FileTimestamp reasons. Both declare no tracking, tracking domains, or collected-data types. These source declarations still require an archive-generated privacy report check.

## SSH, authentication, and trust

LiteTerm uses SwiftNIO SSH over Network.framework transport and requests one `xterm-256color` PTY plus an interactive shell. Authentication is either a password stored in Keychain or an app-generated Ed25519 private key stored in Keychain. Arbitrary imported PEM/RSA/encrypted keys are outside V0.1.

Host metadata JSON contains only ID, label, hostname, port, username, authentication kind, and reconnect preference. Passwords, private keys, and trusted SHA-256 host-key fingerprints are separate Keychain items protected with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. First use requires explicit fingerprint trust. A changed key hard-fails until the user explicitly replaces trust. Transport loss may retry only in the foreground, at most three times after 1, 2, and 4 seconds; authentication rejection, trust mismatch/cancel, backgrounding, and manual disconnect cancel retry work. iPadOS suspension is expected to break the socket.

LAN SSH is why `NSLocalNetworkUsageDescription` is present. LiteTerm does not browse or advertise Bonjour services, so `NSBonjourServices` is intentionally absent.

## Dependencies and licenses

Direct packages are pinned by immutable revision in `project.yml`: SwiftTerm 1.15.0 (`dd2fb8a…`, MIT), swift-nio-ssh 0.15.0 (`3ec2814…`, Apache-2.0), swift-nio-transport-services 1.28.0 (`67787bb…`, Apache-2.0), swift-nio 2.101.3 (`0b18836…`, Apache-2.0), and swift-crypto 4.5.1 (`47d3869…`, Apache-2.0). The exact direct and transitive graph is locked in `LiteTerm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Full license text, revisions, upstream locations, and NOTICE attributions are in `THIRD_PARTY_NOTICES.md`, which is bundled as an app resource.

## Portable candidate checks

A Git remote is optional; this working repository currently has none configured. Remote presence or absence is informational, not a correctness gate. From the repository root:

```sh
./scripts/run-core-tests.sh
swift test
./scripts/verify-project.sh
git diff --check
/usr/bin/plutil -lint LiteTerm/Resources/Info.plist LiteTerm/Resources/PrivacyInfo.xcprivacy Sources/LiteTermCore/Resources/PrivacyInfo.xcprivacy LiteTerm.xcodeproj/project.pbxproj
```

`swift test` compiles the standard test targets in the current Command Line Tools setup; `run-core-tests.sh` is the command that actually executes the custom Core behavior runner. `verify-project.sh` performs read-only checks on tracked sources (Swift build output under `.build` is expected). When full Xcode is selected it additionally runs a generic iOS Simulator `build-for-testing`; without full Xcode that gate is explicitly `OPEN/SKIP`. Portable success is a candidate check, not a release pass.

## Full Xcode, iPad, live SSH, and RSS gates

Select a full Xcode installation, then resolve, build, and test with explicit destinations:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
xcodebuild -resolvePackageDependencies -project LiteTerm.xcodeproj -scheme LiteTerm
xcrun simctl list devices available
SIMULATOR_UDID='<available-ipad-simulator-udid>'
xcodebuild -project LiteTerm.xcodeproj -scheme LiteTerm -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" build
xcodebuild -project LiteTerm.xcodeproj -scheme LiteTerm -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" test
xcrun xctrace list devices
IPAD_UDID='<physical-ipad-udid>'
xcodebuild -project LiteTerm.xcodeproj -scheme LiteTerm -destination "platform=iOS,id=$IPAD_UDID" test
```

On a controlled Mac SSH server, enable Remote Login and record its host fingerprint before performing the 14-step flow in `docs/verification/V0.1-acceptance.md`:

```sh
sudo systemsetup -setremotelogin on
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
```

Test password and LiteTerm-generated Ed25519 authentication separately. Exercise PTY resize and all touch keys, then run a bounded high-output remote command such as `seq 1 200000` to inspect UI responsiveness/backpressure. For a 60-minute physical-device trace after attaching to the launched app:

```sh
mkdir -p verification
xcrun xctrace record --template 'Activity Monitor' --device "$IPAD_UDID" --time-limit 60m --output "$PWD/verification/LiteTerm-60m.trace" --attach LiteTerm
```

Create the release archive and measure the unthinned app payload:

```sh
mkdir -p build
xcodebuild -project LiteTerm.xcodeproj -scheme LiteTerm -configuration Release -destination 'generic/platform=iOS' -archivePath "$PWD/build/LiteTerm.xcarchive" archive
du -sk "$PWD/build/LiteTerm.xcarchive/Products/Applications/LiteTerm.app"
```

In Xcode Organizer, select that archive and generate/review its privacy report before distribution. The checked-in privacy manifest does not replace the archive-generated privacy report, App Store Connect privacy answers, export-compliance review, or App Review. App launch, rotation, software keyboard, clipboard, Files provider behavior, live SSH interoperability, real install size/RSS, 60-minute stability, archive privacy report, and App Store acceptance remain unproven until those gates are run.
