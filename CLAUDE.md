# CLAUDE.md — bscp

## Project overview

`bscp` is a single-file Python 3 script that copies a file or block device
over SSH, transferring only changed blocks.  It is intended for the use case
where `rsync` fails — most commonly raw block devices.

The entire codebase is in one file: `bscp`.  There are no external
dependencies beyond Python 3 stdlib and an installed `ssh` binary.

## Architecture

```
bscp (single file)
├── _remote()          — Remote-side logic as a real Python function.
│                        inspect.getsource(_remote) extracts its source at
│                        runtime; build_ssh_cmd() appends "\n_remote()" and
│                        passes the result to the remote shell, which tries
│                        python3, python2, python in order (first found wins,
│                        via "command -v" + exec).  Client and server are
│                        therefore always the same protocol version.
│                        _remote is compatible with Python 2.6+ and 3.x.
│                        inspect.getsource() reads the script file from disk,
│                        so frozen/zipfile deployment is not supported.
├── IOCounter          — thin wrapper around subprocess stdin/stdout that
│                        tracks total bytes sent/received.  Flushes after
│                        every write to prevent buffering deadlocks.
├── ConnectionLost     — RuntimeError subclass carrying the section start
│                        offset and an `interrupted` flag (True on Ctrl+C,
│                        False on pipe error).  Used for resume reporting.
├── parse_size()       — converts "64K" / "10G" strings to integer bytes.
├── available_memory() — queries OS for available physical RAM via sysconf;
│                        used to cap push section size.
├── fmt_time()         — formats seconds as "m:ss" for progress display.
├── format_size()      — converts a byte count to a human-readable string
│                        (e.g. 8388608 → "8M").  floor=False (default) only
│                        converts exact multiples; floor=True truncates to
│                        the nearest unit (used for display and resume offset).
├── build_resume_cmd() — assembles a copy-pasteable resume command line from
│                        the current argv and the failed section offset.
├── build_ssh_cmd()    — assembles the ssh argv list from ssh_args dict.
├── do_sync()          — all transfer logic for both push and pull.
└── __main__           — argparse, push/pull auto-detection, retry loop.
```

## Module-level constants

`DEFAULT_BLOCK` and `DEFAULT_SECTION` are defined at module level (not inside
`__main__`) so that `build_resume_cmd()` can compare against them to decide
which options to omit from the reconstructed command line.

`MODE_PUSH`, `MODE_PULL`, `PUSH_PULL_MASK`, and `ALLOW_SMALLER` are also
defined at module level for use throughout the client.  Because `_remote()` is
extracted with `inspect.getsource()` and executed standalone on the remote
host, any constants it needs must be **duplicated inside the function body** —
the module scope is not available there.  `HEADER_FMT`, `HEADER_SIZE`,
`MODE_PUSH`, `MODE_PULL`, `PUSH_PULL_MASK`, and `ALLOW_SMALLER` are currently
duplicated this way.

## Key protocol constants

| Name             | Value        | Notes                                                                |
| ---------------- | ------------ | -------------------------------------------------------------------- |
| `HEADER_FMT`     | `'<QQQQQQB'` | 49-byte protocol header struct                                       |
| `MODE_PUSH`      | `0`          | Push/pull bit in mode byte (bit 0)                                   |
| `MODE_PULL`      | `1`          | Push/pull bit in mode byte (bit 0)                                   |
| `PUSH_PULL_MASK` | `1`          | Mask to extract push/pull bit from mode byte                         |
| `ALLOW_SMALLER`  | `2`          | Flag bit in mode byte (bit 1): allow destination smaller than source |
| `PULL_WINDOW`    | `128`        | Batch size for pull phase B (see below)                              |

## Protocol summary

See `PROTOCOL.md` for the full wire-format spec.  Short version:

1. **Handshake**: client sends 49-byte header + filename + hashname; server
   responds with sanity digest; client sends `b'go'`; server sends its file
   size as a uint64.
2. **Section loop**: file processed in `section_size`-byte chunks.  For each
   section:
   - **Phase A**: server streams one hash digest per block → client reads and
     compares with local digests.  Push stores `(pos, block)` for diffs (or
     `pos` only with `--reread`); pull stores `pos` only.
   - **Phase B** push: client sends `count` then `(pos, block)` for each
     diff; server writes them.
   - **Phase B** pull: client sends `count` then offsets in windows of
     `PULL_WINDOW`; server streams blocks back; client writes locally.
3. Client closes stdin; server exits.

### Critical: do not change without updating `_remote()`

`HEADER_FMT`, `MODE_PUSH`, `MODE_PULL`, `PUSH_PULL_MASK`, and `ALLOW_SMALLER`
are defined **in both** the client module and inside `_remote()`.  Any
protocol change must be made in both places.
The `PULL_WINDOW` constant lives only in the client — the server is
stateless with respect to window size.

## Protocol invariants to preserve

- **Header is always 49 bytes** (`struct.calcsize('<QQQQQQB') == 49`).
- **All integers are little-endian uint64** (`<Q`), except the mode byte
  which is uint8 (`B`).
- **Block lengths are always inferred**, never sent on the wire:
  `bl = min(blocksize, sync_size - pos)`.  Both sides compute this
  identically.  Sending the length explicitly would be a protocol break.
- **`section_size = 0` means whole file as one section.**  The server
  computes `eff_section = section_size if section_size else sync_size`.
- **Remote file must exist before sync.**  The tool does not create files.
  The server sends `remote_size = 0` when it cannot open the file; the
  client treats 0 as an error.
- **Push requires `remote_size >= local_size`** unless the `ALLOW_SMALLER`
  flag is set in the mode byte (`--allow-smaller`).  With the flag, both push
  and pull use `sync_size = min(local_size, remote_size)` and a warning is
  printed when the destination is the limiting factor.

