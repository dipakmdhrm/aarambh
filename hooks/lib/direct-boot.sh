# Copy a kernel and its initramfs onto the ESP for direct boot. Sourced.
#
# With Secure Boot signing set up (signing.sh), the copy is signed with this
# OS's key, so shim accepts it whichever distribution's shim starts Aarambh.

ESP_SPACE_MARGIN=$((8 * 1024 * 1024))

esp_free_bytes() {
    df --output=avail -B1 "$ESP_DIR" | tail -n1
}

has_room_for() {
    local needed=$1
    local available

    available=$(esp_free_bytes)
    [ "$needed" -le $((available - ESP_SPACE_MARGIN)) ]
}

disable_direct_boot() {
    rm -rf "$LINUX_DIR"
    warn "$1, direct boot disabled (falling back to the OS boot loader)"
}

# Concatenate the initramfs parts (microcode first) into one file.
merged_initrd() {
    local output=$1
    shift

    if [ "$#" -eq 1 ]; then
        echo "$1"
        return 0
    fi

    cat "$@" > "$output"
    echo "$output"
}

# The source kernel and the signing key; the copy is redone when either changes.
kernel_stamp() {
    printf '%s %s\n' "$(sha256sum < "$1" | cut -d' ' -f1)" "$(signing_id)"
}

copy_kernel() {
    if signing_enabled; then
        sign_file "$1" "$2"
    else
        cp "$1" "$2"
    fi
}

# A kernel already on the ESP is started where it is, unless signing is set
# up and it carries no signature at all (shim would refuse it).
boots_in_place() {
    ! signing_enabled || has_signature "$1"
}

# copy_for_direct_boot <kernel> <initrd> [<initrd>...]
copy_for_direct_boot() {
    local kernel=$1
    local scratch
    local initrd
    local needed
    local part
    local stamp

    shift

    for part in "$kernel" "$@"; do
        if [ ! -f "$part" ]; then
            return 1
        fi
    done

    mkdir -p "$LINUX_DIR"
    scratch=$(mktemp -p "${TMPDIR:-/var/tmp}" aarambh-initrd.XXXXXX)
    initrd=$(merged_initrd "$scratch" "$@")

    stamp=$(kernel_stamp "$kernel")

    if [ -f "$LINUX_DIR/vmlinuz" ] && [ "$(cat "$LINUX_DIR/vmlinuz.stamp" 2>/dev/null)" = "$stamp" ] \
        && cmp -s "$initrd" "$LINUX_DIR/initrd.img"; then
        rm -f "$scratch"
        return 0
    fi

    needed=$(( $(file_size "$kernel") + $(file_size "$initrd") ))

    if ! has_room_for "$needed"; then
        rm -f "$LINUX_DIR/vmlinuz" "$LINUX_DIR/initrd.img"
    fi

    if ! has_room_for "$needed"; then
        rm -f "$scratch"
        disable_direct_boot "not enough space on the EFI partition"
        return 1
    fi

    if ! copy_kernel "$kernel" "$LINUX_DIR/vmlinuz.new" || ! cp "$initrd" "$LINUX_DIR/initrd.img.new"; then
        rm -f "$scratch"
        disable_direct_boot "copying or signing the kernel failed"
        return 1
    fi

    rm -f "$scratch"
    mv -f "$LINUX_DIR/vmlinuz.new" "$LINUX_DIR/vmlinuz"
    mv -f "$LINUX_DIR/initrd.img.new" "$LINUX_DIR/initrd.img"
    echo "$stamp" > "$LINUX_DIR/vmlinuz.stamp"
    sync
}

# Kernel-list fields for a direct boot: |kernel|initrd,initrd|cmdline
direct_fields() {
    local kernel=$1
    local initrds=$2
    local cmdline=$3

    printf '|%s|%s|%s' "$kernel" "$initrds" "$cmdline"
}

copied_fields() {
    direct_fields "$EFI_LINUX_DIR\\vmlinuz" "$EFI_LINUX_DIR\\initrd.img" "$1"
}

# ESP paths for files already on the ESP, comma separated; fails otherwise.
esp_paths() {
    local joined=""
    local path
    local file

    for file in "$@"; do
        path=$(esp_path "$file") || return 1
        if [ -n "$joined" ]; then
            joined="$joined,$path"
        else
            joined=$path
        fi
    done

    printf '%s' "$joined"
}