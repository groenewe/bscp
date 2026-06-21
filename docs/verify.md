# `--verify` — post-copy BLAKE3 cross-check

`--verify` is a **convenience** integrity check that runs *after* a copy
finishes.  It hashes the local file with [`b3sum`](https://github.com/BLAKE3-team/BLAKE3),
runs the same `b3sum` on the remote over SSH, and compares the two digests.
When the two devices are the same size the whole device is hashed on each
side; when they differ in size only the **common prefix** bscp actually copied
is compared (the larger side is dd-limited — see *Unequal device sizes* below).

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

In `__main__`, after a successful copy:

0. Under `--dry-run` nothing was written, so verify runs **only when the scan
   found zero diff blocks** — the scan then claims the two are already
   identical, and b3sum independently confirms it (a mismatch there is a real
   finding worth exit `4`).  With diffs pending, the un-applied changes would
   make b3sum mismatch, so verify is skipped.
1. If `shutil.which('b3sum')` finds nothing locally, verify warns and stops
   (the remote is not contacted).
2. The local `b3sum LOCAL` process and the remote `ssh … HOST 'b3sum REMOTE'`
   are launched **concurrently** (`spawn_hash()`), so wall-clock is the
   slower of the two, not their sum.  Both are then polled in a loop that
   **collects and prints each side's digest the moment its `b3sum` exits** —
   the first hash is on screen straight away (handy to record/store/mail when
   pressed for time) instead of waiting on the slower side — while the loop
   itself ends only once *both* are in (or local failed; see step 3).  Between
   digests it renders a **live countdown line** every `REPORT_INTERVAL`,
   mirroring the scan/copy display and naming only the side(s) still hashing
   (`both ends` → `the remote file` once local is done).  The countdown is a
   launch-style T-minus toward a duration estimate: `b3sum` reads the whole
   device once, exactly as phase A did, so the scan time (`do_sync` returns
   `total_scan_time` — read+hash, *excluding* the copy) is a good predictor,
   scaled by `sync_size / (sync_size − start_offset)` so a resumed run still
   estimates the full-device hash.  It shows `(-m:ss)` while time remains and
   flips to `(+m:ss)`, counting up, once the run outlasts the estimate
   (signalling the estimate was low).  The countdown appears only once
   *elapsed* clears `ETA_WARMUP_SECS` (the same threshold the scan/copy ETA
   uses); below that the field is a bare `...`, since a sub-warmup number is
   noise.  The line is gated on the *original* `-q`/`--batch` (the final
   summary resets `quiet=False`, which must not un-silence it); all
   progress/outcome lines are `\r`-prefixed so each overwrites the live line.
3. If the local hash fails, the remote process is killed rather than waited
   on.  `verify_digest()` takes the leading hex token of each result (the
   path field differs between the two sides, so only the digest is compared).
4. The remote runs over the same `ssh_base()` options as the transfer,
   **including the `ServerAliveInterval=15` keepalive** — essential here,
   because `b3sum` can run for minutes with no channel data, and the
   keepalive probes hold an idle (possibly NAT'd) connection open instead of
   letting it drop.  The remote `ssh` is additionally given **`-tt`** (force
   a remote PTY) and `stdin=DEVNULL`.  Without the PTY, a Ctrl+C during the
   hash leaves the remote `b3sum` running to the end: the handler kills the
   *local* `ssh`, but when that `ssh` is a multiplexing slave (the
   recommended setup — see below), the persistent master keeps the channel
   open, so the slave's death never tears it down; and `b3sum` writes nothing
   until the final digest line, so it never trips `SIGPIPE` either.  A
   controlling terminal closes that gap — the remote `b3sum` is `SIGHUP`'d
   when the channel's PTY is hung up, even over a persistent master.  (The
   PTY merges remote stderr into stdout and adds CRs; `verify_digest()` reads
   the leading hex token, so the digest parse is unaffected.)
5. Each digest is printed as soon as its side finishes (step 2); once both
   are in they are compared **only when the comparison is meaningful** (see
   the gate below), and the verdict (`verify OK` / `VERIFY FAILED`) is printed.

## SSH connections and authentication

The remote `b3sum` runs over a **second, independent** `ssh` invocation
(`b3sum_remote_cmd()`), separate from the transfer's connection — it is
deliberately out of band, not part of the bscp wire protocol.  With
key-based auth (and an agent, or an unencrypted key) this is invisible.  With
interactive auth — password, encrypted key without an agent, or 2FA/OTP — the
two connections authenticate independently, so the operator is prompted
twice, the second time *after* the transfer completes (which can also stall a
non-interactive `--batch` caller waiting on input).

bscp intentionally does **not** pass `-o ControlMaster=...`, so the operator
can collapse both connections onto one authenticated channel via SSH
connection multiplexing in `~/.ssh/config`:

```
Host backup-server
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 60
```

With that in place the transfer connection becomes the master and the verify
connection reuses it — one authentication.  This was chosen over having bscp
auto-enable multiplexing so the carefully-tuned transfer/retry connection
path is left untouched; connection reuse is left to ssh, where it belongs.

## Interruption and connection loss

bscp installs no `SIGHUP`/`SIGTERM` handlers (only `SIGINT` → the
`KeyboardInterrupt` path described above, which kills both `b3sum` children
and exits `130`).  No others are needed — the default dispositions already
give the desired "both ends die" outcome.  Two scenarios, both verified:

- **The terminal running bscp goes away** (its login/SSH session times out or
  is closed).  The kernel delivers `SIGHUP` to bscp's foreground process
  group.  bscp dies on the default action (no `finally`/atexit — acceptable,
  as there is no local cleanup to lose: no temp files, and a partially
  written pull target is resumable).  The local verify `ssh` children are in
  the **same** process group (plain `Popen`, no `start_new_session`), so they
  receive the same `SIGHUP` and die too.  The remote `b3sum` then dies via
  the `-tt` PTY hangup just as in the Ctrl+C case — there is a few-second lag
  while a persistent multiplexing master notices the slave is gone, then
  tears the channel (and its PTY) down.  Confirmed signal-agnostic:
  `SIGHUP`, `SIGTERM`, and `SIGKILL` to the local slave all reap the remote
  `b3sum` over a `ControlMaster`.

- **The verify connection itself drops** (network partition, not the local
  terminal).  `ssh_base()`'s `ServerAliveInterval=15` / `ServerAliveCountMax=4`
  make the local `ssh` declare the link dead within ~60 s and exit; bscp then
  treats the verify as unavailable.  The fate of the remote `b3sum` on the
  far side of the dead link is the **remote sshd's** responsibility (its own
  TCP keepalive / `ClientAliveInterval`), not the client's — inherent to a
  partition and outside bscp's reach.

