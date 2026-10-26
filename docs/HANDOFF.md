# Cadence: implementation handoff

Delivery: [PR #1](https://github.com/Dunky13/Cadence/pull/1). Hosted checks and merge status are recorded there.

## PR #2: latest-main releases and app icon

[PR #2](https://github.com/Dunky13/Cadence/pull/2) adds the no-input production entry point and the bundled copper waveform icon. The user authorized merging after green hosted checks and then publishing the notarized release. Local validation passed all 59 Swift tests, 166 synthetic contracts, and universal installer verification. The implementation commit is signed and DCO signed off.

The `apple-signing` and `production` environments now permit only `main`. The four public Apple configuration variables have been copied from the existing Agent Job Queue signing configuration. The three private Apple secrets still require secure provisioning; GitHub does not return existing secret values. Do not dispatch signing until they are configured. The release version is `0.2.0`, taken from the app plist. Hosted CI, merge, Apple acceptance, and public publication must each be checked separately; local ad-hoc packages are not production artifacts.

Merge the exact checked PR head when its native Apple Silicon/Intel, universal packaging, and aggregate checks pass. Then dispatch `release.yml` on `main` without inputs, inspect retained notarization evidence if it fails, and verify the published assets against their final checksums. Never blindly resubmit pending Apple UUIDs or overwrite an existing release/draft.

## Outcome

A native macOS menu bar utility is implemented and packaged locally. It discovers the logged-in user’s LaunchAgents, describes their execution cadence, displays live launchd status and configured run output, and provides persistent enable/disable controls. It also creates new jobs from cron expressions, saved as native LaunchAgents as requested. The macOS production pipeline is included in the same delivery; Apple submission and public binary release require its separate version-tag flow and environment configuration.

## Run it

From the repository root, open the already built app:

```sh
open dist/Cadence.app
```

Click the waveform icon in the menu bar. The ellipsis menu contains Refresh, Open LaunchAgents Folder, About, and Quit. There is no Dock icon. To rebuild:

```sh
./scripts/build-app.sh
```

The generated app can be moved into Applications. It does not add itself to Login Items.

To create a job, click **+** or choose **New Scheduled Job…**. Enter a name, command, and cron schedule or preset. Optionally choose working/log folders and whether to enable it immediately. **Create job** saves it and selects it in the list. Creation registers the schedule without requesting an extra run.

## Implemented behavior

- Automatic discovery of plists in the current user’s LaunchAgents directory; search and enabled-state filters.
- Interval, calendar, login/load, keep-alive, filesystem, mount, socket, and Mach-service trigger descriptions. Multiple triggers and calendar wildcards remain visible.
- Running, waiting, unloaded, disabled, and unknown states; PID, previous exit code, and runs since load when launchd reports them.
- Persistent enable plus bootstrap, and disable plus bootout. Disabling stops a running process. An externally disabled but still loaded job exposes a separate Stop & disable action.
- Run Now uses kickstart without restarting an existing instance. Enabling a RunAtLoad or KeepAlive job can execute it immediately.
- Separate stdout/stderr viewers with selectable text, copy, refresh, and Reveal in Finder. The last 128 KiB of configured regular log files is read. Missing capture configuration, missing files, unreadable paths, invalid UTF-8, and nonregular files are handled explicitly.
- Five-second refresh while the panel is open, native light/dark appearance, labelled read-only demo mode, and native PNG snapshot export for visual QA.
- Native job creation with validated five-field cron expressions, common presets, a script picker, working/log folder options, and automatic stdout/stderr capture. The scheduler is launchd; the user’s crontab is unchanged.
- Unique job labels, exclusive private file creation, exact saved names and cron summaries, and rollback of newly created files if persistence fails before registration. A failed registration returns the saved job with a warning so the user does not accidentally duplicate it by retrying creation.

## Verification

Validation ran locally on Apple Silicon with macOS 27.0.1 and Swift 6.4. The package targets macOS 14 or later.

- All 59 tests passed: 52 deterministic LaunchCore tests, two real launchd lifecycle tests, and five app-state/form tests. The real tests exercised creation, metadata round-trip, no extra run on creation, enable/load, Run Now, both output streams, disable/unload, and re-enable using unique temporary agents.
- Native accessibility checks exercised search, filtering, selection, the Logs tab, stderr selection, and no-output and no-match states.
- The native creation form opened through the plus action and Cmd+N, rejected an invalid cron expression, accepted a valid future-month schedule, preserved the exact shell command, and selected the saved job. Independent checks confirmed zero runs and empty output immediately after creation, followed by the expected stdout/stderr after the app’s Run Now action.
- The packaged release app enabled an isolated user agent through its actual toggle, ran it through Run Now, and displayed its stdout. Its disable action was followed by an independent launchctl check confirming both the disabled override and absence of the loaded service.
- Native view snapshots were inspected in light and dark appearance. The app bundle’s property list and ad-hoc signature verified successfully. Shell syntax and git whitespace checks passed.
- Test jobs and their temporary plists/log files were removed. Launchd may retain default-enabled overrides for unique test labels; no existing user job was changed.

The full test command is:

```sh
CADENCE_LAUNCHD_INTEGRATION=1 swift test --jobs 2
```

Without that environment variable, the two real launchd tests skip intentionally. Schedule tests compare translated calendar entries against the source cron rules across dates, including Sunday aliases, day-field OR versus wildcard semantics, validation errors, and expansion bounds. Creation tests cover private permissions, exact commands, duplicate names, filesystem rollback, registration failures, and stale/corrupt metadata. A separate regression verifies that a control action delivered during a refresh waits for the read and is then applied and reread, rather than discarded.

## Structure and maintenance

LaunchCore owns typed plist decoding, cron translation, job persistence, launchctl execution and parsing, identity validation, mutation serialization, and bounded log access. Cadence owns AppKit status-item/popover and creation-window lifecycle, observable state, and SwiftUI views. Tests are split between those two modules. Resources holds bundle metadata; scripts builds the local bundle and its icon. There are no third-party package dependencies.

Controls reject duplicate labels, changed plist bytes, conflicting loaded configuration paths, and unknown status formats. Commands are passed as process arguments rather than interpolated into a shell. Launchctl diagnostics are parsed defensively; an unrecognized future format disables controls instead of guessing. Run Now avoids a second execution request when bootstrapping a job that already starts at load; a regression covers login/load and keep-alive variants.

Created jobs run their intentional shell command through `/bin/zsh -f -c`, with explicit system/Homebrew PATH and HOME. They have no RunAtLoad or KeepAlive trigger. Plists, metadata, and log files are created with mode 0600; per-job log directories use 0700. Names and cron expressions live under the user’s `Library/Application Support/Cadence/Jobs`, bound to the exact plist SHA256. External plist edits invalidate those saved display details, with a discovery notice and the actual configuration shown instead.

The app installs standard native editing actions for shortcuts such as Select All and Paste. The command editor disables smart quotes, dash substitutions, text replacements, and spelling corrections so shell text remains exact. Cmd+N, Select All, and straight-quote command entry were exercised through native accessibility input.

## Boundaries

This version manages user LaunchAgents in the GUI domain. Privileged system LaunchAgents and LaunchDaemons are outside its scope. It creates new definitions and log capture without rewriting existing definitions. Editing and deleting jobs through the app are outside this version. Logs are the jobs’ aggregated stdout/stderr files, not a reconstructed per-run history. Cadence does not promise exact next-run times or infer execution time from file modification time.

Cron creation supports numeric values, wildcards, lists, ranges, and steps in the five minute/hour/day/month/weekday fields. Names, macros, seconds, wrapping ranges, and advanced extensions are rejected. Calendar times use local time with launchd’s wake behavior. Partial stepped day-of-month/weekday intersections that launchd cannot represent exactly are rejected, and expanded schedules are capped at 4,096 entries.

The latest distribution tooling builds a universal Apple Silicon/Intel app and a drag-and-drop DMG. It includes macOS-only native CI, a protected manual Developer ID/notarization workflow, and the no-input **Release latest main** production workflow. The production workflow pins latest main, derives its version from the app plist, verifies uploaded draft assets before GitHub publication, and reads back published bytes. Its version tag is created only after signed artifacts pass verification. Submission names include project/version/architecture/stage and receipts retain Apple IDs and CI runs. Every app includes the checked-in copper waveform icon. The complete distribution handoff and activation requirements are in [RELEASING.md](RELEASING.md).

Local Swift tests, release failure contracts, universal compilation, mounted installer layout, drag-copy signatures, and checksums passed. The local package is ad-hoc signed and not notarized. Developer ID acceptance, Apple notarization, and execution on macOS 14 remain unqualified. Hosted CI and native Intel results are tracked in the pull request and workflow runs. Configure signing credentials and release environments before using the production pipeline; no Apple submission or public release was performed during local validation.
