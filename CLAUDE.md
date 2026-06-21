## Project overview

`bscp` is a single-file Python 3 script that copies a file or block device
over SSH, transferring only changed blocks.  It is intended for the use case
where `rsync` fails — most commonly raw block devices.

This repository is a **fork** of the original bscp
(<https://github.com/bscp-tool/bscp>, by Volker Diels-Grabsch —
<https://github.com/vog/bscp>), which inspired and forms the basis of this
version.  Original copyright notices are retained (ISC-style license, see the
header of `bscp`).  Fork URL: `https://github.com/groenewe/bscp`.

The whole client lives in one file: `bscp`.  There are no external
dependencies beyond the Python 3 stdlib and an installed `ssh` binary.

For a client host with no Python interpreter, `bscp` can be compiled into a
single self-contained Nuitka binary (not shipped in the repo — build your
own).  See [docs/nuitka.md](docs/nuitka.md).

## Documentation map

When a change to `bscp` alters externally-visible behaviour — new flag,
changed default, new exit code, broader runtime requirements, etc. — the
following docs must be updated alongside the code:

- **`bscp`** itself — the comment block at the top of the file is a short
  highlights-only summary (remote-execution model, key features).  Keep
  it short; refresh only when one of those highlights changes.
- **`.github/README.md`** — the user-facing reference rendered on the
  GitHub project page.  Update the options table, the requirements line,
  the exit-status table, and add an example when a new flag deserves one.
- **`CLAUDE.md`** (this file) — developer-facing architecture, protocol,
  and constraints.  Update the architecture diagram, any affected
  invariants, and the testing table when new tests land.
- **`docs/*.md`** — the subsystem deep-dives (indexed below).  Update the
  relevant one when you change that subsystem's mechanism (e.g. a
  hashing-threads change touches `docs/remote-execution.md`).
- **`PROTOCOL.md`** — the wire-format spec.  Only touch this on actual
  protocol changes (header layout, mode bits, phase A/B contract).
- **`index.html`** — the public landing page.  Rarely needs updating;
  refresh only when the headline pitch changes.

A bug fix that does not change behaviour does not need doc updates.  A
change that adds, removes, or alters a flag does.

`bscp.python2` is an out-of-band Python-2.7 client fallback (see
[docs/python2-client.md](docs/python2-client.md)).  It is
**not** refreshed alongside every change to `bscp` — only at milestones
the maintainer chooses.  Day-to-day commits to `bscp` should leave
`bscp.python2` alone.

## Subsystem deep-dives (docs/)

Detailed mechanism docs live under `docs/` to keep this file focused on
architecture and invariants.  Update the relevant one when you change that
subsystem:

- **[docs/remote-execution.md](docs/remote-execution.md)** — the remote-side
  execution model: `remote_script` shell-quoting constraints, the
  `bscp-remote` process marker, multi-threaded hashing (`--hash-threads`),
  and the Perl fallback (`remote_perl`).
- **[docs/protocol-internals.md](docs/protocol-internals.md)** — symmetric
  size validation (`do_sync` / `_remote`) and the `PULL_WINDOW` deadlock
  avoidance.
- **[docs/eta-model.md](docs/eta-model.md)** — the unified scan+copy ETA
  model, rate EMAs, and display damping.
- **[docs/python2-client.md](docs/python2-client.md)** — the `bscp.python2`
  Py2.7 client fallback, its compatibility shims, and maintenance policy.
- **[docs/nuitka.md](docs/nuitka.md)** — building a single-file Nuitka binary
  so the client host needs no Python (not shipped in the repo).
- **[docs/verify.md](docs/verify.md)** — the `--verify` post-copy BLAKE3
  cross-check: why it shells out to `b3sum` instead of extending the
  protocol, the eligibility gate for the comparison, and the graceful-skip
  rules.
## Architecture

