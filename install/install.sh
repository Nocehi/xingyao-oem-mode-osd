#!/bin/sh
# Conservative user installer for xingyao-oem-mode-osd.
#
# Copies an immutable listener/QML release into an owned XDG data directory and
# renders two systemd user units that point through an atomically replaced
# `current` symlink. It never enables, starts, stops, or reloads a unit.
set -eu

program=install.sh
unit_marker='# xingyao-oem-mode-osd managed user unit v1'
app_marker='xingyao-oem-mode-osd managed application directory v1'
release_marker='xingyao-oem-mode-osd immutable release v1'

usage() {
    cat <<'EOF'
Usage: install/install.sh [options]

Options:
  --qs-bin PATH        qs executable used by both units
  --listener-bin PATH built listener executable (input artifact)
  --qml-path PATH      Quickshell configuration directory (input artifact)
  --prefix DIR         systemd user unit directory
  --app-dir DIR        managed application data directory
  -h, --help           show this help

Defaults:
  listener: <repo>/zig-out/bin/fnx-oem-osd-listener
  QML:      <repo>/qml
  prefix:   ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
  app-dir:  ${XDG_DATA_HOME:-$HOME/.local/share}/xingyao-oem-mode-osd

The installer copies a coherent release and writes unit files only. It does
not change live systemd state. Existing files not marked as managed by this
project are never overwritten.
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

sed_replacement() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
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

is_managed_app_dir() {
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
    current_release="$1/releases/$current_id"
    [ -d "$current_release" ] || return 1

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
        IFS= read -r first_line < "$manifest" || continue
        [ "$first_line" = "$release_marker" ] || continue
        expected=$(manifest_value "$key" "$manifest") || continue
        if [ "$actual" = "$expected" ]; then
            return 0
        fi
    done
    return 1
}

absolute_dir_parent() {
    requested=$1
    label=$2
    case "$requested" in
        /*) ;;
        *) die "$label must be an absolute path: $requested" ;;
    esac
    [ "$requested" != / ] || die "$label must not be /"
    base=$(basename -- "$requested")
    [ "$base" != . ] && [ "$base" != .. ] && [ "$base" != / ] || die "unsafe $label: $requested"
    parent=$(dirname -- "$requested")
    mkdir -p "$parent"
    parent=$(CDPATH='' cd -- "$parent" && pwd -P) || die "cannot resolve $label parent: $parent"
    printf '%s/%s\n' "$parent" "$base"
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
repo_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
qs_bin=$(command -v qs 2>/dev/null || :)
env_bin=$(command -v env 2>/dev/null || :)
listener_bin="$repo_dir/zig-out/bin/fnx-oem-osd-listener"
qml_path="$repo_dir/qml"
prefix=
app_dir=
prefix_explicit=false
app_dir_explicit=false

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

for required_command in cmp sed sha256sum mktemp readlink env; do
    command -v "$required_command" >/dev/null 2>&1 || die "$required_command not found"
done

[ -n "$qs_bin" ] || die "qs executable not found; pass --qs-bin PATH"
[ -n "$env_bin" ] && [ -x "$env_bin" ] || die "env executable not found"
case "$qs_bin" in
    */*) ;;
    *) qs_bin=$(command -v "$qs_bin" 2>/dev/null || :) ;;
esac
[ -n "$qs_bin" ] && [ -x "$qs_bin" ] || die "qs executable not found or not executable: $qs_bin"
[ -x "$listener_bin" ] || {
    printf '%s: listener binary not found or not executable: %s\n' "$program" "$listener_bin" >&2
    printf 'build it first with: ./scripts/zig-build.sh -Doptimize=ReleaseSmall\n' >&2
    exit 1
}
[ -f "$qml_path/shell.qml" ] && [ ! -L "$qml_path/shell.qml" ] || die "Quickshell config directory has no regular shell.qml: $qml_path"

qs_dir=$(CDPATH='' cd -- "$(dirname -- "$qs_bin")" && pwd -P) || die "cannot resolve qs path: $qs_bin"
qs_bin="$qs_dir/$(basename -- "$qs_bin")"
env_dir=$(CDPATH='' cd -- "$(dirname -- "$env_bin")" && pwd -P) || die "cannot resolve env path: $env_bin"
env_bin="$env_dir/$(basename -- "$env_bin")"
listener_dir=$(CDPATH='' cd -- "$(dirname -- "$listener_bin")" && pwd -P) || die "cannot resolve listener path: $listener_bin"
listener_bin="$listener_dir/$(basename -- "$listener_bin")"
qml_path=$(CDPATH='' cd -- "$qml_path" && pwd -P) || die "cannot resolve QML path: $qml_path"

