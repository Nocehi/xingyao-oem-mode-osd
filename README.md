# xingyao-oem-mode-osd

Quickshell OSD for calibrated display-only OEM events on the MECHREVO Xingyao
14 P916F-STX under Linux: Fn+X performance mode, Fn+F8 keyboard backlight, and
Fn+F3 touchpad state.

This repository is deliberately not a generic Huawei/Mechrevo mode switcher.
The runtime has no hardware-override option and fails closed outside the exact
P916F-STX identity described below.

## Screenshot

![Performance mode OSD](assets/performance-mode.png)

## Supported identity

The original host exposed the following identity and event path:

- DMI `sys_vendor=MECHREVO`
- DMI `board_name=XINGYAO Series-P916F-STX`
- WMI `ABBC0F5B-8EA1-11D1-A000-C90629100000`
- WMI `ABBC0F5C-8EA1-11D1-A000-C90629100000`
- one platform input named `Huawei WMI hotkeys`

Before listening or reporting a successful support check, the listener validates
all five, dynamically resolves that input's current `inputN`, and then accepts
journal records only from that exact device. The generic DMI product name
`XINGYAO Series`, a shared GUID, a marketing name, or the same scancode from
another input device is not enough.

The original-host observation is that the WMI event side delivers the Fn+X
notifications used here, while the method side does not fully match the ABI
expected by the upstream `huawei-wmi` driver. That observation is not evidence
of compatibility with Huawei-derived or sibling ODM hardware.

## What it does

A small Zig listener opens only the local system journal through libsystemd.
It first proves that kernel records are visible to the calling user, installs
strict journal matches, seeks to the tail, and consumes only later entries. A
record must match all of these fields:

```text
_TRANSPORT=kernel
SYSLOG_IDENTIFIER=kernel
_KERNEL_SUBSYSTEM=input
_KERNEL_DEVICE=+input:<the resolved Huawei WMI inputN>
MESSAGE=input <the same inputN>: Unknown key pressed, code: <supported exact code>
```

The seven admitted scancodes become typed semantic events and are sent to a
standalone Quickshell OSD through argv-only IPC. The listener does not grab or
inject input, use an evdev fallback, call `journalctl`, invoke WMI/EC methods,
change power/radio/audio/touchpad/backlight state, or persist a guessed state.
Firmware/EC has already formed every state this listener displays. A repeated
identical event inside 250 ms is debounced; a transition to another state or
feature is never discarded as a duplicate.

The OSD stays visible for about 1.5 seconds. It can read
DankMaterialShell-generated colors and typography. Both fallback palettes are
defined, but with no valid DMS session input the standalone default is dark.
All `zh*` locales use Chinese feature/state labels; other locales use English.
IPC tokens remain stable English identifiers.

The standalone panel deliberately has no screen-edge anchors, so the supported
wlr-layer-shell path centers it independently of DankMaterialShell's own OSD.
It does not consume DMS `osdPosition`; that setting controls DMS's `DankOSD`,
not this process.

## Supported current-board mapping

| Scancode | Typed listener event | Feature/state shown in non-`zh*` locales |
|---|---|---|
| `0x0020` | `keyboard_backlight_off` | Keyboard backlight / `Backlight off` |
| `0x0021` | `keyboard_backlight_low` | Keyboard backlight / `Backlight low` |
| `0x0022` | `keyboard_backlight_high` | Keyboard backlight / `Backlight high` |
| `0x0030` | `touchpad_off` | Touchpad / `Touchpad off` |
| `0x0031` | `touchpad_on` | Touchpad / `Touchpad on` |
| `0x0041` | `mode_balanced` | Fn+X OEM / `Balanced mode` |
| `0x0042` | `mode_performance` | Fn+X OEM / `Performance mode` |

The mapping is stateless. Each admitted record selects its own display state,
including after a listener or desktop-session restart.

## Requirements

- the exact MECHREVO P916F-STX DMI/WMI/input identity above
- Linux, libsystemd, and user-visible kernel journal records
- Zig 0.16.0, binutils, and libsystemd headers/libraries to build
- Quickshell (`qs`) and Qt 6 QML tooling
- GNU coreutils (`env`, `sha256sum`, `mktemp`) and POSIX `sh` for lifecycle scripts
- ShellCheck and `systemd-analyze` for the canonical release gate

