# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Side Screen turns an Android tablet into a real second display for macOS. The macOS host creates a *virtual* display (private `CGVirtualDisplay` API), captures it with ScreenCaptureKit, encodes H.265 with VideoToolbox, and streams it over TCP to an Android client that decodes with MediaCodec and sends touch events back. Two transports: **USB** (adb reverse port forwarding, native Android app) and **wireless** (QR-paired browser viewer over LAN).

Two independent codebases that must stay wire-compatible:
- `MacHost/` — Swift 5.9 / SwiftPM executable, macOS 14+, zero external dependencies
- `AndroidClient/` — Kotlin / Gradle, minSdk 26, target/compile SDK 34, JDK 17

## Commands

```bash
# macOS: build universal binary + .app bundle (this is the canonical build)
./scripts/build_mac.sh
./scripts/build_mac.sh --reset-state   # also wipes stale TCC/defaults after ad-hoc rebuild

# macOS: quick iterate (arm64 only, reuses SideScreen.app so permissions survive)
cd MacHost && swift build -c release

# macOS tests — REQUIRES full Xcode; XCTest is unavailable under CommandLineTools-only
cd MacHost && swift test
cd MacHost && swift test --filter HandshakeCodecTests           # single test class
cd MacHost && swift test --filter HandshakeCodecTests/testParse # single test

# Android
./scripts/build_android.sh                    # sets JAVA_HOME from Android Studio jbr or homebrew openjdk@17
./scripts/install_android.sh                  # build if needed, adb install, set up adb reverse
cd AndroidClient && ./gradlew test            # unit tests
cd AndroidClient && ./gradlew test --tests '*AuthHandshakeTest'

# Lint — both are enforced --strict in CI, neither is installed by default
cd MacHost && swiftlint lint --config .swiftlint.yml --strict
cd AndroidClient && ktlint "app/src/main/java/**/*.kt"

# Dev loop: build mac + bundle + install APK + adb reverse in one shot
./scripts/dev-test.sh

# Reset everything (TCC records, UserDefaults, Android app data, adb reverse)
./scripts/reset_settings.sh
```

CI (`.github/workflows/`) runs **build + lint only** — it never runs the test suites. Run them locally before claiming green.

## Versioning

`VERSION` at the repo root is the single source of truth. `build.gradle.kts` reads `../VERSION` at configure time and derives `versionCode` as `major*10000 + minor*100 + patch`; `build_mac.sh` and `release.yml` read it for `CFBundleVersion`. Never hardcode a version anywhere else — use `./scripts/bump-version.sh [major|minor|patch]`.

## Wire protocol (the thing that breaks quietly)

`MacHost/Sources/StreamingServer.swift` (`private enum WireMessage`) and `AndroidClient/.../StreamClient.kt` (`companion object`) define the same byte constants independently. Changing one without the other produces a silent stall, not a compile error.

| Type | Direction | Meaning |
|---|---|---|
| 0 | host → client | legacy video frame (no metadata) |
| 1 | host → client | display config: width/height/rotation as `Int32` big-endian |
| 2 | client → host | touch event (normalized floats, little-endian native loads) |
| 4 / 5 | client ⇄ host | ping / pong |
| 6 | host → client | video frame + `[keyframe flag][capture timestamp u64 BE]` |
| 7 | client → host | keyframe request (flag bit 1 = force, bypasses throttles) |
| 8 | client → host | "I support type 6" capability advertisement |
| 9 | client → host | display rotation request |

Backward compatibility is deliberate and load-bearing: the host only emits type 6 after the client sends type 8, so old clients keep getting type 0. **Preserve this when adding message types** — mixed-version pairs are a supported configuration (see CHANGELOG 0.9.0).

The host reads input with a *buffered* parser that consumes one message at a time — TCP coalescing previously dropped trailing messages. Don't reintroduce a "read N bytes, handle first message, discard rest" pattern.

## Wireless auth (mirrored implementations)

Four file pairs must be edited together; each pair implements the same format on both sides:

| macOS | Android |
|---|---|
| `HandshakeCodec.swift` | `AuthHandshake.kt` |
| `PairingURL.swift` | `PairingURL.kt` |
| `PairedDeviceStore.swift` | `PairedHostStorage.kt` |
| `ConnectionMode.swift` | `ConnectionMode.kt` |