```
bscp (single file)
├── remote_script      — Triple-quoted Python source for the single-threaded
│                        remote-side process.  build_ssh_cmd() appends
│                        "\n_remote()" and embeds the result inside a
│                        "$py" -O -B -c "..." shell command.  The remote shell
│                        tries python3 (→ remote_script_mt), then python2 and
│                        python (→ this script), then perl, in order
│                        ("command -v" + exec; first found wins), so client
│                        and server are always the same protocol version.
│                        This script body is compatible with Python 2.6+ and
│                        3.x, so no inspect/getsource is needed and the file
│                        works under Nuitka onefile builds.  It runs on
│                        python2/python and on a python3 reached only via the
│                        `python` name (rare: no `python3` binary present).
├── remote_script_mt   — python3-only multi-threaded twin of remote_script.
│                        Phase-A hashing fans out over a ThreadPoolExecutor
│                        (reads stay sequential; only hashing parallelises).
│                        Same wire protocol as remote_script.  Hex-encoded by
│                        build_ssh_cmd() and run via
│                        `python3 -c "exec(bytes.fromhex('...').decode())"`,
│                        so the no-$/no-%/no-" rules do NOT apply here.  The
│                        thread count is baked into the trailing _remote(N)
│                        call (N from --hash-threads; 0 = remote auto-detects
│                        its own cores).  See docs/remote-execution.md.
├── remote_perl        — Triple-quoted Perl translation of remote_script,
│                        used as a fallback when no Python interpreter is
│                        on the remote.  Hex-encoded by build_ssh_cmd() and
│                        decoded with `perl -e 'eval pack(qq{H*}, q{...})'`,
│                        which sidesteps the no-$, no-%, no-" rules that
│                        apply to remote_script.  Single-threaded.  Requires
│                        Perl 5.10+ for little-endian Q< pack format.
├── IOCounter          — thin wrapper around subprocess stdin/stdout that
│                        tracks total bytes sent/received.  Flushes after
│                        every write to prevent buffering deadlocks.  When
│                        --io-timeout > 0 the wrapper switches to a raw-fd
│                        path (os.read / os.write inside select.select()
│                        loops); if select returns no readiness within the
│                        timeout it raises IOTimeout, which do_sync catches
│                        and converts into a ConnectionLost so --retries
│                        engages.  The raw path requires Popen(bufsize=0)
│                        so select on the fd is authoritative — no hidden
│                        Python BufferedReader read-ahead.  Default
│                        (timeout = 0) keeps the buffered path for parity.
│                        When --bwlimit > 0 a combined-direction token bucket
│                        (_throttle, called from both read and write) sleeps
│                        to hold total wire throughput at the rate; burst is
│                        capped at one second's worth.  Client-side only — no
│                        protocol or remote-script change (pull is throttled
│                        via read() backpressure on the SSH pipe).  Bytes are
│                        counted pre-compression (upstream of ssh -C), so the
│                        limit is an upper bound on wire usage — exact for
│                        incompressible data, conservative (wire below RATE)
│                        for compressible.  The deficit-carry detail (do NOT
│                        zero a negative balance after sleeping) is load-
│                        bearing: zeroing double-credits and runs ~2x over.
├── IOTimeout          — OSError subclass raised by IOCounter when the
│                        --io-timeout watchdog fires.  Listed alongside
│                        BrokenPipeError / ConnectionResetError / EOFError
│                        in do_sync's per-section except clause.
├── ConnectionLost     — RuntimeError subclass carrying the section start
│                        offset and an `interrupted` flag (True on Ctrl+C,
│                        False on pipe error).  Used for resume reporting.
├── parse_size()       — converts "64K" / "10G" strings to integer bytes.
├── available_memory() — queries OS for available physical RAM via sysconf;
│                        used to cap section size when --buffer is active.
├── format_time()      — formats seconds as "m:ss" / "h:mm:ss" for progress
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
│                        the current argv and the failed section offset.  Always
│                        appends `-r OFFSET`; __main__ decides whether to print
│                        it at all (see the `progressed()` gate below).
├── ssh_base()         — builds the shared ssh flag list (compress, port,
│                        identity, user `-o`, keepalive).  Used by both
│                        build_ssh_cmd() and external_hash_remote() so the
│                        --verify cross-check reaches the remote over the same
│                        connection options as the transfer.
├── build_ssh_cmd()    — assembles the ssh argv list from ssh_args dict
│                        (starting from ssh_base()).  Dispatches three remote
│                        variants in order: python3 → remote_script_mt
│                        (threaded, hex-encoded), python2/python →
│                        remote_script (single-threaded), perl → remote_perl.
│                        First interpreter found wins.  ssh_base() appends
│                        `-o ServerAliveInterval=15 -o ServerAliveCountMax=4`
│                        after the user's `-o` options so a dropped TCP
│                        connection surfaces as a BrokenPipeError within
│                        ~60s instead of hanging.  User `-o` wins because
│                        ssh applies the first matching `-o`.
├── spawn_hash()       — the --verify BLAKE3 cross-check (out-of-band, NOT a
│   / collect_hash()     protocol change).  b3sum_local_cmd() / b3sum_remote_
│   / b3sum_*_cmd()      cmd() build the `b3sum LOCAL` and `ssh HOST b3sum
│   / verify_digest()    REMOTE` (shell-quoted) commands; spawn_hash() starts
│   / device_size()      each as a Popen so __main__ runs both CONCURRENTLY
│   / dd_hash_params()   (wall-clock = slower side, not the sum); collect_hash()
│   / hash_desc()        waits one and returns its digest.  verify_digest()
│                        extracts the leading hex token (paths differ between
│                        sides, so only the digest is compared).  --verify only
│                        compares the bytes bscp copied — the prefix
│                        [0, sync_size) — so EVERY side larger than that prefix
│                        is dd-limited down to it (a size mismatch → the one
│                        larger side; a -B cap → BOTH).  b3sum_*_cmd() emit
│                        `dd bs=BS count=COUNT 2>/dev/null | b3sum` (guarded by
│                        `command -v dd || exit 127`, so a missing dd is a skip,
│                        not a false zero-byte-hash mismatch).  dd_hash_params()
│                        picks BS — the largest divisor of the prefix <= 1 MiB,
│                        >= 4 KiB — or None (skip) when none divides evenly.
│                        hash_desc() renders how each side was invoked (plain or
│                        dd-prefixed) for the report; a -B copy that leaves the
│                        source tail uncopied also prints an incomplete-backup
│                        warning.  The remote
│                        ssh reuses ssh_base() — its ServerAliveInterval
│                        keepalive holds the idle channel open while b3sum
│                        runs for minutes — and adds `-tt` (force remote PTY)
│                        plus stdin=DEVNULL so a Ctrl+C SIGHUPs the remote
│                        b3sum instead of orphaning it behind a multiplexing
│                        master (see docs/verify.md).  device_size() seek-to-end sizes a
│                        path because os.path.getsize() reports 0 for block
│                        devices.  Orchestrated in __main__ after a successful
│                        copy: both processes are polled in a loop that prints
│                        each side's digest the moment its b3sum exits (so the
│                        first hash is recorded straight away, not held up by
│                        the slower side) and renders a live countdown between
│                        them — a T-minus to do_sync's returned scan-time
│                        estimate that flips to a +m:ss count-up once the run
│                        outlasts it; see docs/verify.md.
├── do_sync()          — all transfer logic for both push and pull.  Hosts
│                        a `show_copy_progress` closure that all three
│                        phase-B branches (push, push --buffer, pull) share.
│                        Phase A hashes local blocks on a ThreadPoolExecutor
│                        (`ex_hash`) via a bounded feed/drain window
│                        (`hash_window` = 2× workers) that preserves wire
│                        order; see docs/remote-execution.md.  Also returns
│                        `remote_size` (drives the --verify size-mismatch
│                        decision — whole-device vs dd-limited prefix) and
│                        `total_scan_time` (phase-A read+hash seconds, excluding
│                        copy — __main__ turns it into the --verify duration
│                        estimate).  When --verify is set and the sizes differ,
│                        do_sync prints the heads-up note at handshake (before
│                        the copy) so the prefix-only check is announced early.
└── __main__           — argparse, push/pull auto-detection, retry loop, and
                         the post-copy --verify orchestration (exit 4 on a
                         confirmed mismatch).  On abort (ConnectionLost or
                         Ctrl+C) a resume command is printed only when
                         `progressed(offset)` is true — i.e. the resume offset
                         advanced past `initial_offset`, the section-rounded
                         start of this run.  If no section completed, the
                         resume offset still equals the start, so the command
                         would merely reproduce the original invocation; bscp
                         then prints the bare `Interrupted` / `Connection lost`
                         line.  Compared against the initial offset, not the
                         retry-mutated `start_offset`, so progress banked by an
                         earlier attempt is still surfaced when a later one
                         stalls without advancing.  BSCP_OPTIONS (shell-split) is
                         prepended to argv before parse_args() so it supplies
                         default options that an explicit flag still overrides
                         (per-host tuning, e.g. `-T 8 -b 192K`).
```

