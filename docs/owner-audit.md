# Hardware-owner audit and evidence boundary

This document is the repository's claim ledger for owners who are not the
original author. It distinguishes code-enforced facts, hardware-free tests,
author-transcribed calibration, and observations that still require a real
P916F-STX session.

## Support boundary

The only supported hardware remains the calibrated MECHREVO P916F-STX. The
runtime now fails closed unless all of these current identities agree:

| Layer | Required identity |
|---|---|
| DMI | `sys_vendor=MECHREVO` |
| DMI | `board_name=XINGYAO Series-P916F-STX` |
| WMI | `ABBC0F5B-8EA1-11D1-A000-C90629100000` with a decimal instance |
| WMI | `ABBC0F5C-8EA1-11D1-A000-C90629100000` with a decimal instance |
| platform/input | exactly one `Huawei WMI hotkeys` input below `/sys/devices/platform/huawei-wmi/input` |
| journal source | that resolved input's dynamic `+input:inputN` device |

The generic DMI `product_name=XINGYAO Series`, a marketing name, either WMI
GUID by itself, a matching scancode on another input device, or another machine
from the same ODM is not compatibility evidence. There is no override flag for
the hardware gate.

`--check-support` verifies only the identity above. `--check-runtime` also
checks that this user can see kernel journal entries and that the strict
journal filters can be installed. Neither command triggers an OEM key, changes
hardware state, calls Quickshell IPC, or proves visible compositor
presentation. Both are read-only, host-dependent preflights and are excluded
from the canonical hardware-free gate.

## Evidence classes

| Claim | Repository evidence | Ceiling |
|---|---|---|
| scancode parser, source-device binding, mapping, debounce, CLI bounds | Zig unit tests | hardware-free implementation evidence |
| DMI/WMI/input support gate and preflight status decisions | production probe/decision logic plus a synthetic sysfs/runtime fixture | gate semantics, not another owner's hardware or journal state |
| install/update/uninstall behavior | `tests/lifecycle.sh` disposable roots | filesystem and unit semantics; no live user-manager mutation |
| generated unit syntax | `systemd-analyze --user verify` | parser/dependency evidence, not successful session startup |
| QML syntax and static bindings | canonical `qmlformat` plus warning-gated `qmllint`; a fail-closed validator accepts only status 0 with no output or status 255 with the exact known `PanelWindow` metadata diagnostic | no Wayland surface or visual proof |
| QML IPC round-trip | optional `tests/live-qml-smoke.sh` in a real session | handler/process proof; visible presentation still requires observation |
| P916F-STX A -> B -> A power mapping | `evidence/p916f-stx-calibration-v1.json` | author-transcribed summary; raw captures are absent |
| Fn+F8 `0x0021 -> 0x0022 -> 0x0020` and physical backlight switching | original operator's dated report in `README.md`; static AML/OEM OSD analysis is not shipped | same-board operator observation, not independently reproducible raw evidence |
| Fn+F3 `0x0030 -> 0x0031`, TPST off/on semantics, and live A -> B -> A touch effect | dated operator/observer report in `README.md`; static AML/OEM OSD analysis and raw live transcripts are not shipped | same-board live evidence establishes suppression/restoration before libinput-visible events while the device node persists; exact internal mechanism remains unresolved |
| physical overlay | dated v0.2.0 and eight-state v0.3.0-dev author-host reports in `README.md`; optional `tests/live-qml-smoke.sh` supplies the IPC/process half | operator-confirmed text/icons and pointer pass-through on the author session; not an automated visual assertion or another compositor/output proof |

The canonical gate parses the calibration JSON and binds its DMI/WMI constants,
power-mode mapping order, all three timestamp/scancode/mode/power samples,
controlled Linux state, audit context, and limitation text. This detects
documentation/code drift; it does not upgrade the transcribed values into raw
evidence. The additional Fn+F8/Fn+F3 and physical-presentation observations
remain explicitly operator-transcribed rather than being folded into that
power-calibration JSON.

## Audited assumptions

### Hardware and calibration

1. The calibrated board continues to expose the DMI and WMI identities listed
   above. A readable but mismatched, missing, or duplicated calibrated identity
   is unsupported hardware (exit 77), not guessed around. An unreadable or
   malformed filesystem/tool result is an internal error (exit 1), not
   disguised as unsupported hardware.
