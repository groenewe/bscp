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

When editing `remote_perl`, remember the file is read by Python first:
backslashes that need to reach Perl (e.g. `\n`, `\&`, `\z` in regex)
must be doubled (`\\n`, `\\&`, `\\z`) in the Python triple-quoted string
literal.  Single quotes in the Perl source are fine — the outer Python
container is also single-quoted via `'''...'''`, so embedded `'` is a
literal quote, not a delimiter.
