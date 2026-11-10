# Kernel list from BootLoaderSpec entries: Fedora, RHEL and friends (GRUB with
# BLS) and every systemd-boot system. Sourced.

bls_field() {
    sed -n "s/^$1[[:space:]]\\+//p" "$2" | head -n1
}

bls_all_fields() {
    sed -n "s/^$1[[:space:]]\\+//p" "$2"
}

bls_entry_dirs() {
    if [ "$BOOTLOADER" = systemd-boot ] && [ -d "$ESP_ROOT/loader/entries" ]; then
        echo "$ESP_ROOT/loader/entries"
    fi

    if [ -d "$ROOT/boot/loader/entries" ]; then
        if [ "$(realpath "$ROOT/boot/loader/entries")" != "$(realpath -m "$ESP_ROOT/loader/entries")" ]; then
            echo "$ROOT/boot/loader/entries"
        fi
    fi
}

machine_id() {
    cat "$ROOT/etc/machine-id" 2>/dev/null || true
}

root_device() {
    sed -n 's/.*\broot=\([^ ]*\).*/\1/p' "$ROOT/proc/cmdline" 2>/dev/null || true
}

# On a shared ESP, keep only the entries that belong to this installation.
belongs_to_this_os() {
    local file=$1
    local id
    local root

    if [ "$BOOTLOADER" != systemd-boot ]; then
        return 0
    fi

    id=$(machine_id)
    root=$(root_device)

    if [ -n "$id" ]; then
        case "$(basename "$file")" in
            "$id"-*) return 0 ;;
        esac
        if [ "$(bls_field machine-id "$file")" = "$id" ]; then
            return 0
        fi
    fi

    if [ -n "$root" ] && grep -qs -- "root=$root" "$file"; then
        return 0
    fi

    return 1
}

entries_by_version() {
    local dir
    local file
    local version

    for dir in $(bls_entry_dirs); do
        for file in "$dir"/*.conf; do
            if [ -f "$file" ] && belongs_to_this_os "$file"; then
                version=$(bls_field version "$file")
                if [ -z "$version" ]; then
                    version=$(basename "$file" .conf)
                fi
                echo "$version|$file"
            fi
        done
    done | sort -t'|' -k1,1 -V -r
}

# Resolve a path from an entry against the partition that holds the entry.
bls_file() {
    local entry=$1
    local path=$2
    local base

    base=$(dirname "$(dirname "$(dirname "$entry")")")

    for candidate in "$base$path" "$ROOT$path" "$ROOT/boot$path"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

bls_initrds() {
    local entry=$1
    local path

    for path in $(bls_all_fields initrd "$entry"); do
        bls_file "$entry" "$path" || return 1
    done
}

bls_options() {
    local options

    options=$(bls_all_fields options "$1" | tr '\n' ' ' | sed 's/[[:space:]]*$//')

    case "$options" in
        *'$kernelopts'*)
            options=$(grub2-editenv list 2>/dev/null | sed -n 's/^kernelopts=//p')
            ;;
    esac

    echo "$options"
}

bls_title() {
    local entry=$1
    local version=$2

    case "$version" in
        *rescue*) echo "Rescue mode" ;;
        [0-9]*) echo "Linux $version" ;;
        *) bls_field title "$entry" ;;
    esac
}

bls_id() {
    if [ "$BOOTLOADER" = systemd-boot ]; then
        basename "$1"
    else
        basename "$1" .conf
    fi
}

list_bls_kernels() {
    local version
    local entry
    local line
    local kernel
    local initrds
    local options
    local parts
    local first=1

    if [ "$BOOTLOADER" = systemd-boot ]; then
        echo "@oneshot systemd-boot"
    else
        echo "@oneshot grub"
    fi

    entries_by_version | while IFS='|' read -r version entry; do
        line="$(bls_title "$entry" "$version")|$(bls_id "$entry")"
        kernel=$(bls_file "$entry" "$(bls_field linux "$entry")" || true)

        if [ -z "$kernel" ]; then
            echo "$line"
            continue
        fi

        initrds=$(bls_initrds "$entry" || true)
        options=$(bls_options "$entry")
        # shellcheck disable=SC2086
        parts=$(esp_paths $initrds || true)

        if esp_path "$kernel" >/dev/null && boots_in_place "$kernel" \
            && { [ -z "$initrds" ] || [ -n "$parts" ]; }; then
            line="$line$(direct_fields "$(esp_path "$kernel")" "$parts" "$options")"
        elif [ "$first" = 1 ] && [ -n "$initrds" ] && [[ "$version" != *rescue* ]]; then
            # shellcheck disable=SC2086
            if copy_for_direct_boot "$kernel" $initrds; then
                line="$line$(copied_fields "$options")"
            fi
        fi

        if [[ "$version" != *rescue* ]]; then
            first=0
        fi

        echo "$line"
    done
}