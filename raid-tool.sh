#!/usr/bin/env bash
#
# multivac — interactive btrfs-on-LUKS array manager
# Copyright (C) 2026  Jonathan Hull <ib_gh_private_1o3naoi3aj3@foobox.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# raid-tool.sh — interactive manager for a btrfs-on-LUKS array.
#
# All site-specific settings (label, mountpoints, NFS unit, members, etc.)
# live in raid.conf, which is SOURCED as bash. Copy raid.conf.example to
# raid.conf and edit it. Override the path with RAID_CONF=/path.
#
# Safety model:
#   * scan() rebuilds all state before each action — never acts on stale maps.
#   * Destructive ops (test/format/remove) REFUSE any disk that is an array
#     member OR backs a mounted fs / swap / the OS, then still require you to
#     type that disk's serial to proceed.
#   * The LUKS layer is auto-closed before raw-disk operations.
#   * Passphrase is prompted once and cached for the session only.
#
# Needs: util-linux, btrfs-progs, cryptsetup, gdisk, e2fsprogs(badblocks),
#        smartmontools. Missing tools are reported per-feature.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; Z=$'\e[0m'
else R=''; G=''; Y=''; C=''; B=''; Z=''; fi
say()  { printf '%s\n' "$*"; }
hd()   { printf '\n%s== %s ==%s\n' "$C$B" "$*" "$Z"; }
warn() { printf '%sWARN:%s %s\n' "$Y" "$Z" "$*"; }
err()  { printf '%sERROR:%s %s\n' "$R" "$Z" "$*" >&2; }
ok()   { printf '%sok%s %s\n' "$G" "$Z" "$*"; }
pause(){ read -rsp $'\nPress Enter to continue…' _; echo; }
have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || { err "'$1' not installed — feature unavailable."; return 1; }; }

[[ $EUID -eq 0 ]] || { err "run as root"; exit 1; }
trap 'unset PASSPHRASE 2>/dev/null' EXIT

# ---- load config --------------------------------------------------------
RAID_CONF="${RAID_CONF:-$SCRIPT_DIR/raid.conf}"
[[ -r $RAID_CONF ]] || { err "config not found: $RAID_CONF — copy raid.conf.example to raid.conf"; exit 1; }
# shellcheck source=/dev/null
source "$RAID_CONF" || { err "failed to source $RAID_CONF"; exit 1; }
RAID_LABEL="${RAID_LABEL:-RAID}"
RAID_MIN_DEVICES="${RAID_MIN_DEVICES:-3}"
: "${RAID_MNT:?RAID_MNT not set in $RAID_CONF}"
[[ ${RAID_MOUNTS+x} ]]           || RAID_MOUNTS=("$RAID_MNT")
[[ ${RAID_LUKS_FORMAT_OPTS+x} ]] || RAID_LUKS_FORMAT_OPTS=(--type luks2)
RAID_NFS_UNIT="${RAID_NFS_UNIT-nfs-server}"