2. The `huawei-wmi` platform input remains named `Huawei WMI hotkeys`. Its
   `inputN` number is dynamic and resolved at every process start.
3. The five admitted journal fields retain the captured values and exact
   message spelling. A kernel/driver/journald format change is a revalidation
   trigger, not permission to weaken admission.
4. `0x0041 -> balanced` and `0x0042 -> performance` are calibrated only for the
   recorded P916F-STX path. BIOS 1.06 was read from the author host during this
   audit on 2026-08-12, one day after the transcribed run; no raw artifact proves
   it was unchanged during that run. The BIOS version is therefore context, not
   a compatibility wildcard or automatic rejection key, and any change still
   requires revalidation.
5. The power values in the JSON are a transcription of an operator-correlated
   run. The repository does not contain raw journal export, RyzenAdj output,
   command transcript, hashes, or an independent observer record.
6. On the same strict P916F-STX journal source, the operator observed Fn+F8
   `0x0021 -> 0x0022 -> 0x0020` plus physical keyboard-backlight switching, and
   Fn+F3 `0x0030 -> 0x0031`. Static current-board AML and exact OEM OSD analysis
   bind these codes to keyboard low/high/off and touchpad off/on respectively.
   Those source artifacts and raw journal exports are not shipped here.
7. On 2026-08-13, a separate live Fn+F3 A -> B -> A observation established the
   Linux touch effect. `0x0030` was followed by a successful non-grabbing open
   of the still-present touchpad event node but zero pointer/gesture events
   during deliberate finger movement and no cursor motion. The next press
   emitted exactly one `0x0031`; a fresh observer then received
   `GESTURE_HOLD_BEGIN` and hundreds of `POINTER_MOTION` events over about 4.2
   seconds while cursor motion returned. This establishes suppression and
   restoration before libinput-visible event generation, not the exact EC,
   firmware, or device-internal mechanism. The OSD performs no touchpad action.
8. The statement that Fn+X is logged without a usable evdev event is an
   original-host observation. The listener does not attempt an evdev, hwdb,
   keyd, or injection fallback for any feature.
9. An identical semantic event within 250 ms is a duplicate; a distinct state
   or feature inside that window is admitted. The 224 ms keyboard low-to-high
   regression is covered deterministically. The interval itself has not been
   independently calibrated as a universal firmware duplicate interval.
10. Airplane `0x00a0`, microphone `0x00a1`, and combined-SKU donor `0x0040`,
    `0x0050`, `0x0051`, and `0x00a2` are not admitted. The first two are
    Windows-userspace request events, not safe display-only state reports.

### Journal and listener runtime

1. The user can read at least one system/kernel journal entry. `sd_journal_open`
   silently ignores inaccessible journal files, so the listener now tests this
   explicitly and exits 78 when kernel visibility is absent.
2. Kernel events are written to the default local system journal namespace.
   Remote journals, alternate namespaces, and user-only journals are excluded.
3. Startup intentionally seeks to the tail. Supported OEM records written
   before the listener starts are not replayed, and no current state is seeded.
4. The resolved `inputN` is assumed stable for one listener process lifetime.
   A driver unbind/rebind or device re-enumeration that changes it requires a
   listener restart; the old strict journal match will not follow a new number.
5. The listener processes each admitted event synchronously. A hung `qs ipc`
   child can delay later journal processing; there is currently no IPC timeout
   or queue. Nonzero/abnormal IPC completion is logged and never reported as a
   displayed OSD.
6. Journal rotation/invalidation behavior is delegated to libsystemd's live
   journal object. There is no synthetic rotated-journal integration fixture.
7. The process is Linux/libsystemd-specific. Cross-compilation and non-systemd
   hosts are outside the tested contract.

### Quickshell and session runtime

1. `qs` is Quickshell-compatible and supports `-p PATH ipc call TARGET
   FUNCTION`. Every production event has a zero-argument wrapper; the existing
   `showPerformance` and `showBalanced` names remain compatible. This transport
   was observed with noctalia-qs 0.0.12; a CLI/IPC compatibility change requires
   revalidation.
2. The systemd user manager has the correct Wayland/session environment when
   the OSD starts. Unit syntax cannot prove `WAYLAND_DISPLAY`, compositor
   readiness, output choice, or layer-shell presentation.
3. `graphical-session.target` ordering exists and is meaningful in the owner's
   session. The units remain enabled from `default.target`; `After=` orders but
   does not create the graphical target.