## PULL\_WINDOW — why it exists and how to change it

Pull phase B sends positions to the server and receives blocks back on the
**same SSH pipe**.  A naive "send all positions → receive all blocks" approach
can deadlock:

- Server writes blocks to stdout faster than client reads them → SSH stdout
  channel window fills → server blocks.
- Server blocked on stdout write → server stops reading positions from stdin
  → SSH stdin window fills → client blocks on writing positions.

The windowed approach fixes this by interleaving send and receive in batches
small enough that the in-flight block data fits within the SSH channel window.
The maximum in-flight data is `PULL_WINDOW × blocksize` (default 128 × 64 KiB
= 8 MiB), comfortably within OpenSSH's dynamic window.

If you increase `blocksize` significantly (e.g. to 1 MiB), consider reducing
`PULL_WINDOW` proportionally.  If you decrease `blocksize`, a larger
`PULL_WINDOW` reduces round-trip overhead on high-latency links.

## Memory model

| Phase                 | Push (default)                                  | Push (`--reread`)                    | Pull                                 |
| --------------------- | ----------------------------------------------- | ------------------------------------ | ------------------------------------ |
| Phase A (per section) | O(diff\_blocks × blocksize) — diff\_blocks list | O(diff\_blocks × 8) — positions only | O(diff\_blocks × 8) — positions only |
| Phase B               | consumed as sent                                | re-reads each block; O(1)            | consumed as received                 |
| Peak                  | ≤ section\_size (all blocks differ)             | negligible                           | negligible                           |

Section size is the primary memory knob (`-s`).  Smaller sections use less
memory at the cost of more phase-boundary round-trips.

**Automatic clamping (push without `--reread`):** at startup, `available_memory()` is called
(`os.sysconf('SC_AVPHYS_PAGES') × SC_PAGE_SIZE`) and `section_size` is capped
at `max(avail // 2, blocksize)`.  With `--reread` (or pull), the client only
stores diff positions (8 bytes each), so no cap is applied.

## Remote script constraints

`_remote()` is a normal Python function; its source is extracted with
`inspect.getsource(_remote)` and passed to the remote shell as
`python3 -O -B -c "..."` (double-quoted).  Inside a double-quoted shell
string, only `\$`, `` \` ``, `\"`, `\\`, and `\<newline>` are special.
This means:

- **Do not use `"` (double quote) anywhere in `_remote`.**  Use single
  quotes for all Python string literals (`b'go'`, `'rb+'`, `'utf-8'`, etc.).
- **Backslash sequences are safe** as long as they are not one of the five
  special bash cases above.  Normal Python escape sequences (`\n`, `\t` etc.)
  are fine when needed.
- **Newlines are literal** and are preserved by bash.
- **`#` comments are safe** inside double-quoted strings.
- Keep `_remote` self-contained: its imports cover everything it needs
  (`hashlib`, `os`, `struct`, `sys`); no file I/O outside the sync loop.
- **Python 2/3 binary I/O**: use `getattr(sys.stdin, 'buffer', sys.stdin)`;
  Python 3 wraps stdin in a text layer (`.buffer` gives raw bytes), Python 2
  does not.  All other constructs in `_remote` are compatible with both.

## Testing

No automated test suite.  Manual functional tests:

```bash
# Setup
dd if=/dev/urandom of=/tmp/src.img bs=1M count=100
cp /tmp/src.img /tmp/dst.img
dd if=/dev/urandom of=/tmp/dst.img bs=4K count=50 seek=1000 conv=notrunc

# Push
python3 bscp -s 10M /tmp/src.img localhost:/tmp/dst.img
diff /tmp/src.img /tmp/dst.img

# Pull
cp /tmp/src.img /tmp/dst2.img
dd if=/dev/urandom of=/tmp/dst2.img bs=4K count=50 seek=2000 conv=notrunc
python3 bscp -s 10M localhost:/tmp/src.img /tmp/dst2.img
diff /tmp/src.img /tmp/dst2.img

# Dry-run (check diff count, files must not change)
python3 bscp -N -s 10M /tmp/src.img localhost:/tmp/dst.img

# Resume (modify last section, resume from its start)
python3 bscp -s 10M -r 90M /tmp/src.img localhost:/tmp/dst.img
diff /tmp/src.img /tmp/dst.img
```

Progress output goes to stderr via `\r`-terminated lines.  Extract the
summary line with: `2>&1 | tr '\r' '\n' | grep '^in='`

Progress format during scan:
```
scan SCANNED/TOTAL (PCT%) diff=N (PCT%) (SPEED MiB/s) ELAPSED ~ETA
```
- `SCANNED/TOTAL` — cumulative blocks across all sections, not per-section
- first `(PCT%)` — percentage of file scanned
- `diff=N` — cumulative diff count; `(PCT%)` — diffs as fraction of blocks scanned
- `ELAPSED` / `~ETA` — wall-clock elapsed and estimated remaining in `m:ss` format;
  ETA is linear extrapolation based on scan throughput only (does not account for
  future copy phases, which is acceptable since scan dominates for typical workloads)

Progress format during copy:
```
[CUR_SECTION/TOTAL_SECTIONS] copy WRITTEN/SECTION_COPY_BYTES (SPEED KiB/s) ELAPSED ~ETA
```

## Style conventions

- Python 3.6+ only; no compatibility shims.
- No external dependencies.
- No comments except where the *why* is non-obvious.
- `remote_script` uses compact style (fewer blank lines) to keep the
  embedded string readable at a glance.
- All struct formats use lowercase `<` prefix for explicit little-endian.
