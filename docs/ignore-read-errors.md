# `--ignore-read-errors` — recover unreadable local blocks (pull)

`--ignore-read-errors` is an **experimental, experts-only** recovery mode.
Normally a read error on the file or device bscp is touching (`EIO`, a CRC
mismatch surfaced by the filesystem, a developing bad block) is fatal: the
read raises, the transfer aborts.  With this flag a read error on the **local
destination during the scan** is no longer fatal — the unreadable block is
treated as a difference and overwritten from the (readable) remote source in
phase B.

The motivating case is a backup image living on a copy-on-write filesystem
(bcachefs, btrfs, ZFS) that has developed a corrupt extent.  Reading the
damaged block returns `EIO`, but *writing* it allocates fresh storage and a
new checksum — so overwriting the block from a good source both restores the
correct data and makes the region readable again.  bscp already overwrites
only the blocks that differ; this flag simply makes "I can't even read it to
compare" count as "it differs."

## Exactly what it does — and does not — cover

The scope is deliberately narrow.  The flag changes behaviour only when **all**
of the following hold:

| Dimension      | Covered                                  | Not covered (stays fatal)                          |
| -------------- | ---------------------------------------- | -------------------------------------------------- |
| Operation      | read                                     | write (both sides)                                 |
| Which file     | the **local** file                       | the **remote** file (either direction)             |
| Direction      | **pull** (local is the destination)      | **push** (local is the source)                     |
| Phase          | **phase A** (the scan / hash pass)       | phase B transfer reads (see below)                 |

Rationale for each boundary:

- **Reads only, never writes.**  The whole repair depends on the corrective
  *write* succeeding.  If the write also fails the block cannot be fixed and
  the operator must know — so write errors remain fatal on both ends.
- **Local only.**  The flag is implemented entirely in the python3 client;
  there is no wire-protocol change and the remote scripts (`remote_script`,
  `remote_script_mt`, `remote_perl`) are untouched.  A bad block in the
  *remote* file is out of scope.
- **Pull only.**  In pull the local file is the **destination**: an unreadable
  block has a known-good replacement waiting on the remote source, so forcing
  the overwrite is strictly an improvement.  In **push** the local file is the
  **source** — there is no good data to substitute for an unreadable source
  block, so the flag is a no-op there (the client prints a note saying so and
  leaves local read errors fatal).
- **Scan phase.**  Persistent bad blocks are detected when phase A reads every
  block to hash it.  Such a block is forced into the diff list, so phase B
  reads it from the *remote* (good) side — the local file is only written in
  phase B pull, never re-read.  A block that hashed fine in phase A but fails a
  (nonexistent) local re-read in phase B does not occur in pull.

## How it works in `do_sync`

Phase A reads each local block, hashes it, and compares the digest with the
remote's.  The read is wrapped by a small `read_block(p, bl)` helper:

```
try:
    return f.read(bl), True
except OSError as e:
    if not ignore_local_read_err:   # (ignore_read_errors and mode == MODE_PULL)
        raise                       # default behaviour: fatal
    f.seek(p + bl)                  # recover the file position past the bad block
    read_errors += 1
    report('... read error at block N ... (--ignore-read-errors) ...')
    return None, False              # signal: unreadable
```

The `f.seek(p + bl)` is load-bearing: after a failed read the file offset is
undefined, so the scan re-seeks past the bad block before continuing.  The
sentinel `(None, False)` flows through the bounded hash window like any other
block — but with **no hash future** attached.  When the window drains, the
remote digest for that block is still read off the wire (the remote sent one
digest per block; the stream must stay in lock-step), and then:

- if the block had no future (unreadable) → it is appended to `diff_positions`
  unconditionally, forcing the overwrite;
- otherwise the local and remote digests are compared as usual.

Phase B pull then requests those positions from the remote and writes the
returned blocks locally, exactly as it would for an ordinary difference.

## Output and exit status

- **Per block:** one warning line is printed the moment a block is found
  unreadable, naming the block index, the file, and the byte offset.  It is a
  `\n`-prefixed warning, so it survives `-q` (which only hides the
  `\r` progress lines) and is suppressed by `--batch` like all stderr.
- **At the end:** if any block was overwritten this way, a closing note states
  how many and recommends a re-run or `--verify` to confirm the repair.
- **Exit status is unchanged** — a successful run still exits `0`.  The flag
  adds no new exit code: a forced overwrite that succeeds *is* success.  The
  warnings (and, for scripted callers, the `--verify` exit `4`/`5`) carry the
  signal.

Because the flag targets a *handful* of bad blocks, error output is
intentionally one line per block.  A device producing thousands of read errors
is failing hardware — diagnosing that, and distinguishing soft from hard
errors, is out of scope; replace the device.

## Testing

`tests.sh` exercises the real error path without root or special block
devices: a tiny `LD_PRELOAD` shim makes `read()` of one 64&nbsp;KiB range of the
destination return `EIO` while letting writes through (mirroring a filesystem
that can still rewrite a CRC-bad extent).  The test confirms that without the
flag the `EIO` is fatal, and that with `--ignore-read-errors` the pull does not
abort, prints the per-block warning, and leaves the destination byte-identical
to the source.  It self-skips where no C compiler is present (and under the
python2 client, which does not implement the flag).
