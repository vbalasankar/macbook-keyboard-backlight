# keyboard-light

Control your MacBook's keyboard backlight using global keyboard
shortcuts. No need to open System Settings.

**Version:** 1.1.0

## Shortcuts

  Shortcut                 Action
  ------------------------ ---------------------
  `Control + Option + O`   Increase brightness
  `Control + Option + P`   Decrease brightness

## Quick Start

Run these commands from the project directory.

``` bash
chmod +x scripts/*.sh
xattr -dr com.apple.quarantine . 2>/dev/null

./scripts/install.sh
```

Test brightness directly:

``` bash
C="$HOME/Library/Application Support/keyboard-light/bin/keyboard-light.sh"

"$C" get
"$C" set 0
"$C" set 100
```

Grant `kbl-helper` permissions under:

-   Privacy & Security → Accessibility
-   Privacy & Security → Input Monitoring

Restart the service:

``` bash
./scripts/restart.sh
```

## Features

-   Global keyboard shortcuts
-   Configurable brightness steps and limits
-   Brightness clamping (0--100%)
-   Automatic backend fallback
-   Starts automatically at login
-   Background service using LaunchAgent
-   No `sudo` required
-   No polling or background timers
-   Pause and resume shortcuts
-   Clean uninstall

## How It Works

1.  A lightweight Swift helper listens for global keyboard events.
2.  Matching shortcuts trigger the Bash controller.
3.  Bash handles brightness calculations, configuration and locking.
4.  CoreBrightness handles reading and writing brightness.
5.  If CoreBrightness is unavailable, keyboard media keys are used as a
    fallback.

Bash handles the logic. Swift is only used where native macOS APIs are
required.

## Configuration

Location:

``` text
~/Library/Application Support/keyboard-light/config
```

  Setting          Default   Description
  ---------------- --------- -----------------------------
  `STEP_PERCENT`   `10`      Brightness change per press
  `MIN_PERCENT`    `0`       Minimum brightness
  `MAX_PERCENT`    `100`     Maximum brightness
  `BACKEND`        `auto`    Brightness backend
  `LOG_LEVEL`      `error`   Logging level

Supported backends: `auto`, `corebrightness`, `mediakey`.

## Requirements

-   Apple Silicon Mac (target: MacBook Air M4)
-   macOS 13 or newer
-   Xcode Command Line Tools for Swift compilation

No third-party dependencies.

## Limitations

-   CoreBrightness uses a private, undocumented Apple API.
-   Compatibility across macOS versions is not guaranteed.
-   macOS automatic keyboard brightness and inactivity timeout can
    override brightness.
-   Shortcuts are intercepted while the service is enabled.
-   Accessibility and Input Monitoring permissions are required.

## Project Structure

``` text
src/
  keyboard-light.sh
  native-helper/
    kbl-helper.swift
    kbl-media.swift

scripts/
  install.sh
  uninstall.sh
  restart.sh
  diagnostics.sh
  common.sh

config/
launchagent/
tests/
.github/workflows/
```

## Useful Commands

``` bash
C="$HOME/Library/Application Support/keyboard-light/bin/keyboard-light.sh"

"$C" get
"$C" set 40
"$C" up
"$C" down
"$C" status
"$C" disable
"$C" enable
```

## Uninstall

``` bash
./scripts/uninstall.sh
```

Remove `kbl-helper` manually from Accessibility and Input Monitoring
permissions.

------------------------------------------------------------------------

**Built for macOS. No Settings. Just shortcuts.**
