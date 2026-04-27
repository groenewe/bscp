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
#
# Exit status: 0 if all tests pass, non-zero otherwise.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BSCP="${BSCP:-$SCRIPT_DIR/bscp}"

WORK=$(mktemp -d)
SRC="$WORK/src.img"
DST="$WORK/dst.img"
DST2="$WORK/dst2.img"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
FAILED=0
FAILED_NAMES=()

run() {
    local name=$1; shift
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

test_buffer_push() {
    make_src 10
    copy_src_to "$DST"
    randomise_in "$DST" 8 300
    "$BSCP" -s 2M --buffer "$SRC" "localhost:$DST" >/dev/null 2>&1 \
        && cmp -s "$SRC" "$DST"
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

# ---------- run ----------
echo "Running bscp regression tests against localhost..."
run "push: random 4K diffs in mid-file"              test_push
run "pull: random 4K diffs in mid-file"              test_pull
run "dry-run leaves destination unchanged"           test_dryrun_does_not_modify
run "resume from a mid-file section boundary"        test_resume_from_section
run "resume from a percentage of local file size"    test_resume_from_percent
run "--buffer push"                                  test_buffer_push
run "--allow-truncate push (smaller dst)"            test_allow_truncate_push
run "--allow-truncate pull (smaller dst)"            test_allow_truncate_pull
run "--batch is silent on success and exits 0"       test_batch_silent_success
run "--block-count prints next-offset resume hint"   test_block_count_continue
run "-B accepts K/M/G byte-size suffix"              test_block_count_size_suffix
run "-B pull within dst size needs no truncate flag" test_block_count_pull_no_truncate_needed
run "-B beyond dst size still requires --truncate"   test_block_count_truncate_still_required
run "-B overshoot prints warning, exits 0"           test_block_count_overshoot_warns
run "-B overshoot + smaller dst exits without hang"  test_block_count_overshoot_smaller_dst_no_hang
run "exit 2 when neither side is HOST:path"          test_exit2_when_no_host
run "friendly error when local file is missing"      test_friendly_error_for_missing_local
run "format_size + parse_size unit tests"            test_format_size_unit_tests

echo
echo "$PASSED passed, $FAILED failed"
if (( FAILED > 0 )); then
    printf 'Failed: %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