## Module-level constants

`DEFAULT_BLOCK` and `DEFAULT_SECTION` are defined at module level (not inside
`__main__`) so that `build_resume_cmd()` can compare against them to decide
which options to omit from the reconstructed command line.

`DEFAULT_HASH_THREADS` (0 = auto) and `HASH_THREADS_CAP` (4) configure the
phase-A hashing pool; `resolve_hash_threads(n)` maps the user value to a
concrete worker count: an explicit `n > 0` is `min(n, os.cpu_count())` —
honoured but never more threads than cores — and auto (`n <= 0`) is
`min(os.cpu_count(), CAP)`.  The client resolves its own count via this
helper; the remote receives the raw `--hash-threads` value baked into its
`_remote(N)` call and resolves it the **same way against its own cores**, so
`-T 8` to a 4-core remote runs 4 threads there (and up to 8 on an 8-core
client), and `0` lets each side auto-detect independently.

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
| `PULL_WINDOW`    | `128`        | Batch size for pull phase B (see docs/protocol-internals.md)         |

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
`ALLOW_TRUNCATE` are defined in the client module **and** inside **both**
remote Python strings (`remote_script` and `remote_script_mt`) **and** the
`remote_perl` string.  Any protocol change must be made in **all four**
places.  The `PULL_WINDOW` constant lives only in the client — the server is
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

