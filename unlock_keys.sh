#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# unlock_keys.sh
#
# Unlocks the ZFS native-encryption keystore and loads all dataset keys
# for an Ubuntu 24.04 ZFS-on-root installation.
#
# Usage:
#   sudo ./unlock_keys.sh [<zpool_name> [<mapper_name>]]
#
set -euo pipefail

# Default pool and mapper names
ZPOOL=${1:-rpool}
MAPPER=${2:-keystore_plain}

# Paths
ZVOL_PATH="/dev/zvol/${ZPOOL}/keystore"
MAPPER_PATH="/dev/mapper/${MAPPER}"
KEY_DIR="/run/keystore/${ZPOOL}"

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Use sudo." >&2
  exit 1
fi

# Check for cryptsetup and zfs commands
for cmd in cryptsetup zfs; do
  command -v "$cmd" >/dev/null || { echo "Error: '$cmd' not found." >&2; exit 1; }
done

# Open the encrypted keystore volume
echo "Opening ZFS keystore volume: $ZVOL_PATH -> $MAPPER..."
cryptsetup open "$ZVOL_PATH" "$MAPPER"

# Create and mount the keystore directory
echo "Mounting keystore at $KEY_DIR..."
mkdir -p "$KEY_DIR"
mount "$MAPPER_PATH" "$KEY_DIR"

# Load ZFS keys for all encrypted datasets
echo "Loading ZFS dataset keys..."
zfs load-key -a

echo "All keys loaded successfully. You may now mount and access your pools."
