#!/bin/sh
# Session-dependent, hardware-free Quickshell IPC smoke.
# This briefly displays three OSD states in the current Wayland session. It is
# intentionally not part of scripts/check.sh or headless CI.
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

for function_name in showPerformance showBalanced showUnknown; do
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

if grep -E -i 'error|failed|fatal' "$smoke_root/qs.log" >/dev/null; then
    sed -n '1,200p' "$smoke_root/qs.log" >&2
    printf 'live-qml-smoke.sh: Quickshell logged an error\n' >&2
    exit 1
fi

printf 'live-qml-smoke.sh: IPC round-trip passed; visible presentation still requires observation\n'
