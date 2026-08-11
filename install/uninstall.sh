#!/bin/sh
# Remove only the two unit files copied by install/install.sh. This script
# never disables, stops, reloads, or otherwise changes live systemd state.
set -eu

usage() {
    cat <<'EOF'
Usage: install/uninstall.sh [--prefix DIR]

  --prefix DIR  user unit directory
  -h, --help    show this help
EOF
}

prefix="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || {
                printf 'uninstall.sh: --prefix requires a value\n' >&2
                exit 1
            }
            prefix=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'uninstall.sh: unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

removed=0
for unit in fnx-oem-osd-osd.service fnx-oem-osd-listener.service; do
    if [ -f "$prefix/$unit" ]; then
        rm -- "$prefix/$unit"
        printf 'removed %s\n' "$prefix/$unit"
        removed=1
    fi
done

if [ "$removed" -eq 0 ]; then
    printf 'uninstall.sh: no fnx-oem-osd units found under %s (nothing to do)\n' "$prefix" >&2
    exit 1
fi

cat <<'EOF'

Unit files removed. Manual follow-up (not performed automatically):

  systemctl --user disable --now fnx-oem-osd-listener.service fnx-oem-osd-osd.service
  systemctl --user daemon-reload

EOF
