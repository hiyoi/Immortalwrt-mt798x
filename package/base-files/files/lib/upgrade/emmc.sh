# Copyright (C) 2021 OpenWrt.org
#

. /lib/functions.sh

# Helper function find_mmc_part, ensure it can correctly find partition devices.
# Ideally, confirm this function exists and works correctly in /lib/functions.sh.
# Alternatively, define a simple version here if needed, for example:
# find_mmc_part() {
#     local part_name="$1"
#     if [ -e "/dev/disk/by-partlabel/$part_name" ]; then
#         readlink -f "/dev/disk/by-partlabel/$part_name"
#         return 0
#     fi
#     # If the partition has no label, you might need to hardcode the device path, e.g.: /dev/mmcblk0p5
#     # This is not recommended; adding a partition label in DTS is the best approach.
#     # if [ "$part_name" = "rootfs_overlay" ]; then
#     #     echo "/dev/mmcblk0p5"
#     #     return 0
#     # fi
#     return 1
# }

emmc_upgrade_tar() {
    local tar_file="$1"
    # Export partition device variables to ensure they are visible during sysupgrade process
    [ "$CI_KERNPART" -a -z "$EMMC_KERN_DEV" ] && export EMMC_KERN_DEV="$(find_mmc_part $CI_KERNPART $CI_ROOTDEV)"
    [ "$CI_ROOTPART" -a -z "$EMMC_ROOT_DEV" ] && export EMMC_ROOT_DEV="$(find_mmc_part $CI_ROOTPART $CI_ROOTDEV)"
    # New: Define overlay partition device. Assume its label in DTS is "overlay" or "rootfs_data".
    # You need to set CI_OVERLAYPART="overlay" in your .mk file or add a partlabel for mmcblk0p5 in DTS,
    # and ensure platform.sh passes this label to find_mmc_part.
    # Temporarily set to CI_OVERLAYPART; if your p5 has no label, you might need to hardcode to /dev/mmcblk0p5.
    [ "$CI_OVERLAYPART" -a -z "$EMMC_OVERLAY_DEV" ] && export EMMC_OVERLAY_DEV="$(find_mmc_part $CI_OVERLAYPART $CI_ROOTDEV)"
    [ "$CI_DATAPART" -a -z "$EMMC_DATA_DEV" ] && export EMMC_DATA_DEV="$(find_mmc_part $CI_DATAPART $CI_ROOTDEV)"

    local has_kernel
    local has_rootfs
    local board_dir=$(tar tf "$tar_file" | grep -m 1 '^sysupgrade-.*/$')
    board_dir=${board_dir%/}

    tar tf "$tar_file" ${board_dir}/kernel 1>/dev/null 2>/dev/null && has_kernel=1
    tar tf "$tar_file" ${board_dir}/root 1>/dev/null 2>/dev/null && has_rootfs=1

    # Write kernel partition
    if [ "$has_kernel" = 1 -a "$EMMC_KERN_DEV" ]; then
        echo "Writing kernel to $EMMC_KERN_DEV..."
        export EMMC_KERNEL_BLOCKS=$(($(tar xf "$tar_file" ${board_dir}/kernel -O | dd of="$EMMC_KERN_DEV" bs=512 2>&1 | grep "records out" | cut -d' ' -f1)))
        echo "Kernel written. Size: $EMMC_KERNEL_BLOCKS blocks."
    fi

    # Write root filesystem partition (SquashFS) and handle F2FS Overlay
    if [ "$has_rootfs" = 1 -a "$EMMC_ROOT_DEV" ]; then
        echo "Processing root filesystem partition $EMMC_ROOT_DEV..."

        echo "Writing rootfs (SquashFS) to $EMMC_ROOT_DEV..."
        export EMMC_ROOTFS_BLOCKS=$(($(tar xf "$tar_file" ${board_dir}/root -O | dd of="$EMMC_ROOT_DEV" bs=512 2>&1 | grep "records out" | cut -d' ' -f1)))
        echo "SquashFS rootfs written. Size: $EMMC_ROOTFS_BLOCKS blocks."

        # Account for 64KiB ROOTDEV_OVERLAY_ALIGN in libfstools (retaining original logic)
        EMMC_ROOTFS_BLOCKS=$(((EMMC_ROOTFS_BLOCKS + 127) & ~127))
        
        # --- NEW: F2FS Overlay partition formatting logic ---
        if [ -n "$EMMC_OVERLAY_DEV" ]; then
            echo "Ensuring overlay partition $EMMC_OVERLAY_DEV is formatted as f2fs..."
            sync
            umount "$EMMC_OVERLAY_DEV" 2>/dev/null || : # Ensure unmounted
            # Force format the overlay partition to f2fs
            if ! mkfs.f2fs -f "$EMMC_OVERLAY_DEV"; then
                echo "ERROR: Failed to format overlay partition $EMMC_OVERLAY_DEV to f2fs!"
                return 1
            fi
            echo "Overlay partition $EMMC_OVERLAY_DEV formatted to f2fs successfully."
        else
            echo "WARNING: Overlay partition not found. Skipping f2fs formatting. Check DTS or .mk for CI_OVERLAYPART definition."
        fi
    fi

    # Clean up old backup (retaining original logic)
    if [ -z "$UPGRADE_BACKUP" ]; then
        if [ "$EMMC_DATA_DEV" ]; then
            dd if=/dev/zero of="$EMMC_DATA_DEV" bs=512 count=8
        elif [ "$EMMC_ROOTFS_BLOCKS" ]; then
            # This line might not be needed in most cases now that f2fs overlay is on a separate partition
            # and we've re-formatted the entire overlay partition.
            # If rootfs and overlay are on the same partition, this line might still be useful,
            # but current logs indicate different partitions.
            # Keeping original behavior for now; consider removal if issues persist.
            dd if=/dev/zero of="$EMMC_ROOT_DEV" bs=512 seek=$EMMC_ROOTFS_BLOCKS count=8
        elif [ "$EMMC_KERNEL_BLOCKS" ]; then
            dd if=/dev/zero of="$EMMC_KERN_DEV" bs=512 seek=$EMMC_KERNEL_BLOCKS count=8
        fi
    fi
}

