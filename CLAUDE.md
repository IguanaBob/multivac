# CLAUDE.md — orientation for AI coding assistants

This file captures context and invariants for anyone (human or AI) working on
`multivac`. Read it before changing the scripts.

## Why "multivac"

Named after Asimov's Multivac, the computer that spends the life of the
universe fighting entropy (see *The Last Question*). Bitrot — flipped bits,
degrading drives, silent data corruption — is entropy on a disk instead of a
galaxy. Scrubbing and RAID1C3's redundancy are that same fight in miniature.
Keep this in mind for tone: this tool exists to resist decay quietly and
reliably, not to be clever.

## What this project is

Interactive management for a **btrfs-on-LUKS** array on a home/small NAS. The
array is btrfs **RAID1C3** (three copies) whose member devices are `cryptsetup`
LUKS2 containers opened on top of whole-disk GPT partitions (`/dev/sdX1`). The
btrfs filesystem sees `/dev/mapper/<name>` devices, not the raw disks — every
tool that maps members to physical disks must resolve through the dm/LUKS layer
(`lsblk -s` down to `TYPE=disk`). Do not assume btrfs members are raw `/dev/sd*`.

## Repo layout

- `raid-tool.sh` — interactive menu; the main tool.
- `unlock-raid.sh` — standalone unlock→mount→NFS; boot-friendly.
- `raid.conf` — **real config, git-ignored, contains secrets** (see below).
- `raid.conf.example` — committed template with placeholder values.
- `LICENSE` — AGPL-3.0.

Both scripts `source` `raid.conf` (path overridable via `RAID_CONF`) and use
`RAID_*` variables. There is no other source of site config.

## Secret / privacy boundary — do not cross

- `raid.conf` holds LUKS header UUIDs and **drive serial numbers**. It is listed
  in `.gitignore` and `.claudeignore`. **Never** commit it, paste its contents
  into a PR/issue, or echo real serials/UUIDs into committed files or logs.
- Only `raid.conf.example` (all-placeholder) is safe to commit.
- The LUKS passphrase is read at runtime (`read -rs`), cached in a shell variable
  for the session, and `unset` on exit. Never persist it, log it, or add a
  code path that writes it anywhere.

## Safety invariants — MUST NOT regress

These are the reason the tool exists. Any change that weakens one is a bug, even
if it "works":

1. **Rescan before acting.** `scan()` rebuilds the member/protected/luks maps at
   the start of every action. Don't cache across prompts.
2. **Refuse protected disks for destructive ops.** A disk that is an array
   member, or backs any mounted fs / swap / the OS, must be blocked from
   test/format/remove (`guard_destructive`). The protected set is derived live
   from `btrfs device usage`, `findmnt`, and `/proc/swaps` — keep it that way;
   do not hardcode disk names.
3. **Serial confirmation** on every destructive path (`confirm_serial`), on top
   of the guard. Both must pass.
4. **Auto-close LUKS before raw-disk work**, and on lock/unmount **never close a
   mapper whose mount is still busy** — unmount first, bail if a mount is busy,
   only then close.
5. **Minimum-device guard on remove** (`RAID_MIN_DEVICES`) so removal can't drop
   the array below its profile's redundancy floor (RAID1C3 = 3).
6. **Show the exact destructive commands** before running (the add flow prints
   its `sgdisk`/`cryptsetup`/`btrfs` plan), and gate them behind a typed keyword.

## Conventions

- Bash, `set -uo pipefail`. Not `set -e` — errors are handled per-op so the
  interactive loop survives a failed action.
- Must pass `bash -n` **and** `shellcheck` clean. When shellcheck suggests
  quoting a variable that is intentionally word-split (e.g. multi-flag option
  lists), convert it to an array instead of quoting — do not defeat the split.
- No hardcoded site values in the `.sh` files — everything site-specific lives
  in `raid.conf`. Adding a feature that needs config means adding a `RAID_*` key
  with a sane default in the load block and documenting it in
  `raid.conf.example` and the README.
- Colour/formatting is guarded by `[[ -t 1 ]]` so piped output stays clean.

## Testing (no hardware needed for most of it)

- `bash -n raid-tool.sh unlock-raid.sh` — syntax.
- `shellcheck raid-tool.sh unlock-raid.sh` — lint.
- `bash -c 'source raid.conf.example; declare -p RAID_MEMBERS'` — config parses.
- Read-only menu actions (list, status, SMART, scrub status) are safe to run on
  a real box. Destructive actions (test `-w`, add, remove, wipe) are not — never
  run them against a member disk while testing.

## Roadmap / desired direction

The current interface is menu-only, which is awkward to drive from a frontend.
The intended refactor (also what makes AGPL's network clause bite for hosted
forks) is an **engine/interface split**:

- Add non-interactive subcommands (`multivac status`, `multivac unlock`, …) and
  a `--json` output mode for read actions, so a web/GUI backend links against a
  scriptable core instead of scraping menu text.
- Define an explicit passphrase channel (stdin / keyfile / env) for headless use
  — design this deliberately, with the secret-handling rules above in mind.
- Keep the interactive menu as one frontend over that core, not the only entry.

Preserve every safety invariant above through any such refactor.
