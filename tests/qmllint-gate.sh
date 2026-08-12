#!/bin/sh
# Hardware-free regression for the exact PanelWindow qmllint exception.
set -eu

cd "$(dirname -- "$0")/.."

fail() {
    printf 'qmllint-gate.sh: FAIL: %s\n' "$*" >&2
    exit 1
}

if grep -F -- '--uncreatable-type disable' scripts/check.sh scripts/qmllint-gate.sh >/dev/null; then
    fail "category-wide uncreatable-type suppression remains"
fi

if [ "$#" -gt 1 ]; then
    fail "usage: tests/qmllint-gate.sh [QMLLINT_BIN]"
elif [ "$#" -eq 1 ]; then
    qmllint_bin=$1
elif [ -x /usr/lib/qt6/bin/qmllint ]; then
    qmllint_bin=/usr/lib/qt6/bin/qmllint
else
    qmllint_bin=$(command -v qmllint 2>/dev/null || :)
fi
[ -n "$qmllint_bin" ] || fail "qmllint not found"
[ -x "$qmllint_bin" ] || fail "qmllint is not executable: $qmllint_bin"
./scripts/qmllint-gate.sh "$qmllint_bin" || fail "real qml/shell.qml gate"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/fnx-qmllint-regression.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM
known_log="$test_root/known.log"
extra_log="$test_root/extra.log"
empty_log="$test_root/empty.log"
truncated_log="$test_root/truncated.log"
malformed_log="$test_root/malformed.log"

# Run the real tool against a disposable qml/shell.qml containing the allowed
# PanelWindow diagnostic plus a second warning from the same category. The
# gate must reject the combined output.
actual_root="$test_root/actual"
mkdir -p "$actual_root/scripts" "$actual_root/qml"
cp scripts/qmllint-gate.sh "$actual_root/scripts/qmllint-gate.sh"
printf '%s\n' \
    'import Quickshell' \
    '' \
    'PanelWindow {' \
    '    DesktopAction {}' \
    '}' > "$actual_root/qml/shell.qml"
if "$actual_root/scripts/qmllint-gate.sh" "$qmllint_bin" > "$test_root/actual-extra.log" 2>&1; then
    fail "real qmllint additional same-category warning was accepted"
fi
grep -F 'Type DesktopAction is not creatable.' "$test_root/actual-extra.log" >/dev/null || fail "real same-category fixture did not trigger DesktopAction warning"

printf '%s\n%s\n%s\n' \
    'Warning: qml/shell.qml:16:1: Type PanelWindow is not creatable. [uncreatable-type]' \
    'PanelWindow {' \
    '^^^^^^^^^^^' > "$known_log"
./scripts/qmllint-gate.sh --validate-log "$known_log" 255 || fail "exact PanelWindow diagnostic was rejected"

# The allowlist is a status/output pair, not an output-only exception. A tool
# or execution failure that happens to print the same diagnostic must fail.
for unexpected_status in 1 2 126 127 42; do
    if ./scripts/qmllint-gate.sh --validate-log "$known_log" "$unexpected_status"; then
        fail "exact diagnostic was accepted with unexpected status $unexpected_status"
    fi
done

# Exercise the complete gate with a fake qmllint, not only the validator
# entrypoint, so child exit-status capture remains covered.
fake_qmllint="$test_root/fake-qmllint"
printf '%s\n' \
    '#!/bin/sh' \
    "printf '%s\\n%s\\n%s\\n' 'Warning: qml/shell.qml:16:1: Type PanelWindow is not creatable. [uncreatable-type]' 'PanelWindow {' '^^^^^^^^^^^'" \
    "exit \"\${FAKE_QMLLINT_STATUS:?}\"" > "$fake_qmllint"
chmod +x "$fake_qmllint"
FAKE_QMLLINT_STATUS=255 ./scripts/qmllint-gate.sh "$fake_qmllint" || fail "full gate rejected exact diagnostic with status 255"
for unexpected_status in 1 2 126 127 42; do
    if FAKE_QMLLINT_STATUS=$unexpected_status ./scripts/qmllint-gate.sh "$fake_qmllint" > "$test_root/fake-$unexpected_status.log" 2>&1; then
        fail "full gate accepted exact diagnostic with unexpected status $unexpected_status"
    fi
done

cp "$known_log" "$extra_log"
printf '%s\n%s\n%s\n' \
    'Warning: qml/shell.qml:99:1: Type DesktopAction is not creatable. [uncreatable-type]' \
    'DesktopAction {' \
    '^^^^^^^^^^^^^' >> "$extra_log"
if ./scripts/qmllint-gate.sh --validate-log "$extra_log" 255; then
    fail "an additional same-category warning was accepted"
fi

: > "$empty_log"
./scripts/qmllint-gate.sh --validate-log "$empty_log" 0 || fail "clean successful output was rejected"
if ./scripts/qmllint-gate.sh --validate-log "$empty_log" 1; then
    fail "unexplained nonzero qmllint status was accepted"
fi
if ./scripts/qmllint-gate.sh --validate-log "$empty_log" 255; then
    fail "empty status-255 output was accepted"
fi
if ./scripts/qmllint-gate.sh --validate-log "$known_log" 0; then
    fail "diagnostic output paired with success was accepted"
fi

sed -n '1,2p' "$known_log" > "$truncated_log"
if ./scripts/qmllint-gate.sh --validate-log "$truncated_log" 255; then
    fail "truncated status-255 diagnostic was accepted"
fi
cp "$known_log" "$malformed_log"
sed -i '1s/qml\/shell.qml:16/qml\/shell.qml:not-a-line/' "$malformed_log"
if ./scripts/qmllint-gate.sh --validate-log "$malformed_log" 255; then
    fail "malformed status-255 diagnostic was accepted"
fi

printf 'qmllint-gate.sh: ALL TESTS PASSED\n'