4. The listener `Wants=` the OSD, but service ordering does not prove the IPC
   handler is ready before an immediate first key press. A failed call is
   logged without retry.
5. DMS palette/settings/session files are optional. Without a valid DMS session
   file the standalone fallback is dark; the included light fallback becomes
   selected only when `isLightMode` is supplied. The standalone panel has no
   screen-edge anchors and is centered by the supported layer-shell path. It
   does not consume DMS `osdPosition`, which controls DMS's separate `DankOSD`.
6. Locale and multi-output behavior are Qt/Quickshell-derived. Static checks
   cover labels and bindings, not which physical output presents the window.
7. On 2026-08-13, the original operator observed a paced source-tree smoke of
   all seven production wrappers plus `showUnknown`. Every IPC call returned
   `FNX_OSD_SHOW_OK`; all eight text/icon states were visually confirmed and
   pointer input passed through. This is author-host presentation evidence, not
   an automated visual assertion or another compositor/output proof.
8. A clean OSD process exit is not restarted by `Restart=on-failure`; a crash
   is. Unsupported hardware and missing journal permission are restart-loop
   protected by exit statuses 77 and 78.
9. `qs` and `/usr/bin/env` are checked and recorded by canonical path at install
   time but are external dependencies, not copied or content-hashed into the
   release. Replacing either executable can change runtime behavior without a
   repository update.
10. `Wants=` starts the OSD before the listener preflight. If the listener then
   exits 77 or 78, the inert OSD process can remain running until it is stopped
   or the graphical session ends; it cannot admit hardware events itself.

### Build and lifecycle

1. The release gate is tested on x86_64 Arch with Zig 0.16.0, current systemd,
   Qt 6, Quickshell, ShellCheck, GNU coreutils, binutils, and POSIX `sh`.
   Other distributions and cross targets are not claimed.
2. The Zig wrapper's `.sframe` workaround applies only to disposable copies of
   native CRT objects. It does not make arbitrary linker/CRT combinations
   supported.
3. Default XDG paths require an absolute XDG home and a non-root user. Root
   defaults are refused; explicit `--prefix` plus `--app-dir` remain available
   for disposable packaging/staging tests.
4. Installation is a copy, not a live reference to the checkout. Listener and
   QML hashes plus the two rendered-unit hashes identify one immutable release;
   `current` is changed with one symlink rename. The application manifest binds
   the managed app directory to one canonical unit prefix so a second prefix
   cannot silently orphan the first unit pair. The already-built listener
   binary and `qml/shell.qml` input artifact are hashed before and after copying
   and compared with the staged snapshot; a concurrent artifact change aborts
   instead of publishing mismatched evidence. Source files, build inputs, and
   the Zig toolchain are not provenance-bound by this manifest.
5. Updates retain older immutable releases. This provides provenance and a
   rollback surface but consumes a small, monotonically growing amount of
   storage until uninstall. No automatic prune policy is claimed.
6. Installer and uninstaller do not call `systemctl`. An update is not active
   until the user reloads and restarts; uninstalling files does not stop an
   already running process. The documented command order is mandatory.
7. Existing unmarked units/directories; symlinks substituted for managed app,
   unit, release, or artifact nodes; non-executable managed listeners; modified
   release files; non-canonical manifest contents; modified units; unexpected
   tree entries; relative paths; and `/` removal targets are refused. The
   scripts do not adopt or delete them. Destination-parent symlinks are the
   separately documented canonicalization case below.
8. A process interruption can occur between the two per-unit atomic renames.
   Both the preceding and new unit hashes remain recorded in immutable release
   manifests, so rerunning the installer can repair that split state and the
   uninstaller can validate either legitimate unit before removal. The pair is
   not a single filesystem transaction.
9. Concurrent installer/uninstaller processes are not serialized by an
   interprocess lock. Do not run lifecycle commands concurrently.
10. The v0.2.0 source-bound units have no new ownership marker or application
    manifest. The audited installer intentionally refuses to overwrite them;
    stop/disable them, preserve any local edits, remove the two legacy unit
    files, then run the new installer. Until migration, editing checkout QML
    can be hot-reloaded by the already running Quickshell process, while the
    listener keeps its old mapped executable until a restart and then opens the
    newly built checkout binary. This can create a mixed live state even
    without `systemctl`.
