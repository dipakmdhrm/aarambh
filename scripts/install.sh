#!/bin/bash
#
# Build Aarambh, copy it to the EFI system partition, connect the running OS
# through hooks/setup.sh (which also signs Aarambh for Secure Boot) and
# register a firmware boot entry: through shim when Aarambh is signed.
#
# Usage: scripts/install.sh [--dry-run] [--reset-config] [--theme <name>]
#                           [--default <os>] [--list-themes] [setup.sh options]

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOT_LABEL="Aarambh"
EFI_LOADER='\EFI\aarambh\aarambh.efi'
RESET_CONFIG=0
SETUP_ARGS=()
SETTINGS_ARGS=()
THEMES="$(sed -n 's/^THEMES="\(.*\)"$/\1/p' "$REPO/hooks/bin/aarambh")"

LEGACY_FILES=(
    light.ttf regular.ttf bold.ttf aarambh-hook.sh
    ubuntu-logo.png fedora-logo.png settings-logo.png restart-logo.png power-logo.png
    ubuntu.jpg fedora.jpg settings.jpg restart.jpg power.jpg
)

# shellcheck source=../hooks/lib/common.sh
. "$REPO/hooks/lib/common.sh"
# shellcheck source=../hooks/lib/detect.sh
. "$REPO/hooks/lib/detect.sh"

list_themes() {
    printf '%s\n' $THEMES
}

check_theme() {
    if [[ " $THEMES " != *" $1 "* ]]; then
        echo "aarambh: error: unknown theme '$1'. Available themes:" >&2
        list_themes >&2
        exit 1
    fi
}

needs_value() {
    if [ -z "${2:-}" ]; then
        die "$1 needs a value"
    fi
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN=1
                SETUP_ARGS+=("$1")
                ;;
            --reset-config) RESET_CONFIG=1 ;;
            --theme)
                needs_value "$1" "${2:-}"
                check_theme "$2"
                SETTINGS_ARGS+=(--theme "$2")
                shift
                ;;
            --default)
                needs_value "$1" "${2:-}"
                SETTINGS_ARGS+=(--default "$2")
                shift
                ;;
            --list-themes)
                list_themes
                exit 0
                ;;
            *) SETUP_ARGS+=("$1") ;;
        esac
        shift
    done
}

report_failure() {
    local status=$?

    if [ "$status" != 0 ]; then
        warn "installation did not finish (exit code $status)"
        warn "run 'make debug' and attach the report to https://github.com/NarkAgni/aarambh/issues"
    fi
}

check_architecture() {
    local machine
    local firmware_bits

    machine=$(uname -m)
    if [ "$machine" != x86_64 ]; then
        die "Aarambh supports 64-bit x86 PCs (x86_64) only, this machine is $machine"
    fi

    firmware_bits=$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || echo 64)
    if [ "$firmware_bits" != 64 ]; then
        die "this PC has ${firmware_bits}-bit UEFI firmware; Aarambh needs 64-bit UEFI"
    fi
}

sudo_run() {
    run sudo "$@"
}

check_uefi() {
    if [ ! -d /sys/firmware/efi ]; then
        die "this system was booted in legacy BIOS mode; Aarambh needs UEFI"
    fi
}

find_esp() {
    detect_esp || die "no EFI system partition mounted at /boot/efi, /efi or /boot"
    TARGET="$ESP_ROOT/EFI/aarambh"
    log "EFI partition: $ESP_ROOT"
}

build() {
    make -C "$REPO"

    if [ ! -d "$REPO/assets/fonts" ]; then
        "$REPO/scripts/make-assets.sh"
    fi
}

remove_legacy_files() {
    local name

    for name in "${LEGACY_FILES[@]}"; do
        if [ -e "$TARGET/$name" ]; then
            sudo_run rm -f "$TARGET/$name"
        fi
    done
}