On Arch Linux the project uses `systemd`, `qt6-declarative`, `quickshell`,
`shellcheck`, `binutils`, and the normal base/coreutils toolset. There is no
third-party Zig dependency. The tested build/CI target is x86_64 Arch; other
distributions and cross builds are not claimed.

## Build and install

This audited tree identifies itself as `0.3.0-dev`; it is not a claim that a
new release was published. Build it with Zig 0.16.0:

```sh
./scripts/zig-build.sh -Doptimize=ReleaseSmall
```

The wrapper never edits native CRT files. When the Zig 0.16.0/Arch GCC 16
`.sframe` incompatibility is present, it strips that metadata only from
disposable CRT copies.

Install a coherent binary/QML snapshot and two inert systemd user units:

```sh
install/install.sh
```

By default, immutable content-addressed releases go under
`${XDG_DATA_HOME:-$HOME/.local/share}/xingyao-oem-mode-osd`, and units go under
`${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user`. Units point through an
atomically replaced `current` symlink, not back into the checkout. Moving or
deleting the clone therefore does not break an installed runtime. The lifecycle
scripts themselves are not installed: keep the clone, or reacquire the audited
source, before a later update or uninstall.

The already-built listener binary and `qml/shell.qml` input artifact are hashed
before and after copying and compared with the staged files. If another process
changes either input artifact during that snapshot, installation aborts before
publishing it. The manifest does not bind `src/main.zig`, the Zig toolchain, or
other build inputs.

Here, immutable means the installer never edits a release in place; it is not
an OS-level write lock. An owner can still change a file, and the next update or
uninstall will preserve that state by refusing its checksum mismatch. The app
manifest is also bound to one canonical unit prefix.

Explicit source and staging overrides are available:

```sh
install/install.sh \
  --listener-bin /absolute/path/fnx-oem-osd-listener \
  --qs-bin /usr/bin/qs \
  --qml-path /absolute/path/qml \
  --prefix /absolute/unit/directory \
  --app-dir /absolute/managed/application/directory
```

The installer never enables, starts, stops, restarts, or reloads a unit. It
refuses root defaults, relative destinations, foreign collisions, symlinked
managed targets, and checksum-modified managed files. Explicit `--prefix` and
`--app-dir` are permitted for disposable packaging tests, including as root.

## Live host preflight (read-only and host-dependent)

Before activation, distinguish identity from runtime readiness:

```sh
zig-out/bin/fnx-oem-osd-listener --check-support
zig-out/bin/fnx-oem-osd-listener --check-runtime
```

The first checks live DMI/WMI/input identity. The second also reads the live
system journal to check kernel visibility and strict-filter setup. These
commands are not part of the deterministic hardware-free gate. Neither one
triggers an OEM key, changes hardware state, calls IPC, or proves visible
presentation.

A passed preflight exits 0. Unsupported hardware identity exits 77; unavailable
runtime prerequisites such as no visible kernel journal exit 78; internal,
filesystem, or tool failures exit 1. CLI misuse exits 2. These results are
mutually exclusive and are never treated as an interchangeable success set.

## Activation

Review and activate the generated units:

```sh
systemctl --user daemon-reload
systemctl --user cat fnx-oem-osd-osd.service fnx-oem-osd-listener.service
systemctl --user enable --now fnx-oem-osd-listener.service
```

The listener unit `Wants=` and orders the OSD unit. Unsupported hardware exits
77, missing kernel-journal visibility exits 78, and both are protected from
restart loops. Other runtime failures retain `Restart=on-failure`.

For a direct source-tree OSD smoke without physically triggering an OEM key:

```sh
qs -p "$PWD/qml" &
qs -p "$PWD/qml" ipc call fnx-oem-osd showPerformance
qs -p "$PWD/qml" ipc call fnx-oem-osd showBalanced
qs -p "$PWD/qml" ipc call fnx-oem-osd showKeyboardLow
qs -p "$PWD/qml" ipc call fnx-oem-osd showTouchpadOff
```

