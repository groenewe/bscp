# Remote execution model

> Part of the bscp developer documentation. See [CLAUDE.md](../CLAUDE.md) for the architecture overview and index.

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
- **All stdin reads go through `rd(n)`**, a read-exactly helper that loops
  until `n` bytes arrive or raises `EOFError` on a short read.  On a blocking
  pipe a short read means EOF (lost SSH connection); acting on it directly
  would silently write a truncated block to the destination in push phase B.
  This mirrors the Perl remote's `r()` helper and the client's own
  short-read guards.  `EOFError` is **not** an `OSError` subclass on
  Python 2, so it is named explicitly in the section-loop `except`
  clause and in the handshake-phase `try/except`.  Never call
  `stdin.read()` directly in the remote body — use `rd()`.
- **Indent with TABS, not spaces** (applies to all three remote literals —
  `remote_script`, `remote_script_mt`, `remote_perl`).  Two of them are
  hex-encoded onto the ssh command line; one tab replaces a 4-space indent
  unit, roughly halving the leading-whitespace bytes on the wire (deepest
  nesting saves most).  Python accepts pure-tab indentation; Perl ignores
  indentation entirely.  The surrounding `bscp` client code stays 4-space
  indented — the tabs are *inside string literals*, so they do not affect
  this file's own indentation and raise no `TabError`.  A `# vim: set ts=4:`
  modeline at the end of `bscp` renders the embedded tabs at width 4; a note
  above `remote_script` records the convention.  When editing a remote
  literal, keep tabs (don't let an editor expand them to spaces).

## Remote process marker

Each `exec`'d remote command in `build_ssh_cmd()` ends with a literal
`bscp-remote` argument (`... -c "<script>" bscp-remote`, `perl -e '...'
bscp-remote`).  The remote bodies never read `argv`, so it is inert, but it
lands in the remote process command line — `ps aux | grep bscp-remote` or an
htop search locates the remote process on the destination host.  It applies
to all three variants (python3/MT, python2/legacy, perl).  Keep it the last
token of each branch; a protocol/dispatch change must preserve it.

## Read-only destinations and write failures

All three remote bodies run the same two guards on a push, and both are
reported through the exit status (see PROTOCOL.md §5.1) rather than the wire
format, so no protocol version is involved:

- **Before the scan** (exit **4**): a Linux block device carrying the
  read-only flag — `losetup -r`, `blockdev --setro`, a read-only dm/MD
  target, read-only media — still returns a usable fd from
  `open(O_RDWR)`; `blkdev_write_iter()` rejects the *writes* with `EPERM`.
  A successful open therefore proves nothing, and the destination has to be
  asked directly: `ioctl(fd, BLKROGET)` (`0x125E`), non-zero meaning
  read-only.  The ioctl returns `ENOTTY` on anything that is not a block
  device, which is why no `S_ISBLK` pre-check is needed, and any error at
  all is read as "cannot tell — proceed".  The probe is Linux-only
  (`uname` / `$^O`) so the number is never issued to a foreign kernel's
  ioctl table.  It is skipped when the `DRY_RUN` mode bit is set: a dry run
  writes nothing, so it must still be able to report the block difference
  against a read-only device.  A regular file on a read-only mount needs no
  probe — there the `open('rb+')` itself fails, which is the pre-existing
  exit-1 path.
- **During phase B** (exit **3**): the write, and the per-section `flush()`
  that follows it (a block smaller than the writer's buffer would otherwise
  surface its error only at close, past every handler and silent under
  `--batch`), report the offset and errno on stderr — which ssh forwards to
  the client terminal — and leave via `os._exit()`.  A plain `sys.exit()`
  would re-raise the same error out of the file object's close-time flush
  and bury the status under a traceback; the Perl body closes the handle
  explicitly for the same reason, since its implicit close would otherwise
  print a second warning over the message.

Both statuses mean "permanent": the client turns them into fatal errors
instead of `ConnectionLost`, so `--retries` does not re-scan the whole
device only to fail identically at the same offset.

The client applies the same `BLKROGET` probe to *its* side (`device_readonly()`)
when the local file is the destination — i.e. on pull — mirroring the
symmetric size checks.

## Multi-threaded hashing (`--hash-threads`)

On fast storage (NVMe, or any local/loopback transfer) the scan phase is
CPU-bound: a single core computing one digest after another saturates while
the disk sits idle.  `--hash-threads N` fans the per-block hashing across a
thread pool.

**Why threads, not processes.** CPython's `hashlib` releases the GIL while
hashing buffers ≥ 2048 bytes, so a `ThreadPoolExecutor` gives true
parallelism at the default 64 KiB block size — no `multiprocessing`, no
pickling, no IPC.  With a custom `blocksize` below ~2 KiB the GIL is not
released and threading yields nothing; that is an accepted edge, not a bug.

**No protocol change, no negotiation.** The wire contract is digest *order*
only.  Each side hashes its own file independently and emits digests in
block order, so client and remote pick their thread counts independently —
nothing about parallelism crosses the wire.  The 49-byte header is
untouched.  The client controls the remote count only by baking the integer
into the remote's `_remote(N)` call (`N` = `--hash-threads`; `0` lets the
remote auto-detect its own cores via `min(os.cpu_count(), 4)`).

