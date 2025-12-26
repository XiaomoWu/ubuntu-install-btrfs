#!/usr/bin/env bash
set -euo pipefail

# ubuntu-btrfs-install-minimal.sh
# Based on diogopessoa/ubuntu-btrfs-install, but keeps ONLY:
#   - @           -> /
#   - @snapshots  -> /.snapshots
#
# Expected: run from Live USB after Ubuntu is installed, BEFORE first reboot.
# Partitions:
#   /dev/<rootdev> : btrfs (currently contains the freshly installed Ubuntu at top-level)
#   /dev/<bootdev> : ext4 mounted at /boot
#   /dev/<efidev>  : vfat mounted at /boot/efi (optional)

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
    echo "ERROR: must run as root"
    exit 1
  fi
}

require_cmds() {
  local cmds=(blkid mount umount btrfs sed chroot update-grub update-initramfs)
  for c in "${cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: missing command: $c"; exit 1; }
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

preparation() {
  echo "--- Preparation ---"
  umount_everything || true
  mkdir -p "$mp"
}

mount_root_top_level() {
  echo "--- Mounting Btrfs top-level (subvolid=5) ---"
  # Top-level mount so we can create subvolumes and rearrange the freshly installed system
  mount -t btrfs -o subvolid=5 /dev/"$rootdev" "$mp"
}

ensure_subvols_only_two() {
  echo "--- Ensuring only @ and @snapshots exist (creating if needed) ---"

  # Create @ and @snapshots if they don't exist yet
  if [[ ! -d "$mp/@" ]]; then
    btrfs subvolume create "$mp/@"
  fi

  if [[ ! -d "$mp/@snapshots" ]]; then
    btrfs subvolume create "$mp/@snapshots"
  fi

  # Snapper expects /.snapshots inside the root subvolume
  mkdir -p "$mp/@/.snapshots"
}

move_installed_system_into_at() {
  echo "--- Moving installed system into @ ---"

  # If the system was already moved previously, bail out safely.
  # Heuristic: if @ already contains typical root dirs, skip.
  if [[ -d "$mp/@/etc" && -d "$mp/@/usr" ]]; then
    echo "Looks like @ already contains the root filesystem; skipping move."
    return 0
  fi

  shopt -s dotglob nullglob

  # Move everything from top-level into @, excluding @ and @snapshots themselves.
  for item in "$mp"/* "$mp"/.*; do
    base="$(basename "$item")"
    case "$base" in
      .|..|@|@snapshots) continue ;;
    esac
    mv "$item" "$mp/@/" || true
  done

  shopt -u dotglob nullglob
}

remount_at_as_root() {
  echo "--- Remounting @ as / ---"
  umount "$mp"
  mount -t btrfs -o subvol=@ /dev/"$rootdev" "$mp"

  # Create mountpoint directories in the running root view
  mkdir -p "$mp/.snapshots"
  mkdir -p "$mp/boot"
  if $efi; then
    mkdir -p "$mp/boot/efi"
  fi
}

ajusta_fstab() {
  echo "--- Adjusting /etc/fstab ---"

  local root_uuid
  root_uuid="$(blkid --output export /dev/"$rootdev" | grep '^UUID=')"

  local fstab_path="$mp/etc/fstab"

  # Remove existing btrfs lines and swap lines (same approach as upstream script)  [oai_citation:3‡GitHub](https://github.com/diogopessoa/ubuntu-btrfs-install/blob/main/ubuntu-btrfs-install.sh?utm_source=chatgpt.com)
  sed -i '/ btrfs /d' "$fstab_path"
  sed -i '/ swap /d' "$fstab_path"

  # Only two mounts: / and /.snapshots
  # Keep same options style used by the original script (compress=zstd:1 etc.)  [oai_citation:4‡GitHub](https://github.com/diogopessoa/ubuntu-btrfs-install/blob/main/ubuntu-btrfs-install.sh?utm_source=chatgpt.com)
  echo "${root_uuid} /           btrfs defaults,ssd,discard=async,noatime,space_cache=v2,compress=zstd:1,subvol=@          0 0" >> "$fstab_path"
  echo "${root_uuid} /.snapshots btrfs defaults,ssd,discard=async,noatime,space_cache=v2,compress=zstd:1,subvol=@snapshots 0 0" >> "$fstab_path"

  local boot_uuid
  boot_uuid="$(blkid --output export /dev/"$bootdev" | grep '^UUID=')"
  echo "${boot_uuid} /boot ext4 defaults 0 2" >> "$fstab_path"

  if $efi; then
    local efi_uuid
    efi_uuid="$(blkid --output export /dev/"$efidev" | grep '^UUID=')"
    echo "${efi_uuid} /boot/efi vfat umask=0077 0 1" >> "$fstab_path"
  fi
}

chroot_and_update() {
  echo "--- Chroot and update boot artifacts ---"

  for dir in proc sys dev run; do
    mount --bind "/$dir" "$mp/$dir"
  done

  mount /dev/"$bootdev" "$mp/boot"
  if $efi; then
    mount /dev/"$efidev" "$mp/boot/efi"
  fi

  chroot "$mp" update-grub
  chroot "$mp" update-initramfs -u
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

main() {
  need_root
  require_cmds
  parse_args "$@"

  preparation
  mount_root_top_level
  ensure_subvols_only_two
  move_installed_system_into_at
  remount_at_as_root
  ajusta_fstab
  chroot_and_update
  umount_everything

  echo "✅ Script completed successfully!"
  echo "🔁 Reboot now."
}

main "$@"
