# Tyland

A macOS Dynamic Island for the notch.

A macOS Dynamic Island for the notch, rebuilt from scratch after tearing down the shipping Alcove
1.7.7. Native SwiftUI + AppKit, no Xcode, no external packages.

**Works on Macs without a notch.** This machine (M1 13", 2020) has none — `safeAreaInsets.top == 0` —
and the real Alcove renders nothing here. `NotchGeometry` detects a physical notch when present and
otherwise synthesises one with 14"/16" dimensions, so the app looks and behaves the same either way.

## Build & run

```bash
./build.sh            # debug
./build.sh release    # optimised
open build/Tyland.app
```

## Install

```bash
./package.sh          # -> build/Tyland.zip (and build/Tyland.dmg when hdiutil is healthy)
```

Unzip and drag `Tyland.app` to `/Applications`. It is ad-hoc signed, so the first launch needs
**right-click → Open** (or `xattr -dr com.apple.quarantine /Applications/Tyland.app` if it was
downloaded). Permissions are keyed to the signature, so moving or rebuilding the app re-prompts.

`package.sh` prefers `hdiutil makehybrid` + `convert` over `hdiutil create -srcfolder`, because the
latter attaches a temporary volume and hangs indefinitely when DiskArbitration is wedged. If the DMG
step is skipped, the ZIP installs identically — `ditto` preserves the code signature, which matters
because the media helper's signing identifier is what makes Now Playing work.

Requires only Command Line Tools — the CLT SDK ships SwiftUI, AppKit, CoreAudio, EventKit and the
rest. No `.xcodeproj`, no SPM manifest.

```bash
./build/Tyland.app/Contents/MacOS/Alcove --self-test   # geometry, shape, activity priority, media maths
TYLAND_DEBUG=1 open -a build/Tyland.app --stderr /tmp/tyland.log   # trace to stderr
```

## Releases

Pushing to `main` cuts a release: `.github/workflows/release.yml` works out the version, builds,
and attaches `Tyland.dmg` (and `Tyland.zip`) to a GitHub release. [`CHANGELOG.md`](CHANGELOG.md) is
regenerated from the commit messages and committed back.

The version comes from [conventional commits](https://www.conventionalcommits.org) since the last
`vX.Y.Z` tag — the commit message chooses the bump, while every push to `main` still publishes:

| Commit                             | Bump  |
| ---------------------------------- | ----- |
| `feat!:` or a `BREAKING CHANGE:` trailer | major |
| `feat:`                            | minor |
| `fix:` / `perf:`                   | patch |
| `docs:` / `chore:` / `refactor:` / `ci:` | patch |

A push of nothing but docs and chores still cuts a patch release, keeping the published artifact
and changelog aligned with every `main` push. A manual workflow run also cuts at least a patch.

The version is stamped into `Info.plist` at build time, so a local `./package.sh` and a released
build report the same number. The bump logic is a plain script, and it tests itself:

```bash
./scripts/next-version.sh --self-check   # 16 cases: bump precedence, tag sorting, junk tags
./scripts/next-version.sh                # what the next release would be, from here
```

Releases are ad-hoc signed and **not notarized** — same right-click → Open caveat as above.

## What it does

| | |
|---|---|
| Now Playing | Album art, artwork-derived gradient, scrubber, transport controls |
| Waveform | Real system audio via a CoreAudio process tap — not a fake animation |
| HUDs | Volume, display brightness, keyboard backlight, battery, charging |
| Devices | Bluetooth connect/disconnect with AirPods battery from the IORegistry |
| Gestures | Two-finger swipe down/up to open/close, left/right to skip tracks |
| Live activities | Focus mode, microphone and camera in use |
| Sounds | Synthesised cues, or macOS system sounds. No audio files bundled |
| Calendar | Upcoming events feed the leave-in ETA activity |
| Leave-in ETA | MapKit travel time to the next event that has a location |
| Downloads | In-progress downloads, with a chime on completion |
| Screen recording | Detected via private `CGSIsScreenWatcherPresent` |
| Particles | Charging sparkle, device-connect burst |
| Lock Screen | Clock, date, battery, now playing — **off by default**, see below |
| Settings | Tabbed: General / Widgets / Sounds / Notch, including size calibration |

## How Now Playing works

macOS 15.4 added an entitlement check to `mediaremoted`; unentitled apps get nothing. Alcove's
answer is an XPC service whose bundle id is `com.apple.controlcenter.TylandHelper` — the check grants
access to anything under `com.apple.*`.

This build does the same thing more simply: `Contents/Helpers/TylandHelper` is a plain child process
signed with `--identifier com.apple.tyland.mediahelper` (see `build.sh`). It links MediaRemote via
`dlopen`, streams newline-delimited JSON on stdout, and takes commands on stdin. It exits when its
stdin closes, so it can never outlive the app.

Verify independently:

```bash
./build/Tyland.app/Contents/Helpers/TylandHelper test   # exit 0 = mediaremoted answered
```

If Apple ever closes this hole the app degrades instead of breaking: `MediaService` runs the
helper's `test` at launch (asynchronously — blocking on it stalled startup) and falls back to
`AppleScriptMediaBackend`, which drives Music and Spotify over Apple Events. That path polls, only
knows scriptable apps, and has no artwork, but music keeps working.

Note the test asks *"will mediaremoted talk to us"*, not *"is something playing"* — conflating the
two wrongly demoted everyone to AppleScript whenever playback was stopped.

## Lock Screen widgets — read before enabling

Uses private CGS Space APIs (`CGSSpaceCreate`, `CGSSpaceSetAbsoluteLevel`, `CGSAddWindowsToSpaces`).
Alcove's author locked himself out of his Mac four times building this. **Disabled by default.**

Before enabling: log in on a second admin account and confirm SSH from another machine works.

```bash
defaults write dev.local.tyland lockScreenEnabled -bool YES   # enable
defaults write dev.local.tyland lockScreenEnabled -bool NO && pkill -x Tyland   # escape hatch
```

Four things had to be exactly right, and getting any of them wrong makes it silently never appear:

| | |
|---|---|
| `SLSSpaceCreate(cid, 1, 0)` | The second argument is the literal **1**. Passing `nil` returns space 0 on every macOS tested. |
| `SLSSpaceSetAbsoluteLevel(cid, space, 400)` | **400** = `kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock`. `Int32.max` does nothing. |
| `SLSSpaceAddWindowsAndRemoveFromSpaces(cid, space, [wid], 7)` | Not `SLSAddWindowsToSpaces`; different function, different argument order. |
| `suspensionBehavior: .deliverImmediately` | Distributed notifications are **suspended for inactive apps**, and this app is always inactive when the screen locks — so `com.apple.screenIsLocked` was queued and never acted on. |

Lock state is therefore detected two ways: the notification (fast path) *and* a
`CGSSessionScreenIsLocked` sample on the shared heartbeat (the one that actually has to work).
A watchdog force-tears-down the space after unlock even if both are missed, and the feature refuses
to start if any private symbol fails to resolve.

The lock-screen card shows artwork, title, artist and progress — **no clock or date**, because
macOS already draws those and duplicating them put the panel straight on top of the system time.
It sits horizontally centred with its centre **72% down** the screen. Nudge it without rebuilding:

```bash
defaults write dev.local.tyland lockScreenPosition -float 0.67   # higher
defaults write dev.local.tyland lockScreenPosition -float 0.77   # lower
```

Diagnostic — presents the card without locking, then tears it down:
`defaults write dev.local.tyland debugPresentLockScreen -bool YES`

## Permissions

Calendars, Bluetooth, Camera, Audio capture (waveform), and `~/Downloads`. Everything degrades
gracefully — a denied permission disables one feature, never the app.

It asks for **neither Input Monitoring nor Accessibility**. Volume and brightness come from
CoreAudio/DisplayServices callbacks rather than key taps, and swipes are handled by the panel's own
`scrollWheel` instead of a global monitor — a global monitor needs Accessibility, and that grant
resets every time the binary is rebuilt, which silently killed every gesture.

**Nothing blocking may run on the main actor.** Building the CoreAudio process tap for the waveform
blocks in `mach_msg` until the Audio Capture consent prompt is answered. Because it ran on the main
actor, it froze the actor entirely: `Task.detached` still ran, but *every* `Task { @MainActor }`
queued forever. Weather never fetched, deferred services never started, and lock-screen teardown
never fired — all silently, with no error anywhere.

The tell: a detached-task canary logged while a MainActor canary did not. If MainActor tasks stop
running, something is occupying the actor — sample the process and look for `mach_msg`.

## The window is sized to the island, not to its maximum

A fixed expanded-size window leaves a dead zone over the menu bar whenever the island is collapsed:
returning `nil` from `hitTest` stops *our* views handling a click, but the window still swallows it —
AppKit does not forward it to whatever is underneath. So the panel resizes to whatever the island
currently is (228×46 collapsed, 408×174 open), growing immediately and shrinking only after the
collapse animation.

That makes hover detection delicate, because the window now resizes *because* of hover:

- SwiftUI's `.onHover` reports a spurious exit on every resize → expand/collapse oscillation.
- An AppKit tracking area is re-added by every `updateTrackingAreas()`, which re-fires
  `mouseEntered` even when the pointer is elsewhere → the same loop.

So enter/exit events are only a trigger; `NSEvent.mouseLocation` against the window frame is the
source of truth. A missed exit would leave the island stuck open, so while hovered the pointer is
also polled on the fast heartbeat and collapses the island the moment it leaves.

## What is deliberately not here

- **Live turn-by-turn navigation.** macOS exposes no way to read Maps' route state. The
  "leave in N minutes" activity delivers the useful half using MapKit.
- **Alcove's sounds and AirPods videos.** Those are copyrighted assets, not APIs. Sounds are
  synthesised at runtime or drawn from `/System/Library/Sounds`; AirPods use the battery-ring
  treatment the real Dynamic Island shows.
- **System notification mirroring.** No sanctioned API; the alternatives break every macOS release.

## Measured cost

M1 13", release build:

| | CPU | RSS |
|---|---|---|
| Island idle, music showing | **0.0–1.9%** | 40 MB |
| Music + live waveform (20 Hz) | **3.5–5.3%** | 49–65 MB |

Ranges, not points: repeated runs of the *same* configuration varied by several percent because
whatever is playing drives Now Playing updates. Measure with `cputime` deltas over a 30 s window
after a 20 s settle — `ps %cpu` is a lifetime average and once hid a 35% regression completely.

Four things mattered, found by profiling rather than guessing:

- Publishing audio levels through the coordinator repainted the whole island (notch path, clip
  shape) 30×/s. Moving levels into their own `LevelStore` took it from ~35% to ~9%.
- `ForEach` over shapes rebuilt a `DynamicViewList` every update. `Canvas` took ~9% to ~3.5%.
- The audio callback must not allocate or hop actors — it writes under a lock, a 20 Hz timer drains.
- Attaching the particle `Canvas` to every compact activity cost ~7% on the common music path;
  it is now added only for the activities that actually emit.

Everything timed rides one `Heartbeat` (250 ms fast / 2 s slow). Nothing else may create a `Timer` —
five more services each owning one is how a fraction of a percent becomes five.

Diagnostic escape hatch used to find the above:
`defaults write dev.local.tyland debugSkipServices "media,activities,weather,downloads,routes"`

## Layout

```
Sources/App/        entry point, delegate, self-test
Sources/Core/       activity model, media state, settings, heartbeat, private symbol lookup
Sources/Notch/      panel, geometry, shape, coordinator, island view
Sources/Services/   audio, brightness, battery, media (+ applescript fallback), tap, calendar,
                    gestures, bluetooth, activities, weather, downloads, routes, sound
Sources/Widgets/    expanded view, waveform, calendar, weather, device, particles, settings
Sources/LockScreen/ CGS space controller (off by default)
Helper/             MediaRemote child process
```
