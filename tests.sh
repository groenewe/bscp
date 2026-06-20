#!/usr/bin/env bash
# Basic regression tests for bscp.
#
# Exercises both push and pull against localhost: over SSH, plus the
# common error paths and the format_size unit tests.
#
# Requires:
#   - the bscp script (default: ./bscp; override with $BSCP)
#   - python3 on PATH
#   - working ssh into localhost (key-based, no prompt)
#
# Usage:
#   ./tests.sh
#   BSCP=/usr/local/bin/bscp ./tests.sh
#   ./tests.sh --force-all          # run every test even under a python2 client
#
# When $BSCP runs under a Python 2 interpreter (e.g. bscp.python2 where
# `python` resolves to Python 2.x), fourteen tests are skipped by default:
# the two --hash-threads tests (the option is python3-only by design), the
# -a algorithm-rejection test (Py2's hashlib lacks the shake_* XOF functions
# the test probes), the nine --verify tests (the convenience b3sum
# cross-check is not implemented in the python2 client), and the two
# BSCP_OPTIONS tests (that env var is not read by the python2 client).  Pass
# --force-all to run them anyway.
#
# Exit status: 0 if all tests pass, non-zero otherwise.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BSCP="${BSCP:-$SCRIPT_DIR/bscp}"

FORCE_ALL=0
for arg in "$@"; do
    case $arg in
        --force-all) FORCE_ALL=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# A python2 client is one whose shebang invokes plain `python` (not python3)
# where that `python` is a Python 2.x interpreter.  A python3 shebang or a
# compiled Nuitka binary is never treated as python2.
PY2_CLIENT=0
case $(head -1 "$BSCP" 2>/dev/null) in
    *python3*) ;;
    *python*)  python -V 2>&1 | grep -q '^Python 2\.' && PY2_CLIENT=1 ;;
esac

# Tests skipped under a python2 client unless --force-all is given.  The
# --verify tests are skipped because the python2 client does not implement
# the (convenience-only) b3sum cross-check, so the flag is unrecognised.
PY2_SKIP="test_hash_threads_push test_hash_threads_single_pull test_reject_bad_algorithm \
test_verify_push_match test_verify_mismatch_exit4 test_verify_skips_when_b3sum_unusable \
test_verify_size_mismatch_skips test_verify_dryrun_zero_diff_runs test_verify_dryrun_with_diff_skips \
test_verify_batch_mismatch_exit4 test_verify_batch_size_mismatch_exit5 test_verify_batch_blockcount_rejected \
test_bscp_options_applies test_bscp_options_cli_overrides"

WORK=$(mktemp -d)
SRC="$WORK/src.img"
DST="$WORK/dst.img"
DST2="$WORK/dst2.img"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
SKIPPED=0
FAILED_NAMES=()
SKIPPED_NAMES=()

run() {
    local name=$1; shift
    local func=$1
    if (( ! FORCE_ALL )) && (( PY2_CLIENT )) && [[ " $PY2_SKIP " == *" $func "* ]]; then
        printf '  skip  %s\n' "$name"
        SKIPPED=$((SKIPPED + 1))
        SKIPPED_NAMES+=("$name")
        return
    fi
    local out
    out=$("$@" 2>&1)
    local rc=$?
    if (( rc == 0 )); then
        printf '  ok    %s\n' "$name"
        PASSED=$((PASSED + 1))
    else
        printf '  FAIL  %s\n' "$name"
        if [[ -n $out ]]; then
            printf '          %s\n' "${out//$'\n'/$'\n          '}"
        fi
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$name")
    fi
}

