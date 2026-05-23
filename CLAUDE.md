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
- **`PROTOCOL.md`** — the wire-format spec.  Only touch this on actual
  protocol changes (header layout, mode bits, phase A/B contract).
- **`index.html`** — the public landing page.  Rarely needs updating;
  refresh only when the headline pitch changes.

A bug fix that does not change behaviour does not need doc updates.  A
change that adds, removes, or alters a flag does.

`bscp.python2` is an out-of-band Python-2.7 client fallback (see
[Python 2 client fallback](#python-2-client-fallback) below).  It is
**not** refreshed alongside every change to `bscp` — only at milestones
the maintainer chooses.  Day-to-day commits to `bscp` should leave
`bscp.python2` alone.

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
├── remote_perl        — Triple-quoted Perl translation of remote_script,
│                        used as a fallback when no Python interpreter is
│                        on the remote.  Hex-encoded by build_ssh_cmd() and
│                        decoded with `perl -e 'eval pack(qq{H*}, q{...})'`,
│                        which sidesteps the no-$, no-%, no-" rules that
│                        apply to remote_script.  Requires Perl 5.10+ for
│                        little-endian Q< pack format.
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
│                        the current argv and the failed section offset.
├── build_ssh_cmd()    — assembles the ssh argv list from ssh_args dict.
│                        Appends `-o ServerAliveInterval=15 -o ServerAliveCountMax=4`
│                        after the user's `-o` options so a dropped TCP
│                        connection surfaces as a BrokenPipeError within
│                        ~60s instead of hanging.  User `-o` wins because
│                        ssh applies the first matching `-o`.
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

| ---------------- | ------------ | -------------------------------------------------------------------- |
| Name             | Value        | Notes                                                                |
| ---------------- | ------------ | -------------------------------------------------------------------- |
| `HEADER_FMT`     | `'<QQQQQQB'` | 49-byte protocol header struct                                       |
| `MODE_PUSH`      | `0`          | Push/pull bit in mode byte (bit 0)                                   |
| `MODE_PULL`      | `1`          | Push/pull bit in mode byte (bit 0)                                   |
| `PUSH_PULL_MASK` | `1`          | Mask to extract push/pull bit from mode byte                         |
| `ALLOW_TRUNCATE` | `2`          | Flag bit in mode byte (bit 1): allow destination smaller than source |
| `PULL_WINDOW`    | `128`        | Batch size for pull phase B (see below)                              |
| ---------------- | ------------ | -------------------------------------------------------------------- |

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

## Symmetric size validation (do\_sync / _remote)

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

`fail()` is a closure that closes both `proc.stdin` and `proc.stdout` and
waits for the remote process before raising `RuntimeError`.  Closing stdin
unblocks the remote if it is waiting on `stdin.read()` (e.g. the post-go
read-2 in the handshake).  Closing stdout unblocks it if it is mid-stream
on `stdout.write()` — which happens when the wire-side `ALLOW_TRUNCATE`
bit is set (any `-B` use) but the client's authoritative check then
refuses, so the remote has already started streaming Phase-A hashes that
the client never reads.  Without closing stdout, `proc.wait()` would
deadlock against the remote's blocked write.

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

The remote's pull-phase-B loop flushes stdout after **every** block write
(both `remote_script` and `remote_perl`).  Per-block flush is a no-op when
`blocksize` ≥ Python's 8 KiB BufferedWriter buffer (the write already
bypasses the buffer), so default `64 KiB` blocks pay no measurable cost.
The flush exists to eliminate a latency-hiccup class where, with small
custom block sizes, blocks would otherwise sit in the remote's Python or
Perl I/O buffer waiting for buffer-fill before reaching the wire — a
read-side stall that looks identical to a deadlock under load.

## Memory model

| --------------------- | ------------------------------------ | ---------------------------------------------- | ------------------------------------ |
| Phase                 | Push (default)                       | Push (`--buffer`)                              | Pull                                 |
| --------------------- | ------------------------------------ | ---------------------------------------------- | ------------------------------------ |
| Phase A (per section) | O(diff\_blocks × 8) — positions only | O(diff\_blocks × blocksize) — positions+blocks | O(diff\_blocks × 8) — positions only |
| Phase B               | re-reads each block; O(1)            | consumed as sent                               | consumed as received                 |
| Peak                  | negligible                           | ≤ section\_size (all blocks differ)            | negligible                           |
| --------------------- | ------------------------------------ | ---------------------------------------------- | ------------------------------------ |

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

## Perl fallback (`remote_perl`)

`remote_perl` is a functional twin of `remote_script` for hosts that have
no Python interpreter on `PATH`.  It speaks the same wire protocol — any
change to `HEADER_FMT`, the mode bits, or the section/phase-A/phase-B
contract must be made in **three** places now: client constants,
`remote_script`, and `remote_perl`.

Unlike the Python remote, `remote_perl` is **not** subject to the no-`$` /
no-`%` / no-`"` rules.  `build_ssh_cmd()` hex-encodes the source and the
remote shell runs it via:

```sh
perl -e 'eval pack(qq{H*}, q{<hex>})'
```

The bash single-quotes protect against bash; the hex alphabet is inert in
any quoting context; Perl's `q{...}` accepts the hex string with no
escaping; `pack 'H*', ...` decodes; `eval` runs.  Cost: the encoded form
is 2× the source size, currently ~6.5 KB on the SSH command line — well
within `ARG_MAX`.

Perl version requirements: 5.10+ (2007) for the `Q<` little-endian pack
format and the `\z` regex anchor.  The body uses `Digest::SHA` (core since
5.9.3) and `Digest::MD5` (core since 5.7.3); both are universal in modern
Perl distributions.

The wrapper tries Python first, then Perl, then prints
`bscp: no python or perl found on remote` and exits 127.  Setting
`BSCP_FORCE_PERL=1` in the **client** environment makes `build_ssh_cmd()`
skip the Python branch entirely; this is the hook tests.sh uses to
exercise the Perl path on a host where both interpreters are installed.

When editing `remote_perl`, remember the file is read by Python first:
backslashes that need to reach Perl (e.g. `\n`, `\&`, `\z` in regex)
must be doubled (`\\n`, `\\&`, `\\z`) in the Python triple-quoted string
literal.  Single quotes in the Perl source are fine — the outer Python
container is also single-quoted via `'''...'''`, so embedded `'` is a
literal quote, not a delimiter.

## Nuitka builds

Two single-file binaries are checked in next to the source: `bscp.amd64`
(x86-64) and `bscp.arm64` (aarch64).  Both were built with Nuitka in
`--mode=onefile` against Python 3.14.3 and **do not require Python on the
client host** (the binary embeds the interpreter and the `bscp` source).
The remote side still needs `python3`, `python2`, `python`, or `perl` on
`PATH` (the binary embeds both `remote_script` and `remote_perl`); it
only replaces the local interpreter, not the embedded protocol.

Build environments:

- `bscp.amd64`: Ubuntu 22.04 (amd64 desktop) (produced binary works on Ubuntu Jammy installs and higher)
- `bscp.arm64`: Ubuntu 24.04 (Raspberry Pi)

To rebuild:

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

## Python 2 client fallback

`bscp.python2` is a parallel client script that runs unchanged on
Python 2.7 *and* Python 3.x.  It exists for the rare case of copying
between a modern host and a legacy box where neither `python3` nor a
Nuitka binary is available locally — e.g. an old RHEL/CentOS install,
an embedded device, or a vendor appliance.  The remote side still uses
the regular `remote_script` / `remote_perl` (which already run under
both Python 2.6+ and 3.x), so wire compatibility is automatic.

**Maintenance policy.**  `bscp.python2` is **not** refreshed on every
change to `bscp`.  The maintainer brings it up to parity at milestones
only (new minor release, before a tagged stable, etc.).  Day-to-day
changes to `bscp` should not touch `bscp.python2`; commits that *do*
update it should say so explicitly in the message.  Testing the Py2
client on every commit is also not required — the regression harness
exercises it implicitly when run against `bscp.python2`, but that is
opt-in via `BSCP=./bscp.python2 ./tests.sh`.

**Feature parity vs. `bscp`.**  `bscp.python2` carries the full feature
set with one deliberate exception:

- `--io-timeout` is dropped.  Its raw-fd `os.read` / `os.write` path
  driven by `select.select()` works cleanly in Python 3 with
  `memoryview` slicing into `os.write`; in Python 2 the same construct
  is fragile across slice/buffer-protocol edge cases, and the feature
  is not worth the risk for the fallback.  The SSH
  `ServerAliveInterval=15` keepalive (kept) still surfaces a dropped
  TCP connection within ~60 s, which is good enough for the rare hosts
  that need the Py2 client.

Everything else — section-based scan/copy, `--buffer`,
`--allow-truncate`, `-B`, resume, retries, the unified ETA model with
EMA-smoothed scan/copy rates and display damping, the Perl remote
fallback — is identical to `bscp`.

**Py2/3 compatibility shims** (all confined to `bscp.python2`):

| ----------------------------------------------------------- | ---------------------------------------------------------------------- |
| Shim                                                        | Why                                                                    |
| ----------------------------------------------------------- | ---------------------------------------------------------------------- |
| `#!/usr/bin/env python`                                     | Resolves to whichever `python` is on `PATH` (2 or 3).                  |
| `# -*- coding: utf-8 -*-`                                   | Source contains em-dashes / box-drawing chars in strings and comments. |
| `from __future__ import division`                           | `/` returns float on Py2 (matches Py3 semantics throughout the file).  |
| `import binascii` + `hexlify(...).decode('ascii')`          | `bytes.hex()` is Py3.5+.                                               |
| `try: from shlex import quote ...                           | `shlex.quote` is Py3.3+; Py2's `pipes.quote` is the same function.     |
|  except ImportError: from pipes import quote as _shquote`   |                                                                        |
| `_PIPE_ERRORS` tuple defined via try/except `NameError`     | `BrokenPipeError` / `ConnectionResetError` are Py3.3+.                 |
| `super(ConnectionLost, self).__init__(...)`                 | Py2 requires the explicit class+instance form.                         |
| `except (IOError, OSError) as e` on `open()`                | Py2 raises `IOError`; Py3 aliases it to `OSError`.                     |
| Single-element list-cell shims (`var[0]`) inside closures   | Py2 has no `nonlocal`.  Used for `t_last_progress`,                    |
|                                                             | `eta_displayed`, `eta_displayed_at`, `ema_scan_rate`, `ema_copy_rate`, |
|                                                             | `rate_prev_scan_secs`, `rate_prev_scanned`, `rate_prev_copy_secs`,     |
|                                                             | `rate_prev_written` — every variable mutated by a closure.             |
| `raise ConnectionLost(...)` without `from exc`              | `raise X from Y` is Py3-only; cause chain is dropped on Py2.           |
| ----------------------------------------------------------- | ---------------------------------------------------------------------- |

When updating `bscp.python2`, the procedure is `cp bscp bscp.python2`
followed by re-applying the shims above (the diff is mechanical and the
shim sites are easy to locate by grepping for `nonlocal`, `bytes.hex()`,
`shlex.quote`, `OSError as`, `BrokenPipeError`, and `from exc`).  After
the shims, re-run `python2 -m py_compile bscp.python2 && python3 -m
py_compile bscp.python2`, then `BSCP=./bscp.python2 ./tests.sh` under
both interpreters.  The `--io-timeout` removal also requires deleting
the `IOTimeout` class, the `IOCounter` raw-fd paths (`_read_raw`,
`_write_raw`), the `popen_bufsize` branch, the `DEFAULT_IO_TIMEOUT`
constant, and the argparse entry.

`bscp.python2` is **not** built with Nuitka — the prebuilt
`bscp.amd64` / `bscp.arm64` binaries already cover the no-Python-on-the-
client case, and they embed Python 3.14.  `bscp.python2` covers the
remaining corner: a client host that has Python 2.7 but neither
Python 3 nor a working Nuitka binary.

## Testing

A bash regression harness lives at `tests.sh` in the repo root.  It runs
against `localhost:` and exercises every code path the manual tests used
to cover, plus a few that were easy to forget:

| ------------------------------------------------ | ------------------------------------------------- |
| Test                                             | What it catches                                   |
| ------------------------------------------------ | ------------------------------------------------- |
| push: random 4K diffs in mid-file                | basic push round-trip, hash-exchange correctness  |
| pull: random 4K diffs in mid-file                | basic pull round-trip, windowed phase B           |
| dry-run leaves destination unchanged             | `-N` does not write; md5 before == after          |
| resume from a mid-file section boundary          | `-r` aligns to section, only re-scans the tail    |
| resume from a percentage of local file size      | `-r NN%` resolves against local size, then rounds |
| perl remote: push (`BSCP_FORCE_PERL=1`)          | wire compatibility of the Perl fallback (push)    |
| perl remote: pull (`BSCP_FORCE_PERL=1`)          | wire compatibility of the Perl fallback (pull)    |
| `--buffer` push                                  | the in-memory diff-block buffer path              |
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
| `format_size` + `parse_size` unit tests          | display 4-digit cap rule + lossless round-trip    |
| ------------------------------------------------ | ------------------------------------------------- |

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
scan SCANNED/TOTAL (PCT%) diff blocks=N (PCT%) (SPEED MiB/s) ELAPSED (ETA)
```
- `SCANNED/TOTAL` — cumulative bytes across all sections, not per-section
- first `(PCT%)` — percentage of file scanned
- `diff blocks=N` — cumulative diff count; second `(PCT%)` — diffs as fraction of
  blocks scanned
- `ELAPSED` / `(ETA)` — wall-clock elapsed and estimated remaining in `m:ss` format.
  ETA uses a unified time-budget model (see [ETA model](#eta-model)).  During the
  first 30s of the run the ETA reads `--:--` (warmup; rate EMAs still seeding).
  After warmup, if the rates are still bootstrap-quality (no copy data yet on a
  run that does have diffs to copy, and < 1% scanned), ETA is shown as `~m:ss`
  to signal that the estimate is a bootstrap guess.

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
  (see [ETA model](#eta-model)).

## ETA model

ETA = `remaining_scan_time + remaining_copy_time`, evaluated at every progress
tick from cumulative counters that survive section boundaries:

- `scan_rate` — time-weighted EMA over phase-A throughput; seeded from the
  cumulative average at the first sample where `total_scan_time` ≥
  `RATE_RELIABLE_SECS` (default 1.0s), then updated at every progress tick
  with `w = 1 − exp(−dt / RATE_EMA_TAU)` (default τ = 5s).  Lets ETA track
  real rate changes mid-run — HDD outer↔inner cylinder geometry, varying
  block-device queue depth, network jitter.
- `copy_rate` — same EMA construction over phase-B bytes/sec; seeded once
  cumulative copy time has reached `RATE_RELIABLE_SECS` **or** cumulative
  written has reached `RATE_RELIABLE_BYTES` (default 4 MiB), so fast
  transfers (localhost, 10 GbE) still seed from real data instead of staying
  in bootstrap forever.  Before the EMA is seeded the rate is bootstrapped
  as `scan_rate * blocksize / BOOTSTRAP_COPY_RATIO` (default ratio 50:1).
  Updated both at copy ticks (live) and at scan ticks (using cumulative
  `total_copy_time` / `total_written`, since copy phases are interleaved
  with longer scan phases and we don't want to wait until the next copy
  tick to seed).
- `diff_frac` — per-section diff-density EMA, blended with the in-progress
  section by its completion ratio.  Completed sections contribute their final
  fraction via `ema = α·sec_frac + (1−α)·ema` (`DIFF_EMA_ALPHA = 0.4`); within
  the current section the running fraction takes over linearly as the section
  scan completes (`w_running = sec_blocks_scanned / sec_blocks_total`).  Lets
  the projection follow varying diff rates across the file (e.g. only the
  middle region changed) without becoming jumpy.
- `remaining_scan_time  = unscanned_blocks / scan_rate`
- `est_future_diffs     = diff_frac * unscanned_blocks`
- `remaining_copy_bytes = (total_diffs + est_future_diffs) * blocksize - total_written`
- `remaining_copy_time  = remaining_copy_bytes / copy_rate`

When `--dry-run` is in effect, no blocks are transferred — `remaining_copy_time`
is forced to zero and the ETA collapses to scan-only.

The `~m:ss` bootstrap marker is displayed until the rate EMAs have been
seeded from real data (both `scan_rate` and `copy_rate`, or just `scan_rate`
under `--dry-run`).  As a fallback for runs that find zero differing blocks
— where `copy_rate` can never seed because no copy ever happens — the
marker also drops once `CONFIDENT_SCAN_FRAC` (default 1%) of the blocks
still to scan have been scanned: at that point the absence of diffs is
taken as authoritative, and the scan-rate EMA alone is enough to project
the remaining time.  Without this gate, a clean transfer of an unchanged
file would carry the `~` marker for its entire duration.

`total_scan_time` and `total_copy_time` accumulate strictly within their
respective phases (`t_phase_a_start` / `t_phase_b_start` deltas), so the two
rates do not contaminate each other.  During the live phase the active
timer is folded in via the `scan_active_since` / `copy_active_since`
arguments to `estimate_eta()`.

Display-side damping is applied unconditionally from the start: the
underlying estimate is still recomputed every progress tick (~0.5s), but
the displayed value is only re-snapped to the fresh estimate every
`ETA_REFRESH_INTERVAL` seconds (default 5s).  Between snaps the displayed
value counts down 1s per wall-clock second so the user sees a steady
countdown instead of per-tick EMA wiggle.  To avoid the early bootstrap
estimate ever reaching the screen at all, the first `ETA_WARMUP_SECS`
(default 30s) of the run displays `--:--` in the ETA slot — long enough
for the rate EMAs to seed from real data before any number appears.

An earlier design had a "downward floor clamp" (ETA may never drop faster
than 1s per wall-clock second) that applied unconditionally, even during
bootstrap.  That prevented bootstrap overestimates from being corrected:
once the floor anchored to an inflated initial value, the display crawled
down at 1s/s for the entire run.  A subsequent revision damped only after
the rate EMAs were seeded, but that left a per-tick-anchor bug — the
displayed value snapped to `fresh_eta` only on the first call, after
which `eta_displayed_at` was updated on every tick and the 5s threshold
never re-fired — and never became "confident" at all on zero-diff runs.
The current design — always damp, always snap on the 5s schedule, show
`--:--` until warmup ends, and grant scan-only confidence at 1%
scanned — addresses both.

Why this design: the old ETA was scan-only during phase A and
section-only-plus-future-scan during phase B, which made it jump at every
section boundary because future copy work was simply omitted from the
phase-A estimate.  The unified formula folds both into a single budget;
the downward clamp absorbs the per-section diff-density noise.

## Quiet and batch modes

`-q` / `--quiet` suppresses the `\r`-terminated scan/copy progress lines.
Errors, warnings, and the final summary line are still printed to stderr.

`--batch` suppresses **all** stderr output (implies `-q`).  The caller must
rely solely on the exit status:

| --------- | ---------------------------------------------- |
| Exit code | Meaning                                        |
| --------- | ---------------------------------------------- |
| `0`       | Success                                        |
| `1`       | Fatal error (I/O failure, remote error, etc.)  |
| `2`       | Bad arguments                                  |
| `3`       | Connection lost — resume with `--resume-from`  |
| `130`     | Interrupted (Ctrl+C)                           |
| --------- | ---------------------------------------------- |

Both flags are forwarded into the resume command printed by
`build_resume_cmd()`, so a resumed invocation keeps the same verbosity level.

`--batch` is exit-code-only by design: there is no sensible way to convey a
resume offset through an 8-bit status, so callers that need to resume on
connection loss should use `-q` instead and parse the `Resume with: ...`
line that goes to stderr.

`-r` / `--resume-from` accepts either a byte offset (with optional K/M/G/T
suffix) or a percentage (`NN%` / `NN.N%`, 0–100).  The percentage is
resolved in `main()` against `os.path.getsize(local_file)` before
section-boundary rounding, so it matches the displayed scan percentage in
the common cases (push, or pull where local and remote are the same size).
With `--allow-truncate` and a destination smaller than the source, the
displayed percentage is against `sync_size = min(local, remote)` while
`-r NN%` is against the local file size — use a byte offset for precision
in that edge case.

## Style conventions

- Python 3.6+ only on the client; no compatibility shims.
- The remote script body must stay 2.6+/3.x compatible (see above).
- No external dependencies.
- No comments except where the *why* is non-obvious.
- `remote_script` uses compact style (fewer blank lines) to keep the
  embedded string readable at a glance.
- All struct formats use lowercase `<` prefix for explicit little-endian.
