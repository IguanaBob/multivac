# multivac

Interactive management for a **btrfs-on-LUKS** disk array: unlock/mount, health
and status, destructive drive testing, scrub and balance control, and guided
add/remove of encrypted members — with guardrails designed to make it hard to
nuke a live array by accident.

Named for Asimov's Multivac, the computer that spends the life of the universe
fighting entropy (most memorably in *The Last Question*). Bitrot is entropy
too, just running on disks instead of galaxies: bits flip, drives degrade, and
left alone a filesystem slowly rots. A btrfs scrub and RAID1C3's extra copies
are the same fight Asimov's machine was fighting — on a much smaller
timescale, and with slightly better odds.

> **License:** AGPL-3.0-or-later. See [LICENSE](LICENSE).

## What's in the box

| File | Purpose |
|------|---------|
| `raid-tool.sh` | Interactive menu: unlock/lock, status, test, scrub, balance, SMART, add/remove drives |
| `unlock-raid.sh` | Standalone unlock → mount → start NFS. Suitable for running at boot |
| `raid.conf.example` | Template config. Copy to `raid.conf` and edit |
| `.gitignore` / `.claudeignore` | Keep the real `raid.conf` (serials, UUIDs) out of git and AI tools |

Both scripts read all site-specific settings from `raid.conf`, so there is a
single source of truth and nothing site-specific is hardcoded.

## Requirements

Linux with: `util-linux` (lsblk, blkid, findmnt), `btrfs-progs`, `cryptsetup`,
`gdisk`, `e2fsprogs` (badblocks), `smartmontools`. Missing tools are reported
per-feature, not at startup. Developed against AlmaLinux/RHEL; nothing is
distro-specific beyond systemd unit names (configurable).

## Install

```sh
git clone https://github.com/IguanaBob/multivac
cd multivac
cp raid.conf.example raid.conf
chmod 600 raid.conf          # it will hold LUKS UUIDs and drive serials
$EDITOR raid.conf            # fill in your array
```

`raid.conf` is git-ignored by design — never commit it.

## Configuration

`raid.conf` is **sourced as bash**, so treat it like a script (root-owned,
not world-writable). Keys:

- `RAID_LABEL` — cosmetic name shown in menus.
- `RAID_MNT` — primary btrfs mountpoint.
- `RAID_MOUNTS` — array of every mountpoint to mount on unlock / unmount on lock.
- `RAID_NFS_UNIT` — systemd unit to start/stop with the array; `""` to disable.
- `RAID_MIN_DEVICES` — refuse removing a member below this count (RAID1C3 = 3).
- `RAID_LUKS_FORMAT_OPTS` — `cryptsetup luksFormat` options for new drives.
- `RAID_MEMBERS` — associative array of LUKS header UUID → mapper name.

Get a member UUID with `blkid -o value -s UUID /dev/sdX1`.

## Usage

```sh
sudo ./raid-tool.sh
```

Menu: `u` unlock & mount, `L` lock & unmount, then numbered actions for list,
status, badblocks test, scrub, manage (add/remove/wipe), SMART, and balance.

For boot-time unlock without the full menu:

```sh
sudo ./unlock-raid.sh
```

### Adding a drive

`raid-tool.sh` → Manage → *add* partitions, `luksFormat`s, `luksOpen`s, and
`btrfs device add`s the new disk, then prints the `[uuid]=mapper` line to paste
into `RAID_MEMBERS`. It requires typing the target's serial and refuses any disk
that is in the array or backs a mounted filesystem.

### Removing a drive

Manage → *remove* runs `btrfs device remove`, closes the LUKS mapper, and
optionally wipes signatures. It refuses to drop below `RAID_MIN_DEVICES`.

## Safety model

- **State is rescanned before every action** — decisions are never made on stale maps.
- **Destructive ops refuse protected disks** — anything that is an array member or
  backs a mounted filesystem, swap, or the OS is blocked outright.
- **Serial confirmation** — destructive ops require typing the target disk's serial.
- **LUKS auto-close before raw-disk work**, and lock never closes a mapper while
  its mount is still busy.
- **Passphrase is prompted once**, cached for the session only, never written to disk.

## Roadmap

- Non-interactive/`--json` output for read actions, so a web or GUI frontend can
  drive a scriptable core rather than scraping menu text.
- Subcommands (`multivac status`, `multivac unlock`, …) alongside the menu.
- A defined passphrase channel (stdin/keyfile) for headless/automated use.

## Contributing

This started as a personal tool for one specific array, so scope is
deliberately narrow. PRs are welcome, but read [CLAUDE.md](CLAUDE.md) first —
especially the safety invariants section — since anything that weakens a
guardrail there won't be merged even if it "works."

## Contact

Found a bug, security issue, or just want to reach out? Email
ib_gh_private_1o3naoi3aj3@foobox.com.

## License

Copyright (C) 2026 Jonathan Hull &lt;ib_gh_private_1o3naoi3aj3@foobox.com&gt;.
Licensed under the GNU Affero General Public License v3.0 or later
(`AGPL-3.0-or-later`). This program is distributed WITHOUT ANY WARRANTY.
See [LICENSE](LICENSE) for the full text.
