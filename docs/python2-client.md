# Python 2 client fallback (`bscp.python2`)

> Part of the bscp developer documentation. See [CLAUDE.md](../CLAUDE.md) for the architecture overview and index.

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
set with six deliberate exceptions.  Note that of the resilience-group
flags only `--io-timeout` is dropped — `--retries` and `--bwlimit` are both
present (`--bwlimit`'s combined-direction token bucket is plain arithmetic
that ports cleanly to Python 2):

- `--io-timeout` is dropped.  Its raw-fd `os.read` / `os.write` path
  driven by `select.select()` works cleanly in Python 3 with
  `memoryview` slicing into `os.write`; in Python 2 the same construct
  is fragile across slice/buffer-protocol edge cases, and the feature
  is not worth the risk for the fallback.  The SSH
  `ServerAliveInterval=15` keepalive (kept) still surfaces a dropped
  TCP connection within ~60 s, which is good enough for the rare hosts
  that need the Py2 client.

- `--hash-threads` is dropped — but only the **client-side** option and
  thread pool.  Multi-threaded hashing is a python3-only efficiency
  feature (see [remote-execution.md](remote-execution.md)); the Py2 client is a
  last-resort path for ancient hosts where the marginal throughput gain
  does not justify the threading complexity.  When refreshing
  `bscp.python2`, omit the `--hash-threads` argparse entry, the
  `ThreadPoolExecutor`/`deque` imports, the `DEFAULT_HASH_THREADS` /
  `HASH_THREADS_CAP` / `resolve_hash_threads` definitions, the `ex_hash`
  pool and `finally` shutdown, and keep the original serial phase-A loop
  (read → hash → compare).

  The *remote* side, however, is **not** dropped: `bscp.python2` still
  carries the `remote_script_mt` string verbatim, and its `build_ssh_cmd`
  still dispatches a python3 remote to that threaded variant (hex-encoded,
  via `binascii.hexlify`).  Because the Py2 client has no `--hash-threads`
  value to pass, the thread count baked into the remote's `_remote(N)`
  call is fixed at `0`, so the python3 remote auto-detects its own cores.
  Net effect: driving a modern python3 host *from* the Py2 client still
  gets multi-threaded remote hashing; only the local client's own hashing
  is single-threaded.

- `--verify` is dropped.  The post-copy b3sum cross-check is a
  convenience-only addition to the python3 client; it is **out of band** —
  it shells out to `b3sum` on each side (locally, and `ssh HOST b3sum` on
  the remote) with no protocol or remote-script involvement — so leaving it
  out of `bscp.python2` costs nothing on the wire.  When refreshing
  `bscp.python2`, omit the `--verify` argparse entry, the `ssh_base` /
  `verify_digest` / `dd_hash_params` / `hash_desc` / `_dd_guard` /
  `b3sum_local_cmd` / `b3sum_remote_cmd` / `spawn_hash` / `collect_hash`
  helpers, and the post-copy verify block in `__main__` (`do_sync` then need
  not return `remote_size` or `total_scan_time`).  `tests.sh` skips the
  twelve `--verify` tests under a
  Python 2 client.  Note `device_size` **is** carried (it predates `--verify`
  in spirit): the `-r NN%` resume path resolves the percentage against it,
  not `os.path.getsize`, which reports 0 for block devices and would
  silently collapse any `NN%` to offset 0.

- `--ignore-read-errors` is dropped.  The recovery mode is entirely
  client-side (no wire change) but python3-only for now; the Py2 client
  keeps every local read error fatal.

- Local-to-local mode (neither side `HOST:path`) is dropped.  The Py2
  client still requires exactly one `HOST:` argument and rejects a
  no-HOST invocation with exit 2.

- `-v`/`--verbose` and `--check-tools` are dropped.  The tool/interpreter
  reporting relies on the `_exec()` echo-injection in the python3 client's
  `build_ssh_cmd`; the Py2 client keeps the plain wrapper.

The `BSCP_OPTIONS` env var (default command-line options, `shlex.split` and
prepended to argv before `parse_args` so an explicit flag still overrides
them) **is** honoured by `bscp.python2`, matching the python3 client;
`tests.sh` runs its two tests under a Python 2 client.

