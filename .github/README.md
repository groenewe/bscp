# Bscp — Secure and efficient copying of block devices

> **This is a fork.**  It builds on, and is inspired by, the original
> [bscp](https://github.com/bscp-tool/bscp) by Volker Diels-Grabsch
> ([vog/bscp](https://github.com/vog/bscp)).  Maintained at
> `https://github.com/groenewe/bscp`; see [Credits](#credits).

Bscp copies a single file or block device over SSH, transferring only the
blocks that have changed.  It fills the gap where `rsync` fails — most
notably when the source or destination is a raw block device.  When both
paths are local (neither is a `HOST:path`) it does the same block-diff copy
directly between them, no SSH involved.

No server-side installation is required: the remote-side script is embedded
in the client and executed via `python(/2/3) -c` over the SSH connection,
with a Perl fallback for hosts that have no Python interpreter.

## Requirements

Python 3 on the local host and Python 2/3 *or* Perl 5.10+ on the remote
host.  SSH access to the remote host.  (For a **local-to-local** copy there
is no remote host — the same block-diff engine runs as a local subprocess —
but the local host must then itself have Python 2/3 or Perl 5.10+, since it
plays both roles.)  The optional `--verify` cross-check
additionally needs [`b3sum`](https://github.com/BLAKE3-team/BLAKE3) on each
side it runs on (it warns and skips where missing), plus `dd` on the larger
side when the two devices differ in size (used to hash only the common prefix).
Unsure whether a host has what a run needs?  `bscp --check-tools SRC DST`
(or add `-v` to any real run) reports `dd`/`b3sum` availability on both ends
and the remote connection method before doing anything.

**Runs almost anywhere.**  The remote side needs no installation and speaks
the same protocol whether it runs under `python3`, `python2`/`python`, or
Perl — so it works on ancient appliances and minimal images as well as
modern hosts.  On the local side you have three options when Python 3 is
inconvenient:

- **Single-file binary** — `bscp` can be compiled with Nuitka into one
  self-contained executable that embeds the interpreter, so the client host
  needs no Python at all.  Not shipped — build your own; see
  [docs/nuitka.md](../docs/nuitka.md).
- **`bscp.python2`** — a parallel client that runs under Python 2.7 *or* 3.x,
  for legacy hosts with no Python 3.  See
  [docs/python2-client.md](../docs/python2-client.md).
- The remote execution model (interpreter dispatch, the Perl fallback,
  multi-threaded hashing) is documented in
  [docs/remote-execution.md](../docs/remote-execution.md).

By default bscp passes `-o ServerAliveInterval=15 -o ServerAliveCountMax=4`
to ssh so a silently-dropped TCP connection is detected within about 60
seconds instead of hanging indefinitely; combined with `--retries N` this
auto-recovers from transient network failures.  Override with your own
`-o ServerAliveInterval=...` (or set it to `0` to disable) if needed —
user-supplied `-o` takes precedence.

## Usage

```
bscp [options] SRC DST

push:   bscp [options] local_file        HOST:remote_file
pull:   bscp [options] HOST:remote_file  local_file
local:  bscp [options] local_src         local_dst          (no ssh)
```

`SRC` and `DST` can be a regular file or a block device (`/dev/sdX`).  At
most one of them may be a `HOST:path` argument; which side carries the
`HOST:` prefix determines the direction.  With **no** `HOST:` on either side
the copy is local-to-local: bscp block-diffs one local path into the other
with no SSH, no network, and no interactive login to `localhost`.  Giving a
`HOST:` prefix to *both* sides (remote-to-remote) is not supported and exits
with status 2.

> **Same-disk caution.**  A local-to-local copy reads the source and writes
> the destination at the same time.  When both live on **one physical
> device** — two partitions of the same disk, or two files on the same
> filesystem — the two streams contend for it, and on a rotational disk
> (HDD) the head seeks constantly between the read and write regions,
> running far slower than a copy between separate disks.  Bscp detects this
> (best-effort, Linux) and prints a warning, but does not refuse.

The destination file or device **must already exist**.  By default it must
also be at least as large as the source (or, when `-B` is used, at least as
large as the requested limit); pass `--allow-truncate` to copy only the
prefix that fits.

### Options

| Flag                          | Default  | Description                                                                                                      |
| ----------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------- |
| `-b SIZE` / `--block-size`    | `64K`    | Comparison/transfer granularity. Supports `K`/`M`/`G` suffixes.                                                  |
| `-s SIZE` / `--section-size`  | `10G`    | File is processed in sections of this size. Bounds peak memory to roughly `diff_blocks_per_section × blocksize`. |
| `-a ALGO` / `--algorithm`     | `sha256` | Hash algorithm. `md5`, `sha1`, `sha224`, `sha256`, `sha384`, `sha512` work on every remote (python3/python2/Perl). Other `hashlib` algorithms (`sha3_256`, `blake2b`, …) need a python3/python2 remote with that algorithm; the Perl remote supports only the six portable ones. `bscp -h` lists the full set available on the local host. |
| `-r OFFSET` / `--resume-from` | `0`      | Skip ahead to this byte offset, or to `NN%` / `NN.N%` of the local file (rounded down to a section boundary).    |
| `-R N` / `--retries`          | `3`      | Automatically retry on connection failure, up to N times, with exponential back-off (`0` disables).              |
| `--io-timeout SECS`           | `0`      | Abort (engaging `--retries`) if no SSH-pipe I/O progress for SECS seconds. Catches stuck remote process or | hung disk while TCP is still alive. `0` disables, falling back to the SSH keepalive (~60s). |
| `--bwlimit RATE`              | `0`      | Limit network I/O to RATE bytes per second (`K`/`M`/`G`/`T` suffix accepted, e.g. `--bwlimit 5M`); both directions combined. `0` = unlimited. The rate is measured on the data handed to `ssh` (pre-compression), so with `-C` the actual wire usage stays at or below RATE — lower for compressible data. For raw block devices (incompressible) the two coincide. |
| `-i FILE` / `--identity`      |          | SSH identity file (`-i FILE`).                                                                                   |
| `-o OPT` / `--ssh-opt`        |          | Extra SSH option, repeatable (passed as `-o OPT`). Takes precedence over the defaults below.                     |
| `-C` / `--compress`           |          | Enable SSH compression. Often a big win over a bandwidth-limited WAN link; usually a slowdown on a fast LAN (compression CPU cost outweighs the bandwidth saved). Enable for remote/WAN copies, leave off on local ones. |
| `-N` / `--dry-run`            |          | Count differing blocks and their total size in bytes only; do not update destination.                            |
| `-B N` / `--block-count`      | `0`      | Limit sync to the first N blocks (0 = no limit). A `K`/`M`/`G`/`T` suffix interprets the value as bytes, rounded up to whole blocks (e.g. `-B 4M`). A warning is printed if the limit exceeds the source size. |
| `--allow-truncate`            |          | Allow the destination to be smaller than the source (or, with `-B`, smaller than the requested limit); only the bytes that fit are copied. |
| `--ignore-read-errors`        |          | **Experimental, experts only. Pull only.** Do not abort when a block of the **local destination** cannot be read during the scan (`EIO`). The unreadable block is treated as a difference and overwritten from the readable remote source — on a copy-on-write filesystem (e.g. bcachefs) this rewrites a CRC-bad extent and makes the region readable again. One warning naming the block offset is printed per affected block. Scope is deliberately narrow: only **local reads**, only the **scan phase**, only **pull** (where the local file is the destination). Write errors stay fatal, and push (local is the source, with no good data to substitute) is unaffected. Meant to recover a handful of bad blocks; many errors mean a failing device, not a job for this flag. Re-run or add `--verify` afterwards to confirm the repair. |
| `--buffer`                    |          | Push: buffer differing blocks in memory during phase B instead of re-reading them from disk. | Higher memory use, fewer disk reads. Experimental. Auto-disabled if available memory is too low. |
| `-T N` / `--hash-threads`     | `0`      | Threads used to hash blocks during the scan phase, on both client and remote (`0` = auto: `min(cores, 4)`). An explicit `N` is clamped to each side's own core count, so `-T 8` to a 4-core remote runs 4 threads there. | Speeds up scanning when hashing is CPU-bound (fast NVMe/local). python2 and Perl remotes stay single-threaded. |
| `-q` / `--quiet`              |          | Suppress scan/copy progress lines. Errors and warnings are still shown.                                          |
| `-v` / `--verbose`            |          | Report external-tool availability (`dd`, `b3sum`) on the local **and** remote ends, plus the remote connection method (`python3`/`python2`/`perl`), then proceed with the transfer. The remote findings are echoed to stderr by the SSH wrapper itself (no protocol change). Suppressed under `--batch`. |
| `--check-tools`               |          | Like `-v`, but exit after reporting **without transferring anything** — a connection/tooling diagnostic. Honors `--batch` (silent; rely on the exit status: `0` = reported, `1` = connection failed). |
| `--batch`                     |          | Suppress all stderr output; use the exit status to detect errors (implies `-q`). | Cannot convey a resume offset — use `-q` instead if a caller needs to parse the "Resume with:" stderr line. |
| `-p PORT` / `--port`          | `22`     | SSH port.                                                                                                        |
| `--verify`                    |          | After copying, run `b3sum` on the local and (when present) remote file **concurrently**, printing each digest the moment its side finishes (so the first hash is recorded without waiting on the slower side), with a live countdown between them (estimated from the scan time). Compare them and report OK / mismatch (**exit 4** on mismatch). Only the bytes bscp actually copied — the prefix `[0, sync_size)` — are compared: when the devices differ in size, or `-B` capped the copy, every side **larger** than that prefix is piped through `dd bs=… count=…` (block size chosen near 1&nbsp;MiB) so both ends hash the same bytes — the report shows the `dd … \| b3sum` form used. A `-B` copy that leaves source data uncopied also prints an **incomplete-backup warning**. A convenience BLAKE3 cross-check, independent of `-a`; warns and skips where `b3sum` is missing on either side, or the copied prefix admits no efficient `dd` block size (or `dd` is absent on a side that needs it). The remote `b3sum` runs under the same SSH keepalive as the transfer, so a long hash does not drop the connection. Under `-N` (dry-run) it runs only when the scan found zero diffs — an independent confirmation that source and destination already match. Under `--batch` a verify that cannot be performed exits `5` (so a suppressed-warning skip is not mistaken for success). |

### Examples

```bash
# Push a local disk image to a remote server
bscp /var/backups/disk.img backup-server:/data/disk.img

# Pull a remote block device to a local image file
bscp root@storage:/dev/sdb /mnt/images/sdb.img

# Local-to-local: refresh a backup image on another disk, no SSH.
# Only the changed blocks are written — cheap re-runs, kind to the SSD.
bscp /dev/sda /mnt/backup-disk/sda.img

# Dry-run: see how many blocks differ without copying
bscp -N /dev/sda myhost:/dev/sda

# Check which tools each end has (dd, b3sum) and how the remote is reached,
# without transferring anything — a pre-flight diagnostic
bscp --check-tools /dev/sda myhost:/dev/sda
#   bscp-local:  dd=yes b3sum=yes
#   bscp-remote: dd=yes b3sum=no
#   bscp-remote: interpreter=python3 (multi-threaded, hash_threads=auto)

# Or report the same up front, then run the copy anyway
bscp -v --verify /dev/sda myhost:/dev/sda

# Use a smaller section size to limit memory on a constrained host
bscp -s 1G /dev/sda myhost:/dev/sda

# Resume an interrupted push from where it failed
bscp --resume-from 42949672960 /dev/sda myhost:/dev/sda

# Or, more conveniently, resume from a percentage of the local file
bscp -r 50% /dev/sda myhost:/dev/sda

# Disable auto-retry on connection failures (default is --retries 3)
bscp --retries 0 /dev/sda myhost:/dev/sda

# Cap network bandwidth at 5 MiB/s (e.g. to leave a WAN link usable)
bscp --bwlimit 5M /dev/sda myhost:/dev/sda

# Limit a long sync to just the first 1 GiB (suffix is bytes, rounded up to blocks)
bscp -B 1G /dev/sda myhost:/dev/sda

# Sync only the prefix that fits when the destination is smaller than the source
bscp --allow-truncate /var/backups/disk.img myhost:/data/disk-half.img

# Copy, then cross-check both ends with an independent BLAKE3 (b3sum) hash
bscp --verify /dev/sda myhost:/dev/sda

# Back a disk up into an LVM logical volume sized to hold it (LVM rounds the LV
# up to a whole extent, so it ends up slightly larger than the source).  The
# destination is big enough, so no --allow-truncate is needed; --verify still
# cross-checks by dd-limiting the larger LV down to the source size, ignoring
# the extent padding.
bscp --verify /dev/sda myhost:/dev/vg0/sda-backup

# Restore that backup: now the larger LV is the source and the smaller device
# the destination, so --allow-truncate IS required.  --verify again dd-limits
# the larger side (the LV being read) so only the restored prefix is compared.
bscp --allow-truncate --verify myhost:/dev/vg0/sda-backup /dev/sda
```

**`--verify` and SSH authentication.**  `--verify` opens a *second* SSH
connection to run `b3sum` on the remote, separate from the transfer.  With
key-based auth (the usual case) this is seamless.  With password / encrypted-
key / 2FA auth it would otherwise prompt a second time — and that prompt
arrives only after the transfer finishes, so a scripted run could appear to
hang.  bscp does not set `ControlMaster`, so enabling SSH connection
multiplexing in `~/.ssh/config` makes both connections share one
authenticated channel (one prompt):

```
Host backup-server
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 60
```

### Environment

| Variable       | Effect                                                                                                   |
| -------------- | -------------------------------------------------------------------------------------------------------- |
| `BSCP_OPTIONS` | Default command-line options, applied *before* the real arguments so an explicit option still overrides them. For per-host tuning you don't want to repeat — e.g. `export BSCP_OPTIONS="-T 8 -b 192K"`. Options only (no `SRC`/`DST`). |

`-T 8` raises the scan to 8 hashing threads — an explicit `-T N` bypasses the
auto-detect cap of `min(cores, 4)` (though still clamped to each side's actual
core count), useful on many-core hosts where `b3sum` otherwise outruns the
scan.  `-b 192K` widens the block size, which can lift
throughput on fast devices — but a larger block is a *coarser* comparison
unit, so it increases the data re-sent per changed region, the write wear on
the destination, and the size of a sparse destination file.  Tune with that
tradeoff in mind.

### Exit status

| Code  | Meaning                                                                  |
| ----- | -------------------------------------------------------------------------|
| `0`   | Transfer completed successfully (or dry-run finished).                   |
| `1`   | Fatal error — remote file not accessible, size mismatch, or SSH failure. |
| `2`   | Bad arguments or usage error.                                            |
| `3`   | Connection lost — transfer incomplete; re-run with `--resume-from`.      |
| `4`   | Verification mismatch — `--verify` found the local and remote b3sum digests differ. |
| `5`   | Verification not performed under `--batch` — `--verify` could not compare (`b3sum`/`dd` missing or failing on either side, or the copied prefix admits no efficient `dd` block size). |
| `130` | Interrupted by user (Ctrl+C).                                            |

## How it works

For each **section** of the file:

1. **Hash exchange** — the remote side reads its blocks sequentially and
   streams a hash digest for each one.  The local side reads its own blocks
   in parallel, compares digests, and records which blocks differ.

2. **Block transfer**:
   - *Push*: the local side sends differing blocks to the remote, which
     writes them at the correct offsets.
   - *Pull*: the local side sends the list of differing offsets; the remote
     reads and streams back the corresponding blocks; the local side writes
     them.

Only differing blocks are transferred.  The section loop keeps peak memory
proportional to the number of differing blocks in one section rather than
the entire file.

Block hashing — the CPU-bound part of the scan on fast storage — is
multi-threaded on both ends when the remote runs Python 3 (see
`--hash-threads`).

The remote helper process is tagged `bscp-remote` on its command line, so
`ps aux | grep bscp-remote` (or an htop search) finds it on the remote host.

See [PROTOCOL.md](../PROTOCOL.md) for the full wire-format specification.

## Use cases

### 1. Off-site disk imaging for hosts with no backup facility

Pull a remote machine's whole system disk — virtual or physical — into a
local image file.  Many budget cloud / dedicated hosters (e.g. Strato.de)
provide no snapshot or backup service of their own; with nothing more than
SSH access you get a full block-level image, and every run after the first
copies only the blocks that changed.

```bash
# First run images the whole disk; later runs are incremental
bscp root@server:/dev/sda /mnt/backup/server-sda.img
```

**Consistency — imaging a live root disk.**  Reading a raw device while its
filesystem is mounted and being written risks a torn image (blocks change
mid-scan).  On Linux, freeze the root device for the duration with
[`overlayroot`](https://manpages.ubuntu.com/manpages/man8/overlayroot.8.html):
install the package and add a dedicated GRUB entry whose kernel command line
includes `overlayroot=tmpfs:recurse=0`.  All root writes are then redirected
to a tmpfs overlay and the underlying device stays read-only and quiescent
("GHOST mode") — safe to image — until you reboot back into the normal
entry.

Put the entry in `/boot/grub/custom.cfg` (GRUB sources it automatically; see
the `source .../custom.cfg` lines near the end of `/boot/grub/grub.cfg`).
The only change versus a normal entry is the added boot parameter on the
`linux` line:

```
menuentry 'GHOST mode (read-only root for imaging)' --class gnu-linux {
        # ... recordfail / load_video / insmod / search --set=root ... as usual ...
        linux   /vmlinuz root=UUID=<your-root-uuid> ro overlayroot=tmpfs:recurse=0 quiet splash
        initrd  /initrd.img
}
```

Boot that entry on the remote host, run the `bscp` pull above against
`/dev/sda`, then reboot into the normal entry.

### 2. SSD-friendly incremental backups (destination longevity)

Because only modified blocks are written, the destination device sees far
fewer writes than a full-copy tool would issue.  On an SSD that directly
extends service life — NAND has a finite number of program/erase cycles — and
it is faster too: writing is typically slower than reading, and `bscp` reads
both sides but writes only the differences.  Re-imaging a mostly-unchanged
disk touches almost nothing on the destination.

### 3. Compressed, sparse, mountable backup images (ZFS, bcachefs, …)

Write the image onto a filesystem with compression enabled (ZFS, bcachefs,
btrfs).  Pre-create the destination as a sparse file and let `bscp` overwrite
it in place:

```bash
# Create a sparse destination the size of the source, then image into it
truncate -s 500G /tank/backups/server-sda.img      # /tank = ZFS, compression=on
bscp root@server:/dev/sda /tank/backups/server-sda.img
```

Three space wins stack up:

- **Filesystem compression** shrinks the stored image.
- **All-zero blocks** — unused regions of the source disk — are detected by
  the destination filesystem and stored as holes (nothing on disk), so empty
  space costs nothing.  (Zero the source's free space first — `fstrim`,
  `zerofree`, or writing and deleting a large zero file — so unused blocks
  actually read back as zeros.)
- Only changed blocks are written on each run (use case 2).

The result is still an ordinary file, so it can be **loop-mounted and
browsed** without a full restore — inspect it, or selectively pull out
individual files or whole directory trees with `cp` / `rsync` / `scp`:

```bash
losetup -fP /tank/backups/server-sda.img           # /dev/loopN, partitions as loopNp1...
mount -o ro /dev/loopNp2 /mnt/restore
# copy out what you need, then: umount /mnt/restore && losetup -d /dev/loopN
```

**Repairing a corrupt block in such an image (`--ignore-read-errors`).**  If
the backing filesystem develops a bad block — e.g. bcachefs reports a CRC
error and one extent of the image returns `EIO` on read — a normal re-image
aborts at that block.  Pull a fresh copy from the source with
`--ignore-read-errors`: each unreadable local block is treated as a difference
and overwritten from the (readable) remote source, which rewrites the bad
extent and makes the region readable again.

```bash
# image went read-bad at one block; overwrite just the damaged blocks from
# the live source.  Each bad block prints a one-line warning with its offset.
bscp --ignore-read-errors root@server:/dev/sda /tank/backups/server-sda.img
# then confirm the repair held:
bscp --verify root@server:/dev/sda /tank/backups/server-sda.img
```

It is a recovery tool for a handful of bad blocks, not a substitute for
replacing failing hardware — many read errors mean the device is dying.  See
[docs/ignore-read-errors.md](../docs/ignore-read-errors.md).

## Comparison with similar tools

| Feature                | bscp             | blocksync.py | rsync   |
| ---------------------- | ---------------- | ------------ | ------- |
| Block device support   | ✓                | ✓            | Limited |
| No server installation | ✓                | —            | —       |
| Push and pull          | ✓                | Push only    | ✓       |
| Default hash           | SHA-256          | MD5          | MD4/MD5 |
| Resume support         | ✓                | —            | Partial |
| Memory bounded         | ✓ (section size) | —            | —       |

## Credits

This is a fork of **bscp**, originally created by Volker Diels-Grabsch and
contributors.  That work inspired and forms the basis of this version:

- Canonical project (latest master): <https://github.com/bscp-tool/bscp>
- Original author's repository: <https://github.com/vog/bscp>

This fork is maintained at `https://github.com/groenewe/bscp`.
It extends the original — see the commit history and the deep-dive docs under
`docs/` for what changed.  All original copyright notices are retained; the
software remains under its original ISC-style license (see the header of
`bscp`).

## See also

- [blocksync.py](https://www.bouncybouncy.net/programs/blocksync.py)
- [lvmsync](https://theshed.hezmatt.org/lvmsync/)
- [casync](https://github.com/systemd/casync)
- [rsync](https://rsync.samba.org/)