emmc_upgrade_fit() {
    local fit_file="$1"
    [ "$CI_KERNPART" -a -z "$EMMC_KERN_DEV" ] && export EMMC_KERN_DEV="$(find_mmc_part $CI_KERNPART $CI_ROOTDEV)"

    if [ "$EMMC_KERN_DEV" ]; then
        export EMMC_KERNEL_BLOCKS=$(($(get_image "$fit_file" | fwtool -i /dev/null -T - | dd of="$EMMC_KERN_DEV" bs=512 2>&1 | grep "records out" | cut -d' ' -f1)))

        [ -z "$UPGRADE_BACKUP" ] && dd if=/dev/zero of="$EMMC_KERN_DEV" bs=512 seek=$EMMC_KERNEL_BLOCKS count=8
    fi
}

emmc_copy_config() {
    if [ "$EMMC_DATA_DEV" ]; then
        dd if="$UPGRADE_BACKUP" of="$EMMC_DATA_DEV" bs=512
    elif [ "$EMMC_ROOTFS_BLOCKS" ]; then
        dd if="$UPGRADE_BACKUP" of="$EMMC_ROOT_DEV" bs=512 seek=$EMMC_ROOTFS_BLOCKS
    elif [ "$EMMC_KERNEL_BLOCKS" ]; then
        dd if="$UPGRADE_BACKUP" of="$EMMC_KERN_DEV" bs=512 seek=$EMMC_KERNEL_BLOCKS
    fi
}

emmc_do_upgrade() {
    local file_type=$(identify_magic_long "$(get_magic_long "$1")")

    case "$file_type" in
        "fit")  emmc_upgrade_fit $1;;
        *)      emmc_upgrade_tar $1;;
    esac
}