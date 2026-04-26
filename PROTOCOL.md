# Bscp Protocol Specification

This document describes the binary wire protocol used between the bscp client
(local) and the bscp server (embedded Python script executed on the remote
host via SSH).

All multi-byte integers are **little-endian unsigned 64-bit** (`uint64`) unless
stated otherwise.  The connection is a single SSH session; `stdin`/`stdout` of
the remote process are used as the bidirectional channel.

---

## 1. Overview

```
Client (local)                       Server (remote, python3 -c "...")
──────────────────────────────────────────────────────────────────────
  ── Header ──────────────────────→
  ── filename bytes ──────────────→
  ── hashname bytes ──────────────→
                                      ←── sanity digest ──────────────
  ── "go" ────────────────────────→
                                      ←── remote_size (uint64) ───────

  ╔═ section loop (one pass per section) ════════════════════════════╗
  ║                                   ←── hash_0 ... hash_N ──────── ║
  ║                                       (one digest per block)     ║
  ║  ── count (uint64) ────────────→                                 ║
  ║  [push] ── (pos, block)×count ─→                                 ║
  ║  [pull] ── pos×count ──────────→                                 ║
  ║                                   ←── block×count ── [pull only] ║
  ╚══════════════════════════════════════════════════════════════════╝
```

---

## 2. Connection setup

The client launches:

```
ssh [options] -- HOST 'python(/2/3) -O -B -c "<embedded script>"'
```

The embedded script is the complete server-side logic, transmitted as part of
the SSH command.  No prior installation on the remote host is required.

---

## 3. Handshake

### 3.1 Header (client → server)

```
Offset  Size  Field
     0     8  size          — bytes to sync (local file size for push;
                               local destination size for pull)
     8     8  blocksize     — bytes per block (must be > 0)
    16     8  section_size  — bytes per section (0 = whole file in one pass)
    24     8  start_offset  — resume offset in bytes (0 for a fresh run;
                               always a multiple of section_size)
    32     8  filename_len  — byte length of the remote filename
    40     8  hashname_len  — byte length of the hash algorithm name
    48     1  mode          — bit 0: 0 = push, 1 = pull
                               bit 1: ALLOW_TRUNCATE flag (destination may
                                      be smaller than source; sync only the
                                      bytes that fit, i.e. use min size)
Total: 49 bytes
```

Immediately following the header, without padding:

- `filename_len` bytes: UTF-8 encoded remote filename
- `hashname_len` bytes: ASCII encoded hash algorithm name (e.g. `sha256`)

### 3.2 Sanity check (server → client, then client → server)

The server computes `HASH(filename_bytes)` using the negotiated algorithm and
writes the digest to stdout, then flushes.

The client verifies the digest.  If it does not match, the remote script did
not execute properly (e.g. Python not found, shell mangled the command).

The client then writes the 2-byte literal `go` to stdin.

### 3.3 Remote size (server → client)

The server opens the remote file, seeks to the end, and writes its size as a
`uint64`.

- If the file cannot be opened, the server writes `0` and exits.  This
  means a legitimately empty (0-byte) remote file is indistinguishable from
  "not found" — known limitation.  The client treats `remote_size == 0` as
  an error and prints `Remote file not found or inaccessible`.
- In **push** the remote is the destination; in **pull** the remote is the
  source.  Without `ALLOW_TRUNCATE`, the server exits if the destination is
  smaller than the source (`dst_size < src_size`).
- With `ALLOW_TRUNCATE`, both sides proceed and use `sync_size = min(size,
  remote_size)`.  The client emits a warning if the destination is the
  smaller side.

The effective number of bytes to sync:

```
                          sync_size
push, no ALLOW_TRUNCATE:  size           (requires remote_size >= size)
push, ALLOW_TRUNCATE:     min(size, remote_size)
pull, no ALLOW_TRUNCATE:  remote_size    (requires size >= remote_size)
pull, ALLOW_TRUNCATE:     min(size, remote_size)
```