**Where it runs.** python3 only, on *both* ends: the client (`do_sync`
phase A) and the python3 remote (`remote_script_mt`).  The python2/python
remote (`remote_script`), the Perl remote (`remote_perl`), and the
`bscp.python2` client are all single-threaded by design — speeding only one
side leaves the other core-bound, so the gain there would be marginal and
not worth the complexity/fragility on the fallback paths.

**Order-preserving bounded pipeline.** Both ends use the same shape: reads
stay single-threaded and sequential (fast, and avoids seek thrash); only
hashing is offloaded.  A `deque` of in-flight work is filled up to
`hash_window = max(2, 2 × workers)` blocks, then drained in submission
order — `future.result()` blocks until that specific block's digest is
ready, so digests reach the wire (remote) or the comparison loop (client)
in exactly the order `remote_script` would have produced them.  Peak extra
memory is `hash_window × blocksize` (e.g. 8 × 64 KiB = 512 KiB at 4
threads), independent of section size.  On the client the in-flight tuple is
`(pos, block, future)` so `--buffer` push still has the block in hand when a
diff is recorded; `done_pos = pos + len(block)` drives the scan-progress
counter (the feed pointer `p` runs ahead by the window and must not be used
for progress).

The pool is created once per `do_sync` call / per remote invocation and
`shutdown(wait=False)` on exit (client: a `finally` on the section loop;
remote: a `finally` around the loop).

**Tuning.** Auto caps at 4 (`HASH_THREADS_CAP`) — hashing parallelism
plateaus once cores outrun sequential read + pipe drain, and higher counts
add scheduler/pipe contention for little gain.  A measured localhost run
(16 cores, 600 MiB, both ends hashing) went 3.6 s → 1.9 s from N=1 to N=4.
An explicit `-T N` overrides the cap but is still clamped to each side's own
core count: the raw value is baked into `_remote(N)` and the remote resolves
it against *its* `os.cpu_count()`, so `-T 8` to a 4-core box runs 4 threads
there (never more threads than cores), matching the client's
`resolve_hash_threads`.

## Perl fallback (`remote_perl`)

`remote_perl` is a functional twin of `remote_script` for hosts that have
no Python interpreter on `PATH`.  It speaks the same wire protocol — any
change to `HEADER_FMT`, the mode bits, or the section/phase-A/phase-B
contract must be made in **four** places now: client constants,
`remote_script`, `remote_script_mt`, and `remote_perl`.

Unlike the Python remote, `remote_perl` is **not** subject to the no-`$` /
no-`%` / no-`"` rules.  `build_ssh_cmd()` hex-encodes the source and the
remote shell runs it via:

```sh
perl -e 'eval pack(qq{H*}, q{<hex>})'
```