Persistence across a dropped controlling terminal is intentionally *not*
bscp's job: run it under `tmux`/`screen` if the session may disconnect.

## What `--verify` compares — the copied prefix

A whole-device `b3sum` of source and destination only matches when the
destination is a byte-for-byte copy of the source over the *entire* device.
bscp does not always copy the whole device, so a meaningful check compares only
the bytes it **did** copy: the prefix `[0, sync_size)`, where `sync_size` is

- `min(local, remote)` for a full copy to a same-or-larger destination, and
- *smaller still* when `-B` / `--block-count` caps the copy to the first N
  blocks (and smaller again if the destination is also smaller).

Any side **larger** than that prefix is dd-limited down to it before hashing:
`dd if=DEV bs=BS count=COUNT 2>/dev/null | b3sum`.  So a size mismatch dd-limits
the one larger side (the smaller side's whole device *is* the prefix), while a
`-B` cap — where *both* ends exceed the prefix — dd-limits **both**.  An
equal-size full copy dd-limits neither and hashes each side directly, keeping
`b3sum`'s fast mmap, multi-threaded read.

### Why device sizes legitimately differ

A size mismatch is not necessarily an error — it is routine for some backup
layouts.  The motivating case: a large disk managed by **LVM**, with each
backed-up device stored as its own **logical volume**.  LVM rounds every LV up
to a whole number of physical extents (4 MiB by default), so an LV provisioned
to hold a given physical device is almost never *exactly* its size — it is the
source rounded up to the next extent boundary.

The two directions are asymmetric:

- **Backup** (physical device → LV): the LV destination is *larger* than the
  source, so it comfortably holds the whole device — **no `--allow-truncate`**
  is needed.  bscp copies the device into the LV's prefix and leaves the extent
  padding untouched.
- **Restore** (LV → physical device): now the *larger* LV is the source and the
  *smaller* device is the destination, so **`--allow-truncate` is required** (a
  destination smaller than the source is otherwise refused).  bscp copies the
  LV's prefix back onto the device.

Either way the two ends differ in size, so a whole-device `b3sum` would differ
on the trailing extent padding alone, even when every copied byte is identical
— and the larger side (the LV in both directions) is the one dd-limits.

The dd-limiting trick makes `--verify` Just Work in both directions: it
compares exactly the bytes bscp copied and ignores the LV's rounding tail.
This is squarely in the spirit of `--verify` as a **convenience** — the same
check can be run by hand with `dd … | b3sum` on each side, but having bscp size
and issue the `dd` automatically means one command both runs the transfer and
confirms it.

### `-B` / `--block-count` partial copies

`-B` deliberately copies only a prefix (the chunked-transfer workflow, where
each run prints a `Continue with: … -r OFFSET` hint to resume).  `--verify` then
confirms exactly that prefix — dd-limiting **both** ends to it — and, because
the source's tail was *not* copied, prints an **incomplete-backup warning**:

```
verify: WARNING — -B copied only the first 4096K of the 8192K local source;
the remaining 4096K is NOT in the destination — incomplete backup
(see the "Continue with" line above to copy the rest)
```

The operator ran a verification expecting "all good", so this says plainly that
only the copied prefix is confirmed and the destination is not yet a complete
backup.  (Earlier versions instead *skipped* the comparison with a "partial
copy: -B" message after hashing each whole device and discarding the result,
and rejected `-B` together with `--batch --verify` at argparse.  Both are gone:
the copied prefix is verifiable, so it now yields a real exit `0` / `4`.)

### dd block size, and the missing-dd guard

Because `dd`'s `count` counts whole `bs` blocks, `bs` must divide the prefix
exactly; `dd_hash_params()` picks the largest such divisor `<= 1 MiB` (fewest
reads / closest to the streaming sweet spot, but never below 4 KiB).  The dd
snippet is guarded with `command -v dd >/dev/null || exit 127` — load-bearing,
because a *missing* `dd` would otherwise let `b3sum` hash an empty pipe and emit
the digest of zero bytes (exit 0), which would compare as a **false mismatch**.
The early-exit makes that side look unavailable (a skip) instead.

### Reporting

A size mismatch is announced **at handshake** — as soon as `do_sync` reads the
remote size, before the (possibly long) copy — so the operator knows up front
that the post-copy check will be prefix-only.  (A `-B` cap is signalled instead
by the post-copy incomplete-backup warning above plus the `Continue with`
hint.)  Each side's digest line in the report shows exactly how `b3sum` was
invoked (`b3sum PATH`, or `dd bs=… count=… | b3sum PATH`), and the OK/mismatch
verdict is annotated with `over the first …` and the reason(s) — `device sizes
differ` and/or `partial copy: -B` — so it is unambiguous that only the prefix
was compared and why.

## Comparison eligibility gate

The comparison is **skipped** (with a warning; see *Exit code* for how
`--batch` changes this) only when it genuinely cannot be carried out:

- the copied prefix has no efficient `dd` block size dividing it (a prime-sized
  prefix, or one smaller than 4 KiB), or `dd` is missing on a side that needs it
  (i.e. a side larger than the prefix) — `device_size()` sizes each end because
  `os.path.getsize()` reports `0` for block devices; or
- `b3sum` is missing or errors on either side.

A size mismatch or a `-B` cap is **no longer** a skip condition — those are
prefix comparisons, handled by dd-limiting (above).  An equal-size full copy
needs no `dd` and is compared whole.

Resume (`-r`) does **not** disable the comparison: the check is over the final
state, which a resumed run completes.  A resumed `-B` chunk verifies the
cumulative prefix `[0, sync_size)` — `sync_size` being the *end* of the chunk
just copied — so the dd limit covers everything copied so far (correct as long
as earlier chunks were copied correctly, the same assumption resume already
makes elsewhere).

## Exit code

| Outcome                                              | Exit |
| ---------------------------------------------------- | ---- |
| Digests match (or no comparison requested)           | `0`  |
| Confirmed mismatch — whole device (full copy) or copied prefix (size mismatch / `-B`) | `4`  |
| Verify could not be performed, **under `--batch`**   | `5`  |

A size mismatch or a `-B` partial copy is **not** a "could not verify"
condition: `dd` limits each oversized side to the copied prefix, the prefix is
compared, and a divergence there is a real **exit 4**.  Only a prefix with no
usable `dd` block size — or a missing/failing `b3sum`/`dd` — falls to the skip
(exit `5` under `--batch`).  (Earlier versions rejected `-B` together with
`--batch --verify` at argparse with exit `2`; that pre-validation is gone, since
the copied prefix is now verifiable.)

Without `--batch`, the skip conditions above just print a warning and leave
the exit code at `0` — the operator can see what happened.  Under `--batch`
all stderr is suppressed, so a silent exit `0` would be indistinguishable
from a verified success.  `verify_unavailable()` therefore exits `5` for any
verify that was requested but could not run (`b3sum`/`dd` missing or failing on
either side, or a copied prefix with no usable `dd` block size).  (The dry-run
"diffs pending, destination not updated" skip is an expected `-N` outcome, not
a verify-impossible condition, so it does not trip exit `5`.)

## Limitations

- Reads go through the OS page cache, so `--verify` confirms the copy logic
  and transport, not necessarily that the bytes are durably on the physical
  medium (it is not an O_DIRECT media scrub).  For bitrot/escrow over time,
  re-run `b3sum -c` against the saved digest after dropping caches.
- It is a single whole-device digest, not a per-section list — if you need
  to localise a divergence, fall back to a `-N` dry-run (which reports
  differing block counts) or to `dcfldd hashwindow`.
