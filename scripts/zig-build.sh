#!/bin/sh
# Build with Zig 0.16.0 while preserving compatibility with current Arch CRTs.
set -eu

command -v zig >/dev/null 2>&1 || {
    printf 'zig-build.sh: zig not found\n' >&2
    exit 1
}

native_config=$(mktemp "${TMPDIR:-/tmp}/fnx-oem-osd-libc.XXXXXX")
work_dir=

cleanup() {
    rm -f -- "$native_config"
    if [ -n "$work_dir" ]; then
        case "$work_dir" in
            "${TMPDIR:-/tmp}"/fnx-oem-osd-crt.*)
                rm -rf -- "$work_dir"
                ;;
        esac
    fi
}
trap cleanup EXIT HUP INT TERM

zig libc > "$native_config"
native_crt_dir=$(sed -n 's/^crt_dir=//p' "$native_config")
has_sframe=false
if [ -n "$native_crt_dir" ] && [ -f "$native_crt_dir/crt1.o" ]; then
    command -v readelf >/dev/null 2>&1 || {
        printf 'zig-build.sh: readelf is required to inspect the native CRT\n' >&2
        exit 1
    }
    if readelf -S --wide "$native_crt_dir/crt1.o" | grep -q '[.]sframe'; then
        has_sframe=true
    fi
fi

# The official Zig 0.16.0 Linux binary cannot parse R_X86_64_PC64
# relocations in the .sframe metadata emitted by current Arch GCC 16 CRT
# objects. Packaged Zig builds may already handle them. When needed, strip
# only that metadata from disposable start-file copies; never modify /usr/lib.
if [ "$has_sframe" = true ]; then
    for command_name in awk objcopy; do
        command -v "$command_name" >/dev/null 2>&1 || {
            printf 'zig-build.sh: %s is required for current Arch CRT compatibility\n' \
                "$command_name" >&2
            exit 1
        }
    done

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/fnx-oem-osd-crt.XXXXXX")
    libc_config="$work_dir/libc.txt"

    for crt_name in crt1.o Scrt1.o rcrt1.o crti.o crtn.o; do
        if [ -f "$native_crt_dir/$crt_name" ]; then
            cp "$native_crt_dir/$crt_name" "$work_dir/$crt_name"
            objcopy --remove-section=.sframe --remove-section=.rela.sframe \
                "$work_dir/$crt_name"
        fi
    done

    for libc_name in \
        libc.so libc.a libm.so libm.a libpthread.so libpthread.a \
        libdl.so libdl.a librt.so librt.a libutil.so libutil.a; do
        if [ -e "$native_crt_dir/$libc_name" ]; then
            ln -s "$native_crt_dir/$libc_name" "$work_dir/$libc_name"
        fi
    done

    awk -v crt_dir="$work_dir" '
        /^crt_dir=/ { print "crt_dir=" crt_dir; next }
        { print }
    ' "$native_config" > "$libc_config"
    zig libc "$libc_config" >/dev/null
    zig build --libc "$libc_config" "$@"
else
    zig build "$@"
fi