Everything else — section-based scan/copy, `--buffer`,
`--allow-truncate`, `-B`, resume, retries, the unified ETA model with
EMA-smoothed scan/copy rates and display damping, the grouped `--help`
layout, the hash-algorithm advertise/validate (`PORTABLE_ALGOS`,
`algorithm_help`, `parse_algorithm`), the `bscp-remote` process marker,
and the Perl remote fallback — is identical to `bscp`.

**Py2/3 compatibility shims** (all confined to `bscp.python2`):

| Shim                                                      | Why                                                                    |
| --------------------------------------------------------- | ---------------------------------------------------------------------- |
| `#!/usr/bin/env python`                                   | Resolves to whichever `python` is on `PATH` (2 or 3).                  |
| `# -*- coding: utf-8 -*-`                                 | Source contains em-dashes / box-drawing chars in strings and comments. |
| `from __future__ import division`                         | `/` returns float on Py2 (matches Py3 semantics throughout the file).  |
| `import binascii` + `hexlify(...).decode('ascii')`        | `bytes.hex()` is Py3.5+; used for both the Perl and `remote_script_mt` hex payloads. |
| `try: from shlex import quote ... except ImportError: from pipes import quote as _shquote` | `shlex.quote` is Py3.3+; Py2's `pipes.quote` is the same function. |
| `_PIPE_ERRORS` tuple defined via try/except `NameError`   | `BrokenPipeError` / `ConnectionResetError` are Py3.3+.                 |
| `super(ConnectionLost, self).__init__(...)`               | Py2 requires the explicit class+instance form.                         |
| `except (IOError, OSError) as e` on `open()`              | Py2 raises `IOError`; Py3 aliases it to `OSError`.                     |
| Single-element list-cell shims (`var[0]`) inside closures | Py2 has no `nonlocal`.  Used for `t_last_progress`, `eta_displayed`, `eta_displayed_at`, `ema_scan_rate`, `ema_copy_rate`, `rate_prev_scan_secs`, `rate_prev_scanned`, `rate_prev_copy_secs`, `rate_prev_written` — every variable mutated by a closure. |
| `raise ConnectionLost(...)` without `from exc`            | `raise X from Y` is Py3-only; cause chain is dropped on Py2.           |

When updating `bscp.python2`, the procedure is `cp bscp bscp.python2`
followed by re-applying the shims above (the diff is mechanical and the
shim sites are easy to locate by grepping for `nonlocal`, `bytes.hex()`,
`shlex.quote`, `OSError as`, `BrokenPipeError`, and `from exc`).  The
three remote source literals (`remote_script`, `remote_script_mt`,
`remote_perl`) and the tab-indentation note above them are copied
verbatim from `bscp` — they are interpreter-agnostic string data executed
on the remote, so no shim applies inside them.  `build_ssh_cmd` is the one
place the kept-but-rewired MT path lives: rewrite its `.hex()` calls as
`binascii.hexlify(...).decode('ascii')` and bake `_remote(0)` into the
`remote_script_mt` payload (the Py2 client has no `--hash-threads` value
to pass).  After the shims, re-run `python2 -m py_compile bscp.python2 &&
python3 -m py_compile bscp.python2`, then `BSCP=./bscp.python2 ./tests.sh`
under both interpreters.  When the client runs under Python 2, `tests.sh`
auto-skips twenty tests (the two `--hash-threads` tests, since the option
is absent; the `-a` rejection test, since Py2's `hashlib` lacks the
`shake_*` XOF functions it probes; the twelve `--verify` tests, since the
b3sum cross-check is not implemented in the Py2 client; the
`--ignore-read-errors` test; the two local-to-local tests; and the two
`-v`/`--check-tools` tests).  The two
`BSCP_OPTIONS` tests run under Py2 (the env var is honoured there too).
Pass `--force-all`
to run them anyway and watch them fail in the documented ways.  Under
python3 the same file passes the tests for the features it implements.  The
`--io-timeout` removal also
requires deleting the
`IOTimeout` class, the `IOCounter` raw-fd paths (`_read_raw`,
`_write_raw`), the `popen_bufsize` branch, the `import select`, the
`DEFAULT_IO_TIMEOUT` constant, and the argparse entry.

`bscp.python2` is **not** built with Nuitka — a Nuitka binary (see
[nuitka.md](nuitka.md)) already covers the no-Python-on-the-client case and
embeds Python 3.  `bscp.python2` covers the remaining corner: a client host
that has Python 2.7 but neither Python 3 nor a working Nuitka binary.