11. "Immutable release" means the installer never edits a release directory in
    place. It is not filesystem immutability: the owner can still modify files,
    after which update/uninstall correctly refuse the checksum mismatch.
12. Destination parent symlinks are resolved to physical paths during install.
    If an XDG parent symlink is later retargeted, pass the physical prefix and
    app directory printed by the installer to reach the original installation.
13. Markers and SHA-256 manifests protect cooperative owner state from
    accidental overwrite/removal; they are not signatures and do not
    authenticate files against a malicious process running as the same user.
14. Uninstall validates all targets before starting removal, but removal of two
    units plus the app tree is not one filesystem transaction. Interruption
    before recursive app removal is normally rerunnable; interruption during
    that removal can leave a partial tree that is deliberately refused and must
    be inspected before manual cleanup.
15. The installed runtime is independent of the checkout, but `install.sh` and
    `uninstall.sh` are not copied into the managed app tree. Deleting the clone
    does not stop the OSD; it does require reacquiring the audited source before
    the next file lifecycle operation.

## Failure-mode matrix

| Phase | Failure | Observable result | Recovery |
|---|---|---|---|
| build | wrong Zig/toolchain, missing headers/libsystemd, unsupported CRT | nonzero build; no system install | install the stated build tools or inspect the exact linker error |
| install | missing/non-executable `qs` or listener, missing QML | preflight failure before managed writes | correct the explicit source path and rerun |
| install | listener or QML changes while being copied | staged release is rejected before publication | stop the concurrent producer, rebuild, and rerun |
| install | foreign or modified target | fail-closed refusal | preserve/move the owner file or use a separate absolute prefix/app dir |
| install | interruption after release creation | complete immutable release may remain; `current` is old or new | rerun the same installer; content-addressed releases are idempotent |
| install | interruption between unit renames | one old and one new managed unit may remain | rerun installer to repair, or uninstall; both hashes are recognized |
| runtime | unsupported DMI/WMI/input identity | exit 77, no restart loop | do not bypass; inspect identity and collect new calibration before code changes |
| runtime | unreadable/malformed preflight input or internal/tool error | exit 1 | inspect the exact filesystem or tool error; do not report it as unsupported hardware |
| runtime | listener preflight exits 77/78 after pulling in OSD | listener remains stopped; idle OSD may remain active | inspect the listener result, then stop the OSD if it is not wanted |
| runtime | no kernel journal visibility | exit 78, no restart loop | fix journal access, log out/in if group/ACL changed, rerun `--check-runtime` |
| runtime | QML/Wayland/IPC unavailable | OSD unit restarts on failure or listener logs IPC failure | inspect both user-unit journals and session environment |
| runtime | IPC returns zero | accepted call only | visually verify presentation when physical proof is required |
| update | install succeeded but no restart | running processes continue the old mapped release | `daemon-reload`, then restart both units |
| update | old releases accumulate | bounded per-release disk growth | retain for evidence or uninstall; no automatic deletion is performed |
| legacy v0.2 checkout edit/build | QML may hot-reload immediately; listener changes only on its next restart | mixed old/new runtime despite no unit reload | stop legacy units before source work, or complete the documented managed-install migration |
| update/uninstall | source checkout was deleted | installed runtime continues, but lifecycle script is unavailable | reacquire this audited source revision before operating on managed files |
| uninstall | units still running | file removal would not stop them | disable/stop first, as documented |
| uninstall | checksum/tree mismatch | no removal begins | preserve and inspect the owner change; restore exact managed data if removal is intended |
| uninstall | interruption during removal | unit/app subset or partial app tree may remain | rerun if the app tree is still valid; otherwise inspect and remove only proven managed remnants manually |
| uninstall | already absent | exit 0 with `already uninstalled` | none |

## Revalidation packet for any future hardware proposal

Do not add a model, alias, DMI value, GUID, input name, scancode, or mapping
from similarity alone. A proposal needs, at minimum:

1. exact DMI vendor/board identity and BIOS/firmware version;
2. complete WMI UUIDs and the bound platform/input topology;
3. raw verbose journal records for every proposed scancode;
4. an operator-labelled state sequence with controlled relevant Linux state;
5. immediate independent state readback or physical observation appropriate to
   the proposed feature for every press;
6. a physical IPC/overlay smoke that keeps accepted IPC separate from visible
   presentation; and
7. a new evidence artifact, parser/source-gate tests, and an explicit review of
   whether the support boundary is being expanded.
