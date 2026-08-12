#!/bin/sh
# Remove only files and immutable releases owned by install/install.sh.
# This script never disables, stops, reloads, or otherwise changes live
# systemd state. Stop/disable the units before running it.
set -eu

program=uninstall.sh
unit_marker='# xingyao-oem-mode-osd managed user unit v1'
app_marker='xingyao-oem-mode-osd managed application directory v1'
release_marker='xingyao-oem-mode-osd immutable release v1'

usage() {
    cat <<'EOF'
Usage: install/uninstall.sh [options]

  --prefix DIR  systemd user unit directory
  --app-dir DIR managed application data directory
  -h, --help    show this help

Defaults:
  prefix:  ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
  app-dir: ${XDG_DATA_HOME:-$HOME/.local/share}/xingyao-oem-mode-osd

Stop and disable both user units before running this file-only uninstaller.
Unowned, modified, or structurally unexpected files are refused, not removed.
EOF
}

die() {
    printf '%s: %s\n' "$program" "$*" >&2
    exit 1
}

require_value() {
    [ "$#" -ge 2 ] || die "$1 requires a value"
    [ -n "$2" ] || die "$1 requires a non-empty value"
}

sha256_file() {
    hash_line=$(sha256sum < "$1") || return 1
    hash=${hash_line%% *}
    case "$hash" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#hash}" -eq 64 ] || return 1
    printf '%s\n' "$hash"
}

manifest_value() {
    key=$1
    manifest=$2
    value=$(sed -n "s/^${key}=//p" "$manifest")
    case "$value" in
        ''|*'
'*) return 1 ;;
    esac
    printf '%s\n' "$value"
}

is_managed_unit() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    IFS= read -r first_line < "$1" || return 1
    [ "$first_line" = "$unit_marker" ]
}

only_expected_entries() {
    directory=$1
    shift
    for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
        if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
            continue
        fi
        entry_name=$(basename -- "$entry")
        expected=false
        for allowed_name in "$@"; do
            if [ "$entry_name" = "$allowed_name" ]; then
                expected=true
                break
            fi
        done
        [ "$expected" = true ] || return 1
    done
}

validate_release() {
    release_dir=$1
    [ -d "$release_dir" ] && [ ! -L "$release_dir" ] || return 1
    only_expected_entries "$release_dir" bin qml manifest || return 1
    [ -d "$release_dir/bin" ] && [ ! -L "$release_dir/bin" ] || return 1
    [ -d "$release_dir/qml" ] && [ ! -L "$release_dir/qml" ] || return 1
    only_expected_entries "$release_dir/bin" fnx-oem-osd-listener || return 1
    only_expected_entries "$release_dir/qml" shell.qml || return 1
    [ -f "$release_dir/manifest" ] && [ ! -L "$release_dir/manifest" ] || return 1
    [ -f "$release_dir/bin/fnx-oem-osd-listener" ] && [ ! -L "$release_dir/bin/fnx-oem-osd-listener" ] && [ -x "$release_dir/bin/fnx-oem-osd-listener" ] || return 1
    [ -f "$release_dir/qml/shell.qml" ] && [ ! -L "$release_dir/qml/shell.qml" ] && [ -r "$release_dir/qml/shell.qml" ] || return 1
    IFS= read -r first_line < "$release_dir/manifest" || return 1
    [ "$first_line" = "$release_marker" ] || return 1
    expected_listener=$(manifest_value listener_sha256 "$release_dir/manifest") || return 1
    expected_qml=$(manifest_value qml_sha256 "$release_dir/manifest") || return 1
    expected_osd_unit=$(manifest_value osd_unit_sha256 "$release_dir/manifest") || return 1
    expected_listener_unit=$(manifest_value listener_unit_sha256 "$release_dir/manifest") || return 1
    case "$expected_listener$expected_qml$expected_osd_unit$expected_listener_unit" in *[!0-9a-f]*) return 1 ;; esac
    [ "${#expected_listener}" -eq 64 ] && [ "${#expected_qml}" -eq 64 ] || return 1
    [ "${#expected_osd_unit}" -eq 64 ] && [ "${#expected_listener_unit}" -eq 64 ] || return 1
    printf '%s\nlistener_sha256=%s\nqml_sha256=%s\nosd_unit_sha256=%s\nlistener_unit_sha256=%s\n' \
        "$release_marker" "$expected_listener" "$expected_qml" \
        "$expected_osd_unit" "$expected_listener_unit" | \
        cmp -s - "$release_dir/manifest" || return 1
    [ "$(sha256_file "$release_dir/bin/fnx-oem-osd-listener")" = "$expected_listener" ] || return 1
    [ "$(sha256_file "$release_dir/qml/shell.qml")" = "$expected_qml" ] || return 1
    computed_line=$(printf '%s\n%s\n%s\n%s\n' \
        "$expected_listener" "$expected_qml" "$expected_osd_unit" "$expected_listener_unit" | sha256sum)
    computed_id=${computed_line%% *}
    [ "$(basename -- "$release_dir")" = "$computed_id" ] || return 1
}