Handshake: request `[magic "SSWA"][token 32][name_len 1][name ≤64 UTF-8]`, response `[magic "SSWR"][status 1]`. The 32-byte token comes from `SecRandomCopyBytes`, lives in `UserDefaults` under `wireless.authToken`, and is compared in constant time (`WirelessAuth.validate`). Loopback connections skip auth entirely (that's the USB path); non-loopback connections are rejected outright when `expectedAuthToken` is nil. Pairing URL scheme is `sidescreen://host:port?t=<base64url token>&name=<mac name>`, registered as a deep link in `AndroidManifest.xml`.

## Ports

Default stream port is **54321** (user-configurable in Settings; was 8888 before 0.7.2). Everything else derives from or sits next to it:

- `settings.port` — native H.265 TCP stream (`StreamingServer`)
- `BrowserStreamServer.webPort(for:)` = `port + 1` — HTTP/MJPEG browser viewer + health endpoint
- `54323` — `GalaxyCameraServer` (Android phone camera → Mac)
- `54324` — `GalaxyCameraPreviewServer` (local HTTP preview, consumed by OBS via `scripts/setup_obs_galaxy_camera.sh`)

USB mode requires `adb reverse` on all three of stream/web/camera ports; `AppDelegate.setupADBReverse()` does this automatically with 3 retries (first-install authorization is racy). If you add a port, update `setup-usb.sh`, `install_android.sh`, and `reset_settings.sh` too.

## macOS host architecture

`main.swift` → `AppDelegate` (menu bar app, no storyboard) owns everything:

- **`VirtualDisplayManager`** — private `CGVirtualDisplay` API, reached through `Sources/CGVirtualDisplayBridge.h` + `module.modulemap`. This is why `Package.swift` needs `unsafeFlags(["-Xcc", "-fmodule-map-file=Sources/module.modulemap"])` on both targets; removing them breaks the build. HiDPI = allocate 2× physical pixels for the same logical size.
- **`ScreenCapture`** — SCStream on the virtual display, with a frame-flow watchdog that restarts the stream and falls back to `CGDisplayStream` if frames stop arriving. Its frame handler is the fan-out point: each pixel buffer goes to both the H.265 encoder *and* `BrowserStreamServer`. Backpressure is a hard cap of 2 pending encodes — dropped frames are preferred over queue growth.
- **`VideoEncoder`** — VideoToolbox HEVC, short GOP. `requestKeyframe()` forces an IDR; requests arriving before the encoder exists are latched and applied at init.
- **`StreamingServer`** — `NWListener` TCP, `noDelay` + fast open. A newly connected client is held at `waitingForSyncFrame` until the first keyframe, so no P-frames reach a cold decoder.
- **`BrowserStreamServer`** — JPEG-over-HTTP path for the wireless browser viewer (no MediaCodec involved), same touch callback signature as the native path.
- **`SettingsWindow.swift`** — SwiftUI settings + `SettingsStore` (`@Published` properties that write straight to `UserDefaults`). This file also owns the QR rendering panel.

**Touch input** arrives normalized, then `AppDelegate` runs a gesture state machine (tap / long-press / drag / two-finger scroll / pinch / momentum) and injects `CGEvent`s. This needs **Accessibility** permission; capture needs **Screen Recording**. Ad-hoc signing changes the binary signature on every rebuild, which invalidates the existing TCC grant — that's what `--reset-state` / `reset_settings.sh` (`tccutil reset` + `lsregister`) exist for.

## Android client architecture

`MainActivity` hosts both connection modes (USB tab / wireless tab via `WirelessTabController`) plus the settings bottom sheet. `StreamClient` owns the socket, the message loop, and keyframe-freshness tracking; `VideoDecoder` wraps MediaCodec HEVC with explicit decoder selection (`findBestDecoder`) and drops decoder output older than 100 ms rather than rendering stale frames. `InputPredictor` extrapolates touch positions to hide network latency. `GalaxyCameraActivity` is the separate camera-uplink feature. `DiagLog` writes diagnostics off the calling thread — keep it that way, synchronous file I/O showed up in input-latency profiles.

## Conventions

- SwiftLint config disables most style rules (`line_length`, `file_length`, `function_body_length`, `identifier_name`, …) but runs `--strict` in CI, so *any* remaining warning fails the build. `included: Sources` only — tests aren't linted.
- ktlint 1.1.1 over `app/src/main/java/**/*.kt`, also `--strict` in CI. Trailing commas and multiline parameter lists are the house style it enforces.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:`); branches are `feature/…`, `fix/…`, `docs/…`.
- User-visible releases get a full CHANGELOG entry explaining the *mechanism* of the fix, not just the symptom — match the existing depth.
