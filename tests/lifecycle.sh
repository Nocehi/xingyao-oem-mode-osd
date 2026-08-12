#!/bin/sh
# Hardware-free install/update/uninstall and generated-unit contract tests.
set -eu

cd "$(dirname -- "$0")/.."

fail() {
    printf 'lifecycle.sh: FAIL: %s\n' "$*" >&2
    exit 1
}

for required in cmp cp find grep mktemp readlink sha256sum systemd-analyze; do
    command -v "$required" >/dev/null 2>&1 || fail "$required not found"
done
[ -x zig-out/bin/fnx-oem-osd-listener ] || fail "built listener missing"
real_cp=$(command -v cp)

test_root=$(mktemp -d "${TMPDIR:-/tmp}/fnx-oem-osd-lifecycle.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM

repo_leaf=$(printf 'clone path & percent%% dollar\044 quote\042 backslash\134')
dollar_sign=$(printf '\044')
smoke_repo="$test_root/$repo_leaf"
tool_dir="$smoke_repo/tool path & percent% dollar$dollar_sign"
unit_dir="$test_root/unit path & percent% dollar$dollar_sign"
app_dir="$test_root/app path & percent% dollar$dollar_sign"
verify_runtime="$test_root/runtime"
mkdir -p "$smoke_repo/install" "$smoke_repo/qml" "$smoke_repo/zig-out/bin" \
    "$tool_dir" "$verify_runtime"
cp install/install.sh install/uninstall.sh install/*.service.in "$smoke_repo/install/"
cp qml/shell.qml "$smoke_repo/qml/"
cp zig-out/bin/fnx-oem-osd-listener "$smoke_repo/zig-out/bin/"
fake_qs="$tool_dir/qs"
printf '#!/bin/sh\nexit 0\n' > "$fake_qs"
chmod +x "$fake_qs"
systemctl_called="$test_root/systemctl-called"
fake_systemctl="$tool_dir/systemctl"
printf '#!/bin/sh\n: > "%sSYSTEMCTL_CALLED"\nexit 99\n' "$dollar_sign" > "$fake_systemctl"
chmod +x "$fake_systemctl"
export SYSTEMCTL_CALLED="$systemctl_called"
PATH="$tool_dir:$PATH"
export PATH

"$smoke_repo/install/install.sh" \
    --qs-bin "$fake_qs" \
    --prefix "$unit_dir" \
    --app-dir "$app_dir" > "$test_root/initial-install.log"

for unit in fnx-oem-osd-osd.service fnx-oem-osd-listener.service; do
    generated="$unit_dir/$unit"
    [ -f "$generated" ] || fail "initial install omitted $unit"
    first_line=$(sed -n '1p' "$generated")
    [ "$first_line" = '# xingyao-oem-mode-osd managed user unit v1' ] || fail "$unit has no ownership marker"
    if grep -E '@[A-Z][A-Z0-9_]*@|--repo-dir|--qml-config-dir' "$generated" >/dev/null; then
        fail "$unit contains an unresolved or obsolete token"
    fi
    grep -F '%%' "$generated" >/dev/null || fail "$unit did not escape percent"
    grep -F 'dollar$' "$generated" >/dev/null || fail "$unit did not preserve dollar"
    grep -F 'ExecStart=:' "$generated" >/dev/null || fail "$unit does not disable systemd environment expansion"
done

current_target=$(readlink "$app_dir/current") || fail "current release link missing"
case "$current_target" in releases/*) ;; *) fail "current link is not release-relative: $current_target" ;; esac
current_release="$app_dir/$current_target"
cmp "$smoke_repo/zig-out/bin/fnx-oem-osd-listener" "$current_release/bin/fnx-oem-osd-listener" || fail "listener copy differs"
cmp "$smoke_repo/qml/shell.qml" "$current_release/qml/shell.qml" || fail "QML copy differs"
escaped_app_dir=$(printf '%s' "$app_dir" | sed 's/%/%%/g')
grep -F "$escaped_app_dir/current/bin/fnx-oem-osd-listener" "$unit_dir/fnx-oem-osd-listener.service" >/dev/null || fail "listener unit is not release-backed"
grep -F "$escaped_app_dir/current/qml" "$unit_dir/fnx-oem-osd-osd.service" >/dev/null || fail "OSD unit is not release-backed"

verify_log="$test_root/systemd-verify.log"
if ! XDG_RUNTIME_DIR="$verify_runtime" DBUS_SESSION_BUS_ADDRESS='' \
    systemd-analyze --user --generators=no --man=no verify \
    "$unit_dir/fnx-oem-osd-osd.service" \
    "$unit_dir/fnx-oem-osd-listener.service" > "$verify_log" 2>&1; then
    sed -n '1,200p' "$verify_log" >&2
    fail "systemd-analyze --user verify"
fi

# Reinstalling identical inputs is idempotent: it selects the same immutable
# release and does not manufacture another release directory.
"$smoke_repo/install/install.sh" \
    --qs-bin "$fake_qs" --prefix "$unit_dir" --app-dir "$app_dir" \
    > "$test_root/reinstall.log"
reinstall_target=$(readlink "$app_dir/current")
[ "$reinstall_target" = "$current_target" ] || fail "idempotent reinstall changed release"
release_count=$(find "$app_dir/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$release_count" -eq 1 ] || fail "idempotent reinstall created $release_count releases"
cp "$unit_dir/fnx-oem-osd-listener.service" "$test_root/listener-unit.initial"

# One managed app directory is bound to one canonical unit prefix. Reusing it
# with a second prefix must neither orphan the first units nor let an
# uninstaller aimed at the wrong prefix remove the app payload.
alternate_unit_dir="$test_root/alternate unit prefix"
mkdir -p "$alternate_unit_dir"
if "$smoke_repo/install/install.sh" --qs-bin "$fake_qs" --prefix "$alternate_unit_dir" --app-dir "$app_dir" > "$test_root/prefix-rebind-install.log" 2>&1; then
    fail "installer rebound a managed app directory to another unit prefix"
fi
if "$smoke_repo/install/uninstall.sh" --prefix "$alternate_unit_dir" --app-dir "$app_dir" > "$test_root/prefix-rebind-uninstall.log" 2>&1; then
    fail "uninstaller accepted a unit prefix different from the app manifest"
fi
[ -d "$app_dir" ] && [ -f "$unit_dir/fnx-oem-osd-osd.service" ] || fail "prefix-binding refusal changed managed state"
[ ! -e "$alternate_unit_dir/fnx-oem-osd-osd.service" ] || fail "prefix-binding refusal wrote an alternate unit"

# A changed binary and QML are installed as one new release. The prior release
# remains intact for evidence/rollback, and current changes as one symlink move.
update_source="$test_root/update source"
mkdir -p "$update_source/qml"
cp "$smoke_repo/zig-out/bin/fnx-oem-osd-listener" "$update_source/listener"
printf 'post-ELF-test-marker' >> "$update_source/listener"
chmod +x "$update_source/listener"
cp "$smoke_repo/qml/shell.qml" "$update_source/qml/shell.qml"
printf '\n// lifecycle update fixture\n' >> "$update_source/qml/shell.qml"
fake_qs_updated="$tool_dir/qs updated"
cp "$fake_qs" "$fake_qs_updated"
chmod +x "$fake_qs_updated"
"$smoke_repo/install/install.sh" \
    --listener-bin "$update_source/listener" \
    --qml-path "$update_source/qml" \
    --qs-bin "$fake_qs_updated" \
    --prefix "$unit_dir" \
    --app-dir "$app_dir" > "$test_root/update.log"
updated_target=$(readlink "$app_dir/current")
[ "$updated_target" != "$current_target" ] || fail "changed inputs did not select a new release"
release_count=$(find "$app_dir/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$release_count" -eq 2 ] || fail "update did not retain exactly two releases"
cmp "$update_source/listener" "$app_dir/current/bin/fnx-oem-osd-listener" || fail "updated listener is incoherent"
cmp "$update_source/qml/shell.qml" "$app_dir/current/qml/shell.qml" || fail "updated QML is incoherent"

# Simulate interruption between the two unit renames by restoring one previous
# managed unit while current points at the new release. A rerun recognizes the
# prior manifest hash and repairs the split state.
cp "$unit_dir/fnx-oem-osd-listener.service" "$test_root/listener-unit.updated"
if cmp -s "$test_root/listener-unit.initial" "$test_root/listener-unit.updated"; then
    fail "update fixture did not produce a distinct rendered listener unit"
fi
cp "$test_root/listener-unit.initial" "$unit_dir/fnx-oem-osd-listener.service"
"$smoke_repo/install/install.sh" \
    --listener-bin "$update_source/listener" \
    --qml-path "$update_source/qml" \
    --qs-bin "$fake_qs_updated" \
    --prefix "$unit_dir" \
    --app-dir "$app_dir" > "$test_root/split-repair.log"
cmp "$test_root/listener-unit.updated" "$unit_dir/fnx-oem-osd-listener.service" || fail "rerun did not repair split unit state"

# Modified manifests, installed artifacts, permissions, and units are evidence
# of owner state. Installer and uninstaller refuse them before changing
# anything.
cp "$app_dir/.managed" "$test_root/app-manifest.before-tamper"
printf 'unexpected_app_metadata=true\n' >> "$app_dir/.managed"
if "$smoke_repo/install/install.sh" --listener-bin "$update_source/listener" --qml-path "$update_source/qml" --qs-bin "$fake_qs_updated" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/tampered-app-manifest-install.log" 2>&1; then
    fail "installer accepted extra application-manifest content"
fi
if "$smoke_repo/install/uninstall.sh" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/tampered-app-manifest-uninstall.log" 2>&1; then
    fail "uninstaller accepted extra application-manifest content"
fi
cp "$test_root/app-manifest.before-tamper" "$app_dir/.managed"

cp "$app_dir/current/manifest" "$test_root/release-manifest.before-tamper"
printf 'unexpected_release_metadata=true\n' >> "$app_dir/current/manifest"
if "$smoke_repo/install/install.sh" --listener-bin "$update_source/listener" --qml-path "$update_source/qml" --qs-bin "$fake_qs_updated" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/tampered-release-manifest-install.log" 2>&1; then
    fail "installer accepted extra release-manifest content"
fi
if "$smoke_repo/install/uninstall.sh" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/tampered-release-manifest-uninstall.log" 2>&1; then
    fail "uninstaller accepted extra release-manifest content"
fi
cp "$test_root/release-manifest.before-tamper" "$app_dir/current/manifest"

printf '\n// old release owner modification\n' >> "$app_dir/$current_target/qml/shell.qml"
if "$smoke_repo/install/install.sh" --listener-bin "$update_source/listener" --qml-path "$update_source/qml" --qs-bin "$fake_qs_updated" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/tampered-old-release.log" 2>&1; then
    fail "installer accepted a modified retained release"
fi
cp "$smoke_repo/qml/shell.qml" "$app_dir/$current_target/qml/shell.qml"

printf 'unexpected owner file\n' > "$app_dir/owner-notes.txt"
if "$smoke_repo/install/uninstall.sh" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/unexpected-tree.log" 2>&1; then
    fail "uninstaller accepted an unexpected app-tree entry"
fi
rm -- "$app_dir/owner-notes.txt"

printf 'hidden owner file\n' > "$app_dir/releases/.owner-note"
if "$smoke_repo/install/install.sh" --listener-bin "$update_source/listener" --qml-path "$update_source/qml" --qs-bin "$fake_qs_updated" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/hidden-release-entry-install.log" 2>&1; then
    fail "installer ignored an unexpected hidden releases entry"
fi
if "$smoke_repo/install/uninstall.sh" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/hidden-release-entry-uninstall.log" 2>&1; then
    fail "uninstaller accepted an unexpected hidden releases entry"
fi
rm -- "$app_dir/releases/.owner-note"

cp "$app_dir/current/qml/shell.qml" "$test_root/qml.before-tamper"
printf '\n// owner modification\n' >> "$app_dir/current/qml/shell.qml"
if "$smoke_repo/install/install.sh" --listener-bin "$update_source/listener" --qml-path "$update_source/qml" --qs-bin "$fake_qs_updated" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/tampered-app-install.log" 2>&1; then
    fail "installer accepted a modified installed QML file"
fi
if "$smoke_repo/install/uninstall.sh" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/tampered-app.log" 2>&1; then
    fail "uninstaller accepted a modified installed QML file"
fi
[ -d "$app_dir" ] && [ -f "$unit_dir/fnx-oem-osd-osd.service" ] || fail "failed app refusal removed managed state"
cp "$test_root/qml.before-tamper" "$app_dir/current/qml/shell.qml"

chmod 0644 "$app_dir/current/bin/fnx-oem-osd-listener"
if "$smoke_repo/install/install.sh" --listener-bin "$update_source/listener" --qml-path "$update_source/qml" --qs-bin "$fake_qs_updated" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/non-executable-listener-install.log" 2>&1; then
    fail "installer accepted a non-executable managed listener"
fi
if "$smoke_repo/install/uninstall.sh" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/non-executable-listener-uninstall.log" 2>&1; then
    fail "uninstaller accepted a non-executable managed listener"
fi
chmod 0755 "$app_dir/current/bin/fnx-oem-osd-listener"

cp "$unit_dir/fnx-oem-osd-osd.service" "$test_root/osd-unit.before-tamper"
printf '\n# owner modification\n' >> "$unit_dir/fnx-oem-osd-osd.service"
if "$smoke_repo/install/install.sh" --listener-bin "$update_source/listener" --qml-path "$update_source/qml" --qs-bin "$fake_qs_updated" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/tampered-unit-install.log" 2>&1; then
    fail "installer accepted a modified managed unit"
fi
if "$smoke_repo/install/uninstall.sh" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/tampered-unit.log" 2>&1; then
    fail "uninstaller accepted a modified managed unit"
fi
[ -d "$app_dir" ] && [ -f "$unit_dir/fnx-oem-osd-listener.service" ] || fail "failed unit refusal removed managed state"
cp "$test_root/osd-unit.before-tamper" "$unit_dir/fnx-oem-osd-osd.service"

# Foreign collision checks happen before managed application/unit writes.
foreign_unit_dir="$test_root/foreign units"
foreign_app_dir="$test_root/foreign app target"
mkdir -p "$foreign_unit_dir"
printf '[Unit]\nDescription=owner file\n' > "$foreign_unit_dir/fnx-oem-osd-osd.service"
if "$smoke_repo/install/install.sh" --qs-bin "$fake_qs" --prefix "$foreign_unit_dir" --app-dir "$foreign_app_dir" > "$test_root/foreign-unit.log" 2>&1; then
    fail "installer overwrote a foreign unit"
fi
grep -F 'Description=owner file' "$foreign_unit_dir/fnx-oem-osd-osd.service" >/dev/null || fail "foreign unit changed"
[ ! -e "$foreign_app_dir" ] || fail "foreign-unit refusal left an app install"

foreign_unit_dir_2="$test_root/foreign app units"
foreign_app_dir_2="$test_root/foreign app"
mkdir -p "$foreign_app_dir_2"
printf 'owner data\n' > "$foreign_app_dir_2/notes.txt"
if "$smoke_repo/install/install.sh" --qs-bin "$fake_qs" --prefix "$foreign_unit_dir_2" --app-dir "$foreign_app_dir_2" > "$test_root/foreign-app.log" 2>&1; then
    fail "installer adopted a foreign app directory"
fi
[ ! -e "$foreign_unit_dir_2/fnx-oem-osd-osd.service" ] || fail "foreign-app refusal wrote a unit"
grep -F 'owner data' "$foreign_app_dir_2/notes.txt" >/dev/null || fail "foreign app data changed"

if "$smoke_repo/install/install.sh" --prefix > "$test_root/missing-value.log" 2>&1; then
    fail "installer accepted a missing option value"
fi
if "$smoke_repo/install/install.sh" --qs-bin "$fake_qs" --prefix relative --app-dir "$test_root/unused-app" > "$test_root/relative-prefix.log" 2>&1; then
    fail "installer accepted a relative unit prefix"
fi
if "$smoke_repo/install/uninstall.sh" --prefix / --app-dir "$test_root/unused-app" > "$test_root/root-target.log" 2>&1; then
    fail "uninstaller accepted / as a removal target"
fi

# A file-only uninstall is also recoverable directly from the legitimate split
# unit state. Use symlinked parent aliases to prove uninstall resolves the same
# physical destinations that install recorded without accepting an app-dir
# symlink itself.
cp "$test_root/listener-unit.initial" "$unit_dir/fnx-oem-osd-listener.service"
path_alias="$test_root/physical parent alias"
ln -s "$test_root" "$path_alias"
unit_alias="$path_alias/$(basename -- "$unit_dir")"
app_alias="$path_alias/$(basename -- "$app_dir")"
"$smoke_repo/install/uninstall.sh" --prefix "$unit_alias" --app-dir "$app_alias" > "$test_root/uninstall.log"
[ ! -e "$app_dir" ] || fail "uninstall left managed app directory"
[ ! -e "$unit_dir/fnx-oem-osd-osd.service" ] || fail "uninstall left OSD unit"
[ ! -e "$unit_dir/fnx-oem-osd-listener.service" ] || fail "uninstall left listener unit"
"$smoke_repo/install/uninstall.sh" --prefix "$unit_dir" --app-dir "$app_dir" > "$test_root/uninstall-again.log"

# Exercise default XDG routing independently of the real uid (CI commonly runs
# as root). The fake id is confined to this disposable PATH and lets both the
# non-root default path and root-default refusal remain deterministic.
fake_id="$tool_dir/id"
printf '#!/bin/sh\nprintf "%%s\\n" "%sFAKE_ID_VALUE"\n' "$dollar_sign" > "$fake_id"
chmod +x "$fake_id"
default_home="$test_root/default home"
default_config="$test_root/default config"
default_data="$test_root/default data"
mkdir -p "$default_home" "$default_config" "$default_data"
FAKE_ID_VALUE=1000 HOME="$default_home" XDG_CONFIG_HOME="$default_config" XDG_DATA_HOME="$default_data" \
    "$smoke_repo/install/install.sh" --qs-bin "$fake_qs" > "$test_root/default-install.log"
default_prefix="$default_config/systemd/user"
default_app="$default_data/xingyao-oem-mode-osd"
[ -f "$default_prefix/fnx-oem-osd-listener.service" ] && [ -d "$default_app" ] || fail "non-root XDG defaults were not installed"
FAKE_ID_VALUE=1000 HOME="$default_home" XDG_CONFIG_HOME="$default_config" XDG_DATA_HOME="$default_data" \
    "$smoke_repo/install/uninstall.sh" > "$test_root/default-uninstall.log"
[ ! -e "$default_app" ] && [ ! -e "$default_prefix/fnx-oem-osd-listener.service" ] || fail "default XDG uninstall left managed state"

if FAKE_ID_VALUE=0 HOME="$default_home" XDG_CONFIG_HOME="$default_config" XDG_DATA_HOME="$default_data" \
    "$smoke_repo/install/install.sh" --qs-bin "$fake_qs" > "$test_root/root-default-install.log" 2>&1; then
    fail "installer accepted root defaults"
fi
if FAKE_ID_VALUE=0 HOME="$default_home" XDG_CONFIG_HOME="$default_config" XDG_DATA_HOME="$default_data" \
    "$smoke_repo/install/uninstall.sh" > "$test_root/root-default-uninstall.log" 2>&1; then
    fail "uninstaller accepted root defaults"
fi
if FAKE_ID_VALUE=1000 HOME="$default_home" XDG_CONFIG_HOME=relative XDG_DATA_HOME="$default_data" \
    "$smoke_repo/install/install.sh" --qs-bin "$fake_qs" > "$test_root/relative-xdg.log" 2>&1; then
    fail "installer accepted a relative XDG_CONFIG_HOME"
fi

# Inject a deterministic input-artifact copy race. The shim changes the built listener only
# after cp has produced the staged file; the installer's before/staged/after
# hashes must reject publication and cleanup all managed targets.
race_source="$test_root/racing source"
race_prefix="$test_root/race units"
race_app="$test_root/race app"
mkdir -p "$race_source/qml"
cp "$smoke_repo/zig-out/bin/fnx-oem-osd-listener" "$race_source/listener"
chmod +x "$race_source/listener"
cp "$smoke_repo/qml/shell.qml" "$race_source/qml/shell.qml"
fake_cp="$tool_dir/cp"
printf '#!/bin/sh\nset -eu\n"%sREAL_CP_BIN" "%s@"\nif [ -n "%sMUTATE_SOURCE_AFTER_COPY" ] && [ ! -e "%sMUTATION_MARKER" ]; then\n    : > "%sMUTATION_MARKER"\n    printf race >> "%sMUTATE_SOURCE_AFTER_COPY"\nfi\n' \
    "$dollar_sign" "$dollar_sign" "$dollar_sign" "$dollar_sign" "$dollar_sign" "$dollar_sign" > "$fake_cp"
chmod +x "$fake_cp"
race_marker="$test_root/race-triggered"
if REAL_CP_BIN="$real_cp" MUTATE_SOURCE_AFTER_COPY="$race_source/listener" MUTATION_MARKER="$race_marker" \
    "$smoke_repo/install/install.sh" --listener-bin "$race_source/listener" --qml-path "$race_source/qml" --qs-bin "$fake_qs" --prefix "$race_prefix" --app-dir "$race_app" > "$test_root/source-race.log" 2>&1; then
    fail "installer published an input artifact that changed during snapshot copy"
fi
grep -F 'binary input changed while the release snapshot was copied' "$test_root/source-race.log" >/dev/null || fail "artifact-race refusal was not diagnostic"
[ ! -e "$race_app" ] && [ ! -e "$race_prefix/fnx-oem-osd-listener.service" ] || fail "artifact-race refusal published managed state"
[ ! -e "$systemctl_called" ] || fail "a lifecycle script invoked systemctl"

printf 'lifecycle.sh: ALL TESTS PASSED\n'
