# `--verify` — post-copy BLAKE3 cross-check

`--verify` is a **convenience** integrity check that runs *after* a copy
finishes.  It hashes the local file with [`b3sum`](https://github.com/BLAKE3-team/BLAKE3)
and, when the whole device was copied to a same-size destination, runs the
same `b3sum` on the remote over SSH and compares the two digests.

## Why an external tool, not the protocol

bscp already exchanges per-block hashes during phase A, but those digests
are:

1. computed with the **same** algorithm used for block comparison (`-a`,
   default `sha256`), so a single rollup of them adds no independent guard
   against a weakness in that algorithm; and
2. read from the destination **before** phase B writes it — they describe
   the pre-copy device, not the bytes that actually landed.

A genuine post-copy check therefore needs a *fresh read* of the destination
with an *independent* algorithm.  Rather than extend the wire protocol (and
the four remote implementations) to carry a second hash phase, `--verify`
shells out to `b3sum`:

- **Independent.** BLAKE3 is unrelated to the `sha*`/`md5` block-comparison
  family, so it cross-checks against both algorithm weaknesses and any
  systematic hashing fault.
- **Multi-threaded for free.** `b3sum` parallelises internally, so a fast
  device is not bottlenecked on a single core — without bscp threading the
  verify itself.
- **Externally trustworthy.** The artifact is `b3sum`'s own output.  A user
  can re-validate later with the stock tool (`b3sum -c FILE`) — no bscp
  required — which a bespoke bscp log format could never offer.
- **No protocol change.** `PROTOCOL.md` is untouched; the remote side is a
  plain `ssh HOST b3sum REMOTE`, not the bscp remote script.

## Mechanism

In `__main__`, after a successful (non-dry-run) copy:

1. If `shutil.which('b3sum')` finds nothing locally, verify warns and stops
   (the remote is not contacted).
2. A **duration estimate** is printed first.  `b3sum` reads the whole device
   once, exactly as phase A did, so the scan time (`do_sync` now returns
   `total_scan_time` — read+hash, *excluding* the copy) is a good predictor.
   It is scaled by `sync_size / (sync_size − start_offset)` so a resumed run
   (where phase A skipped the head) still estimates the full-device hash.
   Shown only when the estimate is ≥ 1 s.
3. The local `b3sum LOCAL` process and the remote `ssh … HOST 'b3sum REMOTE'`
   are launched **concurrently** (`spawn_hash()`), so wall-clock is the
   slower of the two, not their sum.  The local result is collected first
   (`collect_hash()`) while the remote runs; if the local hash fails, the
   remote process is killed rather than waited on.  `verify_digest()` takes
   the leading hex token of each (the path field differs between the two
   sides, so only the digest is compared).
4. The remote runs over the same `ssh_base()` options as the transfer,
   **including the `ServerAliveInterval=15` keepalive** — essential here,
   because `b3sum` can run for minutes with no channel data, and the
   keepalive probes hold an idle (possibly NAT'd) connection open instead of
   letting it drop.
5. Both digests are printed, then compared **only when the comparison is
   meaningful** (see the gate below), and the verdict (`verify OK` /
   `VERIFY FAILED`) is printed.

## Comparison eligibility gate

A whole-device `b3sum` of source and destination only matches when the
destination is a byte-for-byte copy of the source over the entire device.
The comparison is therefore **skipped with a warning** (exit stays `0`) when:

- `-B` / `--block-count` capped the copy (only a prefix was synced);
- the local and remote sizes differ (e.g. `--allow-truncate` to a smaller
  destination) — `device_size()` is used because `os.path.getsize()` reports
  `0` for block devices; or
- `b3sum` is missing or errors on either side.

Resume (`-r`) does **not** disable the comparison: the check is over the
final whole-device state, which a resumed run completes.

## Exit code

A **confirmed** mismatch (both digests present, sizes equal, full copy, and
the hex differs) exits `4`.  Every skip path above leaves the exit code
unchanged.  Under `--batch` (all stderr suppressed) exit `4` is the only
signal of a mismatch.

## Limitations

- Reads go through the OS page cache, so `--verify` confirms the copy logic
  and transport, not necessarily that the bytes are durably on the physical
  medium (it is not an O_DIRECT media scrub).  For bitrot/escrow over time,
  re-run `b3sum -c` against the saved digest after dropping caches.
- It is a single whole-device digest, not a per-section list — if you need
  to localise a divergence, fall back to a `-N` dry-run (which reports
  differing block counts) or to `dcfldd hashwindow`.
