#!/bin/sh
# Conservative user installer for fnx-oem-osd.
#
# Copies two rendered systemd user units. It never enables, starts, reloads,
# stops, or disables a unit. The repository root is derived from this script's
# own location, so a clone path may contain shell-significant characters.
set -eu

usage() {
    cat <<'EOF'
Usage: install/install.sh [options]

Options:
  --qs-bin PATH        qs executable used by both units
  --listener-bin PATH built listener executable
  --qml-path PATH      Quickshell configuration directory
  --prefix DIR         user unit directory
  -h, --help           show this help

Defaults are derived from the installer location and the current user:
  listener: <repo>/zig-out/bin/fnx-oem-osd-listener
  QML:      <repo>/qml
  prefix:   ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

The installer writes unit files only. It does not change live systemd state.
EOF
}

die() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

require_value() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
}

# Quote one complete systemd command-line argument. The unit templates use
# systemd's `:` executable prefix to disable environment expansion, so literal
# dollar characters need no rewriting. Percent remains a unit specifier byte
# and must be doubled.
systemd_quote() {
    printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/"/\\"/g' \
        -e 's/%/%%/g' \
        -e 's/^/"/' \
        -e 's/$/"/'
}

# Escape a value that will be used as a sed replacement with | as delimiter.
sed_replacement() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
qs_bin=$(command -v qs 2>/dev/null || :)
listener_bin="$repo_dir/zig-out/bin/fnx-oem-osd-listener"
qml_path="$repo_dir/qml"
prefix="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --qs-bin)
            require_value "$@"
            qs_bin=$2
            shift 2
            ;;
        --listener-bin)
            require_value "$@"
            listener_bin=$2
            shift 2
            ;;
        --qml-path)
            require_value "$@"
            qml_path=$2
            shift 2
            ;;
        --prefix)
            require_value "$@"
            prefix=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'install.sh: unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

[ -n "$qs_bin" ] || die "qs executable not found; pass --qs-bin PATH"
case "$qs_bin" in
    */*) ;;
    *) qs_bin=$(command -v "$qs_bin" 2>/dev/null || :) ;;
esac
[ -n "$qs_bin" ] && [ -x "$qs_bin" ] || die "qs executable not found or not executable: $qs_bin"
[ -x "$listener_bin" ] || {
    printf 'install.sh: listener binary not found or not executable: %s\n' "$listener_bin" >&2
    printf 'build it first with: zig build -Doptimize=ReleaseSmall\n' >&2
    exit 1
}
[ -f "$qml_path/shell.qml" ] || die "Quickshell config directory has no shell.qml: $qml_path"

# Resolve existing executable/config paths to absolute physical directories.
qs_dir=$(CDPATH='' cd -- "$(dirname -- "$qs_bin")" && pwd -P) || die "cannot resolve qs path: $qs_bin"
qs_bin="$qs_dir/$(basename -- "$qs_bin")"
listener_dir=$(CDPATH='' cd -- "$(dirname -- "$listener_bin")" && pwd -P) || die "cannot resolve listener path: $listener_bin"
listener_bin="$listener_dir/$(basename -- "$listener_bin")"
qml_path=$(CDPATH='' cd -- "$qml_path" && pwd -P) || die "cannot resolve QML path: $qml_path"

newline='
'
case "$qs_bin$listener_bin$qml_path" in
    *"$newline"*) die "newlines are not supported in unit command paths" ;;
esac

qs_unit=$(systemd_quote "$qs_bin")
listener_unit=$(systemd_quote "$listener_bin")
qml_unit=$(systemd_quote "$qml_path")
qs_sed=$(sed_replacement "$qs_unit")
listener_sed=$(sed_replacement "$listener_unit")
qml_sed=$(sed_replacement "$qml_unit")

mkdir -p "$prefix"

tmp_unit=
trap 'if [ -n "${tmp_unit:-}" ]; then rm -f -- "$tmp_unit"; fi' EXIT HUP INT TERM
for unit in fnx-oem-osd-osd.service fnx-oem-osd-listener.service; do
    tmp_unit="$prefix/.$unit.tmp.$$"
    sed -e "s|@QS_BIN@|$qs_sed|g" \
        -e "s|@QML_PATH@|$qml_sed|g" \
        -e "s|@LISTENER_BIN@|$listener_sed|g" \
        "$repo_dir/install/$unit.in" > "$tmp_unit"
    chmod 0644 "$tmp_unit"
    mv -f -- "$tmp_unit" "$prefix/$unit"
    tmp_unit=
    printf 'installed %s\n' "$prefix/$unit"
done
trap - EXIT HUP INT TERM

cat <<EOF

fnx-oem-osd units are installed but NOT enabled or started (by design).
Verify them and activate manually, e.g.:

  systemctl --user daemon-reload
  systemctl --user cat fnx-oem-osd-osd.service fnx-oem-osd-listener.service
  systemctl --user enable --now fnx-oem-osd-osd.service fnx-oem-osd-listener.service

To stop and roll back:

  systemctl --user disable --now fnx-oem-osd-listener.service fnx-oem-osd-osd.service
  "$script_dir/uninstall.sh"
  systemctl --user daemon-reload

The listener maps each admitted scancode directly:
  0x0041 -> balanced
  0x0042 -> performance
No current-mode seed is configured or persisted.
EOF
