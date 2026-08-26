# Local workspaces physical-iPad gate

Date: 2026-08-26

## Outcome

Status: **OPEN**.

No physical-iPad test session, full-Xcode signing environment, development installation, or device measurement record was available. Mac measurements are not substituted for iPad evidence. The source remains a candidate, and the embedded-Python capability remains disabled while its verified XCFramework and simulator/device gates are absent.

This record contains no device name, UDID, Apple Account, user identity, local path, project content, IP address, port, preview secret, command, stdout, or stderr.

## Required device evidence

| Scenario | Status | Required observation |
| --- | --- | --- |
| Development signing and installation | OPEN | App installs and launches on the target iPad from the pinned project graph. |
| Cold start and idle | OPEN | Aggregate launch duration and steady foreground RSS; candidate idle ceiling is 90 MiB. |
| Web Check/Test/Run/Ready | OPEN | Real WebKit smoke, authenticated preview, one Ready port, edit invalidation, and steady RSS at or below 160 MiB. |
| Python compile/unittest/script | OPEN | Verified embedded runtime compiles, tests, runs, bounds output, and completes a non-service script with no port. |
| Python WSGI Ready | OPEN | App-owned authenticated loopback listener adapts bounded requests to the callable; Python owns no socket; steady RSS is at or below 180 MiB. |
| Stop and background | OPEN | Listener, accepted connections, health probes, preview, runtime task, output growth, and Ready lease reach zero before the background state is accepted. |
| Resume and rerun | OPEN | A new generation starts cleanly; stale callbacks cannot revive an old runtime or port. |
| Memory pressure | OPEN | The app fails closed, revokes the port, and recovers without retaining private runtime content. |
| Thirty start/stop cycles | OPEN | No monotonic retained-memory growth. |
| Runaway Python deadline and stop | OPEN | Deadline/cancellation is observable and no runtime continues after the stop-timeout boundary. |
| Sixty-minute Web and Python service runs | OPEN | Stable foreground service, bounded output, current health lease, and no non-loopback traffic. |
| Touch-only workflow | OPEN | Folder authorization, edit, Check/Test/Run, Problems, Ports, Preview, mutation invalidation, rerun, and Stop complete without a hardware keyboard. |

## Release rule

- Do not raise or reinterpret the 90/160/180 MiB candidate ceilings without measured evidence and a reviewed specification change.
- Any threshold failure keeps the affected runtime disabled and records the measured aggregate; it is not converted into a warning-only pass.
- A simulator pass cannot close this physical-device gate.
- Physical-iPad evidence cannot close archive privacy, signing distribution, export compliance, or App Review gates.
