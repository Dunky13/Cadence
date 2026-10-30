# Cadence

A small native macOS menu bar app for the scripts you run with launchd.

- Discover the current user’s `Library/LaunchAgents` plists automatically.
- Read interval, calendar, login, keep-alive, filesystem, and demand-based triggers.
- See whether a job is running, waiting, unloaded, or disabled, alongside the PID, previous exit code, and runs since load when launchd reports them.
- Enable or disable individual jobs persistently. Disabling also unloads the job, stopping any running instance.
- Read the end of configured stdout and stderr log files, with selectable text, copy, refresh, and Reveal in Finder.
- Search scripts and filter by enabled state. Status and open logs refresh every five seconds while the panel is open.
- Run an enabled job immediately without restarting an existing run.
- Create jobs from cron expressions or schedule presets, with automatic stdout/stderr capture.

SwiftUI interface, AppKit menu bar integration, no third-party dependencies. Requires macOS 14 or later and Xcode’s Swift 6 toolchain to build.

## Drag-and-drop installer

Build a universal Apple Silicon/Intel installer from the repository root:

```sh
./scripts/package-macos.sh universal
```

Open `dist/packages/0.2.0-universal-local/Cadence-Installer-0.2.0-universal-local.dmg` and drag **Cadence.app** to **Applications**. Local packages are ad-hoc signed and not notarized. Updating the app preserves your scripts, schedules, enabled states, and logs.

macOS-only CI tests both architectures and builds a verified universal installer. Successful trusted-main CI automatically promotes its exact artifact through Developer ID signing, app and DMG notarization, installed-app verification and immutable GitHub publication. The stable version comes from `Resources/Info.plist`; already-published versions are a no-op. A daily check skips unchanged commits; intentional manual recovery reuses retained bytes and Apple UUIDs. See [release instructions](docs/RELEASING.md) for credentials, recovery and qualification boundaries.

