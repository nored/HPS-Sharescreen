#!/bin/bash
# =============================================================================
# Recovery script — run on your Mac/Linux with the Pi's SD card mounted
# Finds the rootfs partition and fixes the broken config
# =============================================================================

# Find the rootfs — look for common mount points
ROOTFS=""
for path in /Volumes/rootfs /media/*/rootfs /mnt/rootfs /media/$USER/rootfs; do
  if [ -d "$path/etc/systemd" ]; then
    ROOTFS="$path"
    break
  fi
done

if [ -z "$ROOTFS" ]; then
  echo "Could not find rootfs partition."
  echo "Mount the SD card and pass the rootfs path:"
  echo "  sudo bash recover.sh /path/to/rootfs"
  ROOTFS="$1"
fi

if [ ! -d "$ROOTFS/etc/systemd" ]; then
  echo "ERROR: $ROOTFS does not look like a rootfs partition"
  exit 1
fi

echo "Found rootfs at: $ROOTFS"

# 1. Disable the broken sharescreen service
rm -f "$ROOTFS/etc/systemd/system/multi-user.target.wants/sharescreen.service"
rm -f "$ROOTFS/etc/systemd/system/sharescreen.service"
echo "  Removed sharescreen service"

# 2. Re-enable getty so you get a console
mkdir -p "$ROOTFS/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/getty@.service "$ROOTFS/etc/systemd/system/getty.target.wants/getty@tty1.service"
echo "  Re-enabled getty@tty1"

echo ""
echo "Done. Put the SD card back in the Pi and boot."
echo "You should get SSH and console back."