## Testing

A bash regression harness lives at `tests.sh` in the repo root.  It runs
against `localhost:` and exercises every code path the manual tests used
to cover, plus a few that were easy to forget:

| Test                                             | What it catches                                   |
| ------------------------------------------------ | ------------------------------------------------- |
| push: random 4K diffs in mid-file                | basic push round-trip, hash-exchange correctness  |
| pull: random 4K diffs in mid-file                | basic pull round-trip, windowed phase B           |
| dry-run leaves destination unchanged             | `-N` does not write; md5 before == after          |
| resume from a mid-file section boundary          | `-r` aligns to section, only re-scans the tail    |
| resume from a percentage of local file size      | `-r NN%` resolves against local size, then rounds |
| perl remote: push (`BSCP_FORCE_PERL=1`)          | wire compatibility of the Perl fallback (push)    |
| perl remote: pull (`BSCP_FORCE_PERL=1`)          | wire compatibility of the Perl fallback (pull)    |
| legacy remote: push (`BSCP_FORCE_PYTHON2=1`)     | single-threaded `remote_script` push (not the MT) |
| legacy remote: pull (`BSCP_FORCE_PYTHON2=1`)     | single-threaded `remote_script` pull (not the MT) |
| `--buffer` push                                  | the in-memory diff-block buffer path              |
| `--bwlimit` push throttles to rate               | token-bucket rate limit engages (timing floor)    |
| `--hash-threads 4` push (multi-section)          | threaded phase-A feed/drain, digest wire order    |
| `--hash-threads 1` pull (serial pool path)       | threaded path correct when degenerate to 1 worker |
| `--allow-truncate` push (smaller dst)            | both refusal-without-flag and warning-with-flag   |
| `--allow-truncate` pull (smaller dst)            | symmetric pull behaviour                          |
| `--batch` is silent on success and exits 0       | no stderr leakage; exit-code-only contract        |
| `--block-count` prints next-offset resume hint   | `Continue with: ... -r 4M` chaining               |
| `-B` accepts K/M/G byte-size suffix              | suffixed -B is bytes, rounded up to whole blocks  |
| `-B` pull within dst size needs no truncate flag | -B does not spuriously trip the truncate check    |
| `-B` beyond dst size still requires `--truncate` | -B and --allow-truncate stay independent          |
| `-B` overshoot prints warning, exits 0           | calculated size > actual source warns, syncs rest |
| exit 2 when neither side is HOST:path            | argparse path                                     |
| friendly error when local file is missing        | OSError → `Error: Cannot open local file ...`     |
| reject unknown / zero-digest `-a` algorithm      | `parse_algorithm` guard: exit 2, names the algo   |
| connection failure engages retries, exits 3 | handshake-stage conn loss → `ConnectionLost`, not fatal exit 1; no redundant `-r 0` printed when no section completed |
| `format_size` + `parse_size` unit tests          | display 4-digit cap rule + lossless round-trip    |
| `--verify` push, matching b3sum                  | local+remote b3sum run, compared, "verify OK"     |
| `--verify` detects a mismatch, exits 4           | divergent digests → "VERIFY FAILED", exit 4       |
| `--verify` skips gracefully when b3sum missing   | absent/failing b3sum warns, exit stays 0          |
| `--verify` compares common prefix on size mismatch | `--allow-truncate` smaller dst → dd-limit larger side, handshake note, "verify OK ... over the first N" |
| `--verify` under `-N` runs when scan finds 0 diffs | dry-run + identical → b3sum confirms, "verify OK"  |
| `--verify` under `-N` skips when diffs pending   | dry-run + diffs → skipped, destination untouched  |
| `--batch --verify` mismatch is silent, exits 4   | exit code is the only mismatch signal under batch |
| `--batch --verify` size mismatch silent, exits 0 | dd-limited prefix compare succeeds silently under batch |
| `--batch --verify` unavailable silent, exits 5   | failing b3sum under batch → verify-not-performed signalled |
| `--verify` `-B` compares prefix, warns incomplete | -B → dd-limit BOTH sides to copied prefix, "verify OK ... over the first N (partial copy: -B)", incomplete-backup warning |
| `--batch --verify` `-B` verifies prefix, exits 0 | -B+batch+verify no longer rejected — clean prefix exits 0 silently |
| `--verify` `-B` `-N` suppresses incomplete warning | dry-run copies nothing → no incomplete-backup warning, prefix still verified |
| `BSCP_OPTIONS` default options take effect       | env options prepended to argv before parse_args   |
| `BSCP_OPTIONS` overridden by explicit CLI option | explicit flag wins (env placed first, last wins)  |

