#!/bin/sh
# Session-dependent, hardware-free Quickshell IPC smoke.
# This invokes every supported OSD state plus the compatibility fallback in a
# temporary Quickshell process. It validates IPC/handler liveness, not visible
# presentation, and is intentionally outside scripts/check.sh and headless CI.
set -eu

cd "$(dirname -- "$0")/.."
command -v qs >/dev/null 2>&1 || {
    printf 'live-qml-smoke.sh: qs not found\n' >&2
    exit 1
}
[ -f qml/shell.qml ] || {
    printf 'live-qml-smoke.sh: qml/shell.qml missing\n' >&2
    exit 1
}

smoke_root=$(mktemp -d "${TMPDIR:-/tmp}/fnx-qml-live.XXXXXX")
smoke_pid=
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "${smoke_pid:-}" ] && kill -0 "$smoke_pid" 2>/dev/null; then
        kill "$smoke_pid" 2>/dev/null || :
        wait "$smoke_pid" 2>/dev/null || :
    fi
    rm -rf -- "$smoke_root"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$smoke_root/qml"
cp qml/shell.qml "$smoke_root/qml/shell.qml"
qs -p "$smoke_root/qml" --no-color > "$smoke_root/qs.log" 2>&1 &
smoke_pid=$!

ready=false
attempt=0
while [ "$attempt" -lt 30 ]; do
    if qs -p "$smoke_root/qml" ipc show > "$smoke_root/ipc-show.log" 2>&1; then
        ready=true
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ "$ready" != true ]; then
    sed -n '1,200p' "$smoke_root/qs.log" >&2
    printf 'live-qml-smoke.sh: IPC handler did not become ready\n' >&2
    exit 1
fi

for function_name in \
    showPerformance showBalanced \
    showKeyboardOff showKeyboardLow showKeyboardHigh \
    showTouchpadOff showTouchpadOn \
    showUnknown; do
    output_file="$smoke_root/$function_name.log"
    qs -p "$smoke_root/qml" ipc call fnx-oem-osd "$function_name" > "$output_file"
    grep -F 'FNX_OSD_SHOW_OK' "$output_file" >/dev/null || {
        sed -n '1,120p' "$output_file" >&2
        printf 'live-qml-smoke.sh: %s did not return success\n' "$function_name" >&2
        exit 1
    }
    printf '%s: ' "$function_name"
    sed -n '1p' "$output_file"
done

kill -0 "$smoke_pid" 2>/dev/null || {
    sed -n '1,200p' "$smoke_root/qs.log" >&2
    printf 'live-qml-smoke.sh: Quickshell exited during IPC smoke\n' >&2
    exit 1
}
kill "$smoke_pid"
wait "$smoke_pid" 2>/dev/null || :
smoke_pid=

fatal_log="$smoke_root/fatal.log"
if grep -E '^[[:space:]]*(ERROR|CRITICAL|FATAL)([[:space:]:]|$)' \
    "$smoke_root/qs.log" > "$fatal_log"; then
    sed -n '1,200p' "$smoke_root/qs.log" >&2
    printf 'live-qml-smoke.sh: Quickshell logged an error-severity entry\n' >&2
    exit 1
fi

# Preserve warnings for the operator without treating message text such as
# "Failed to register with host portal" as an error-severity entry.
warning_log="$smoke_root/warnings.log"
if grep -E '^[[:space:]]*WARN([[:space:]:]|$)' \
    "$smoke_root/qs.log" > "$warning_log"; then
    printf 'live-qml-smoke.sh: non-fatal Quickshell warning(s):\n' >&2
    sed -n '1,120p' "$warning_log" >&2
fi

printf 'live-qml-smoke.sh: IPC round-trip passed; visible presentation still requires observation\n'