PASSPHRASE=""
get_pass() {
  [[ -n $PASSPHRASE ]] && return 0
  read -rsp "LUKS passphrase (cached for this session): " PASSPHRASE; echo
  [[ -n $PASSPHRASE ]] || { err "empty passphrase"; return 1; }
}
require_members() {
  if ! declare -p RAID_MEMBERS >/dev/null 2>&1 || (( ${#RAID_MEMBERS[@]} == 0 )); then
    err "no RAID_MEMBERS defined in $RAID_CONF"; return 1; fi
  return 0
}

# ---- live state, rebuilt by scan() -------------------------------------
declare -gA MEMBER_DEVID MEMBER_MAPPER PROTECTED LUKS_ON
phys_of() { lsblk -s -n -r -o NAME,TYPE "$1" 2>/dev/null | awk '$2=="disk"{print $1}'; }

scan() {
  MEMBER_DEVID=(); MEMBER_MAPPER=(); PROTECTED=(); LUKS_ON=()
  local dev id d src m n mapper

  if mountpoint -q "$RAID_MNT"; then
    while read -r dev id; do
      dev=${dev%,}
      mapper=$(lsblk -no NAME "$dev" 2>/dev/null | head -1)
      for d in $(phys_of "$dev"); do
        MEMBER_DEVID[$d]=$id; MEMBER_MAPPER[$d]=$mapper; PROTECTED[$d]=1
      done
    done < <(btrfs device usage "$RAID_MNT" 2>/dev/null | awk '/ID:/{print $1, $3}')
  fi

  while read -r src; do
    src=${src%%\[*}
    [[ $src == /dev/* ]] || continue
    for d in $(phys_of "$src"); do PROTECTED[$d]=1; done
  done < <(findmnt -rno SOURCE | sort -u)

  while read -r src _; do
    [[ $src == /dev/* ]] || continue
    for d in $(phys_of "$src"); do PROTECTED[$d]=1; done
  done < <(tail -n +2 /proc/swaps 2>/dev/null)

  for m in /dev/mapper/*; do
    n=$(basename "$m"); [[ $n == control ]] && continue
    dmsetup table "$n" 2>/dev/null | grep -q ' crypt ' || continue
    for d in $(phys_of "$m"); do LUKS_ON[$d]="$n"; done
  done
}

role_of() {
  local d=$1
  if   [[ -n ${MEMBER_DEVID[$d]:-} ]]; then printf 'array devid %s' "${MEMBER_DEVID[$d]}"
  elif [[ -n ${PROTECTED[$d]:-}   ]]; then printf 'in-use (mounted/OS/swap)'
  elif [[ -n ${LUKS_ON[$d]:-}     ]]; then printf 'luks open, idle'
  else printf '%sSPARE%s' "$G" "$Z"; fi
}

list_disks() {
  hd "Block devices"
  printf '%-5s %-5s %-8s %-18s %-22s %s\n' DISK TRAN SIZE MODEL SERIAL ROLE
  local line NAME TRAN SIZE MODEL SERIAL
  while IFS= read -r line; do
    eval "$line"
    printf '%-5s %-5s %-8s %-18.18s %-22.22s %s\n' \
      "$NAME" "${TRAN:--}" "$SIZE" "${MODEL:--}" "${SERIAL:--}" "$(role_of "$NAME")"
  done < <(lsblk -dn -P -o NAME,TRAN,SIZE,MODEL,SERIAL)
}

members_table() {
  local d
  for d in "${!MEMBER_DEVID[@]}"; do
    printf '  devid %-3s /dev/%-4s %s  [%s]\n' "${MEMBER_DEVID[$d]}" "$d" \
      "$(lsblk -dno SERIAL /dev/"$d")" "${MEMBER_MAPPER[$d]}"
  done | sort -k2 -n
}

# ---- guards -------------------------------------------------------------
guard_destructive() {
  local d=$1
  if [[ -n ${MEMBER_DEVID[$d]:-} ]]; then
    err "/dev/$d is ARRAY devid ${MEMBER_DEVID[$d]} — refusing."; return 1; fi
  if [[ -n ${PROTECTED[$d]:-} ]]; then
    err "/dev/$d backs a mounted fs / swap / OS — refusing."; return 1; fi
  return 0
}
confirm_serial() {
  local d=$1 serial want
  serial=$(lsblk -dno SERIAL /dev/"$d" 2>/dev/null)
  [[ -n $serial ]] || { err "no serial readable for /dev/$d — aborting for safety."; return 1; }
  printf '%sType the serial of /dev/%s to confirm:%s ' "$B" "$d" "$Z"; read -r want
  [[ $want == "$serial" ]] || { err "serial mismatch — aborting."; return 1; }
  return 0
}
pick_disk() { local p=${1:-"Disk (e.g. sde)"}; read -rp "$p: " REPLY_DISK; REPLY_DISK=${REPLY_DISK#/dev/}; [[ -b /dev/$REPLY_DISK ]] || { err "no such block device"; return 1; }; }
close_luks_on() {
  local d=$1
  [[ -n ${LUKS_ON[$d]:-} ]] || return 0
  say "Closing LUKS mapper ${LUKS_ON[$d]} on /dev/$d …"
  cryptsetup close "${LUKS_ON[$d]}" || { err "close failed (mapper busy?)"; return 1; }
  ok "closed"
}
start_nfs() {
  [[ -n $RAID_NFS_UNIT ]] || return 0
  if systemctl is-active --quiet "$RAID_NFS_UNIT"; then ok "$RAID_NFS_UNIT (running)"
  elif systemctl start "$RAID_NFS_UNIT"; then ok "$RAID_NFS_UNIT"
  else err "failed to start $RAID_NFS_UNIT"; fi
}

# ---- u: unlock & mount --------------------------------------------------
action_unlock() {
  require_members || { pause; return; }
  hd "Unlock & mount ${RAID_LABEL} (${#RAID_MEMBERS[@]} members)"
  local uuid dev missing=()
  for uuid in "${!RAID_MEMBERS[@]}"; do
    dev=/dev/disk/by-uuid/$uuid
    if [[ ! -e $dev ]] || [[ "$(blkid -o value -s TYPE "$dev" 2>/dev/null)" != crypto_LUKS ]]; then
      missing+=("$uuid -> ${RAID_MEMBERS[$uuid]}"); fi
  done
  if (( ${#missing[@]} )); then
    err "missing or non-LUKS members:"; printf '  %s\n' "${missing[@]}"; pause; return; fi
  get_pass || { pause; return; }
  local fail=0 name
  for uuid in "${!RAID_MEMBERS[@]}"; do
    name=${RAID_MEMBERS[$uuid]}
    if [[ -e /dev/mapper/$name ]]; then ok "$name (already open)"; continue; fi
    if printf '%s' "$PASSPHRASE" | cryptsetup luksOpen /dev/disk/by-uuid/"$uuid" "$name"; then
      ok "$name"
    else
      err "$name failed to open"; fail=1; fi
  done
  (( fail )) && { err "not mounting — some members failed to open"; pause; return; }
  local mp
  for mp in "${RAID_MOUNTS[@]}"; do
    if mountpoint -q "$mp"; then ok "$mp (already mounted)"
    elif mount "$mp"; then ok "$mp"
    else err "mount $mp failed"; pause; return; fi
  done
  start_nfs
  ok "${RAID_LABEL} unlocked & mounted"
  pause
}

# ---- L: lock & unmount --------------------------------------------------
action_lock() {
  require_members || { pause; return; }
  warn "This stops ${RAID_NFS_UNIT:-<no NFS unit>}, unmounts the array, and closes all member LUKS mappers."
  local f; read -rp "Type LOCK to proceed: " f
  [[ $f == LOCK ]] || { err "cancelled"; pause; return; }
  if [[ -n $RAID_NFS_UNIT ]]; then
    if systemctl stop "$RAID_NFS_UNIT" 2>/dev/null; then ok "stopped $RAID_NFS_UNIT"; else warn "$RAID_NFS_UNIT not stopped (was it running?)"; fi
  fi
  local mp busy=0
  for mp in "${RAID_MOUNTS[@]}"; do
    mountpoint -q "$mp" || continue
    if umount "$mp"; then ok "umount $mp"; else err "umount $mp failed (in use?)"; busy=1; fi
  done
  (( busy )) && { err "leaving LUKS open because a mount is still busy — free it and retry."; pause; return; }
  local name
  for name in "${RAID_MEMBERS[@]}"; do
    [[ -e /dev/mapper/$name ]] || continue
    if cryptsetup close "$name"; then ok "closed $name"; else err "close $name failed (still in use?)"; fi
  done
  ok "${RAID_LABEL} locked"
  pause
}

# ---- 1: list -----------------------------------------------------------
action_list() { scan; list_disks; pause; }

# ---- 2: array status ---------------------------------------------------
action_status() {
  scan
  mountpoint -q "$RAID_MNT" || { err "$RAID_MNT not mounted — use option 'u' to unlock"; pause; return; }
  hd "Filesystem"; btrfs filesystem show "$RAID_MNT"
  hd "Usage";      btrfs filesystem usage -T "$RAID_MNT" 2>/dev/null | head -n 20
  hd "Per-device";  btrfs device usage "$RAID_MNT"
  hd "Error counters"; btrfs device stats "$RAID_MNT" | grep -v ' 0$' || ok "all counters zero"
  hd "Scrub"; btrfs scrub status "$RAID_MNT" 2>/dev/null | sed -n '1,6p'
  hd "devid -> disk"; members_table
  pause
}

# ---- 3: test a drive ---------------------------------------------------
action_test() {
  need badblocks || { pause; return; }
  scan; list_disks
  pick_disk "Disk to TEST" || { pause; return; }
  local d=$REPLY_DISK
  guard_destructive "$d" || { pause; return; }
  hd "Test type"
  say "  1) DESTRUCTIVE write test  (badblocks -b 4096 -c 65536 -wsv) — ERASES the disk"
  say "  2) read-only test          (badblocks -b 4096 -c 65536 -sv)"
  read -rp "> " t
  [[ $t == 1 || $t == 2 ]] || { err "cancelled"; pause; return; }
  close_luks_on "$d" || { pause; return; }
  scan
  if [[ $t == 1 ]]; then
    warn "This destroys ALL data (incl. any LUKS header) on /dev/$d."
    confirm_serial "$d" || { pause; return; }
  fi
  local log
  log="/var/log/badblocks_${d}_$(date +%F_%H%M).log"
  say "Logging to $log. Large disks take many hours — consider running this"
  say "under tmux/screen so it survives a dropped session."
  read -rp "Proceed? [y/N] " g; [[ $g == y ]] || { err "cancelled"; pause; return; }
  if [[ $t == 1 ]]; then
    badblocks -b 4096 -c 65536 -wsv "/dev/$d" 2>&1 | tee "$log"
  else
    badblocks -b 4096 -c 65536 -sv  "/dev/$d" 2>&1 | tee "$log"
  fi
  ok "done — results in $log"
  pause
}

# ---- 4: scrub ----------------------------------------------------------
action_scrub() {
  mountpoint -q "$RAID_MNT" || { err "$RAID_MNT not mounted"; pause; return; }
  hd "Scrub"
  say "  1) start (background)   2) status   3) stop/cancel"
  read -rp "> " s
  case $s in
    1) btrfs scrub start "$RAID_MNT" && ok "started — check status with option 2" ;;
    2) btrfs scrub status "$RAID_MNT" ;;
    3) btrfs scrub cancel "$RAID_MNT" && ok "cancelled" ;;
    *) err "cancelled" ;;
  esac
  pause
}

# ---- 5: manage (format/add/remove) -------------------------------------
action_manage() {
  hd "Manage drives"
  say "  1) Format a new drive, LUKS, and ADD to the array"
  say "  2) REMOVE a drive from the array (btrfs remove + luksClose)"
  say "  3) Wipe/format a SPARE only (no array involvement)"
  read -rp "> " m
  case $m in 1) manage_add ;; 2) manage_remove ;; 3) manage_wipe ;; *) err "cancelled"; pause ;; esac
}

manage_add() {
  local t
  for t in sgdisk cryptsetup partprobe btrfs; do need "$t" || { pause; return; }; done
  mountpoint -q "$RAID_MNT" || { err "$RAID_MNT not mounted"; pause; return; }
  scan; list_disks
  pick_disk "New drive to add" || { pause; return; }
  local d=$REPLY_DISK
  guard_destructive "$d" || { pause; return; }
  close_luks_on "$d" || { pause; return; }; scan
  local model serial size mapper part x
  model=$(lsblk -dno MODEL /dev/"$d" | tr -s ' ' '_' | tr -cd 'A-Za-z0-9_')
  serial=$(lsblk -dno SERIAL /dev/"$d")
  size=$(lsblk -dno SIZE /dev/"$d")
  mapper="luks_$(echo "$size" | tr -d '.' | tr 'TG' 'tg')b_${model}_${serial}"
  read -rp "Mapper name [$mapper]: " x; [[ -n $x ]] && mapper=$x
  part="/dev/${d}1"
  hd "Planned actions on /dev/$d ($model $serial)"
  say "  sgdisk --zap-all /dev/$d"
  say "  sgdisk -n 1:0:0 -c 1:primary /dev/$d"
  say "  cryptsetup -q luksFormat ${RAID_LUKS_FORMAT_OPTS[*]} $part"
  say "  cryptsetup open $part $mapper"
  say "  btrfs device add /dev/mapper/$mapper $RAID_MNT"
  warn "This ERASES /dev/$d completely."
  confirm_serial "$d" || { pause; return; }
  get_pass || { pause; return; }
  local f
  read -rp "Final confirm — type ADD: " f; [[ $f == ADD ]] || { err "cancelled"; pause; return; }
  sgdisk --zap-all "/dev/$d"             || { err "zap failed"; pause; return; }
  sgdisk -n 1:0:0 -c 1:primary "/dev/$d" || { err "partition failed"; pause; return; }
  partprobe "/dev/$d"; udevadm settle; sleep 1
  printf '%s' "$PASSPHRASE" | cryptsetup -q luksFormat "${RAID_LUKS_FORMAT_OPTS[@]}" "$part" || { err "luksFormat failed"; pause; return; }
  printf '%s' "$PASSPHRASE" | cryptsetup open "$part" "$mapper" || { err "luksOpen failed"; pause; return; }
  btrfs device add "/dev/mapper/$mapper" "$RAID_MNT" || { err "btrfs add failed"; pause; return; }
  ok "added /dev/mapper/$mapper to $RAID_MNT"
  local partuuid
  partuuid=$(blkid -o value -s UUID "$part")
  warn "Add this member to RAID_MEMBERS in $RAID_CONF so it unlocks at boot:"
  say  "   [$partuuid]=$mapper"
  local b
  read -rp "Run a data balance now to spread existing data? [y/N] " b
  if [[ $b == y ]]; then
    if btrfs balance start --bg -dlimit=20 "$RAID_MNT"; then
      ok "balance started (limited, running in background)"
      say "Check progress: menu → 7 → 3, or run: btrfs balance status $RAID_MNT"
    fi
  fi
  pause
}

manage_remove() {
  scan
  mountpoint -q "$RAID_MNT" || { err "$RAID_MNT not mounted"; pause; return; }
  local count=${#MEMBER_DEVID[@]}
  hd "Current members ($count)"; members_table
  if (( count <= RAID_MIN_DEVICES )); then
    err "profile minimum is $RAID_MIN_DEVICES devices; only $count present — refusing removal."; pause; return
  fi
  local rid tgt="" mapper="" d
  read -rp "devid to remove: " rid
  for d in "${!MEMBER_DEVID[@]}"; do
    [[ ${MEMBER_DEVID[$d]} == "$rid" ]] && { tgt=$d; mapper=${MEMBER_MAPPER[$d]}; }
  done
  [[ -n $tgt ]] || { err "no member with devid $rid"; pause; return; }
  warn "btrfs will relocate all data off devid $rid onto the remaining $((count-1)) disks."
  warn "This can take a long time and needs free space elsewhere."
  confirm_serial "$tgt" || { pause; return; }
  local f
  read -rp "Final confirm — type REMOVE: " f; [[ $f == REMOVE ]] || { err "cancelled"; pause; return; }
  btrfs device remove "/dev/mapper/$mapper" "$RAID_MNT" || { err "btrfs remove failed"; pause; return; }
  ok "removed from array"
  cryptsetup close "$mapper" 2>/dev/null && ok "closed LUKS $mapper"
  warn "Remove its line from RAID_MEMBERS in $RAID_CONF (mapper: $mapper)."
  local w
  read -rp "Wipe LUKS/fs signatures on /dev/$tgt now? [y/N] " w
  if [[ $w == y ]]; then wipefs -a "/dev/$tgt" && ok "wiped"; fi
  pause
}

manage_wipe() {
  scan; list_disks
  pick_disk "SPARE to wipe/format" || { pause; return; }
  local d=$REPLY_DISK
  guard_destructive "$d" || { pause; return; }
  close_luks_on "$d" || { pause; return; }
  warn "This erases all partitions/signatures on /dev/$d."
  confirm_serial "$d" || { pause; return; }
  local f
  read -rp "Type WIPE: " f; [[ $f == WIPE ]] || { err "cancelled"; pause; return; }
  wipefs -a "/dev/$d" && sgdisk --zap-all "/dev/$d" && ok "wiped /dev/$d"
  pause
}

# ---- 6: SMART ----------------------------------------------------------
action_smart() {
  need smartctl || { pause; return; }
  scan; list_disks
  pick_disk "Disk for SMART" || { pause; return; }
  hd "SMART health /dev/$REPLY_DISK"
  smartctl -H "/dev/$REPLY_DISK"
  smartctl -A "/dev/$REPLY_DISK" | sed -n '1,25p'
  pause
}

# ---- 7: balance --------------------------------------------------------
action_balance() {
  mountpoint -q "$RAID_MNT" || { err "$RAID_MNT not mounted"; pause; return; }
  hd "Balance"
  say "  1) start (data, limited: -dlimit=20)   2) start (full data)   3) status   4) cancel"
  read -rp "> " b
  case $b in
    1) if btrfs balance start --bg -dlimit=20 "$RAID_MNT"; then
         ok "started (limited, running in background)"
         say "Check progress: menu → 7 → 3, or run: btrfs balance status $RAID_MNT"
       fi ;;
    2) local f
       read -rp "Full balance can run long. Type BALANCE: " f
       if [[ $f == BALANCE ]]; then
         if btrfs balance start --bg "$RAID_MNT"; then
           ok "started (running in background)"
           say "Check progress: menu → 7 → 3, or run: btrfs balance status $RAID_MNT"
         fi
       else
         err "cancelled"
       fi ;;
    3) btrfs balance status "$RAID_MNT";;
    4) btrfs balance cancel "$RAID_MNT" && ok "cancelled";;
    *) err "cancelled";;
  esac
  pause
}

# ---- menu --------------------------------------------------------------
menu() {
  clear 2>/dev/null || true
  printf '%s%s  %s RAID tool%s   (%s)\n' "$B" "$C" "$RAID_LABEL" "$Z" "$RAID_MNT"
  if mountpoint -q "$RAID_MNT"; then printf '  status: %smounted%s\n' "$G" "$Z"
  else printf '  status: %sNOT mounted%s\n' "$R" "$Z"; fi
  cat <<MENU

  u) Unlock & mount array
  L) Lock & unmount array

  1) List all drives
  2) Array status
  3) Test a drive (badblocks) — write mode is DESTRUCTIVE
  4) Scrub (start/status/stop)
  5) Manage drives (format / add / remove)
  6) SMART health
  7) Balance (start/status/stop)
  q) Quit
MENU
  read -rp $'\nSelect: ' choice
  case $choice in
    u|U) action_unlock ;;  l|L) action_lock ;;
    1) action_list ;;   2) action_status ;;  3) action_test ;;
    4) action_scrub ;;  5) action_manage ;;  6) action_smart ;;
    7) action_balance ;; q|Q) exit 0 ;;
    *) : ;;
  esac
}

while true; do menu; done
