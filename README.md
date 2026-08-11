# xingyao-oem-mode-osd

Quickshell OSD for the Fn+X OEM performance/balanced modes on the Mechrevo Xingyao 14 (P916F-STX) under Linux.

## Screenshot

![Performance mode OSD](assets/performance-mode.png)

## Hardware notes

On the P916F-STX, ACPI exposes the ABBC0F5B / ABBC0F5C HWMI GUID pair recognised by Linux huawei-wmi. The event side works well enough to deliver the Fn+X notifications used by this project; the method side, however, does not fully match the ABI expected by the upstream driver. Whether that says anything about Huawei-derived hardware or firmware, I have no idea.

This project is tested and calibrated on P916F-STX only.

## What it does

A small Zig listener tails new systemd journal entries through the native
sd-journal API. It admits only the exact kernel/input record shape observed for
the P916F-STX Fn+X ACPI WMI notification, maps the two calibrated scancodes to
semantic `performance` or `balanced` values, and calls a standalone Quickshell
OSD through argv-only IPC.

The listener does not grab or inject input, poll files, call `journalctl`,
change power limits, or keep toggle state. The upstream `huawei_wmi` input path
logs these unknown scancodes without emitting an evdev event, so the journal is
the available event surface on this machine.

The OSD stays visible for about 1.5 seconds. It optionally follows
DankMaterialShell's generated matugen palette and typography, with complete
standalone light/dark fallbacks. All `zh*` locales display `性能模式`, `均衡模式`,
and the manual compatibility fallback `OEM 模式已切換`; other locales display
`Performance mode`, `Balanced mode`, and `OEM mode switched`. Runtime IPC
values remain the stable English semantic tokens.

## Calibrated mapping

| Scancode | Listener value | OSD label in non-`zh*` locales |
|---|---|---|
| `0x0041` | `balanced` | `Balanced mode` |
| `0x0042` | `performance` | `Performance mode` |

The mapping is stateless. Each admitted record selects its own mode, including
after a listener or desktop-session restart.

## Requirements

- Mechrevo Xingyao 14 P916F-STX with the currently observed ACPI WMI event path
- Linux with systemd journal access and the `huawei_wmi` driver path
- Zig 0.16.0, binutils, and libsystemd headers/libraries to build the listener
- Quickshell (`qs`) and Qt 6 QML tooling
- ShellCheck and `systemd-analyze` to run the canonical release gate

On Arch Linux, the relevant packages are available as `systemd`,
`qt6-declarative`, `quickshell`, and `shellcheck`. The project has no
third-party Zig dependency.

## Build / install

The v0.2.0 release is source-only. Build locally with Zig 0.16.0:

```sh
./scripts/zig-build.sh -Doptimize=ReleaseSmall
```

The wrapper leaves system files untouched. On current Arch toolchains, it works
around the official Zig 0.16.0 binary's inability to parse `.sframe` metadata
in GCC 16 CRT start files by stripping that metadata from temporary copies.
The resulting listener is `zig-out/bin/fnx-oem-osd-listener`. The conservative
installer renders two systemd user units but does not enable, start, stop, or
reload anything:

```sh
install/install.sh
```

It derives the repository root from its own location, including clone paths
that require shell/systemd quoting. Explicit overrides remain available:

```sh
install/install.sh \
  --listener-bin /absolute/path/fnx-oem-osd-listener \
  --qs-bin /usr/bin/qs \
  --qml-path /absolute/path/qml
```

The one canonical local and CI gate is:

```sh
./scripts/check.sh
```

It runs Zig formatting, unit tests, ReleaseSafe/ReleaseSmall builds, QML
format/lint checks, ShellCheck, an installer temporary-prefix smoke, generated
unit placeholder/obsolete-argument checks, and
`systemd-analyze --user verify`. GitHub Actions runs this same command in an
Arch Linux container with the official Zig 0.16.0 x86_64 tarball pinned by
SHA256; it does not install a fallback Zig package.

## Runtime / systemd

Review the generated units, then activate them manually:

```sh
systemctl --user daemon-reload
systemctl --user cat fnx-oem-osd-osd.service fnx-oem-osd-listener.service
systemctl --user enable --now fnx-oem-osd-osd.service fnx-oem-osd-listener.service
```

For a direct OSD smoke without Fn+X:

```sh
qs -p "$PWD/qml" &
qs -p "$PWD/qml" ipc call fnx-oem-osd showPerformance
qs -p "$PWD/qml" ipc call fnx-oem-osd showBalanced
```

The production listener uses only the zero-argument `showPerformance` and
`showBalanced` wrappers. They retain compatibility with noctalia-qs 0.0.12,
whose `ipc call` command rejects positional function arguments.

## Calibration evidence

On 2026-08-11, an AC-online A -> B -> A run held Linux
`platform_profile`, EPP, and the CPU governor at `performance`. Each
operator-confirmed Fn+X press was correlated with the complete kernel record
and an immediate read-only `/usr/local/bin/ryzenadj -i` snapshot:

| Kernel event (Asia/Hong_Kong) | STAPM / FAST PPT / SLOW PPT | Result |
|---|---:|---|
| `21:46:27.386`, `0x0041` | `15 / 30 / 25 W` | balanced |
| `21:48:46.138`, `0x0042` | `28 / 45 / 35 W` | performance |
| `21:56:04.159`, `0x0041` | `15 / 30 / 25 W` | balanced |

The admitted records had `_TRANSPORT=kernel`,
`SYSLOG_IDENTIFIER=kernel`, `_KERNEL_SUBSYSTEM=input`, a dynamic
`_KERNEL_DEVICE=+input:inputN`, and a matching
`MESSAGE=input inputN: Unknown key pressed, code: 0x0041|0x0042`. The
listener validates the dynamic `inputN` agreement instead of hard-coding its
current number.

A later physical v0.2.0 smoke captured `0x0042`, the listener reported
`performance`, Quickshell returned `FNX_OSD_SHOW_OK`, and the operator visually
confirmed the performance overlay. The temporary smoke processes were stopped
afterward; the observations are calibration evidence, not simulated tests in
the release gate.

## Limitations / revalidation boundary

Support is promised only for the tested and calibrated P916F-STX. The same
ABBC GUID pair by itself is not compatibility evidence. Another Mechrevo,
Huawei, or ODM model must first provide its WMI GUIDs, observed scancodes, and
real calibration evidence before any mapping is added.

Revalidate after a BIOS/firmware, hardware, kernel driver, journal record
shape, or relevant power-stack change. Linux `platform_profile`, EPP, or PPD
names do not substitute for OEM-mode calibration.

`./scripts/check.sh` is a static/build/install-template gate. It does not
simulate Fn+X, the SMU, RyzenAdj readback, the physical OSD, or the
`huawei_wmi` hardware path. A successful IPC return also does not by itself
prove that a Wayland compositor visibly presented the overlay.

## Uninstall

Disable the live units manually, remove the two generated files, and reload
the user manager:

```sh
systemctl --user disable --now fnx-oem-osd-listener.service fnx-oem-osd-osd.service
install/uninstall.sh
systemctl --user daemon-reload
```

The uninstaller removes only those two unit files. It does not change live
systemd state itself.

## License

MIT License. See [LICENSE](LICENSE).

Copyright (c) 2026 Nocehi
