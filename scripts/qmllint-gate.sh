#!/bin/sh
# Fail-closed qmllint gate with one exact Quickshell metadata exception.
set -eu

cd "$(dirname -- "$0")/.."

validate_log() {
    log_file=$1
    lint_status=$2
    case "$lint_status" in ''|*[!0-9]*) return 1 ;; esac

    # A warning-free qmllint run is always acceptable. Any diagnostic paired
    # with success is unexpected and therefore rejected.
    if [ "$lint_status" -eq 0 ]; then
        [ ! -s "$log_file" ]
        return
    fi

    # Qt 6.11.1 reports the known warning with 255. The exception is the
    # exact status/output pair; ordinary tool or execution failures must not
    # become successful merely because their output resembles the warning.
    [ "$lint_status" -eq 255 ] || return 1

    [ "$(wc -l < "$log_file")" -eq 3 ] || return 1
    first_line=$(sed -n '1p' "$log_file")
    second_line=$(sed -n '2p' "$log_file")
    third_line=$(sed -n '3p' "$log_file")

    allowed_prefix='Warning: qml/shell.qml:'
    allowed_suffix=':1: Type PanelWindow is not creatable. [uncreatable-type]'
    case "$first_line" in
        "$allowed_prefix"*"$allowed_suffix") ;;
        *) return 1 ;;
    esac
    location=${first_line#"$allowed_prefix"}
    line_number=${location%"$allowed_suffix"}
    case "$line_number" in ''|*[!0-9]*) return 1 ;; esac

    [ "$second_line" = 'PanelWindow {' ] || return 1
    [ "$third_line" = '^^^^^^^^^^^' ] || return 1
}

if [ "${1:-}" = --validate-log ]; then
    [ "$#" -eq 3 ] || exit 2
    validate_log "$2" "$3"
    exit
fi

[ "$#" -eq 1 ] || {
    printf 'usage: %s QMLLINT_BIN\n' "$0" >&2
    exit 2
}
qmllint_bin=$1
[ -x "$qmllint_bin" ] || {
    printf 'qmllint-gate.sh: not executable: %s\n' "$qmllint_bin" >&2
    exit 1
}

gate_root=$(mktemp -d "${TMPDIR:-/tmp}/fnx-qmllint-gate.XXXXXX")
trap 'rm -rf -- "$gate_root"' EXIT HUP INT TERM
lint_log="$gate_root/qmllint.log"

set +e
if [ -d /usr/lib/qt6/qml/Quickshell ]; then
    "$qmllint_bin" -W 0 -I /usr/lib/qt6/qml qml/shell.qml > "$lint_log" 2>&1
else
    "$qmllint_bin" -W 0 qml/shell.qml > "$lint_log" 2>&1
fi
lint_status=$?
set -e

if validate_log "$lint_log" "$lint_status"; then
    exit 0
fi

printf 'qmllint-gate.sh: rejected qmllint status/output (status=%s)\n' "$lint_status" >&2
sed -n '1,160p' "$lint_log" >&2
exit 1
