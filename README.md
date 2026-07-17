# Flick Series

Flick Series is a macOS utility prototype that uses MacBook lid motion as an input device.

The macOS app is **Flick**. A small set of hinge gestures can trigger different workspace actions without keyboard shortcuts, mouse gestures, or AI.

## Core Idea

Flick Series does not trigger actions from fixed lid-angle thresholds.

Gestures are detected from the lid angle trajectory over time:

- direction
- speed
- amplitude
- local reversal
- timing

For example, the app looks for motion patterns such as a quick close followed by a small reopening, rather than a rule like "angle below 45 degrees."

## Gestures

The input gestures are:

| Gesture | Motion |
| --- | --- |
| Close | Quickly close the display partway, then reopen slightly |
| Open | Quickly open the display further, then close slightly |

The word "Flick" is reserved for app features, not gesture names.

## Actions

Each gesture can be assigned to one of these actions:

| Action | Behavior |
| --- | --- |
| Flick Arrange | Arrange visible windows on the active screen and Space |
| Flick Focus | Keep the active window visible and hide the rest |
| Flick Hide | Hide general app windows to reveal the Desktop |
| Flick Privacy | Apply the enabled display, audio, app-hiding, work-mode, media, and focus protections |
| Flick Privacy Cancel | Restore the most recent state captured before Flick Privacy ran |

Default assignments:

| Gesture | Default Action |
| --- | --- |
| Close | Flick Arrange |
| Open | Flick Focus |

Assignments are saved locally with `UserDefaults`. Assigning Flick Privacy to one gesture automatically pairs Flick Privacy Cancel with the other gesture unless that other gesture has a saved manual choice.

## Current macOS App

The Swift macOS app lives in:

```text
Sources/Flick
```

Main pieces:

- `LidAngleSensor.swift` reads MacBook lid angle data through IOKit HID.
- `CloseGestureDetector.swift` detects the Close gesture from motion trajectory.
- `OpenGestureDetector.swift` detects the Open gesture from motion trajectory.
- `WindowArranger.swift` arranges windows with macOS Accessibility APIs.
- `WorkspaceActionExecutor.swift` implements Flick Focus and Flick Hide.
- `FlickPrivacyExecutor.swift` applies Privacy protections and performs best-effort restoration from a saved snapshot.
- `FlickDashboardView.swift` provides the dashboard UI and action assignment controls.
- `FlickController.swift` connects sensor polling, gesture detection, and actions.

There is also an earlier Python prototype:

```text
flick_prototype.py
```

The Swift app is the current implementation target.

## Requirements

- macOS 13 or later
- Xcode
- A MacBook with a readable lid angle HID sensor
- Accessibility permission for the installed app

The app is designed for MacBook hardware. On Macs without the lid angle sensor, the dashboard can still open, but live gesture detection will not work.

## Build

Build with Xcode:

```sh
xcodebuild \
  -project Flick.xcodeproj \
  -scheme Flick \
  -configuration Debug \
  -derivedDataPath /private/tmp/FlickDerivedData \
  build
```

## Install Locally

The install script builds the app, signs it with a stable local designated requirement, installs it into `/Applications`, and opens it:

```sh
./scripts/install_flick.sh
```

Installed app path:

```text
/Applications/Flick.app
```

## Permissions

Flick needs macOS Accessibility permission to inspect, move, hide, and restore windows.

Enable it here:

```text
System Settings > Privacy & Security > Accessibility > Flick
```

If macOS prompts for Automation or System Events access during experiments, allow it as well.

If the app was rebuilt or replaced and permissions behave strangely, remove and re-add Flick in Accessibility settings.

## Run

After launching the app:

1. Open the dashboard from the status bar item.
2. Choose `Close` or `Open`.
3. Assign a Flick action, including `Flick Privacy` or `Flick Privacy Cancel`.
4. Use the `Run` button to test the assigned action manually.
5. Use the MacBook lid motion to trigger the assigned action.

## Window Arrangement Policy

Flick Arrange targets windows visible on the active screen/Space and avoids hidden, minimized, invalid, or off-screen windows where possible.

Current layout rules include:

- 1 window: fill the usable screen area
- 2 windows: left/right split
- 3 windows: active window on the right half, two others stacked on the left
- 4 windows: 2 x 2
- 6 windows: 3 x 2
- 7 windows: top row of 3, bottom row of 4
- 8 windows: 4 x 2
- 9 windows: 3 x 3

Some macOS apps enforce their own minimum window sizes. When a target size is smaller than an app allows, macOS may clamp the final size.

## Product Direction

Flick Series is not primarily a window manager.

The central idea is:

```text
Use the laptop hinge as an input device.
```

Flick Arrange, Flick Focus, Flick Hide, Flick Privacy, and Flick Privacy Cancel are MVP actions for validating that interaction model.

## Privacy Restore Limits

Flick Privacy stores the previous built-in display brightness, output volume, apps it actually hid, and the active app/window before applying changes. Flick Privacy Cancel restores those values independently so one failed step does not stop the others.

macOS does not expose a stable public API for reading and restoring Focus state. Work-mode restoration therefore uses an optional user-configured Shortcut. Media playback is paused by Privacy but intentionally is not resumed by Cancel because the app cannot reliably identify the prior system media session.
