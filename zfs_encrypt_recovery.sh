#!/usr/bin/env bash
# =============================================================================
# ZFS-on-Root Recovery Script - Simple Interactive Version
# =============================================================================
# NOTE:
#   Use this tool to recover an Ubuntu ZFS-on-root install when your initramfs
#   or dracut changes have broken the boot process (e.g., after experimenting
#   with dracut on an encrypted root and the system no longer loads).
#   It guides you through selecting pools, unlocking encryption, mounting
#   datasets, and rebuilding your boot configuration safely.
#
# Repairs an encrypted ZFS installation by letting the user select everything
#
# Usage:
#   Interactive mode: zfs_encrypt_recovery.sh
#   With key file:    ./recovery.sh /path/to/keyfile
#   With passphrase: run unlock_keys.sh first
#   Automated mode:   ROOT_POOL=rpool BOOT_POOL=bpool EFI_PART=/dev/nvme0n1p1 ./recovery.sh [/path/to/keyfile]
# =============================================================================

set -euo pipefail

# ---------- color helpers ---------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cecho() {
    printf "%b%s%b\n" "$1" "$2" "$NC"
}

# ---------- cleanup trap ----------------------------------------------------
cleanup() {
    local rc=$?
    if (( rc )); then
        cecho "$YELLOW" "\n[cleanup] Unmounting filesystems and exporting pools..."
        umount -Rl /mnt 2>/dev/null || true
        for p in "${ROOT_POOL_NAME:-}" "${BOOT_POOL_NAME:-}"; do
            if zpool list -H -o name 2>/dev/null | grep -qx "$p"; then
                zpool export "$p" 2>/dev/null || true
            fi
        done
        cecho "$RED" "Script failed with status $rc"
    fi
}
trap cleanup EXIT

# ---------- prereq checks ---------------------------------------------------
if (( EUID != 0 )); then
    cecho "$RED" "This script must be run as root."
    exit 1
fi

# Optional key file
KEY_FILE="${1:-}"

cecho "$BLUE" "=== ZFS Recovery Script ==="
cecho "$BLUE" "This will help you repair a broken ZFS boot configuration.\n"

if [[ -n "$KEY_FILE" ]]; then
    if [[ -f "$KEY_FILE" ]]; then
        cecho "$GREEN" "Using key file: $KEY_FILE"
    else
        cecho "$RED" "Key file not found: $KEY_FILE"
        exit 1
    fi
fi

# ---------- Step 1: Select pools and EFI partition --------------------------
if [[ -n "${ROOT_POOL:-}" && -n "${BOOT_POOL:-}" && -n "${EFI_PART:-}" ]]; then
    cecho "$GREEN" "Using environment variables:"
    cecho "$GREEN" "  ROOT_POOL=$ROOT_POOL"
    cecho "$GREEN" "  BOOT_POOL=$BOOT_POOL"
    cecho "$GREEN" "  EFI_PART=$EFI_PART"
    ROOT_POOL_NAME="$ROOT_POOL"
    BOOT_POOL_NAME="$BOOT_POOL"
    EFI_PARTITION="$EFI_PART"
else
    cecho "$YELLOW" "\nStep 1: Select your ZFS pools"
    IMPORTED=$(zpool list -H -o name 2>/dev/null || true)
    if [[ -n "$IMPORTED" ]]; then
        cecho "$BLUE" "Already imported pools: $IMPORTED"
    fi
    ALL=$(zpool import 2>/dev/null | awk '/pool:/{print $2}')
    if [[ -n "$ALL" ]]; then
        cecho "$BLUE" "Available pools to import: $ALL"
    fi
    if [[ -z "$IMPORTED" && -z "$ALL" ]]; then
        cecho "$RED" "No ZFS pools found!"
        exit 1
    fi
    echo
    read -rp "Enter your ROOT pool name (e.g., 'rpool'): " ROOT_POOL_NAME
    cecho "$BLUE" "Tip: This is usually the ZFS root pool created by the installer, commonly named 'rpool'."
    echo
    read -rp "Enter your BOOT pool name (e.g., 'bpool'): " BOOT_POOL_NAME
    cecho "$BLUE" "Tip: This pool contains your boot and EFI datasets; on Ubuntu it's often 'bpool'."

    echo
    cecho "$YELLOW" "Step 2: Select your EFI partition"
    cecho "$BLUE" "Your disk layout (look for FSTYPE 'vfat'):"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -E 'disk|part'
    echo
    cecho "$BLUE" "Common EFI partitions are 100-550MB and formatted as vfat (FAT32)."
    read -rp "Enter your EFI partition (vfat, e.g., /dev/nvme0n1p1): " EFI_PARTITION
    cecho "$BLUE" "Tip: Ensure the partition's FSTYPE column shows 'vfat' or 'FAT32'."
fi