The app includes a copper waveform icon in Finder, the installer, and About. Its checked-in artwork and reproducible generator are described in the [icon instructions](docs/RELEASING.md#app-icon).

## Build and run

From the repository root:

```sh
./scripts/build-app.sh
open dist/Cadence.app
```

The waveform icon appears in the menu bar. Click it to open Cadence; use the ellipsis menu to quit. There is no Dock icon. The bundle can be moved into Applications. The script builds for the current Mac’s architecture by default; use `./scripts/build-app.sh release universal` for both architectures. These builds are ad-hoc signed for local use. Developer ID signing and notarization use the separate distribution workflow.

For a quicker development build:

```sh
./scripts/build-app.sh debug
open dist/Cadence.app --args --show
```

You can also open `Package.swift` in Xcode, select the Cadence executable, and run it.

## Scope and controls

Cadence manages plists directly inside the logged-in user’s `Library/LaunchAgents` directory, in that user’s `gui/<uid>` launchd domain. It can create new definitions; existing plist contents are preserved. It does not discover privileged LaunchDaemons, change system agents, or request administrator access. A missing directory produces an empty state; opening the folder or creating a job creates it if necessary.

Enable first calls `launchctl enable`, then bootstraps an unloaded job. Disable first calls `launchctl disable`, then boots out a loaded job. These changes persist across restart. Enabling a `RunAtLoad` or `KeepAlive` job may immediately execute it. Disabling can terminate an active run. If a step fails, Cadence reports the partial result and rereads the actual state.

An externally disabled job may still be loaded and running or waiting for triggers. Cadence preserves its runtime status and offers “Stop & disable” to unload it. “Enabled” means permitted to load; “Not loaded” means its definition is not currently registered. Run Now loads an enabled job if needed and uses `kickstart` without its restart flag.

For unloaded jobs that already start when loaded, loading supplies the run request; Cadence does not issue a second kickstart that could execute a short script twice.

Duplicate labels, changed configuration files, loaded jobs using another plist, unknown launchctl output, and query failures prevent unsafe controls. No jobs are enabled, disabled, or run simply by opening the app. Cadence does not register itself to start at login; add the app through macOS Login Items if desired.

## Schedules and logs

Schedules describe the plist’s triggers, rather than promising an exact next-run time. Calendar schedules use local time and wildcard fields; multiple calendar entries are preserved. Interval triggers can be missed while asleep or already running. Launchd controls actual execution.

Logs come from `StandardOutPath` and `StandardErrorPath`. New jobs created in Cadence configure capture automatically. Existing jobs without those keys show instructions rather than an empty fabricated log. Relative log paths resolve against `WorkingDirectory`, or `/` if omitted; launchd does not expand shell variables or tilde paths in these fields.

Only the last 128 KiB of each regular file is read. Large files, binary or invalid UTF-8 bytes, missing files, permissions errors, and nonregular paths are handled explicitly. File modification time describes the log file, not the last execution. Logs are aggregated output, not a reconstructed per-run history. They stay on your Mac; Cadence has no network service or telemetry.

## Create a scheduled job

1. Click **+** in the menu bar panel, choose **New Scheduled Job…** from its menu, or press **⌘N** while the panel is open.
2. Enter a name and command, or choose an executable script. Include an interpreter for a script that is not executable, for example `/bin/bash /path/to/script.sh`.
3. Choose a preset or enter five cron fields: **minute hour day month weekday**. For example, `*/15 * * * *` runs every 15 minutes and `0 9 * * 1-5` runs at 09:00 on weekdays. The form validates the expression and shows its meaning.
4. Optionally select an existing working folder and log folder. Defaults are your home folder and the user’s `Library/Logs/Cadence` directory. Each job gets its own private log subfolder.
5. Leave **Enable after creating** on to register its schedule, or turn it off to save a disabled job. Click **Create job**; Cadence selects it in the list.

The scheduler is launchd, using `StartCalendarInterval`; cron expressions provide the schedule syntax. Times use your Mac’s local time zone, and calendar times missed during sleep coalesce into a run on wake. Creation does not issue Run Now or add a login trigger.

Supported syntax is numeric five-field cron: `*`, values, comma lists, ascending ranges, and steps after `*` or a range. Sunday may be 0 or 7. Names, `@` shortcuts, seconds, wrapping ranges, and advanced cron extensions are rejected. Day-of-month/weekday OR semantics are preserved. Stepped day-field intersections that cannot be represented exactly by launchd are rejected, as are schedules requiring more than 4,096 calendar entries.

Commands run as `/bin/zsh -f -c` with your home directory in `HOME` and an explicit system/Homebrew `PATH`. Interactive shell profiles and aliases are not loaded. Shell syntax in the command is intentional; the app does not execute it while saving. Files and metadata are private, and unique labels prevent same-name jobs from overwriting one another.

Job names and cron expressions are saved in the user’s `Library/Application Support/Cadence/Jobs` directory, bound to the plist’s SHA256. If a plist is edited externally, Cadence shows its actual configuration and a notice that saved display details were ignored. A registration failure leaves the saved job visible with a warning, so retrying does not accidentally create a duplicate.

## Validation

```sh
swift test --jobs 2
```

Real launchd lifecycle tests are opt-in because they register and run temporary jobs in the current login session:

```sh
CADENCE_LAUNCHD_INTEGRATION=1 swift test --jobs 2
```

They use unique test labels and temporary files to check creation, metadata persistence, no extra run on creation, enable/load, Run Now, stdout/stderr, disable/unload, and re-enable. Each test cleans up its own job and never operates on an existing user job. Launchd can retain harmless enabled overrides for unique test labels after cleanup.

## Read-only demo and native snapshots

```sh
dist/Cadence.app/Contents/MacOS/Cadence --demo
```

Demo mode is visibly labelled and uses sample scripts with job controls disabled. It does not mix samples into live discovery.

For visual QA, pass `--demo --snapshot <output.png>`, optionally with `--logs`, `--new-job`, `--light`, or `--dark`. This renders the actual native view to a PNG and exits. The output’s parent directory must exist. Omit `--demo` to inspect live discovery without changing any jobs. Snapshot files may contain private job details and should stay local.

## Source layout

- `Sources/LaunchCore`: plist parsing, launchctl boundary, job controls, and bounded log reading.
- `Sources/Cadence`: menu bar lifecycle, observable state, and native views.
- `Tests/LaunchCoreTests`: deterministic tests and the opt-in launchd integration test.
- `Tests/CadenceTests`: app-state concurrency regression coverage.
- `Resources`: app metadata.
- `scripts`: local app packaging and icon generation.

Implementation notes and verification boundaries are in [the handoff](docs/HANDOFF.md).

References: [Apple’s launchd guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html), the current Mac’s `man launchctl` and `man launchd.plist`, and [Apple’s menu bar utility guidance](https://developer.apple.com/documentation/swiftui/menubarextra).