The client computes `sync_size = min(local_size, remote_size)`
unconditionally; this gives the correct value in every row above because
the size-mismatch case has already been rejected unless `ALLOW_TRUNCATE` is
set.

---

## 4. Section loop

Both sides independently compute the section boundaries from the header fields:

```
for sec_start in range(start_offset, sync_size, eff_section_size):
    sec_end = min(sec_start + eff_section_size, sync_size)
    # process [sec_start, sec_end)
```

where `eff_section_size = section_size if section_size > 0 else sync_size`.

The loop runs in lockstep — no per-section framing is exchanged.

### 4.1 Phase A — hash exchange (both modes)

The server reads each block in `[sec_start, sec_end)` sequentially and writes
one digest per block to stdout, then flushes.

Block boundaries:

```
block 0: [sec_start,            sec_start + blocksize)
block 1: [sec_start + blocksize, sec_start + 2×blocksize)
...
last:    [p,                    sec_end)   where sec_end - p ≤ blocksize
```

The client simultaneously reads its local file block by block, computes
digests, and compares them with the incoming remote digests.

- **Push**: by default, only differing block offsets are stored, and blocks
  are re-read from disk during phase B.  With `--buffer`, blocks are
  retained as `(offset, data)` pairs at the cost of higher peak memory.
- **Pull**: differing block offsets are stored as a list.

### 4.2 Phase B — block transfer

Phase B begins after the server has sent (and flushed) all digests for the
section, and the client has consumed them all.

#### Push (client → server)

```
count (uint64)                   — number of differing blocks to follow
                                   (0 for a dry-run)

Repeated count times:
  offset (uint64)                — byte offset within the file
  data   (variable)              — block bytes; length = min(blocksize,
                                   sync_size - offset)
```

The server reads each `(offset, data)` pair and writes the data at the given
offset.

#### Pull (client → server, then server → client)

The client sends all requested offsets first, then reads all returned blocks.
To avoid filling the SSH flow-control window before the receiver drains it,
the client batches its requests in windows of 128 offsets:

```
count (uint64)                   — total number of differing blocks
                                   (0 for a dry-run)

For each window of up to 128 offsets:
  [client → server]  offset×W   — W uint64 byte offsets
  [server → client]  data×W     — W blocks, each min(blocksize,
                                   sync_size - offset) bytes
```

The server streams blocks as soon as it reads each offset; it does not buffer
the full window before responding.

---

## 5. Termination

After the section loop completes, the client closes the SSH stdin pipe.
The server's stdin read returns EOF and it exits normally.

---

## 6. Resume

If a transfer is interrupted, the client prints:

```
connection lost — retry with: --resume-from <last_section_start>
```

Restarting with `--resume-from N` sets `start_offset = N` (rounded down
to the nearest section boundary).  Both sides skip directly to that offset.
Reprocessing a section is always safe because phase A re-compares the actual
content on both sides.

---

## 7. Design notes

**Why sections?**  Processing the file in sections bounds the amount of
differing-block data held in memory during phase B to at most one section's
worth of diffs rather than the entire file.

**Why a windowed pull?**  A naive "send all offsets then receive all blocks"
pull implementation can deadlock: the server writes blocks to stdout faster
than the client reads them (filling the SSH channel window), while the server
is simultaneously unable to read more offsets from stdin because it is blocked
on the stdout write.  The windowed approach ensures that for each batch, the
client is actively draining stdout before sending the next batch.

**Why no threading?**  Sections provide sufficient memory bounds without
requiring concurrent file I/O or message framing on either side.  The protocol
is strictly sequential within each section, making it easy to reason about
correctness and to implement in a self-contained embedded script.

**Why embed the server script?**  Embedding eliminates the need to install or
update any software on the remote host.  The client and server are always the
same protocol version.

The server source is held client-side as a triple-quoted Python string
(`remote_script`), not extracted from a real function via
`inspect.getsource()`.  This keeps the file frozen-friendly: prebuilt
single-file binaries (Nuitka onefile, PyInstaller, etc.) work because
nothing needs to read the original `.py` file at runtime.
