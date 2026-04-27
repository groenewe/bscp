# Bscp — Secure and efficient copying of block devices

Bscp copies a single file or block device over SSH, transferring only the
blocks that have changed.  It fills the gap where `rsync` fails — most
notably when the source or destination is a raw block device.

No server-side installation is required: the remote-side script is embedded
in the client binary and executed via `python(/2/3) -c` over the SSH connection.

## Requirements

Python 3 on the local host and Python 2 or 3 on the remote host.  SSH access to the remote host.

## Usage

```
bscp [options] SRC DST

push:  bscp [options] local_file   HOST:remote_file
pull:  bscp [options] HOST:remote_file   local_file
```

`SRC` and `DST` can be a regular file or a block device (`/dev/sdX`).
Exactly one of them must be a `HOST:path` argument; which side carries the
`HOST:` prefix determines the direction.

The destination file or device **must already exist**.  By default it must
also be at least as large as the source (or, when `-B` is used, at least as
large as the requested limit); pass `--allow-truncate` to copy only the
prefix that fits.

### Options

| ---------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------- |
| Flag                         | Default  | Description                                                                                                      |
| ---------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------- |
| `-b SIZE` / `--block-size`   | `64K`    | Comparison/transfer granularity. Supports `K`/`M`/`G` suffixes.                                                  |
| `-s SIZE` / `--section-size` | `10G`    | File is processed in sections of this size. Bounds peak memory to roughly `diff_blocks_per_section × blocksize`. |
| `-a ALGO` / `--algorithm`    | `sha256` | Hash algorithm. Any algorithm supported by Python's `hashlib` is accepted (e.g. `sha512`, `sha3-256`).           |
| `-r BYTES` / `--resume-from` | `0`      | Skip ahead to this byte offset (rounded down to a section boundary). Use after an interrupted transfer.          |
| `--retries N`                | `0`      | Automatically retry on connection failure, up to N times, with exponential back-off.                             |
| `-i FILE` / `--identity`     |          | SSH identity file (`-i FILE`).                                                                                   |
| `-o OPT` / `--ssh-opt`       |          | Extra SSH option, repeatable (passed as `-o OPT`).                                                               |
| `-C` / `--compress`          |          | Enable SSH compression.                                                                                          |
| `-N` / `--dry-run`           |          | Count differing blocks only; do not update destination.                                                          |
| `-B N` / `--block-count`     | `0`      | Limit sync to the first N blocks (0 = no limit). A `K`/`M`/`G`/`T` suffix interprets the value as bytes,         |
|                              |          | rounded up to whole blocks (e.g. `-B 4M`). A warning is printed if the limit exceeds the source size.            |
| `--allow-truncate`           |          | Allow the destination to be smaller than the source (or, with `-B`, smaller than the requested limit);           |
|                              |          | only the bytes that fit are copied.                                                                              |
| `--buffer`                   |          | Push: buffer differing blocks in memory during phase B instead of re-reading them from disk.                     |
|                              |          | Higher memory use, fewer disk reads. Experimental. Auto-disabled if available memory is too low.                 |
| `-q` / `--quiet`             |          | Suppress scan/copy progress lines. Errors and warnings are still shown.                                          |
| `--batch`                    |          | Suppress all stderr output; use the exit status to detect errors (implies `-q`).                                 |
| `-p PORT` / `--port`         | `22`     | SSH port.                                                                                                        |
| ---------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------- |

### Examples

```bash
# Push a local disk image to a remote server
bscp /var/backups/disk.img backup-server:/data/disk.img

# Pull a remote block device to a local image file
bscp root@storage:/dev/sdb /mnt/images/sdb.img

# Dry-run: see how many blocks differ without copying
bscp -N /dev/sda myhost:/dev/sda

# Use a smaller section size to limit memory on a constrained host
bscp -s 1G /dev/sda myhost:/dev/sda

# Resume an interrupted push from where it failed
bscp --resume-from 42949672960 /dev/sda myhost:/dev/sda

# Auto-retry up to 3 times on transient connection failures
bscp --retries 3 /dev/sda myhost:/dev/sda

# Limit a long sync to just the first 1 GiB (suffix is bytes, rounded up to blocks)
bscp -B 1G /dev/sda myhost:/dev/sda

# Sync only the prefix that fits when the destination is smaller than the source
bscp --allow-truncate /var/backups/disk.img myhost:/data/disk-half.img
```

### Exit status

| ----- | -------------------------------------------------------------------------------- |
| Code  | Meaning                                                                          |
| ----- | -------------------------------------------------------------------------------- |
| `0`   | Transfer completed successfully (or dry-run finished).                           |
| `1`   | Fatal error — remote file not accessible, size mismatch, or SSH failure.         |
| `2`   | Bad arguments or usage error.                                                    |
| `3`   | Connection lost — transfer incomplete; re-run with `--resume-from`.              |
| `130` | Interrupted by user (Ctrl+C).                                                    |
| ----- | -------------------------------------------------------------------------------- |

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

See [PROTOCOL.md](../PROTOCOL.md) for the full wire-format specification.

## Comparison with similar tools

| ---------------------- | ---------------- | ------------ | ------- |
| Feature                | bscp             | blocksync.py | rsync   |
| ---------------------- | ---------------- | ------------ | ------- |
| Block device support   | ✓                | ✓            | Limited |
| No server installation | ✓                | —            | —       |
| Push and pull          | ✓                | Push only    | ✓       |
| Default hash           | SHA-256          | MD5          | MD4/MD5 |
| Resume support         | ✓                | —            | Partial |
| Memory bounded         | ✓ (section size) | —            | —       |
| ---------------------- | ---------------- | ------------ | ------- |

## See also

- [blocksync.py](https://www.bouncybouncy.net/programs/blocksync.py)
- [lvmsync](https://theshed.hezmatt.org/lvmsync/)
- [casync](https://github.com/systemd/casync)
- [rsync](https://rsync.samba.org/)