newline='
'
case "$qs_bin$listener_bin$qml_path$prefix$app_dir" in
    *"$newline"*) die "newlines are not supported in install paths" ;;
esac

case "$prefix" in /*) ;; *) die "--prefix must be an absolute path: $prefix" ;; esac
[ "$prefix" != / ] || die "--prefix must not be /"
mkdir -p "$prefix"
prefix=$(CDPATH='' cd -- "$prefix" && pwd -P) || die "cannot resolve prefix: $prefix"
app_dir=$(absolute_dir_parent "$app_dir" "--app-dir")
app_parent=$(dirname -- "$app_dir")

existing_app=false
if [ -e "$app_dir" ] || [ -L "$app_dir" ]; then
    is_managed_app_dir "$app_dir" || die "refusing to use unowned application directory: $app_dir"
    existing_app=true
fi
for unit in fnx-oem-osd-osd.service fnx-oem-osd-listener.service; do
    target="$prefix/$unit"
    if [ -e "$target" ] || [ -L "$target" ]; then
        is_managed_unit "$target" || die "refusing to overwrite unowned unit: $target"
        [ "$existing_app" = true ] || die "managed unit has no owned application directory: $target"
        case "$unit" in
            fnx-oem-osd-osd.service) hash_key=osd_unit_sha256 ;;
            fnx-oem-osd-listener.service) hash_key=listener_unit_sha256 ;;
        esac
        actual_unit=$(sha256_file "$target") || die "cannot hash existing unit: $target"
        unit_hash_is_managed "$app_dir" "$hash_key" "$actual_unit" || die "refusing to overwrite modified unit: $target"
    fi
    [ -f "$repo_dir/install/$unit.in" ] || die "unit template missing: $repo_dir/install/$unit.in"
done

listener_input_hash=$(sha256_file "$listener_bin") || die "cannot hash listener: $listener_bin"
qml_input_hash=$(sha256_file "$qml_path/shell.qml") || die "cannot hash QML: $qml_path/shell.qml"

stage_root=$(mktemp -d "$app_parent/.xingyao-oem-mode-osd.stage.XXXXXX")
unit_stage=$(mktemp -d "$prefix/.xingyao-oem-mode-osd.units.XXXXXX")
tmp_link=
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "${tmp_link:-}" ]; then rm -f -- "$tmp_link"; fi
    if [ -n "${tmp_unit:-}" ]; then rm -f -- "$tmp_unit"; fi
    if [ -n "${stage_root:-}" ]; then rm -rf -- "$stage_root"; fi
    if [ -n "${unit_stage:-}" ]; then rm -rf -- "$unit_stage"; fi
    exit "$status"
}
trap cleanup EXIT HUP INT TERM
tmp_unit=

stage_release="$stage_root/release"
mkdir -p "$stage_release/bin" "$stage_release/qml"
cp -- "$listener_bin" "$stage_release/bin/fnx-oem-osd-listener"
cp -- "$qml_path/shell.qml" "$stage_release/qml/shell.qml"
chmod 0755 "$stage_release/bin/fnx-oem-osd-listener"
chmod 0644 "$stage_release/qml/shell.qml"
listener_hash=$(sha256_file "$stage_release/bin/fnx-oem-osd-listener") || die "cannot hash staged listener"
qml_hash=$(sha256_file "$stage_release/qml/shell.qml") || die "cannot hash staged QML"
listener_input_hash_after=$(sha256_file "$listener_bin") || die "cannot rehash listener: $listener_bin"
qml_input_hash_after=$(sha256_file "$qml_path/shell.qml") || die "cannot rehash QML: $qml_path/shell.qml"
[ "$listener_input_hash" = "$listener_hash" ] && [ "$listener_input_hash_after" = "$listener_hash" ] || \
    die "listener binary input changed while the release snapshot was copied"
[ "$qml_input_hash" = "$qml_hash" ] && [ "$qml_input_hash_after" = "$qml_hash" ] || \
    die "QML input artifact changed while the release snapshot was copied"

installed_listener="$app_dir/current/bin/fnx-oem-osd-listener"
installed_qml="$app_dir/current/qml"
env_unit=$(systemd_quote "$env_bin")
qs_unit=$(systemd_quote "$qs_bin")
listener_unit=$(systemd_quote "$installed_listener")
qml_unit=$(systemd_quote "$installed_qml")
env_sed=$(sed_replacement "$env_unit")
qs_sed=$(sed_replacement "$qs_unit")
listener_sed=$(sed_replacement "$listener_unit")
qml_sed=$(sed_replacement "$qml_unit")

for unit in fnx-oem-osd-osd.service fnx-oem-osd-listener.service; do
    sed -e "s|@ENV_BIN@|$env_sed|g" \
        -e "s|@QS_BIN@|$qs_sed|g" \
        -e "s|@QML_PATH@|$qml_sed|g" \
        -e "s|@LISTENER_BIN@|$listener_sed|g" \
        "$repo_dir/install/$unit.in" > "$unit_stage/$unit"
    chmod 0644 "$unit_stage/$unit"
    if grep -E '@[A-Z][A-Z0-9_]*@' "$unit_stage/$unit" >/dev/null; then
        die "generated unit contains an unresolved placeholder: $unit"
    fi
done

osd_unit_hash=$(sha256_file "$unit_stage/fnx-oem-osd-osd.service") || die "cannot hash generated OSD unit"
listener_unit_hash=$(sha256_file "$unit_stage/fnx-oem-osd-listener.service") || die "cannot hash generated listener unit"
release_line=$(printf '%s\n%s\n%s\n%s\n' \
    "$listener_hash" "$qml_hash" "$osd_unit_hash" "$listener_unit_hash" | sha256sum)
release_id=${release_line%% *}
case "$release_id" in ''|*[!0-9a-f]*) die "cannot derive release id" ;; esac
[ "${#release_id}" -eq 64 ] || die "invalid derived release id"
cat > "$stage_release/manifest" <<EOF
$release_marker
listener_sha256=$listener_hash
qml_sha256=$qml_hash
osd_unit_sha256=$osd_unit_hash
listener_unit_sha256=$listener_unit_hash
EOF
chmod 0644 "$stage_release/manifest"

if [ ! -e "$app_dir" ]; then
    stage_app="$stage_root/app"
    mkdir -p "$stage_app/releases"
    mv -- "$stage_release" "$stage_app/releases/$release_id"
    printf '%s\nunit_prefix=%s\n' "$app_marker" "$prefix" > "$stage_app/.managed"
    ln -s "releases/$release_id" "$stage_app/current"
    mv -T -- "$stage_app" "$app_dir"
else
    mkdir -p "$app_dir/releases"
    final_release="$app_dir/releases/$release_id"
    if [ -e "$final_release" ] || [ -L "$final_release" ]; then
        [ -f "$final_release/manifest" ] || die "release id collision at $final_release"
        [ "$(sha256_file "$final_release/bin/fnx-oem-osd-listener")" = "$listener_hash" ] || die "release id collision for listener"
        [ "$(sha256_file "$final_release/qml/shell.qml")" = "$qml_hash" ] || die "release id collision for QML"
    else
        mv -T -- "$stage_release" "$final_release"
    fi
    tmp_link="$app_dir/.current.tmp.$$"
    [ ! -e "$tmp_link" ] && [ ! -L "$tmp_link" ] || die "temporary current link already exists: $tmp_link"
    ln -s "releases/$release_id" "$tmp_link"
    mv -Tf -- "$tmp_link" "$app_dir/current"
    tmp_link=
fi

for unit in fnx-oem-osd-osd.service fnx-oem-osd-listener.service; do
    tmp_unit=$(mktemp "$prefix/.$unit.new.XXXXXX")
    cp -- "$unit_stage/$unit" "$tmp_unit"
    chmod 0644 "$tmp_unit"
    mv -Tf -- "$tmp_unit" "$prefix/$unit"
    tmp_unit=
    printf 'installed %s\n' "$prefix/$unit"
done

printf 'installed immutable release %s under %s\n' "$release_id" "$app_dir"
printf 'current -> releases/%s\n' "$release_id"

cat <<EOF

Files are installed but units are NOT reloaded, enabled, started, or restarted.

First activation:
  systemctl --user daemon-reload
  systemctl --user cat fnx-oem-osd-osd.service fnx-oem-osd-listener.service
  systemctl --user enable --now fnx-oem-osd-listener.service

After a later install/update:
  systemctl --user daemon-reload
  systemctl --user restart fnx-oem-osd-osd.service fnx-oem-osd-listener.service

Before uninstalling:
  systemctl --user disable --now fnx-oem-osd-listener.service fnx-oem-osd-osd.service
  "$script_dir/uninstall.sh" --prefix "$prefix" --app-dir "$app_dir"
  systemctl --user daemon-reload

The runtime remains fail-closed to the calibrated P916F-STX identity:
  0x0041 -> balanced
  0x0042 -> performance
EOF
