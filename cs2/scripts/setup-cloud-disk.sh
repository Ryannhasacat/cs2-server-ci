#!/usr/bin/env bash
# Initialize the cloud data disk for CS2 install persistence.
# Must be run with sudo. Idempotent: safe to re-run.
#
# Usage: sudo bash cs2/scripts/setup-cloud-disk.sh [device] [mount-point]
#   default device = /dev/vdb
#   default mount  = /mnt/cs2-install
#
# What it does:
#   1. mkfs.ext4 the device (only if not already formatted)
#   2. mkdir -p the mount point
#   3. Add fstab entry (UUID-based) so the disk auto-mounts on boot
#   4. mount -a
#   5. Create /mnt/cs2-install/cs2 (the bind mount target)
#   6. chown 1001:1001 (matches the steam user inside the container)
#
# After this script: docker compose up -d will see an empty
# /mnt/cs2-install/cs2, the cs2 container will mount it to /opt/cs2,
# and the entrypoint will run SteamCMD to download CS2 (~20-30 min
# on first start, instant validate on subsequent starts).

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: this script needs root. Re-run with sudo."
    echo "  sudo bash $0 /dev/vdb /mnt/cs2-install"
    exit 1
fi

DEVICE="${1:-/dev/vdb}"
MOUNT="${2:-/mnt/cs2-install}"
# UID 1001 is the 'steam' user inside the cs2 container.
# Keep in sync with Dockerfile's `useradd -m -u 1001 -s /bin/bash steam`.
CONTAINER_UID=1001
CONTAINER_GID=1001

echo "==> Device: $DEVICE"
echo "==> Mount:  $MOUNT"
echo "==> Container UID:GID = $CONTAINER_UID:$CONTAINER_GID"
echo

# 1. Already mounted?
if mountpoint -q "$MOUNT"; then
    echo "OK: $MOUNT is already mounted; nothing to do."
    mkdir -p "$MOUNT/cs2"
    chown -R $CONTAINER_UID:$CONTAINER_GID "$MOUNT/cs2" 2>/dev/null || true
    echo "OK: $MOUNT/cs2 is ready."
    echo
    echo "Verify:  df -h $MOUNT  &&  ls -la $MOUNT/cs2"
    exit 0
fi

# 2. Check device exists
if [ ! -b "$DEVICE" ]; then
    echo "ERROR: $DEVICE is not a block device."
    echo "Run 'lsblk' to see available disks (e.g. /dev/vdb /dev/sdb /dev/nvme1n1)."
    exit 1
fi

# 3. Format if needed
if blkid "$DEVICE" >/dev/null 2>&1; then
    echo "OK: $DEVICE already has a filesystem, skipping mkfs."
else
    echo "==> Formatting $DEVICE as ext4..."
    mkfs.ext4 -F "$DEVICE"
fi

# 4. mkdir + fstab
mkdir -p "$MOUNT"
UUID=$(blkid -s UUID -o value "$DEVICE")
if [ -z "$UUID" ]; then
    echo "ERROR: could not read UUID of $DEVICE"
    exit 1
fi

FSTAB_LINE="UUID=$UUID  $MOUNT  ext4  defaults,nofail  0  2"
if grep -q "UUID=$UUID" /etc/fstab; then
    echo "OK: $UUID already in /etc/fstab"
else
    echo "==> Adding to /etc/fstab: $FSTAB_LINE"
    echo "$FSTAB_LINE" >> /etc/fstab
fi

# 5. mount
echo "==> mount -a"
mount -a
if ! mountpoint -q "$MOUNT"; then
    echo "ERROR: mount failed. Check 'dmesg | tail' for details."
    exit 1
fi

# 6. cs2/ subdir + chown
mkdir -p "$MOUNT/cs2"
chown -R $CONTAINER_UID:$CONTAINER_GID "$MOUNT"
chmod 755 "$MOUNT"

echo
echo "=== summary ==="
df -h "$MOUNT"
ls -ld "$MOUNT" "$MOUNT/cs2"
echo
echo "Done. Next steps:"
echo "  cd /opt/cs2-server"
echo "  docker compose pull"
echo "  docker compose up -d                # 首次会下载 CS2 20-30 min"
echo "  docker compose logs -f cs2"