The bash single-quotes protect against bash; the hex alphabet is inert in
any quoting context; Perl's `q{...}` accepts the hex string with no
escaping; `pack 'H*', ...` decodes; `eval` runs.  Cost: the encoded form
is 2× the source size, currently ~5.5 KB (`remote_perl`) / ~6.2 KB
(`remote_script_mt`) on the SSH command line — well within `ARG_MAX`.

Perl version requirements: 5.10+ (2007) for the `Q<` little-endian pack
format and the `\z` regex anchor.  The body uses `Digest::SHA` (core since
5.9.3) and `Digest::MD5` (core since 5.7.3); both are universal in modern
Perl distributions.

Hash-algorithm support on the Perl remote is limited to `make_hash`'s set:
`md5` plus `sha1`/`sha224`/`sha256`/`sha384`/`sha512` — the portable six
(`PORTABLE_ALGOS` on the client).  The Python remotes accept anything their
`hashlib` exposes, so a `sha3_*`/`blake2*` etc. `-a` value only works when
the remote resolves to python3 or python2 *and* that build's `hashlib` has
the algorithm.  The client lists its own locally-available extras in
`bscp -h` but cannot know the remote's set in advance; an unsupported
algorithm surfaces as a remote handshake error.  XOF/variable-length
functions (`shake_*`, `digest_size == 0`) are filtered out of the help
list because the wire protocol assumes a fixed digest size.

The wrapper tries python3 (threaded `remote_script_mt`), then python2/python
(single-threaded `remote_script`), then Perl, then prints
`bscp: no python or perl found on remote` and exits 127.  Two **client**
environment hooks let tests.sh reach paths a fully-equipped host would
otherwise never run:

- `BSCP_FORCE_PERL=1` makes `build_ssh_cmd()` skip both Python branches, so
  the Perl fallback runs even where python is installed.
- `BSCP_FORCE_PYTHON2=1` skips the python3/`remote_script_mt` branch, so the
  single-threaded legacy `remote_script` runs even where python3 is present
  (it executes under the first of `python3 python2 python` found — testing
  the *script*, not specifically the python2 *binary*, so it works on a
  python3-only host).

`BSCP_FORCE_PERL` takes precedence over `BSCP_FORCE_PYTHON2` if both are set.

## Reporting the remote toolchain (`--verbose` / `--check-tools`)

Some bscp behaviour depends on external helpers on the remote — `dd` and
`b3sum` for the `--verify` cross-check — and on which interpreter the wrapper
ends up choosing.  `--verbose` (`-v`) and `--check-tools` surface all three
without a protocol change, by making the remote **report over its own
stderr**, which ssh already forwards to the client terminal (the existing
`echo "bscp: no python or perl found on remote" >&2` line proves the channel
works).

When either flag is set (and `--batch` is not), `build_ssh_cmd()` assembles
the wrapper through an `_exec()` helper instead of the plain
`<cond> && exec …;` clauses:

- A **tool probe** is prepended:
  `for t in dd b3sum; do command -v "$t" … && echo "bscp-<tag>: $t=yes" >&2 || echo "bscp-<tag>: $t=no" >&2; done;`
- Each interpreter dispatch is wrapped so the chosen one announces itself just
  before it `exec`s away:
  `<cond> && { echo "bscp-<tag>: interpreter=… " >&2; exec …; };`

`<tag>` is `remote` for a real ssh remote and `dst` for the local-to-local
destination.  Because the echo happens *before* `exec` (and `exec` replaces
the process), the reported interpreter is exactly the one that runs.

Two constraints made this safe to inline:

- The verbose wrapper embeds the hex/script payloads **immediately** (in
  `_exec()`), not through a deferred `%`-format over the whole wrapper string,
  so the injected echo text can contain arbitrary characters without risking
  `%`-format interpretation.  The **non-verbose** wrapper is assembled the same
  way and is byte-for-byte identical to the previous deferred-format version
  (the payloads contain no `%`, which is also why the old deferred format
  worked).