# ---------- Step 2: Import pools -------------------------------------------
cecho "$BLUE" "\nImporting ZFS pools..."
for POOL in "$ROOT_POOL_NAME" "$BOOT_POOL_NAME"; do
    if ! zpool list -H -o name | grep -qx "$POOL"; then
        cecho "$BLUE" "Importing pool: $POOL"
        zpool import -f -N "$POOL"
    else
        cecho "$GREEN" "Pool $POOL already imported"
    fi
done

# ---------- Step 3: Unlock encryption --------------------------------------
KEYSTATUS=$(zfs get -H -o value keystatus "$ROOT_POOL_NAME" 2>/dev/null || echo unavailable)
if [[ "$KEYSTATUS" != "available" ]]; then
    cecho "$YELLOW" "\nRoot pool is encrypted. Unlocking..."
    if [[ -n "$KEY_FILE" ]]; then
        zfs load-key -L "file://$KEY_FILE" "$ROOT_POOL_NAME"
    else
        zfs load-key -a
    fi
else
    cecho "$GREEN" "Root pool already unlocked"
fi

# ---------- Step 4: Identify datasets --------------------------------------
ROOT_DATASET=$(zpool get -H -o value bootfs "$ROOT_POOL_NAME" 2>/dev/null || echo -)
BOOT_DATASET=$(zpool get -H -o value bootfs "$BOOT_POOL_NAME" 2>/dev/null || echo -)

if [[ -z "$ROOT_DATASET" || "$ROOT_DATASET" == "-" ]]; then
    cecho "$YELLOW" "No bootfs set for $ROOT_POOL_NAME. Available:"
    zfs list -H -o name -r "$ROOT_POOL_NAME" | grep -v '@' | sed 's/^/  - /'
    read -rp "Enter root dataset name: " ROOT_DATASET
fi
if [[ -z "$BOOT_DATASET" || "$BOOT_DATASET" == "-" ]]; then
    cecho "$YELLOW" "No bootfs set for $BOOT_POOL_NAME. Available:"
    zfs list -H -o name -r "$BOOT_POOL_NAME" | grep -v '@' | sed 's/^/  - /'
    read -rp "Enter boot dataset name: " BOOT_DATASET
fi

cecho "$GREEN" "\nUsing:"
cecho "$GREEN" "  Root dataset: $ROOT_DATASET"
cecho "$GREEN" "  Boot dataset: $BOOT_DATASET"
cecho "$GREEN" "  EFI partition: $EFI_PARTITION"

# ---------- Step 5: Mount filesystems --------------------------------------
cecho "$BLUE" "\nMounting filesystems..."
mkdir -p /mnt /mnt/boot /mnt/boot/efi
# Temporarily override dataset mountpoints
zfs set mountpoint=/mnt "$ROOT_DATASET"
zfs set mountpoint=/mnt/boot "$BOOT_DATASET"
# Mount datasets
if ! zfs mount "$ROOT_DATASET"; then
    cecho "$YELLOW" "Note: $ROOT_DATASET already mounted or failed to mount, continuing..."
fi
if ! zfs mount "$BOOT_DATASET"; then
    cecho "$YELLOW" "Note: $BOOT_DATASET already mounted or failed to mount, continuing..."
fi
# Mount EFI partition
if ! mount "$EFI_PARTITION" /mnt/boot/efi; then
    cecho "$YELLOW" "Note: EFI partition $EFI_PARTITION already mounted or failed to mount, continuing..."
fi

# Bind mounts for chroot
for d in dev dev/pts proc sys run; do
    mount --rbind "/$d" "/mnt/$d"
    mount --make-rslave "/mnt/$d"
done
# Copy DNS resolution if needed
if ! cp -L /etc/resolv.conf /mnt/etc/resolv.conf; then
    cecho "$YELLOW" "Warning: resolv.conf copy skipped (already same or error)"
fi

# ---------- Step 6: Repair boot in chroot ---------------------------------
cecho "$BLUE" "\nRepairing boot configuration..."
cat > /mnt/var/tmp/repair.sh << 'EOF'
#!/bin/bash
set -e
apt-get purge -y dracut* zfs-dracut || true
apt-get install -y --reinstall initramfs-tools zfs-initramfs grub-efi-amd64
update-initramfs -u -k all
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
update-grub
EOF
chmod +x /mnt/var/tmp/repair.sh
chroot /mnt /var/tmp/repair.sh
rm /mnt/var/tmp/repair.sh

# ---------- Step 7: Cleanup ------------------------------------------------
cecho "$BLUE" "\nCleaning up..."
umount -R /mnt
# Attempt to export pools but continue on failure
if ! zpool export "$BOOT_POOL_NAME"; then
    cecho "$YELLOW" "Warning: could not export $BOOT_POOL_NAME (pool busy), continuing..."
fi
if ! zpool export "$ROOT_POOL_NAME"; then
    cecho "$YELLOW" "Warning: could not export $ROOT_POOL_NAME (pool busy), continuing..."
fi

cecho "$GREEN" "\n================================================================="
cecho "$GREEN" "Recovery complete! Remove the USB and reboot."
cecho "$GREEN" "================================================================="