The production listener uses zero-argument wrappers for every supported state:
`showPerformance`, `showBalanced`, `showKeyboardOff`, `showKeyboardLow`,
`showKeyboardHigh`, `showTouchpadOff`, and `showTouchpadOn`. The existing two
mode wrappers remain compatible. This path was chosen for noctalia-qs 0.0.12,
whose `ipc call` command rejects positional function arguments. An accepted IPC
response is not proof that a compositor visibly presented the surface.

For a disposable session-dependent round-trip of all seven production wrappers
plus the manual unknown-state compatibility fallback, run:

```sh
./tests/live-qml-smoke.sh
```

It invokes each state against the temporary Quickshell process it creates and
terminates only that process. It is not part of headless CI, and its success
still needs a human or captured visual observation before making a presentation
claim. Error-severity Quickshell entries fail the smoke; warnings remain visible
to the operator without being classified by words such as `Failed` inside the
warning message.

## Update and rollback surface

Build the new listener and rerun `install/install.sh`. Listener, QML, and both
rendered units are hashed into one immutable release; `current` changes only
after that release is complete. Older releases are retained for provenance and
manual rollback analysis. The installer does not activate the update:

```sh
systemctl --user daemon-reload
systemctl --user restart fnx-oem-osd-osd.service fnx-oem-osd-listener.service
```

A running process continues its prior mapped release until restarted. Do not
run installer and uninstaller concurrently. If a process is interrupted
between the two unit-file renames, rerun the installer; hashes from both the
previous and new immutable releases are accepted as repairable managed state.
The uninstaller also recognizes that legitimate split state.

Legacy v0.2.0 units pointed directly into the source checkout and have no new
ownership manifest. This installer intentionally refuses to overwrite them.
Stop/disable them, preserve any local edits, remove only those two legacy unit
files, then run the audited installer. Before migration, checkout QML edits may
be hot-reloaded by a running Quickshell process, while a rebuilt listener is
picked up only on the next service restart; this is why an apparently inert
source edit can otherwise create a mixed live state.

## Canonical hardware-free gate

```sh
./scripts/check.sh
```

It runs Zig formatting and unit tests, ReleaseSafe/ReleaseSmall builds, and
warning-gated QML lint. The fail-closed validator accepts only status 0 with no
diagnostic, or status 255 with the exact documented Quickshell `PanelWindow`
metadata diagnostic; every other status/output pair fails. It also runs
ShellCheck, fixture-based listener CLI/exit-status tests that use a disposable
synthetic sysfs root and no live journal, calibration-JSON/code-binding tests, lifecycle failure injection,
special-character path quoting, exact manifest and prefix ownership checks,
checksum/foreign-file refusal, split-update repair/removal, idempotent
install/uninstall, and `systemd-analyze --user verify`.

GitHub Actions executes the same command in a rolling Arch container with the
official Zig 0.16.0 x86_64 tarball pinned by SHA256. The Arch container and
repository action tags are not a fully reproducible dependency snapshot.

## Calibration evidence and claim ceiling

On 2026-08-11, the original author recorded an AC-online A -> B -> A run while
holding Linux `platform_profile`, EPP, and the CPU governor at `performance`:

| Kernel event (Asia/Hong_Kong) | STAPM / FAST PPT / SLOW PPT | Result |
|---|---:|---|
| `21:46:27.386`, `0x0041` | `15 / 30 / 25 W` | balanced |
| `21:48:46.138`, `0x0042` | `28 / 45 / 35 W` | performance |
| `21:56:04.159`, `0x0041` | `15 / 30 / 25 W` | balanced |

The machine-readable copy is
[`evidence/p916f-stx-calibration-v1.json`](evidence/p916f-stx-calibration-v1.json).
It is explicitly classified as an author-transcribed summary: this repository
does not ship the raw verbose journal export, RyzenAdj outputs, command
transcript, or their hashes. Tests prevent the summary, support constants, and
production mapping from silently diverging; they do not independently verify
the physical measurements.