- The wrapper shell text itself was never under the no-`$`/no-`%`/no-`"` rules
  (those apply only to the embedded `remote_script` Python source), so `$t`,
  `>&2`, and the quoted `echo` strings are all fine.

`--check-tools` additionally short-circuits in `__main__`: it spawns that same
wrapper, closes the subprocess stdin so the remote's handshake `rd()` hits EOF
and it exits cleanly right after printing, and then exits **without
transferring**.  Exit status is `0` once the report is produced, or `1` only
when ssh itself failed to connect (returncode 255); the remote body's own
EOF-driven `exit 1` is treated as success.  Local `dd`/`b3sum` availability is
reported separately in `__main__` via `shutil.which()`.

## Local-to-local (no ssh)

When neither `SRC` nor `DST` carries a `HOST:` prefix, `__main__` sets
`remote_host = None` and runs a **local-to-local** copy in push mode (client
reads `SRC`, the "remote" body writes `DST`).  `build_ssh_cmd()` builds the
*exact same* interpreter-probe wrapper string, but instead of handing it to
`ssh HOST` it runs it under a local shell:

```
['sh', '-c', wrapper, 'bscp-local']
```

So the same python3 → python2/python → perl dispatch, hex-encoding, and
`command -v` probing apply — the only difference is that the wrapper executes
on the local host and operates on `DST` as an ordinary local path.  The whole
wire protocol (handshake, phase A hash exchange, phase B) runs unchanged over
the subprocess pipe; there is no SSH, no network, and no protocol change.
`ssh_base()`'s compression and keepalive flags are irrelevant to a local pipe
and are skipped (the local branch returns before they are added).  The process
marker is `bscp-local` here rather than `bscp-remote`, so `ps aux | grep
bscp-local` finds the subprocess — but note it lands as `$0`, not as an
`exec … argv`, because the wrapper's own `exec "$py" … bscp-remote` still tags
the interpreter with `bscp-remote`.  Both markers may therefore be visible.

Because the local host now plays the remote's role too, it must itself have a
Python 2/3 or Perl interpreter available — even a Nuitka-built client (which
otherwise needs no local Python) needs one on `PATH` for local-to-local.

`BSCP_FORCE_PERL` / `BSCP_FORCE_PYTHON2` work in local mode as well, since the
wrapper string is shared.  The `--verify` cross-check adapts too:
`b3sum_remote_cmd()` returns the local `b3sum` command (no ssh, no PTY) when
`remote_host is None`, so both digests are computed locally.

A same-physical-disk guard (`warn_same_disk()` / `backing_disk()`) warns —
best-effort, Linux only — when `SRC` and `DST` resolve to one backing disk, so
the operator is aware of the read/write head contention before a slow copy.

### Ctrl+C in local mode

One thing the local subprocess does *not* share with an ssh remote: signals.
It is an ordinary child in the client's process group, so a terminal Ctrl+C is
delivered to it as well as to the client (an ssh remote never sees the signal
— the ssh client absorbs it and the channel simply closes).  Left to the
default disposition, the destination side would abort its blocking `rd()` with
an unhandled `KeyboardInterrupt` and print a traceback — which, because the
body is run as `python3 -c "exec(bytes.fromhex('...'))"`, includes the entire
hex payload — right across the client's own `Interrupted - Resume with:`
message.

All three bodies therefore ignore `SIGINT` (`signal.SIG_IGN`; Perl:
`$SIG{INT} = 'IGNORE'`) as their first act.  Shutdown stays client-driven:
the client's `_shutdown_proc()` closes stdin, the destination side reads EOF
and exits, and `proc.wait()` returns as before.  This costs nothing on the ssh
path, where the signal never arrives in the first place.

When editing `remote_perl`, remember the file is read by Python first:
backslashes that need to reach Perl (e.g. `\n`, `\&`, `\z` in regex)
must be doubled (`\\n`, `\\&`, `\\z`) in the Python triple-quoted string
literal.  Single quotes in the Perl source are fine — the outer Python
container is also single-quoted via `'''...'''`, so embedded `'` is a
literal quote, not a delimiter.
