#!/bin/sh
# Deterministic hardware-free listener CLI and preflight-decision tests.
set -eu

cd "$(dirname -- "$0")/.."
listener=zig-out/bin/fnx-oem-osd-listener
./scripts/zig-build.sh cli-fixture >/dev/null
fixture=zig-out/bin/fnx-oem-osd-cli-fixture
[ -x "$listener" ] || {
    printf 'cli.sh: FAIL: built listener missing\n' >&2
    exit 1
}
[ -x "$fixture" ] || {
    printf 'cli.sh: FAIL: CLI fixture runner missing\n' >&2
    exit 1
}

test_root=$(mktemp -d "${TMPDIR:-/tmp}/fnx-oem-osd-cli.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM

"$listener" --help > "$test_root/help"
grep -F -- '--check-support' "$test_root/help" >/dev/null
grep -F -- '--check-runtime' "$test_root/help" >/dev/null
grep -F -- 'P916F-STX' "$test_root/help" >/dev/null
[ "$("$listener" --version)" = 'fnx-oem-osd-listener 0.3.0-dev' ]

expect_exit_2() {
    name=$1
    shift
    set +e
    "$listener" "$@" > "$test_root/$name.log" 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ] || {
        sed -n '1,120p' "$test_root/$name.log" >&2
        printf 'cli.sh: FAIL: %s returned %s instead of 2\n' "$name" "$status" >&2
        exit 1
    }
}

expect_exit_2 unknown-option --not-an-option
expect_exit_2 missing-qml
expect_exit_2 missing-qml-value --qml-path
expect_exit_2 empty-qml --qml-path ''
expect_exit_2 empty-qs --qml-path /tmp --qs-bin ''
expect_exit_2 negative-debounce --debounce-ms -1 --qml-path /tmp
expect_exit_2 overflowing-debounce --debounce-ms 18446744073709551615 --qml-path /tmp
expect_exit_2 conflicting-checks --check-support --check-runtime

create_support_fixture() {
    root=$1
    vendor=$2
    mkdir -p \
        "$root/sys/class/dmi/id" \
        "$root/sys/bus/wmi/devices/ABBC0F5B-8EA1-11D1-A000-C90629100000-0" \
        "$root/sys/bus/wmi/devices/ABBC0F5C-8EA1-11D1-A000-C90629100000-1" \
        "$root/sys/devices/platform/huawei-wmi/input/input42"
    printf '%s\n' "$vendor" > "$root/sys/class/dmi/id/sys_vendor"
    printf '%s\n' 'XINGYAO Series-P916F-STX' > "$root/sys/class/dmi/id/board_name"
    printf '%s\n' 'Huawei WMI hotkeys' > "$root/sys/devices/platform/huawei-wmi/input/input42/name"
}

expect_status() {
    expected=$1
    name=$2
    shift 2
    set +e
    "$@" > "$test_root/$name.log" 2>&1
    status=$?
    set -e
    [ "$status" -eq "$expected" ] || {
        sed -n '1,120p' "$test_root/$name.log" >&2
        printf 'cli.sh: FAIL: %s returned %s instead of %s\n' "$name" "$status" "$expected" >&2
        exit 1
    }
}

supported_root="$test_root/supported"
unsupported_root="$test_root/unsupported"
malformed_root="$test_root/malformed"
create_support_fixture "$supported_root" MECHREVO
create_support_fixture "$unsupported_root" OTHER
mkdir -p "$malformed_root"

expect_status 0 supported "$fixture" --check-support "$supported_root"
expect_status 77 unsupported "$fixture" --check-support "$unsupported_root"
expect_status 0 runtime-ready "$fixture" --check-runtime "$supported_root" ready
expect_status 78 runtime-refusal "$fixture" --check-runtime "$supported_root" unavailable
expect_status 1 runtime-error "$fixture" --check-runtime "$supported_root" error
expect_status 1 malformed-root "$fixture" --check-support "$malformed_root"

printf 'cli.sh: ALL TESTS PASSED\n'
