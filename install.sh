#!/usr/bin/env bash
set -euo pipefail

# ubuntu-btrfs-install-minimal.sh
# Keeps ONLY two Btrfs subvolumes:
#   @          -> /
#   @snapshots -> /.snapshots
#
# Run from Ubuntu Live USB after Ubuntu is installed to the Btrfs root partition,
# BEFORE the first reboot into the installed system.
#
# Usage:
#   sudo ./ubuntu-btrfs-install-minimal.sh <rootdev> <bootdev> [efidev]
# Examples:
#   sudo ./ubuntu-btrfs-install-minimal.sh nvme0n1p3 nvme0n1p2 nvme0n1p1
#   sudo ./ubuntu-btrfs-install-minimal.sh sda3 sda2

usage() {
  cat <<'EOF'
Usage:
  sudo ./ubuntu-btrfs-install-minimal.sh <rootdev> <bootdev> [efidev]

Examples:
  sudo ./ubuntu-btrfs-install-minimal.sh sda3 sda2
  sudo ./ubuntu-btrfs-install-minimal.sh nvme0n1p3 nvme0n1p2 nvme0n1p1
EOF
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
  fi
}

require_cmds() {
  local cmds=(blkid mount umount btrfs sed chroot findmnt)
  for c in "${cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing command: $c" >&2; exit 1; }
  done
}

parse_args() {
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    usage
    exit 1
  fi

  rootdev="$1"
  bootdev="$2"
  efidev="${3:-}"

  efi=false
  if [[ -n "$efidev" ]]; then
    efi=true
  fi

  mp="/mnt"
}

umount_everything() {
  set +e
  for dir in proc sys dev run; do
    umount "$mp/$dir" 2>/dev/null || true
  done
  umount "$mp/boot/efi" 2>/dev/null || true
  umount "$mp/boot" 2>/dev/null || true
  umount "$mp" 2>/dev/null || true
  set -e
}

preparation() {
  echo "--- Preparation ---"
  mkdir -p "$mp"
  umount_everything || true
}

mount_root_top_level() {
  echo "--- Mounting Btrfs top-level (subvolid=5) ---"
  mount -t btrfs -o subvolid=5 /dev/"$rootdev" "$mp"

  if ! findmnt -n -o FSTYPE "$mp" | grep -qx btrfs; then
    echo "ERROR: $mp is not mounted as btrfs (check rootdev)" >&2
    exit 1
  fi
}

ensure_subvols_only_two() {
  echo "--- Ensuring @ and @snapshots exist ---"

  if [[ ! -d "$mp/@" ]]; then
    btrfs subvolume create "$mp/@"
  fi

  if [[ ! -d "$mp/@snapshots" ]]; then
    btrfs subvolume create "$mp/@snapshots"
  fi

  # Ensure Snapper-style mountpoint exists inside @
  mkdir -p "$mp/@/.snapshots"
}

move_installed_system_into_at() {
  echo "--- Moving installed system into @ ---"

  # If already moved, don't do it again.
  if [[ -d "$mp/@/etc" && -d "$mp/@/usr" ]]; then
    echo "Detected root filesystem already under @; skipping move."
    return 0
  fi

  # Move everything at top-level into @, excluding @ and @snapshots
  while IFS= read -r -d '' item; do
    base="$(basename "$item")"
    case "$base" in
      @|@snapshots) continue ;;
    esac
    mv "$item" "$mp/@/"
  done < <(find "$mp" -mindepth 1 -maxdepth 1 -print0)
}

remount_at_as_root() {
  echo "--- Remounting @ as / ---"
  umount "$mp"
  mount -t btrfs -o subvol=@ /dev/"$rootdev" "$mp"

  mkdir -p "$mp/.snapshots"
  mkdir -p "$mp/boot"
  if $efi; then
    mkdir -p "$mp/boot/efi"
  fi
}

adjust_fstab() {
  echo "--- Updating /etc/fstab ---"

  local fstab_path="$mp/etc/fstab"
  if [[ ! -f "$fstab_path" ]]; then
    echo "ERROR: $fstab_path not found; is the installed system mounted under @?" >&2
    exit 1
  fi

  local root_uuid boot_uuid efi_uuid
  root_uuid="$(blkid --output export /dev/"$rootdev" | grep '^UUID=')"
  boot_uuid="$(blkid --output export /dev/"$bootdev" | grep '^UUID=')"
  if $efi; then
    efi_uuid="$(blkid --output export /dev/"$efidev" | grep '^UUID=')"
  fi

  # Remove existing lines that we will regenerate
  sed -i '/ btrfs /d' "$fstab_path"
  sed -i '/ swap /d' "$fstab_path"
  sed -i '\| /boot |d' "$fstab_path"
  sed -i '\| /boot/efi |d' "$fstab_path"

  # Two Btrfs mounts only
  local btrfs_opts="defaults,ssd,discard=async,noatime,space_cache=v2,compress=zstd:1"
  echo "${root_uuid} /           btrfs ${btrfs_opts},subvol=@          0 0" >> "$fstab_path"
  echo "${root_uuid} /.snapshots btrfs ${btrfs_opts},subvol=@snapshots 0 0" >> "$fstab_path"

  # Boot mounts
  echo "${boot_uuid} /boot ext4 defaults 0 2" >> "$fstab_path"
  if $efi; then
    echo "${efi_uuid} /boot/efi vfat umask=0077 0 1" >> "$fstab_path"
  fi
}

chroot_and_update() {
  echo "--- Chroot: update grub + initramfs ---"

  for dir in proc sys dev run; do
    mount --bind "/$dir" "$mp/$dir"
  done

  mount /dev/"$bootdev" "$mp/boot"
  if $efi; then
    mount /dev/"$efidev" "$mp/boot/efi"
  fi

  # These must exist inside the installed system (not on the Live ISO PATH)
  chroot "$mp" /usr/sbin/update-grub
  chroot "$mp" /usr/sbin/update-initramfs -u
}

main() {
  need_root
  require_cmds
  parse_args "$@"

  preparation
  mount_root_top_level
  ensure_subvols_only_two
  move_installed_system_into_at
  remount_at_as_root
  adjust_fstab
  chroot_and_update
  umount_everything

  echo "Done. Reboot."
}

main "$@"