validate_managed_app() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    only_expected_entries "$1" .managed current releases || return 1
    [ -f "$1/.managed" ] && [ ! -L "$1/.managed" ] || return 1
    printf '%s\nunit_prefix=%s\n' "$app_marker" "$prefix" | \
        cmp -s - "$1/.managed" || return 1
    [ -d "$1/releases" ] && [ ! -L "$1/releases" ] || return 1
    [ -L "$1/current" ] || return 1
    current_target=$(readlink "$1/current") || return 1
    case "$current_target" in releases/*) ;; *) return 1 ;; esac
    current_id=${current_target#releases/}
    case "$current_id" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#current_id}" -eq 64 ] || return 1
    [ -d "$1/releases/$current_id" ] || return 1

    found_release=false
    for release_dir in "$1"/releases/* "$1"/releases/.[!.]* "$1"/releases/..?*; do
        if [ ! -e "$release_dir" ] && [ ! -L "$release_dir" ]; then
            continue
        fi
        release_id=$(basename -- "$release_dir")
        case "$release_id" in ''|*[!0-9a-f]*) return 1 ;; esac
        [ "${#release_id}" -eq 64 ] || return 1
        validate_release "$release_dir" || return 1
        found_release=true
    done
    [ "$found_release" = true ]
}

unit_hash_is_managed() {
    managed_app=$1
    key=$2
    actual=$3
    for manifest in "$managed_app"/releases/*/manifest; do
        [ -f "$manifest" ] && [ ! -L "$manifest" ] || continue
        expected=$(manifest_value "$key" "$manifest") || continue
        if [ "$actual" = "$expected" ]; then
            return 0
        fi
    done
    return 1
}

prefix=
app_dir=
prefix_explicit=false
app_dir_explicit=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            require_value "$@"
            prefix=$2
            prefix_explicit=true
            shift 2
            ;;
        --app-dir)
            require_value "$@"
            app_dir=$2
            app_dir_explicit=true
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf '%s: unknown option: %s\n' "$program" "$1" >&2
            exit 2
            ;;
    esac
done

if [ "$prefix_explicit" = false ] || [ "$app_dir_explicit" = false ]; then
    [ "$(id -u)" -ne 0 ] || die "refusing root defaults; do not use sudo (or pass both --prefix and --app-dir for staging)"
    [ -n "${HOME:-}" ] || die "HOME is unset; pass both --prefix and --app-dir"