# ---------- preflight ----------
[[ -x $BSCP ]] || { echo "bscp not found / not executable at $BSCP" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 not on PATH" >&2; exit 2; }
ssh -o BatchMode=yes -o ConnectTimeout=5 localhost true 2>/dev/null || {
    echo "ssh localhost requires passwordless login for these tests" >&2
    exit 2
}

# ---------- fixtures ----------
make_src()       { dd if=/dev/urandom of="$SRC"  bs=1M count="$1" status=none; }
make_blank()     { dd if=/dev/urandom of="$1"    bs=1M count="$2" status=none; }
copy_src_to()    { cp "$SRC" "$1"; }
randomise_in()   { dd if=/dev/urandom of="$1"    bs=4K count="$2" seek="$3" \
                      conv=notrunc status=none; }

# ---------- tests ----------
test_push() {
    make_src 10
    copy_src_to "$DST"
    randomise_in "$DST" 8 200
    "$BSCP" -s 2M "$SRC" "localhost:$DST" >/dev/null 2>&1 \
        && cmp -s "$SRC" "$DST"
}

test_pull() {
    make_src 10
    copy_src_to "$DST2"
    randomise_in "$DST2" 8 400
    "$BSCP" -s 2M "localhost:$SRC" "$DST2" >/dev/null 2>&1 \
        && cmp -s "$SRC" "$DST2"
}

test_dryrun_does_not_modify() {
    make_src 10
    copy_src_to "$DST"
    randomise_in "$DST" 8 100
    local before after
    before=$(md5sum "$DST" | cut -d' ' -f1)
    "$BSCP" -N -s 2M "$SRC" "localhost:$DST" >/dev/null 2>&1 || return 1
    after=$(md5sum "$DST" | cut -d' ' -f1)
    [[ $before == "$after" ]]
}

test_resume_from_section() {
    make_src 10
    copy_src_to "$DST"
    # Modify only the last section (8 MiB onward) and resume from there.
    randomise_in "$DST" 2 2200
    "$BSCP" -s 2M -r 8M "$SRC" "localhost:$DST" >/dev/null 2>&1 \
        && cmp -s "$SRC" "$DST"
}

test_resume_from_percent() {
    make_src 10
    copy_src_to "$DST"
    # Modify only the second half (5 MiB onward); -r 50% rounds down to
    # the 4 MiB section boundary (-s 2M), still covering every diff.
    randomise_in "$DST" 2 1500
    "$BSCP" -s 2M -r 50% "$SRC" "localhost:$DST" >/dev/null 2>&1 \
        && cmp -s "$SRC" "$DST"
}

# BSCP_FORCE_PERL=1 makes build_ssh_cmd skip the Python branch, exercising
# the Perl fallback against a host that has both interpreters.
test_perl_remote_push() {
    command -v perl >/dev/null || return 0   # skip on hosts without perl
    make_src 4
    copy_src_to "$DST"
    randomise_in "$DST" 20 300
    BSCP_FORCE_PERL=1 "$BSCP" "$SRC" "localhost:$DST" >/dev/null 2>&1 \
        && cmp -s "$SRC" "$DST"
}

test_perl_remote_pull() {
    command -v perl >/dev/null || return 0
    make_src 4
    copy_src_to "$DST"
    randomise_in "$DST" 20 400
    BSCP_FORCE_PERL=1 "$BSCP" "localhost:$SRC" "$DST" >/dev/null 2>&1 \
        && cmp -s "$SRC" "$DST"
}

# BSCP_FORCE_PYTHON2=1 makes build_ssh_cmd skip the python3/remote_script_mt
# branch, exercising the single-threaded legacy remote_script even on a host
# that has python3 (where the default path would always pick the threaded
# remote).  Runs the legacy script under whichever python is found first.
test_legacy_remote_push() {
    make_src 8
    copy_src_to "$DST"
    randomise_in "$DST" 12 200
    BSCP_FORCE_PYTHON2=1 "$BSCP" -s 2M "$SRC" "localhost:$DST" >/dev/null 2>&1 \
        && cmp -s "$SRC" "$DST"
}

test_legacy_remote_pull() {
    make_src 8
    copy_src_to "$DST2"
    randomise_in "$DST2" 12 300
    BSCP_FORCE_PYTHON2=1 "$BSCP" -s 2M "localhost:$SRC" "$DST2" >/dev/null 2>&1 \
        && cmp -s "$SRC" "$DST2"
}

test_buffer_push() {
    make_src 10
    copy_src_to "$DST"
    randomise_in "$DST" 8 300
    "$BSCP" -s 2M --buffer "$SRC" "localhost:$DST" >/dev/null 2>&1 \
        && cmp -s "$SRC" "$DST"
}

test_bwlimit_push() {
    # 8 MiB of all-different blocks at 2 MiB/s should take ~3s (8 MiB minus a
    # 1s = 2 MiB burst budget, all over 2 MiB/s).  Unthrottled this transfer
    # finishes well under 1s, so a >= 2s floor proves the throttle engaged
    # without being so tight it flakes under load.  Correctness still checked.
    make_src 8
    make_blank "$DST" 8          # random dst => every block differs
    local start elapsed
    start=$SECONDS
    "$BSCP" -s 8M --bwlimit 2M "$SRC" "localhost:$DST" >/dev/null 2>&1 || return 1
    elapsed=$((SECONDS - start))
    cmp -s "$SRC" "$DST" || return 1
    (( elapsed >= 2 ))
}

test_hash_threads_push() {
    # Multi-section push with diffs scattered across sections, hashing fanned
    # out over 4 threads — exercises the threaded phase-A feed/drain window
    # and that digests stay in wire order across section boundaries.
    make_src 20
    copy_src_to "$DST"
    randomise_in "$DST" 4 50
    randomise_in "$DST" 4 2000
    randomise_in "$DST" 4 4900
    "$BSCP" -s 4M --hash-threads 4 "$SRC" "localhost:$DST" >/dev/null 2>&1 \
        && cmp -s "$SRC" "$DST"
}

test_hash_threads_single_pull() {
    # --hash-threads 1 forces a one-worker pool: verifies the threaded path is
    # correct when it degenerates to serial, on the pull side.
    make_src 12
    copy_src_to "$DST2"
    randomise_in "$DST2" 6 600
    "$BSCP" -s 3M --hash-threads 1 "localhost:$SRC" "$DST2" >/dev/null 2>&1 \
        && cmp -s "$SRC" "$DST2"
}

test_allow_truncate_push() {
    make_src 10
    make_blank "$DST" 8
    # Without the flag, push must refuse with non-zero exit.
    "$BSCP" -s 2M "$SRC" "localhost:$DST" >/dev/null 2>&1 && return 1
    # With the flag, push succeeds and the first 8 MiB must match.
    "$BSCP" -s 2M --allow-truncate "$SRC" "localhost:$DST" >/dev/null 2>&1 || return 1
    cmp -n $((8 * 1024 * 1024)) "$SRC" "$DST"
}

test_allow_truncate_pull() {
    make_src 10
    make_blank "$DST2" 4
    "$BSCP" -s 2M "localhost:$SRC" "$DST2" >/dev/null 2>&1 && return 1
    "$BSCP" -s 2M --allow-truncate "localhost:$SRC" "$DST2" >/dev/null 2>&1 || return 1
    cmp -n $((4 * 1024 * 1024)) "$SRC" "$DST2"
}

test_batch_silent_success() {
    make_src 10
    copy_src_to "$DST"
    randomise_in "$DST" 4 500
    local out
    out=$("$BSCP" -s 2M --batch "$SRC" "localhost:$DST" 2>&1)
    local rc=$?
    (( rc == 0 )) && [[ -z $out ]] && cmp -s "$SRC" "$DST"
}

test_block_count_continue() {
    make_src 10
    copy_src_to "$DST"
    randomise_in "$DST" 8 200
    # Limit to first 64 blocks (= 4 MiB at 64K block size).
    local out
    out=$("$BSCP" -s 2M -B 64 "$SRC" "localhost:$DST" 2>&1)
    (( $? == 0 )) || return 1
    # The hint must point at the next offset, not at the start.
    echo "$out" | grep -q -- '-r 4M'
}

test_block_count_size_suffix() {
    make_src 10
    copy_src_to "$DST"
    randomise_in "$DST" 8 200
    # -B 4M should be equivalent to -B 64 at the default 64K block size.
    local out
    out=$("$BSCP" -s 2M -B 4M "$SRC" "localhost:$DST" 2>&1)
    (( $? == 0 )) || return 1
    echo "$out" | grep -q -- '-r 4M' && cmp -n $((4 * 1024 * 1024)) "$SRC" "$DST"
}

test_block_count_pull_no_truncate_needed() {
    make_src 10
    copy_src_to "$DST2"
    randomise_in "$DST2" 8 100
    # Pull where local and remote are both 10 MiB; -B caps the requested sync
    # to 4 MiB.  Effective source (4 MiB) fits in the local destination, so no
    # --allow-truncate should be required even though local would otherwise be
    # "shorter" than what -B caps from the wire-side.
    "$BSCP" -s 2M -B 64 "localhost:$SRC" "$DST2" >/dev/null 2>&1 \
        && cmp -n $((4 * 1024 * 1024)) "$SRC" "$DST2"
}

test_block_count_truncate_still_required() {
    make_src 10
    make_blank "$DST" 4
    # Push with -B 8M asks for more than the 4 MiB destination can hold.
    # Without --allow-truncate this must refuse, and exit non-zero.
    "$BSCP" -s 2M -B 8M "$SRC" "localhost:$DST" >/dev/null 2>&1 && return 1
    # With --allow-truncate it proceeds and the first 4 MiB land.
    "$BSCP" -s 2M -B 8M --allow-truncate "$SRC" "localhost:$DST" >/dev/null 2>&1 || return 1
    cmp -n $((4 * 1024 * 1024)) "$SRC" "$DST"
}

test_block_count_overshoot_warns() {
    make_src 4
    copy_src_to "$DST"
    randomise_in "$DST" 4 100
    # -B 16M asks for more than the 4 MiB source — must warn, not fail.
    local out
    out=$("$BSCP" -s 2M -B 16M "$SRC" "localhost:$DST" 2>&1)
    (( $? == 0 )) || return 1
    echo "$out" | grep -q 'Warning: -B requests'
}

test_block_count_overshoot_smaller_dst_no_hang() {
    # Pre-fix this deadlocked: -B sets the wire-side ALLOW_TRUNCATE bit so the
    # remote starts streaming Phase-A hashes, the client then refuses on its
    # own check, and proc.wait() blocks against the remote's blocked stdout
    # write.  sync_size needs to be large enough (>= ~128 MiB at default 64 KiB
    # blocks / sha256) for the digest stream to fill the OS pipe buffer; sparse
    # files keep the test cheap.  Output must mention --allow-truncate.
    truncate -s 256M "$SRC"
    truncate -s 128M "$DST"
    local out rc
    out=$(timeout 30 "$BSCP" -B 512M "$SRC" "localhost:$DST" 2>&1)
    rc=$?
    # rc 124 = timeout = bug still present.
    (( rc != 0 && rc != 124 )) && grep -q -- '--allow-truncate' <<<"$out"
}

# --verify runs b3sum on both ends out-of-band (no protocol change) and
# compares.  These tests need b3sum on PATH; where it is absent they
# return 0 (reported ok), mirroring the perl-remote skip idiom above.
test_verify_push_match() {
    command -v b3sum >/dev/null || return 0
    make_src 8
    copy_src_to "$DST"
    randomise_in "$DST" 8 100
    local out
    out=$("$BSCP" -s 2M --verify "$SRC" "localhost:$DST" 2>&1)
    cmp -s "$SRC" "$DST" || return 1
    grep -q 'verify OK: local and remote b3sum match' <<<"$out"
}

# A fake b3sum on the local PATH yields a digest unlike the remote's real
# b3sum, forcing a mismatch on an otherwise-identical, equal-size pair.  ssh
# does not forward PATH, so the remote still uses its real b3sum.
test_verify_mismatch_exit4() {
    command -v b3sum >/dev/null || return 0
    make_src 4
    copy_src_to "$DST"
    local fake="$WORK/fakebin"
    mkdir -p "$fake"
    printf '#!/bin/sh\nprintf "%%s  %%s\\n" "$(basename "$1" | md5sum | cut -d" " -f1)" "$1"\n' > "$fake/b3sum"
    chmod +x "$fake/b3sum"
    local out rc
    out=$(PATH="$fake:$PATH" "$BSCP" --verify "$SRC" "localhost:$DST" 2>&1)
    rc=$?
    rm -rf "$fake"
    (( rc == 4 )) && grep -q 'VERIFY FAILED' <<<"$out"
}

# A present-but-failing b3sum (exit nonzero) must warn and skip without
# changing the transfer's exit code.  Does not need a real b3sum.
test_verify_skips_when_b3sum_unusable() {
    make_src 4
    copy_src_to "$DST"
    randomise_in "$DST" 8 100
    local bad="$WORK/badbin"
    mkdir -p "$bad"
    printf '#!/bin/sh\nexit 7\n' > "$bad/b3sum"
    chmod +x "$bad/b3sum"
    local out rc
    out=$(PATH="$bad:$PATH" "$BSCP" --verify "$SRC" "localhost:$DST" 2>&1)
    rc=$?
    rm -rf "$bad"
    cmp -s "$SRC" "$DST" || return 1
    (( rc == 0 )) || return 1
    grep -q 'verify: skipped' <<<"$out"
}

# Whole-device hashes legitimately differ when the destination is smaller, so
# the comparison is skipped (warning) and the exit code stays 0.
test_verify_size_mismatch_skips() {
    command -v b3sum >/dev/null || return 0
    make_src 8
    make_blank "$DST2" 5
    local out rc
    out=$("$BSCP" --allow-truncate --verify "$SRC" "localhost:$DST2" 2>&1)
    rc=$?
    (( rc == 0 )) || return 1
    grep -q 'comparison skipped (sizes differ' <<<"$out"
}

# Under --dry-run, verify runs only when the scan found zero diffs (an
# independent confirmation the two already match).
test_verify_dryrun_zero_diff_runs() {
    command -v b3sum >/dev/null || return 0
    make_src 6
    copy_src_to "$DST"            # identical -> scan finds 0 diffs
    local out
    out=$("$BSCP" -N --verify "$SRC" "localhost:$DST" 2>&1)
    grep -q 'verify OK: local and remote b3sum match' <<<"$out"
}

# With diffs pending, --dry-run verify is skipped (un-applied changes would
# make b3sum mismatch) and the destination is left untouched.
test_verify_dryrun_with_diff_skips() {
    command -v b3sum >/dev/null || return 0
    make_src 6
    copy_src_to "$DST"
    randomise_in "$DST" 8 100     # introduce diffs
    local before out rc
    before=$(md5sum "$DST" | cut -d' ' -f1)
    out=$("$BSCP" -N --verify "$SRC" "localhost:$DST" 2>&1)
    rc=$?
    [[ $(md5sum "$DST" | cut -d' ' -f1) == "$before" ]] || return 1
    (( rc == 0 )) || return 1
    grep -q 'verify: skipped (--dry-run found' <<<"$out"
}

# --batch + --verify: a mismatch must still surface via exit 4 with NO stderr
# (the only channel left under --batch; the combination the help documents).
test_verify_batch_mismatch_exit4() {
    command -v b3sum >/dev/null || return 0
    make_src 4
    copy_src_to "$DST"
    local fake="$WORK/fakebin2"
    mkdir -p "$fake"
    printf '#!/bin/sh\nprintf "%%s  %%s\\n" "$(basename "$1" | md5sum | cut -d" " -f1)" "$1"\n' > "$fake/b3sum"
    chmod +x "$fake/b3sum"
    local out rc
    out=$(PATH="$fake:$PATH" "$BSCP" --batch --verify "$SRC" "localhost:$DST" 2>&1)
    rc=$?
    rm -rf "$fake"
    (( rc == 4 )) && [[ -z $out ]]
}

# Under --batch a verify that cannot run (here: sizes differ) must exit 5,
# silently — otherwise a suppressed skip-warning looks like success.
test_verify_batch_size_mismatch_exit5() {
    command -v b3sum >/dev/null || return 0
    make_src 8
    make_blank "$DST2" 5
    local out rc
    out=$("$BSCP" --batch --allow-truncate --verify "$SRC" "localhost:$DST2" 2>&1)
    rc=$?
    (( rc == 5 )) && [[ -z $out ]]
}

# -B can never be whole-device verified; combined with --batch --verify it is
# rejected at argparse (exit 2) rather than running a full copy first.  Needs
# no b3sum (the rejection happens before any work).
test_verify_batch_blockcount_rejected() {
    make_src 4
    copy_src_to "$DST"
    "$BSCP" --batch --verify -B 1M "$SRC" "localhost:$DST" >/dev/null 2>&1
    (( $? == 2 ))
}

# BSCP_OPTIONS supplies default options before the real argv.  -B 1M from the
# env caps the sync to the first 1 MiB, which prints a "Continue with" hint —
# observable proof the env option took effect.
test_bscp_options_applies() {
    make_src 4
    copy_src_to "$DST"
    randomise_in "$DST" 8 100
    local out
    out=$(BSCP_OPTIONS="-B 1M" "$BSCP" "$SRC" "localhost:$DST" 2>&1)
    grep -q "Continue with" <<<"$out"
}

# An explicit command-line option overrides the env default: -B 0 (no limit)
# on the CLI beats -B 1M from BSCP_OPTIONS, so no "Continue with" hint.
test_bscp_options_cli_overrides() {
    make_src 4
    copy_src_to "$DST"
    randomise_in "$DST" 8 100
    local out
    out=$(BSCP_OPTIONS="-B 1M" "$BSCP" -B 0 "$SRC" "localhost:$DST" 2>&1)
    ! grep -q "Continue with" <<<"$out"
}

test_exit2_when_no_host() {
    "$BSCP" "$SRC" "$DST" >/dev/null 2>&1
    (( $? == 2 ))
}

test_friendly_error_for_missing_local() {
    local out
    out=$("$BSCP" /nonexistent-bscp-test.img "localhost:$DST" 2>&1)
    local rc=$?
    (( rc == 1 )) && grep -q 'Cannot open local file' <<<"$out"
}

test_reject_bad_algorithm() {
    # Unknown algorithm and XOF/zero-digest algorithm both rejected at
    # arg-parse with exit 2; the message names the algorithm.
    local out rc
    out=$("$BSCP" -a notahash "$SRC" "localhost:$DST" 2>&1); rc=$?
    (( rc == 2 )) && grep -q "unknown hash algorithm 'notahash'" <<<"$out" || return 1
    out=$("$BSCP" -a shake_128 "$SRC" "localhost:$DST" 2>&1); rc=$?
    (( rc == 2 )) && grep -q "no fixed digest size" <<<"$out"
}

test_conn_failure_retries_exit3() {
    # An unreachable host (RFC5737 TEST-NET-1, never routable) must engage the
    # --retries loop and exit 3, NOT fail hard with exit 1.  Regression for the
    # handshake-stage bug where ssh "no route to host" raised a plain
    # RuntimeError ("Remote script failed to execute") that bypassed retries.
    local out rc
    out=$("$BSCP" -R 1 -o ConnectTimeout=1 -o BatchMode=yes \
                  "192.0.2.1:/dev/null" "$DST" 2>&1); rc=$?
    (( rc == 3 )) && grep -q 'retrying (1/1)' <<<"$out"
}

test_format_size_unit_tests() {
    # The unit tests `import` the helpers as a module, so we need Python source.
    # When $BSCP points at a Nuitka binary, fall back to the checked-in source.
    local mod_src=$BSCP
    if ! head -1 "$BSCP" 2>/dev/null | grep -q '^#!.*python'; then
        mod_src="$SCRIPT_DIR/bscp"
    fi
    cp "$mod_src" "$WORK/bscp_mod.py"
    PYTHONPATH="$WORK" python3 - <<'PY'
import bscp_mod as m
K, M, G, T = 1 << 10, 1 << 20, 1 << 30, 1 << 40

# (n, expected) for format_size(n, floor=True).
display_cases = [
    (0,         '0'),
    (9,         '9'),
    (10,        '10'),
    (9999,      '9999'),
    (10000,     '9K'),
    (10 * K,    '10K'),
    (9999 * K,  '9999K'),
    (10000 * K, '9M'),
    (1 * M,     '1024K'),
    (8 * M,     '8192K'),
    (9 * M,     '9216K'),
    (10 * M,    '10M'),
    (9999 * M,  '9999M'),
    (10000 * M, '9G'),
    (10240 * M, '10G'),
    (9 * G,     '9216M'),
    (10 * G,    '10G'),
    (1 * T,     '1024G'),
    (10 * T,    '10T'),
]
errs = []
for n, exp in display_cases:
    got = m.format_size(n, floor=True)
    if got != exp:
        errs.append('format_size(%d, floor=True) = %r, expected %r' % (n, got, exp))

# format_size(floor=False) must round-trip losslessly through parse_size().
roundtrip = [0, 1, 1024, 65536, 1*M, 1*G, 1*T, 8*M + 512, 5160, 100*M + 50*K, 1024*G]
for n in roundtrip:
    s = m.format_size(n)
    p = m.parse_size(s)
    if p != n:
        errs.append('parse_size(format_size(%d)) = %d (via %r)' % (n, p, s))

if errs:
    print('\n'.join(errs))
    raise SystemExit(1)
PY
}

# resolve_hash_threads: an explicit -T N is clamped to the host's core count
# (never more threads than cores), while auto (0) uses min(cores, CAP).  This
# covers the client side; the python3 remote mirrors the same logic against
# its own cores.  Self-skips on the python2 client (no --hash-threads there).
test_hash_threads_clamped_to_cores() {
    local mod_src=$BSCP
    if ! head -1 "$BSCP" 2>/dev/null | grep -q '^#!.*python'; then
        mod_src="$SCRIPT_DIR/bscp"
    fi
    cp "$mod_src" "$WORK/bscp_mod.py"
    PYTHONPATH="$WORK" python3 - <<'PY'
import os, bscp_mod as m
if not hasattr(m, 'resolve_hash_threads'):
    raise SystemExit(0)            # python2 client: --hash-threads absent
cores = os.cpu_count() or 1
errs = []
cases = [
    (cores + 100, cores),                       # explicit beyond cores -> clamped
    (1,           1),                            # explicit within cores -> honoured
    (max(1, cores - 1), min(max(1, cores - 1), cores)),
    (0,           min(cores, m.HASH_THREADS_CAP)),  # auto -> min(cores, CAP)
]
for n, exp in cases:
    got = m.resolve_hash_threads(n)
    if got != exp:
        errs.append('resolve_hash_threads(%d) = %d, expected %d' % (n, got, exp))
if errs:
    print('\n'.join(errs))
    raise SystemExit(1)
PY
}

# ---------- run ----------
echo "Running bscp regression tests against localhost..."
run "push: random 4K diffs in mid-file"              test_push
run "pull: random 4K diffs in mid-file"              test_pull
run "dry-run leaves destination unchanged"           test_dryrun_does_not_modify
run "resume from a mid-file section boundary"        test_resume_from_section
run "resume from a percentage of local file size"    test_resume_from_percent
run "perl remote: push (BSCP_FORCE_PERL=1)"          test_perl_remote_push
run "perl remote: pull (BSCP_FORCE_PERL=1)"          test_perl_remote_pull
run "legacy remote: push (BSCP_FORCE_PYTHON2=1)"     test_legacy_remote_push
run "legacy remote: pull (BSCP_FORCE_PYTHON2=1)"     test_legacy_remote_pull
run "--buffer push"                                  test_buffer_push
run "--bwlimit push throttles to rate"               test_bwlimit_push
run "--hash-threads 4 push (multi-section)"          test_hash_threads_push
run "--hash-threads 1 pull (serial pool path)"       test_hash_threads_single_pull
run "--allow-truncate push (smaller dst)"            test_allow_truncate_push
run "--allow-truncate pull (smaller dst)"            test_allow_truncate_pull
run "--batch is silent on success and exits 0"       test_batch_silent_success
run "--block-count prints next-offset resume hint"   test_block_count_continue
run "-B accepts K/M/G byte-size suffix"              test_block_count_size_suffix
run "-B pull within dst size needs no truncate flag" test_block_count_pull_no_truncate_needed
run "-B beyond dst size still requires --truncate"   test_block_count_truncate_still_required
run "-B overshoot prints warning, exits 0"           test_block_count_overshoot_warns
run "-B overshoot + smaller dst exits without hang"  test_block_count_overshoot_smaller_dst_no_hang
run "--verify push, matching b3sum digests"          test_verify_push_match
run "--verify detects a mismatch, exits 4"           test_verify_mismatch_exit4
run "--verify skips gracefully when b3sum unusable"  test_verify_skips_when_b3sum_unusable
run "--verify skips compare on size mismatch"        test_verify_size_mismatch_skips
run "--verify under -N runs when scan finds 0 diffs" test_verify_dryrun_zero_diff_runs
run "--verify under -N skips when diffs are pending"  test_verify_dryrun_with_diff_skips
run "--batch --verify mismatch: silent, exits 4"     test_verify_batch_mismatch_exit4
run "--batch --verify size mismatch: silent, exits 5" test_verify_batch_size_mismatch_exit5
run "--batch --verify + -B rejected at argparse (2)" test_verify_batch_blockcount_rejected
run "BSCP_OPTIONS default options take effect"       test_bscp_options_applies
run "BSCP_OPTIONS overridden by explicit CLI option" test_bscp_options_cli_overrides
run "exit 2 when neither side is HOST:path"          test_exit2_when_no_host
run "friendly error when local file is missing"      test_friendly_error_for_missing_local
run "reject unknown / zero-digest -a algorithm"      test_reject_bad_algorithm
run "connection failure engages retries, exits 3"    test_conn_failure_retries_exit3
run "format_size + parse_size unit tests"            test_format_size_unit_tests
run "resolve_hash_threads clamps -T N to cores"      test_hash_threads_clamped_to_cores

echo
echo "$PASSED passed, $FAILED failed, $SKIPPED skipped"
if (( SKIPPED > 0 )); then
    printf 'Skipped (python2 client; use --force-all to run): %s\n' "${SKIPPED_NAMES[@]}"
fi
if (( FAILED > 0 )); then
    printf 'Failed: %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
