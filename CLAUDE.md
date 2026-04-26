# CLAUDE.md — bscp

## Project overview

`bscp` is a single-file Python 3 script that copies a file or block device
over SSH, transferring only changed blocks.  It is intended for the use case
where `rsync` fails — most commonly raw block devices.

The whole client lives in one file: `bscp`.  There are no external
dependencies beyond the Python 3 stdlib and an installed `ssh` binary.

Two prebuilt single-file Nuitka binaries are checked in for hosts that have
no Python interpreter installed: `bscp.amd64` (x86-64) and `bscp.arm64`
(aarch64).  See [Nuitka builds](#nuitka-builds) below.

## Architecture

```
bscp (single file)
├── remote_script      — Triple-quoted Python source for the remote-side
│                        process.  build_ssh_cmd() appends "\n_remote()"
│                        and embeds the result inside a "$py" -O -B -c "..."
│                        shell command.  The remote shell tries python3,
│                        python2, python in order ("command -v" + exec; first
│                        found wins), so client and server are always the
│                        same protocol version.
│                        The script body is compatible with Python 2.6+ and
│                        3.x, so no inspect/getsource is needed and the file
│                        works under Nuitka onefile builds.
├── IOCounter          — thin wrapper around subprocess stdin/stdout that
│                        tracks total bytes sent/received.  Flushes after
│                        every write to prevent buffering deadlocks.
├── ConnectionLost     — RuntimeError subclass carrying the section start
│                        offset and an `interrupted` flag (True on Ctrl+C,
│                        False on pipe error).  Used for resume reporting.
├── parse_size()       — converts "64K" / "10G" strings to integer bytes.
├── available_memory() — queries OS for available physical RAM via sysconf;
│                        used to cap section size when --buffer is active.
├── fmt_time()         — formats seconds as "m:ss" / "h:mm:ss" for progress
│                        display.
├── format_size()      — converts a byte count to a human-readable string.
│                        floor=False (default) only emits a unit when n is
│                        an exact multiple of it; round-trips losslessly
│                        through parse_size() and is the safe choice for
│                        anything fed back to the CLI (resume offsets,
│                        rebuilt argv).  floor=True is for display: pick
│                        the largest unit that keeps the count to four
│                        digits or fewer.  At unit boundaries this means
│                        9999M shows as "9999M" but 10000M (= 9.77G) shows
│                        as "9G", and 10240M (= 10G) as "10G" — the count
│                        may drop below ten when the hard 4-digit cap
│                        forces the next unit up.  Supported suffixes are
│                        K, M, G, T (1024-based).
├── build_resume_cmd() — assembles a copy-pasteable resume command line from
│                        the current argv and the failed section offset.
├── build_ssh_cmd()    — assembles the ssh argv list from ssh_args dict.
├── do_sync()          — all transfer logic for both push and pull.  Hosts
│                        a `show_copy_progress` closure that all three
│                        phase-B branches (push, push --buffer, pull) share.
└── __main__           — argparse, push/pull auto-detection, retry loop.
```

## Module-level constants

`DEFAULT_BLOCK` and `DEFAULT_SECTION` are defined at module level (not inside
`__main__`) so that `build_resume_cmd()` can compare against them to decide
which options to omit from the reconstructed command line.

`MODE_PUSH`, `MODE_PULL`, and `ALLOW_TRUNCATE` are also defined at module
level for use throughout the client.  Because the remote runs from a string
literal extracted standalone on the remote host, any constants the remote
needs must be **duplicated inside the script body** — the client module
scope is not available there.  `HEADER_FMT`, `HEADER_SIZE`, `MODE_PUSH`,
`MODE_PULL`, `PUSH_PULL_MASK`, and `ALLOW_TRUNCATE` are duplicated this way.
The mask byte is split client-side into `mode | ALLOW_TRUNCATE`; the remote
reverses this with `mode & PUSH_PULL_MASK` and `mode & ALLOW_TRUNCATE`.

## Key protocol constants

| Name             | Value        | Notes                                                                |
| ---------------- | ------------ | -------------------------------------------------------------------- |
| `HEADER_FMT`     | `'<QQQQQQB'` | 49-byte protocol header struct                                       |
| `MODE_PUSH`      | `0`          | Push/pull bit in mode byte (bit 0)                                   |
| `MODE_PULL`      | `1`          | Push/pull bit in mode byte (bit 0)                                   |
| `PUSH_PULL_MASK` | `1`          | Mask to extract push/pull bit from mode byte                         |
| `ALLOW_TRUNCATE` | `2`          | Flag bit in mode byte (bit 1): allow destination smaller than source |
| `PULL_WINDOW`    | `128`        | Batch size for pull phase B (see below)                              |

## Protocol summary

See `PROTOCOL.md` for the full wire-format spec.  Short version:

1. **Handshake**: client sends 49-byte header + filename + hashname; server
   responds with sanity digest; client sends `b'go'`; server sends its file
   size as a uint64.
2. **Section loop**: file processed in `section_size`-byte chunks.  For each
   section:
   - **Phase A**: server streams one hash digest per block → client reads and
     compares with local digests.  Default push and pull store diff
     positions only (8 bytes each); push with `--buffer` stores
     `(pos, block)` pairs so phase B can skip a re-read.
   - **Phase B** push: client sends `count` then `(pos, block)` for each
     diff; server writes them.
   - **Phase B** pull: client sends `count` then offsets in windows of
     `PULL_WINDOW`; server streams blocks back; client writes locally.
3. Client closes stdin; server exits.

### Critical: keep client and remote constants in sync

`HEADER_FMT`, `MODE_PUSH`, `MODE_PULL`, `PUSH_PULL_MASK`, and
`ALLOW_TRUNCATE` are defined **in both** the client module and inside the
`remote_script` string.  Any protocol change must be made in both places.
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
  computes `eff_section = section_size or sync_size`.  The client's main()
  similarly skips the resume-rounding step when `section_size == 0`.
- **Remote file must exist before sync.**  The tool does not create files.
  The server sends `remote_size = 0` when it cannot open the file; the
  client treats 0 as an error.  This means a legitimately-empty remote file
  is indistinguishable from "not found" — known limitation, documented in
  `PROTOCOL.md`.
- **Without `ALLOW_TRUNCATE`, destination size must be ≥ effective source
  size**, where `effective_src = min(src_size, requested)` and `requested =
  start_offset + block_count * blocksize` if `-B` is in use (else `src_size`).
  In push the remote is the destination; in pull the local file is.  Both
  client and server enforce this from their respective side.  With the
  `ALLOW_TRUNCATE` flag set (`--allow-truncate`), `sync_size = min(local,
  remote)` and a warning is printed when the destination is the limiting
  side.  `--block-count` (`-B`) and `--allow-truncate` are independent:
  `-B` caps how much data flows through, but if its effective source still
  exceeds the destination (e.g. push `-B 80M` to a 50M remote), the
  destination-smaller check fires and `--allow-truncate` is required.
  An overshoot — `-B` asking for more than the source actually has — is
  only a warning.

## Symmetric size validation (do_sync / _remote)

The push and pull size checks were originally written as four separate
`if` branches.  They are now expressed as a single check on
`(src_size, dst_size)`, derived from `mode`:

```python
if mode == MODE_PUSH:
    src_label, src_size, dst_label, dst_size = 'local',  local_size,  'remote', remote_size
else:
    src_label, src_size, dst_label, dst_size = 'remote', remote_size, 'local',  local_size

if dst_size < src_size:
    if not allow_truncate:
        fail('%s destination size %d (%d blocks) < %s source size %d (%d blocks); ...')
    report('Warning: %s destination (%s) smaller than %s source (%s); ...')

sync_size = min(local_size, remote_size)
```

`fail()` is a closure that closes `proc.stdin` and waits for the remote
process before raising `RuntimeError`, so the remote cannot be left blocked
on `stdin.read(2)` waiting for the `go` token after a failed handshake.

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

| Phase                 | Push (default)                       | Push (`--buffer`)                              | Pull                                 |
| --------------------- | ------------------------------------ | ---------------------------------------------- | ------------------------------------ |
| Phase A (per section) | O(diff\_blocks × 8) — positions only | O(diff\_blocks × blocksize) — positions+blocks | O(diff\_blocks × 8) — positions only |
| Phase B               | re-reads each block; O(1)            | consumed as sent                               | consumed as received                 |
| Peak                  | negligible                           | ≤ section\_size (all blocks differ)            | negligible                           |

Section size (`-s`) is only a real memory knob when `--buffer` is in use.
By default the client only retains 8-byte offsets, so a single section can
cover the whole file without RAM impact.

**Automatic clamping (push with `--buffer`):** at startup,
`available_memory()` is called (`os.sysconf('SC_AVPHYS_PAGES') ×
SC_PAGE_SIZE`) and `section_size` is capped at `max(avail // 2, blocksize)`.
A `section_size` of 0 (whole-file-in-one-section) is also clamped under
`--buffer` so the buffered diff list cannot exhaust RAM.

**Automatic disable of `--buffer`:** if available memory is below
`MIN_MEMORY_PUSH` (`64 × DEFAULT_BLOCK`, i.e. 4 MiB), `--buffer` is
silently disabled and a note is printed to stderr (suppressed by `--batch`).
The transfer falls back to the default re-read mode.

## Remote script constraints

`remote_script` is a triple-quoted Python source string; it is concatenated
with `\n_remote()` and passed to the remote shell as
`python(/2/3) -O -B -c "..."` (double-quoted).  Inside a double-quoted shell
string, only `\$`, `` \` ``, `\"`, `\\`, and `\<newline>` are special.
This means:

- **Do not use `"` (double quote) anywhere in `remote_script`.**  Use single
  quotes for all Python string literals (`b'go'`, `'rb+'`, `'utf-8'`, etc.).
- **Backslash sequences are safe** as long as they are not one of the five
  special bash cases above.  Normal Python escape sequences (`\n`, `\t` etc.)
  are fine when needed.
- **No `$` characters either** — the shell would expand them.  The current
  source contains none.
- **No `%` characters** — `remote_script` is interpolated into the shell
  string with `'... -c "%s" ...' % script`, so a stray `%` would confuse
  Python's percent-formatting.  The current source contains none.
- **Newlines are literal** and are preserved by bash.
- **`#` comments are safe** inside double-quoted strings.
- Keep the body self-contained: its imports cover everything it needs
  (`hashlib`, `os`, `struct`, `sys`); no file I/O outside the sync loop.
- **Python 2/3 binary I/O**: use `getattr(sys.stdin, 'buffer', sys.stdin)`;
  Python 3 wraps stdin in a text layer (`.buffer` gives raw bytes), Python 2
  does not.  All other constructs in the body are compatible with both.

## Nuitka builds

Two single-file binaries are checked in next to the source: `bscp.amd64`
(x86-64) and `bscp.arm64` (aarch64).  Both were built with Nuitka in
`--mode=onefile` against Python 3.14.3 and **do not require Python on the
client host** (the binary embeds the interpreter and the `bscp` source).
The remote side still needs `python3`, `python2`, or `python` on `PATH` —
the binary only replaces the local interpreter, not the embedded protocol.

Build environments:

- `bscp.amd64`: Ubuntu 22.04 (amd64 desktop)
- `bscp.arm64`: Ubuntu 24.04 (Raspberry Pi)

To rebuild (see also the comment block at the top of `bscp`):

```sh
sudo apt install patchelf
pyenv local 3.14.3
python -m venv nuitka && source nuitka/bin/activate
pip install --upgrade pip wheel Nuitka[all]
python -m nuitka bscp --mode=onefile --static-libpython=yes -o bscp.nuitka
```

`--mode=onefile` produces a single self-extracting executable; the
alternative `--mode=standalone` produces a directory tree and is **not**
the supported configuration.  Because `remote_script` is a plain string
literal (no `inspect.getsource()`), Nuitka's onefile mode works without
any source-bundling tricks.

## Testing

A bash regression harness lives at `tests.sh` in the repo root.  It runs
against `localhost:` and exercises every code path the manual tests used
to cover, plus a few that were easy to forget:

| Test                                            | What it catches                                   |
| ----------------------------------------------- | ------------------------------------------------- |
| push: random 4K diffs in mid-file               | basic push round-trip, hash-exchange correctness  |
| pull: random 4K diffs in mid-file               | basic pull round-trip, windowed phase B           |
| dry-run leaves destination unchanged            | `-N` does not write; md5 before == after          |
| resume from a mid-file section boundary         | `-r` aligns to section, only re-scans the tail    |
| `--buffer` push                                 | the in-memory diff-block buffer path              |
| `--allow-truncate` push (smaller dst)           | both refusal-without-flag and warning-with-flag   |
| `--allow-truncate` pull (smaller dst)           | symmetric pull behaviour                          |
| `--batch` is silent on success and exits 0      | no stderr leakage; exit-code-only contract        |
| `--block-count` prints next-offset resume hint  | `Continue with: ... -r 4M` chaining               |
| `-B` accepts K/M/G byte-size suffix             | suffixed -B is bytes, rounded up to whole blocks  |
| `-B` pull within dst size needs no truncate flag | -B does not spuriously trip the truncate check   |
| `-B` beyond dst size still requires `--truncate` | -B and --allow-truncate stay independent          |
| `-B` overshoot prints warning, exits 0          | calculated size > actual source warns, syncs rest |
| exit 2 when neither side is HOST:path           | argparse path                                     |
| friendly error when local file is missing       | OSError → `Error: Cannot open local file ...`     |
| `format_size` + `parse_size` unit tests         | display 4-digit cap rule + lossless round-trip    |

Prerequisites: `python3` on PATH, and passwordless `ssh localhost`.  Run:

```bash
./tests.sh
# or, when testing a different binary:
BSCP=./bscp.amd64 ./tests.sh
```

The script writes its fixtures into a `mktemp -d` directory and removes
them on exit.  Exit status is `0` on success, `1` if any test failed (with
the failing names listed at the end), or `2` on missing prerequisites.

When investigating a single failure interactively, the manual idiom is
still useful:

```bash
dd if=/dev/urandom of=/tmp/src.img bs=1M count=100
cp /tmp/src.img /tmp/dst.img
dd if=/dev/urandom of=/tmp/dst.img bs=4K count=50 seek=1000 conv=notrunc
python3 bscp -s 10M /tmp/src.img localhost:/tmp/dst.img
diff /tmp/src.img /tmp/dst.img
```

Progress output goes to stderr via `\r`-terminated lines.  Extract the
summary line with: `2>&1 | tr '\r' '\n' | grep '^in='`

Progress format during scan:
```
scan SCANNED/TOTAL (PCT%) diff=N (PCT%) (SPEED MiB/s) ELAPSED (ETA)
```
- `SCANNED/TOTAL` — cumulative blocks across all sections, not per-section
- first `(PCT%)` — percentage of file scanned
- `diff=N` — cumulative diff count; `(PCT%)` — diffs as fraction of blocks scanned
- `ELAPSED` / `(ETA)` — wall-clock elapsed and estimated remaining in `m:ss` format;
  ETA is linear extrapolation based on scan throughput only (does not account for
  future copy phases, which is acceptable since scan dominates for typical workloads)

Progress format during copy:
```
[CUR_SECTION/TOTAL_SECTIONS] copy WRITTEN/SECTION_COPY_BYTES (SPEED KiB/s) ELAPSED (ETA)
```

## Quiet and batch modes

`-q` / `--quiet` suppresses the `\r`-terminated scan/copy progress lines.
Errors, warnings, and the final summary line are still printed to stderr.

`--batch` suppresses **all** stderr output (implies `-q`).  The caller must
rely solely on the exit status:

| Exit code | Meaning                                        |
| --------- | ---------------------------------------------- |
| `0`       | Success                                        |
| `1`       | Fatal error (I/O failure, remote error, etc.)  |
| `2`       | Bad arguments                                  |
| `3`       | Connection lost — resume with `--resume-from`  |
| `130`     | Interrupted (Ctrl+C)                           |

Both flags are forwarded into the resume command printed by
`build_resume_cmd()`, so a resumed invocation keeps the same verbosity level.

## Style conventions

- Python 3.6+ only on the client; no compatibility shims.
- The remote script body must stay 2.6+/3.x compatible (see above).
- No external dependencies.
- No comments except where the *why* is non-obvious.
- `remote_script` uses compact style (fewer blank lines) to keep the
  embedded string readable at a glance.
- All struct formats use lowercase `<` prefix for explicit little-endian.