Prerequisites: `python3` on PATH, and passwordless `ssh localhost`.  Run:

```bash
./tests.sh
# or, when testing a different binary (e.g. a Nuitka build):
BSCP=./bscp.nuitka ./tests.sh
# or the Py2 client (skips 14 py3-only tests when `python` is Python 2):
BSCP=./bscp.python2 ./tests.sh
```

The script writes its fixtures into a `mktemp -d` directory and removes
them on exit.  Exit status is `0` on success, `1` if any test failed (with
the failing names listed at the end), or `2` on missing prerequisites.

When `$BSCP` runs under a Python 2 interpreter (detected from its shebang
plus `python -V`), twelve tests are skipped by default and reported as
`skip`: the two `--hash-threads` tests (the option is python3-only), the
`-a` algorithm-rejection test (Py2's `hashlib` lacks the `shake_*` XOF
functions it probes), and the nine `--verify` tests (the convenience b3sum
cross-check is not implemented in the python2 client, so the flag is
unrecognised).  The two `BSCP_OPTIONS` tests run under the python2 client
too (it now honours the env var).  Pass `--force-all` to run every test
regardless of interpreter.

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
scan SCANNED/TOTAL (PCT%) diff blocks=N (PCT%) (SPEED MiB/s) ELAPSED (ETA)
```
- `SCANNED/TOTAL` — cumulative bytes across all sections, not per-section
- first `(PCT%)` — percentage of file scanned
- `diff blocks=N` — cumulative diff count; second `(PCT%)` — diffs as fraction of
  blocks scanned
- `ELAPSED` / `(ETA)` — wall-clock elapsed and estimated remaining in `m:ss` format.
  ETA uses a unified time-budget model (see [docs/eta-model.md](docs/eta-model.md)).  During the
  first 20s of the run the `(ETA)` field is omitted entirely from the progress
  line (warmup; rate EMAs still seeding — no number is shown rather than a
  placeholder).  After warmup, if the rates are still bootstrap-quality (no copy
  data yet on a run that does have diffs to copy, and < 5% scanned), ETA is shown
  as `~m:ss` to signal that the estimate is a bootstrap guess.

Progress format during copy (mirrors the scan layout — same column order so the
display does not visually re-arrange between phases):
```
copy WPOS/TOTAL (PCT%) block C/N (SEC_PCT%) (SPEED KiB/s) ELAPSED (ETA)
```
- `WPOS/TOTAL` — current block write offset / total file size; first `(PCT%)` is
  overall file position.  `WPOS` is the start offset of the block being written, so
  it never reaches 100% — by design, to avoid misreading a section's last frame as
  whole-file completion.
- `block C/N` — cumulative blocks copied so far across all sections (`C`) over the
  cumulative diff-block count discovered by scan so far (`N`).  During the copy of
  any one section, `N` is frozen at the value scan ended on for sections processed
  so far; it advances when the next section's scan completes.
- `SEC_PCT%` — running fraction of this section's diff blocks copied
  (`blocks_done_this_section / section_diff_count`).
- `ELAPSED` / `(ETA)` — same convention as scan; same unified model
  (see [docs/eta-model.md](docs/eta-model.md)).

Progress format during `--verify` (while the `b3sum` processes run):
```
verify: hashing WHAT with b3sum (COUNTDOWN)
```
- `WHAT` — the side(s) still hashing: `both ends`, then `the remote file` /
  `the local file` once the first side finishes.  Each side's digest is
  printed on its own line the moment its `b3sum` exits (`verify: local b3sum
  PATH = …` / `verify: remote b3sum PATH = …`), so the first hash is recorded
  without waiting on the slower side.
- `COUNTDOWN` — a launch-style T-minus toward `eta`, the scan-time estimate
  (see docs/verify.md).  Shown as `(-m:ss)` while time remains, flipping to
  `(+m:ss)` and counting up once the run outlasts the estimate (signalling it
  was low).  The field appears only once *elapsed* clears `ETA_WARMUP_SECS`
  (the same threshold the scan/copy ETA uses); below that it is a bare `...`,
  since a sub-warmup number is noise.  There is no separate wall-clock field.
  Suppressed by `-q`/`--batch` like other progress.

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
| `4`       | `--verify` mismatch (local/remote b3sum differ)|
| `5`       | `--verify` not performed under `--batch`       |
| `130`     | Interrupted (Ctrl+C)                           |

`--verify` adds exit `4` (mismatch) and exit `5`.  Exit `5` exists only
because `--batch` suppresses stderr: a verify that *could not run* (`b3sum`/`dd`
missing or failing on either side, or a copied prefix with no usable `dd` block
size) would otherwise warn and exit `0`, which under `--batch` is
indistinguishable from a clean success.  So under `--batch` those skip
conditions exit `5` instead (see `verify_unavailable()` in `__main__`);
**without** `--batch` they stay visible warnings with exit `0`.  A size
mismatch and a `-B` partial copy are **not** skip conditions — they are prefix
comparisons (every side larger than the copied prefix is dd-limited to it), so
they yield a real exit `0`/`4`.  (`-B` together with `--batch --verify` used to
be rejected at argparse with exit `2`; that pre-validation was removed once the
copied prefix became verifiable.)  `--resume-from` likewise verifies the
cumulative copied prefix, so an incomplete resume surfaces as a normal exit `4`
mismatch.

Both flags are forwarded into the resume command printed by
`build_resume_cmd()`, so a resumed invocation keeps the same verbosity level.

`--batch` is exit-code-only by design: there is no sensible way to convey a
resume offset through an 8-bit status, so callers that need to resume on
connection loss should use `-q` instead and parse the `Resume with: ...`
line that goes to stderr.  That line is printed only when the run banked
progress past its start offset (see `progressed()` above); an abort with no
completed section prints a bare `Interrupted` / `Connection lost` instead,
so a parser must treat the line's *absence* as "rerun the original command".

`-r` / `--resume-from` accepts either a byte offset (with optional K/M/G/T
suffix) or a percentage (`NN%` / `NN.N%`, 0–100).  The percentage is
resolved in `main()` against `device_size(local_file)` (seek-to-end, *not*
`os.path.getsize`, which reports 0 for block devices and would silently
collapse any `NN%` to offset 0) before
section-boundary rounding, so it matches the displayed scan percentage in
the common cases (push, or pull where local and remote are the same size).
With `--allow-truncate` and a destination smaller than the source, the
displayed percentage is against `sync_size = min(local, remote)` while
`-r NN%` is against the local file size — use a byte offset for precision
in that edge case.

## Style conventions

- Python 3.6+ only on the client; no compatibility shims.
- The remote script body must stay 2.6+/3.x compatible (see
  docs/remote-execution.md).
- No external dependencies.
- No comments except where the *why* is non-obvious.
- `remote_script` uses compact style (fewer blank lines) to keep the
  embedded string readable at a glance.
- All struct formats use lowercase `<` prefix for explicit little-endian.
