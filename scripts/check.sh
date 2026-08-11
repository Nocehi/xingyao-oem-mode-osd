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

for required_command in zig objcopy readelf shellcheck systemd-analyze; do
    command -v "$required_command" >/dev/null 2>&1 || fail "$required_command not found"
done

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

zig fmt --check build.zig src/main.zig >/dev/null || fail "zig fmt --check"
ok "zig fmt --check (build.zig src/main.zig)"

./scripts/zig-build.sh test >/dev/null || fail "zig build test"
ok "zig build test"

./scripts/zig-build.sh -Doptimize=ReleaseSafe >/dev/null || fail "zig build -Doptimize=ReleaseSafe"
ok "zig build -Doptimize=ReleaseSafe"

# ReleaseSmall runs last so zig-out contains the source-release build target.
./scripts/zig-build.sh -Doptimize=ReleaseSmall >/dev/null || fail "zig build -Doptimize=ReleaseSmall"
ok "zig build -Doptimize=ReleaseSmall"

"$qmlformat_bin" qml/shell.qml | diff -u qml/shell.qml - >/dev/null || fail "qmlformat: qml/shell.qml not canonical"
ok "qmlformat canonical (qml/shell.qml)"

if [ -d /usr/lib/qt6/qml/Quickshell ]; then
    "$qmllint_bin" -I /usr/lib/qt6/qml qml/shell.qml >/dev/null || fail "qmllint"
    ok "qmllint (import path /usr/lib/qt6/qml)"
else
    "$qmllint_bin" qml/shell.qml >/dev/null || fail "qmllint"
    ok "qmllint"
fi

grep -qx 'import Quickshell.Io' qml/shell.qml || fail "qml/shell.qml must import Quickshell.Io for IpcHandler"
ok "Quickshell.Io import present for IpcHandler"

for shell_file in scripts/check.sh scripts/zig-build.sh install/install.sh install/uninstall.sh; do
    sh -n "$shell_file" || fail "sh -n $shell_file"
done
ok "sh -n (all shell scripts)"

shellcheck -s sh scripts/check.sh scripts/zig-build.sh install/install.sh install/uninstall.sh || fail "ShellCheck"
ok "ShellCheck"

[ -x zig-out/bin/fnx-oem-osd-listener ] || fail "zig-out/bin/fnx-oem-osd-listener missing"
for artifact in \
    README.md LICENSE build.zig src/main.zig qml/shell.qml \
    assets/performance-mode.png .github/workflows/ci.yml scripts/zig-build.sh \
    install/fnx-oem-osd-osd.service.in \
    install/fnx-oem-osd-listener.service.in \
    install/install.sh install/uninstall.sh; do
    [ -f "$artifact" ] || fail "missing artifact: $artifact"
done
ok "required release artifacts present"

if grep -R -n -E -- '--repo-dir|--qml-config-dir|@REPO_DIR@|@QML_CONFIG_DIR@' README.md install; then
    fail "obsolete installer argument or placeholder remains"
fi
ok "obsolete installer arguments/placeholders absent"

# Exercise repository-root derivation and systemd quoting in a disposable
# clone-like path containing whitespace and shell/systemd-significant bytes.
smoke_parent=${TMPDIR:-/tmp}
smoke_root=$(mktemp -d "$smoke_parent/fnx-oem-osd-check.XXXXXX")
trap 'rm -rf -- "$smoke_root"' EXIT HUP INT TERM
verify_runtime="$smoke_root/runtime"
smoke_repo="$smoke_root/clone path & percent% dollar\$"
smoke_tool_dir="$smoke_repo/tool path & percent% dollar\$"
smoke_prefix="$smoke_root/unit path & percent% dollar\$"
mkdir -p "$smoke_repo/install" "$smoke_repo/qml" \
    "$smoke_repo/zig-out/bin" "$smoke_tool_dir" "$verify_runtime"
cp install/install.sh install/uninstall.sh install/*.service.in "$smoke_repo/install/"
cp qml/shell.qml "$smoke_repo/qml/"
cp zig-out/bin/fnx-oem-osd-listener "$smoke_repo/zig-out/bin/"
fake_qs="$smoke_tool_dir/qs"
printf '#!/bin/sh\nexit 0\n' > "$fake_qs"
chmod +x "$fake_qs"

"$smoke_repo/install/install.sh" \
    --qs-bin "$fake_qs" \
    --prefix "$smoke_prefix" > "$smoke_root/default-install.log"

for generated_unit in \
    "$smoke_prefix/fnx-oem-osd-osd.service" \
    "$smoke_prefix/fnx-oem-osd-listener.service"; do
    [ -f "$generated_unit" ] || fail "temporary installer smoke did not generate $(basename -- "$generated_unit")"
    if grep -E '@[A-Z][A-Z0-9_]*@|--repo-dir|--qml-config-dir' "$generated_unit" >/dev/null; then
        fail "generated unit contains a placeholder or obsolete argument: $generated_unit"
    fi
    grep -F '%%' "$generated_unit" >/dev/null || fail "generated unit did not escape percent in clone path"
    grep -F 'dollar$' "$generated_unit" >/dev/null || fail "generated unit did not preserve dollar in clone path"
    if grep -F 'dollar$$' "$generated_unit" >/dev/null; then
        fail "generated unit double-escaped dollar in clone path"
    fi
    grep -F 'ExecStart=:' "$generated_unit" >/dev/null || fail "generated unit does not disable environment expansion"
done

verify_log="$smoke_root/systemd-default.log"
if ! XDG_RUNTIME_DIR="$verify_runtime" DBUS_SESSION_BUS_ADDRESS='' \
    systemd-analyze --user verify \
    "$smoke_prefix/fnx-oem-osd-osd.service" \
    "$smoke_prefix/fnx-oem-osd-listener.service" > "$verify_log" 2>&1; then
    sed -n '1,200p' "$verify_log" >&2
    fail "systemd-analyze --user verify (derived clone paths)"
fi

override_listener_dir="$smoke_root/override listener & percent% dollar\$"
override_qml="$smoke_root/override qml & percent% dollar\$"
override_prefix="$smoke_root/override units"
mkdir -p "$override_listener_dir" "$override_qml"
override_listener="$override_listener_dir/fnx-oem-osd-listener"
cp zig-out/bin/fnx-oem-osd-listener "$override_listener"
cp qml/shell.qml "$override_qml/"

"$smoke_repo/install/install.sh" \
    --listener-bin "$override_listener" \
    --qs-bin "$fake_qs" \
    --qml-path "$override_qml" \
    --prefix "$override_prefix" > "$smoke_root/override-install.log"

override_verify_log="$smoke_root/systemd-override.log"
if ! XDG_RUNTIME_DIR="$verify_runtime" DBUS_SESSION_BUS_ADDRESS='' \
    systemd-analyze --user verify \
    "$override_prefix/fnx-oem-osd-osd.service" \
    "$override_prefix/fnx-oem-osd-listener.service" > "$override_verify_log" 2>&1; then
    sed -n '1,200p' "$override_verify_log" >&2
    fail "systemd-analyze --user verify (explicit overrides)"
fi

"$smoke_repo/install/uninstall.sh" --prefix "$override_prefix" > "$smoke_root/uninstall.log"
[ ! -e "$override_prefix/fnx-oem-osd-osd.service" ] || fail "temporary uninstall left OSD unit"
[ ! -e "$override_prefix/fnx-oem-osd-listener.service" ] || fail "temporary uninstall left listener unit"
ok "installer temporary-prefix smoke and generated systemd units"

printf 'check.sh: ALL CHECKS PASSED\n'