The original author also reported a physical v0.2.0 smoke in which `0x0042`
mapped to `performance`, Quickshell returned `FNX_OSD_SHOW_OK`, and the overlay
was visually confirmed. That report is not simulated by CI.

On 2026-08-13, a paced source-tree smoke invoked all seven production wrappers
plus the manual unknown-state fallback. Every call returned
`FNX_OSD_SHOW_OK`; the operator visually confirmed the correct text and icon for
all eight states and confirmed that pointer input passed through the overlay.
This is an operator-transcribed author-host presentation report, not an
automated visual assertion or proof for another compositor or output layout.

### Additional display-only current-board evidence

On 2026-08-12 (Asia/Hong_Kong), the original operator observed these events on
the same dynamically resolved Huawei WMI input and the same strict kernel
journal source admitted by the listener:

- Fn+F8 emitted `0x0021 -> 0x0022 -> 0x0020`; the operator also physically
  observed the keyboard backlight switching under Linux. Static current-board
  AML and exact OEM OSD analysis bind these states to low, high, and off.
- Fn+F3 emitted `0x0030 -> 0x0031`. Static current-board AML `TPST` semantics
  and exact OEM OSD analysis bind them to touchpad off and on.

On 2026-08-13, a separate live Fn+F3 A -> B -> A observation closed the
touch-event effect gap on this P916F-STX. At `00:28:51.638394`, the strict
Huawei WMI journal source emitted `0x0030`; the touchpad event node remained
present and openable, but a fresh non-grabbing `libinput debug-events` observer
received no pointer or gesture events during deliberate finger movement, and
the cursor did not move. At `00:32:28.635244`, the next press emitted exactly
one `0x0031`; a fresh observer then received `GESTURE_HOLD_BEGIN` and hundreds
of `POINTER_MOTION` events over about 4.2 seconds, and cursor motion returned.
This establishes suppression and restoration before libinput-visible event
generation while the device node remains present. It does not identify the
exact EC, firmware, or device-internal mechanism.

These are operator/observer-transcribed observations; this repository does not
ship the raw journal or libinput transcripts or hashes for them. The
implementation is display-only and does not cause either state transition.
Fn+F7 microphone (`0x00a1`), Fn+F9 airplane mode (`0x00a0`), and combined-SKU
donor codes `0x0040`, `0x0050`, `0x0051`, and `0x00a2` remain deliberately
unadmitted.

See [`docs/owner-audit.md`](docs/owner-audit.md) for the complete assumption,
failure-mode, evidence-class, and future revalidation ledger.

## Limitations and revalidation boundary

Revalidate after a BIOS/firmware, board, kernel driver, journal record shape,
Quickshell IPC, or relevant power-stack change. Linux `platform_profile`, EPP,
PPD names, shared WMI GUIDs, or a successful static gate do not substitute for
OEM-mode calibration.

The release gate does not simulate an OEM key, keyboard/touchpad hardware
effects, the SMU, RyzenAdj readback, live journal rotation, IPC timeout
behavior, session-environment propagation, multi-output placement, or physical
OSD presentation. The current listener also waits synchronously for each `qs
ipc` child and has no child timeout.

Do not add another model, DMI alias, input name, scancode, or mapping without
the revalidation packet specified in the owner audit.

## Uninstall

Stop and disable live units before removing files:

```sh
systemctl --user disable --now fnx-oem-osd-listener.service fnx-oem-osd-osd.service
install/uninstall.sh
systemctl --user daemon-reload
```

The uninstaller never calls `systemctl`. It verifies ownership markers, the
current symlink, the exact shape of every retained release manifest, artifact
hashes and executability, unit hashes, prefix binding, and tree shape before
removal. Modified or unexpected state is preserved with a nonzero refusal. An
already absent installation is a successful idempotent no-op.

Those markers and hashes prevent accidental lifecycle damage; they are not
cryptographic signatures against a malicious process running as the same user.
Removal is not a multi-file transaction. If it is interrupted during recursive
app removal and the remaining tree no longer validates, inspect it before any
manual cleanup rather than forcing the script past its refusal.

## License

MIT License. See [LICENSE](LICENSE).

Copyright (c) 2026 Nocehi
