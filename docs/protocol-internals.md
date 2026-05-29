# Protocol internals

> Part of the bscp developer documentation. See [CLAUDE.md](../CLAUDE.md) for the architecture overview and index.

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
