#!/usr/bin/env bash
#
# multivac — unlock/mount helper for a btrfs-on-LUKS array
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
# unlock-raid.sh — unlock a btrfs-on-LUKS array's members, mount it, and
# start NFS. Standalone (suitable for boot). Shares all settings with
# raid-tool.sh via raid.conf, so there is ONE source of truth.
#
# Copy raid.conf.example to raid.conf and edit it. Override with RAID_CONF.
#
# Idempotent: already-open containers, already-mounted paths, and an
# already-running NFS server are detected and skipped.
#
# Scope: the data array only. OS-root LUKS and cryptswap are handled by
# systemd at boot, not here.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

if [[ -t 1 ]]; then C_R=$'\e[31m'; C_G=$'\e[32m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else C_R=''; C_G=''; C_C=''; C_0=''; fi
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
info() { printf '%s==>%s %s\n'    "$C_C" "$C_0" "$*"; }
ok()   { printf '  %sok%s   %s\n' "$C_G" "$C_0" "$*"; }
bad()  { printf '  %sfail%s %s\n' "$C_R" "$C_0" "$*"; }

[[ $EUID -eq 0 ]] || die "must run as root"
command -v cryptsetup >/dev/null || die "cryptsetup not found"

# ---- load config --------------------------------------------------------
RAID_CONF="${RAID_CONF:-$SCRIPT_DIR/raid.conf}"
[[ -r $RAID_CONF ]] || die "config not found: $RAID_CONF — copy raid.conf.example to raid.conf"
# shellcheck source=/dev/null
source "$RAID_CONF" || die "failed to source $RAID_CONF"
: "${RAID_MNT:?RAID_MNT not set in $RAID_CONF}"
[[ ${RAID_MOUNTS+x} ]] || RAID_MOUNTS=("$RAID_MNT")
RAID_NFS_UNIT="${RAID_NFS_UNIT-nfs-server}"
declare -p RAID_MEMBERS >/dev/null 2>&1 || die "RAID_MEMBERS not defined in $RAID_CONF"
(( ${#RAID_MEMBERS[@]} )) || die "no members defined in $RAID_CONF"

# ---- preflight: every UUID must exist and be crypto_LUKS ----------------
missing=()
for uuid in "${!RAID_MEMBERS[@]}"; do
  dev="/dev/disk/by-uuid/$uuid"
  if [[ ! -e "$dev" ]] ||
     [[ "$(blkid -o value -s TYPE "$dev" 2>/dev/null)" != crypto_LUKS ]]; then
    missing+=("$uuid -> ${RAID_MEMBERS[$uuid]}")
  fi
done
if (( ${#missing[@]} )); then
  printf 'Missing or non-LUKS members:\n'; printf '  %s\n' "${missing[@]}"
  die "resolve the above before unlocking (wrong UUID, or drive absent)"
fi

# ---- prompt once --------------------------------------------------------
read -rs -p "LUKS passphrase: " PW; echo
[[ -n "$PW" ]] || die "empty passphrase"

# ---- open each member (skip if already open) ----------------------------
info "Unlocking ${#RAID_MEMBERS[@]} array members"
fail=0
for uuid in "${!RAID_MEMBERS[@]}"; do
  name="${RAID_MEMBERS[$uuid]}"
  if [[ -e "/dev/mapper/$name" ]]; then ok "$name (already open)"; continue; fi
  if printf '%s' "$PW" | cryptsetup luksOpen "/dev/disk/by-uuid/$uuid" "$name"; then
    ok "$name"
  else
    rc=$?
    bad "$name (cryptsetup rc=$rc$([[ $rc -eq 2 ]] && echo ': bad passphrase'))"
    fail=1
  fi
done
unset PW

(( fail )) && die "one or more members failed to open — not mounting (array would be degraded)"

# ---- mount --------------------------------------------------------------
info "Mounting"
for mp in "${RAID_MOUNTS[@]}"; do
  if mountpoint -q "$mp"; then ok "$mp (already mounted)"
  elif mount "$mp";      then ok "$mp"
  else die "mount $mp failed"; fi
done

# ---- NFS ----------------------------------------------------------------
if [[ -n $RAID_NFS_UNIT ]]; then
  info "Starting NFS"
  if systemctl is-active --quiet "$RAID_NFS_UNIT"; then ok "$RAID_NFS_UNIT (already running)"
  elif systemctl start "$RAID_NFS_UNIT";           then ok "$RAID_NFS_UNIT"
  else die "failed to start $RAID_NFS_UNIT"; fi
fi

info "All operations complete"
exit 0
