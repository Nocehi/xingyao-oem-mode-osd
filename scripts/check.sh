#!/bin/sh
# Canonical, non-interactive release gate for fnx-oem-osd.
# Run from any directory with: ./scripts/check.sh
set -eu

cd "$(dirname -- "$0")/.."
repo=$(pwd -P)

fail() {
    printf 'check.sh: FAIL: %s\n' "$*" >&2
    exit 1
}

ok() {
    printf 'check.sh: ok: %s\n' "$*"
}

for required_command in zig objcopy readelf shellcheck systemd-analyze sha256sum readlink; do
    command -v "$required_command" >/dev/null 2>&1 || fail "$required_command not found"
done
zig_version=$(zig version)
[ "$zig_version" = 0.16.0 ] || fail "Zig 0.16.0 required (found $zig_version)"
ok "Zig version 0.16.0"

# Arch keeps the Qt 6 QML tools outside PATH. Prefer them explicitly so a
# separately installed Qt 5 wrapper cannot silently lint Quickshell's Qt 6 QML.
if [ -x /usr/lib/qt6/bin/qmlformat ]; then
    qmlformat_bin=/usr/lib/qt6/bin/qmlformat
else
    qmlformat_bin=$(command -v qmlformat 2>/dev/null || :)
fi
[ -n "$qmlformat_bin" ] || fail "qmlformat not found (qt6-declarative)"

if [ -x /usr/lib/qt6/bin/qmllint ]; then
    qmllint_bin=/usr/lib/qt6/bin/qmllint
else
    qmllint_bin=$(command -v qmllint 2>/dev/null || :)
fi
[ -n "$qmllint_bin" ] || fail "qmllint not found (qt6-declarative)"

# Keep Zig's global cache in a known writable location.
if [ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ]; then
    export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$TMPDIR/zig-global-cache}"
else
    export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$repo/.zig-cache/global-cache}"
fi

zig fmt --check build.zig src/main.zig test_suite.zig tests/cli_fixture.zig >/dev/null || fail "zig fmt --check"
ok "zig fmt --check (build.zig src/main.zig test_suite.zig tests/cli_fixture.zig)"

./scripts/zig-build.sh test >/dev/null || fail "zig build test"
ok "zig build test"

./scripts/zig-build.sh -Doptimize=ReleaseSafe >/dev/null || fail "zig build -Doptimize=ReleaseSafe"
ok "zig build -Doptimize=ReleaseSafe"

# ReleaseSmall runs last so zig-out contains the source-release build target.
./scripts/zig-build.sh -Doptimize=ReleaseSmall >/dev/null || fail "zig build -Doptimize=ReleaseSmall"
ok "zig build -Doptimize=ReleaseSmall"

"$qmlformat_bin" qml/shell.qml | diff -u qml/shell.qml - >/dev/null || fail "qmlformat: qml/shell.qml not canonical"
ok "qmlformat canonical (qml/shell.qml)"

# Quickshell's qmltypes marks its documented PanelWindow root uncreatable.
# Accept only status 255 paired with that exact three-line diagnostic. Status 0
# is valid only with no output; every other status/output pair fails.
./tests/qmllint-gate.sh "$qmllint_bin" >/dev/null || fail "qmllint exact-diagnostic gate"
ok "qmllint: exact PanelWindow metadata diagnostic allowed; every other diagnostic rejected"

grep -qx 'import Quickshell.Io' qml/shell.qml || fail "qml/shell.qml must import Quickshell.Io for IpcHandler"
ok "Quickshell.Io import present for IpcHandler"

for shell_file in scripts/check.sh scripts/zig-build.sh scripts/qmllint-gate.sh install/install.sh install/uninstall.sh tests/cli.sh tests/lifecycle.sh tests/live-qml-smoke.sh tests/qmllint-gate.sh; do
    sh -n "$shell_file" || fail "sh -n $shell_file"
done
ok "sh -n (all shell scripts)"

shellcheck -s sh scripts/check.sh scripts/zig-build.sh scripts/qmllint-gate.sh install/install.sh install/uninstall.sh tests/cli.sh tests/lifecycle.sh tests/live-qml-smoke.sh tests/qmllint-gate.sh || fail "ShellCheck"
ok "ShellCheck"

[ -x zig-out/bin/fnx-oem-osd-listener ] || fail "zig-out/bin/fnx-oem-osd-listener missing"
for artifact in \
    README.md LICENSE build.zig src/main.zig test_suite.zig qml/shell.qml \
    assets/performance-mode.png .github/workflows/ci.yml scripts/zig-build.sh \
    scripts/qmllint-gate.sh tests/qmllint-gate.sh tests/cli_fixture.zig \
    docs/owner-audit.md evidence/p916f-stx-calibration-v1.json \
    install/fnx-oem-osd-osd.service.in \
    install/fnx-oem-osd-listener.service.in \
    install/install.sh install/uninstall.sh tests/cli.sh tests/lifecycle.sh \
    tests/live-qml-smoke.sh; do
    [ -f "$artifact" ] || fail "missing artifact: $artifact"
done
ok "required release artifacts present"

if grep -R -n -E -- '--repo-dir|--qml-config-dir|@REPO_DIR@|@QML_CONFIG_DIR@' README.md install; then
    fail "obsolete installer argument or placeholder remains"
fi
ok "obsolete installer arguments/placeholders absent"

./tests/lifecycle.sh >/dev/null || fail "hardware-free install/update/uninstall lifecycle tests"
ok "hardware-free install/update/uninstall lifecycle tests and generated systemd units"

./tests/cli.sh >/dev/null || fail "hardware-free listener CLI tests"
ok "fixture-based listener CLI and preflight-status tests (no live sysfs or journal)"

printf 'check.sh: ALL CHECKS PASSED\n'
