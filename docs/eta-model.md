# ETA model

> Part of the bscp developer documentation. See [CLAUDE.md](../CLAUDE.md) for the architecture overview and index.

ETA = `remaining_scan_time + remaining_copy_time`, evaluated at every progress
tick from cumulative counters that survive section boundaries:

- `scan_rate` — time-weighted EMA over phase-A throughput; seeded from the
  cumulative average at the first sample where `total_scan_time` ≥
  `RATE_RELIABLE_SECS` (default 5.0s), then updated at every progress tick
  with `w = 1 − exp(−dt / RATE_EMA_TAU)` (default τ = 5s).  Lets ETA track
  real rate changes mid-run — HDD outer↔inner cylinder geometry, varying
  block-device queue depth, network jitter.
- `copy_rate` — same EMA construction over phase-B bytes/sec; seeded once
  cumulative copy time has reached `RATE_RELIABLE_SECS` **or** cumulative
  written has reached `RATE_RELIABLE_COPY_BYTES` (default 8 MiB), so fast
  transfers (localhost, 10 GbE) still seed from real data instead of staying
  in bootstrap forever.  Before the EMA is seeded the rate is bootstrapped
  as `scan_rate * blocksize / BOOTSTRAP_COPY_RATIO` (default ratio 64:1).
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
marker also drops once `CONFIDENT_SCAN_FRAC` (default 5%) of the blocks
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
underlying estimate is recomputed every progress tick (~0.5s) into a
heavily-weighted EMA (`eta_smoothed`, weight 0.01 on the fresh sample,
with a `−REPORT_INTERVAL` decrement applied to the prior so the smoother
naturally tracks a falling ETA).  The *displayed* value is re-snapped
from `eta_smoothed` only every `ETA_REFRESH_INTERVAL` seconds (default
10s) and held constant between snaps — explicitly chosen over a
per-second countdown so the on-screen number never appears to drift
independently of measured progress; cumulative continuity is carried by
`eta_smoothed`, which has been tracking smoothly all along.  To avoid
the early bootstrap estimate ever reaching the screen at all, the first
`ETA_WARMUP_SECS` (default 20s) of the run omits the `(ETA)` field from
the progress line entirely (`display_eta()` returns `None`; the caller
substitutes an empty string) — long enough for the rate EMAs to seed
from real data before any number appears.

Earlier designs went through several iterations before landing on the
current one: a "downward floor clamp" that applied unconditionally
prevented bootstrap overestimates from being corrected (the floor
anchored to an inflated initial value and the display crawled down at
1s/s for the entire run); a later revision damped only after the rate
EMAs were seeded but had a per-tick-anchor bug where `eta_displayed_at`
was updated on every tick so the refresh threshold never re-fired; and
neither variant became "confident" at all on zero-diff runs.  The
current design — always damp via the EMA, always snap on the refresh
schedule, hold between snaps, omit the `(ETA)` field until warmup ends,
and grant scan-only confidence at 5% scanned — addresses all three.

Why this design: the old ETA was scan-only during phase A and
section-only-plus-future-scan during phase B, which made it jump at every
section boundary because future copy work was simply omitted from the
phase-A estimate.  The unified formula folds both into a single budget;
the downward clamp absorbs the per-section diff-density noise.