copy_config() {
    if [ "$RESET_CONFIG" = 1 ] || [ ! -f "$TARGET/aarambh.conf" ]; then
        sudo_run cp "$REPO/config/aarambh.conf" "$TARGET/aarambh.conf"
    else
        log "keeping the existing $TARGET/aarambh.conf (use --reset-config to replace it)"
    fi
}

copy_files() {
    local folder

    sudo_run mkdir -p "$TARGET"
    sudo_run cp "$REPO/build/aarambh.efi" "$TARGET/aarambh.efi"
    sudo_run cp "$REPO/assets/distros.conf" "$TARGET/distros.conf"

    for folder in fonts logos backgrounds plymouth hooks; do
        sudo_run rm -rf "${TARGET:?}/$folder"
    done

    sudo_run cp -r "$REPO/assets/fonts" "$REPO/assets/logos" "$REPO/assets/backgrounds" "$TARGET/"
    sudo_run mkdir -p "$TARGET/plymouth"

    for folder in "$REPO"/assets/plymouth/*/; do
        local name

        name=$(basename "$folder")
        if [ "$name" != template ]; then
            sudo_run cp -r "$folder" "$TARGET/plymouth/"
            sudo_run cp "$REPO/assets/plymouth/template/aarambh.plymouth" \
                "$REPO/assets/plymouth/template/aarambh.script" "$TARGET/plymouth/$name/"
        fi
    done

    sudo_run cp -r "$REPO/hooks" "$TARGET/hooks"
    copy_config
}

# Through shim when setup.sh signed Aarambh for it, else Aarambh itself.
boot_loader_path() {
    local mode=""
    local file=""

    if [ -f "$ENV_FILE" ]; then
        mode=$(sed -n 's/^SIGN_MODE=//p' "$ENV_FILE")
        file=$(sed -n 's/^SHIM_FILE=//p' "$ENV_FILE")
    fi

    if [ "$mode" = mok ] && [ -n "$file" ]; then
        printf '\\EFI\\aarambh\\%s' "$file"
    else
        printf '%s' "$EFI_LOADER"
    fi
}

aarambh_entry() {
    sudo efibootmgr -v | grep -E "^Boot[0-9A-Fa-f]{4}\*? $BOOT_LABEL" | head -n1
}

register_boot_entry() {
    local loader
    local entry
    local source
    local disk
    local partition

    if ! has_command efibootmgr; then
        die "efibootmgr is not installed"
    fi

    loader=$(boot_loader_path)
    entry=$(aarambh_entry)

    if [ -n "$entry" ] && grep -qiF "$loader" <<< "$entry"; then
        return 0
    fi

    if [ -n "$entry" ]; then
        sudo_run efibootmgr -q -b "$(sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' <<< "$entry")" -B
    fi

    source=$(findmnt -no SOURCE "$ESP_ROOT")
    disk=/dev/$(lsblk -no PKNAME "$source")
    partition=$(cat "/sys/class/block/$(basename "$source")/partition")

    sudo_run efibootmgr -q -c -d "$disk" -p "$partition" -L "$BOOT_LABEL" -l "$loader"
}

parse_arguments "$@"
trap report_failure EXIT
check_uefi
check_architecture
find_esp
build

if [ "$DRY_RUN" = 1 ]; then
    log "dry run: nothing will be changed"
fi

remove_legacy_files
copy_files

if [ "$DRY_RUN" = 1 ]; then
    sudo bash "$REPO/hooks/setup.sh" "${SETUP_ARGS[@]}" || true
    register_boot_entry
    if [ "${#SETTINGS_ARGS[@]}" -gt 0 ]; then
        echo "  would run: aarambh ${SETTINGS_ARGS[*]}"
    fi
    exit 0
fi

sudo bash "$TARGET/hooks/setup.sh" "${SETUP_ARGS[@]}"
register_boot_entry

if [ "${#SETTINGS_ARGS[@]}" -gt 0 ]; then
    sudo bash "$TARGET/hooks/bin/aarambh" "${SETTINGS_ARGS[@]}"
fi

log "installed to $TARGET"
sudo efibootmgr | grep -E "BootOrder| $BOOT_LABEL" || true