fi
if [ "$prefix_explicit" = false ]; then
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
        case "$XDG_CONFIG_HOME" in /*) ;; *) die "XDG_CONFIG_HOME must be absolute" ;; esac
        prefix="$XDG_CONFIG_HOME/systemd/user"
    else
        prefix="$HOME/.config/systemd/user"
    fi
fi
if [ "$app_dir_explicit" = false ]; then
    if [ -n "${XDG_DATA_HOME:-}" ]; then
        case "$XDG_DATA_HOME" in /*) ;; *) die "XDG_DATA_HOME must be absolute" ;; esac
        app_dir="$XDG_DATA_HOME/xingyao-oem-mode-osd"
    else
        app_dir="$HOME/.local/share/xingyao-oem-mode-osd"
    fi
fi

for required_command in cmp sed sha256sum readlink; do
    command -v "$required_command" >/dev/null 2>&1 || die "$required_command not found"
done
case "$prefix" in /*) ;; *) die "--prefix must be an absolute path: $prefix" ;; esac
case "$app_dir" in /*) ;; *) die "--app-dir must be an absolute path: $app_dir" ;; esac
[ "$prefix" != / ] && [ "$app_dir" != / ] || die "refusing / as a removal target"

newline='
'
case "$prefix$app_dir" in *"$newline"*) die "newlines are not supported in uninstall paths" ;; esac

# Match the physical destinations recorded by install.sh while retaining the
# final app-directory component so a symlink substituted for the managed app
# itself is still rejected by validate_managed_app.
if [ -e "$prefix" ] || [ -L "$prefix" ]; then
    [ -d "$prefix" ] || die "unit prefix is not a directory: $prefix"
    prefix=$(CDPATH='' cd -- "$prefix" && pwd -P) || die "cannot resolve unit prefix: $prefix"
else
    prefix_base=$(basename -- "$prefix")
    prefix_parent=$(dirname -- "$prefix")
    if [ -d "$prefix_parent" ]; then
        prefix_parent=$(CDPATH='' cd -- "$prefix_parent" && pwd -P) || die "cannot resolve unit-prefix parent: $prefix_parent"
        prefix="$prefix_parent/$prefix_base"
    fi
fi
app_base=$(basename -- "$app_dir")
[ "$app_base" != . ] && [ "$app_base" != .. ] && [ "$app_base" != / ] || die "unsafe --app-dir: $app_dir"
app_parent=$(dirname -- "$app_dir")
if [ -d "$app_parent" ]; then
    app_parent=$(CDPATH='' cd -- "$app_parent" && pwd -P) || die "cannot resolve app-dir parent: $app_parent"
    app_dir="$app_parent/$app_base"
fi
[ "$prefix" != / ] && [ "$app_dir" != / ] || die "refusing / as a removal target"

found=0
app_present=false
if [ -e "$app_dir" ] || [ -L "$app_dir" ]; then
    validate_managed_app "$app_dir" || die "refusing to remove modified or structurally unexpected application directory: $app_dir"
    app_present=true
    found=1
fi
for unit in fnx-oem-osd-osd.service fnx-oem-osd-listener.service; do
    target="$prefix/$unit"
    if [ -e "$target" ] || [ -L "$target" ]; then
        is_managed_unit "$target" || die "refusing to remove unowned unit: $target"
        [ "$app_present" = true ] || die "refusing to remove unit without its ownership manifest: $target"
        case "$unit" in
            fnx-oem-osd-osd.service) hash_key=osd_unit_sha256 ;;
            fnx-oem-osd-listener.service) hash_key=listener_unit_sha256 ;;
        esac
        actual_unit=$(sha256_file "$target") || die "cannot hash unit: $target"
        unit_hash_is_managed "$app_dir" "$hash_key" "$actual_unit" || die "refusing to remove modified unit: $target"
        found=1
    fi
done

if [ "$found" -eq 0 ]; then
    printf '%s: no managed files found (already uninstalled)\n' "$program"
    exit 0
fi

for unit in fnx-oem-osd-osd.service fnx-oem-osd-listener.service; do
    target="$prefix/$unit"
    if [ -e "$target" ]; then
        rm -- "$target"
        printf 'removed %s\n' "$target"
    fi
done
if [ -d "$app_dir" ]; then
    rm -rf -- "$app_dir"
    printf 'removed managed application directory %s\n' "$app_dir"
fi

cat <<'EOF'

Managed files were removed. This script did not stop a live process or reload
the user manager. If the units were disabled/stopped first as required, finish
with:

  systemctl --user daemon-reload

EOF
