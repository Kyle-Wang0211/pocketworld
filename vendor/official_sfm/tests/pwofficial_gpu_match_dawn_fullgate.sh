#!/usr/bin/env bash
# pwofficial_gpu_match_dawn_fullgate.sh — the 2026-09-02 full gate
# (~/Developer/pw_h2_fullgate_20260902/run_fullgate.sh) re-pointed at the
# production Dawn TU host arm: every temporal K12 pair of a real 12MP session
# db, native Metal (shipped TU) vs the Dawn TU, ordered-pairs SHA-256 compared
# byte-for-byte. Differences from the original script: the bin dir and the
# frame library are parameters (the original hard-codes both and shares one
# frame dir across dbs), and the environment is passed through untouched so
# backend variants (tiled / chunk sizes) can be gated with the same script.
#
# usage: BIN=<build_dir> FULLGATE_DB=<db> [MAXF=<n>] [LABEL=<name>] \
#          pwofficial_gpu_match_dawn_fullgate.sh
set -euo pipefail
BIN="${BIN:?build dir with fair_match_extract_fixture/native_arm/portable_arm}"
DB="${FULLGATE_DB:?session db}"
MAXF="${MAXF:-146}"
LABEL="${LABEL:-dawntu}"
ROOT="${FULLGATE_ROOT:-$HOME/Developer/pw_h2_fullgate_20260902}"
DBNAME=$(basename "$DB" .db)
LIB="${FULLGATE_LIB:-$ROOT/frames_$DBNAME}"
PAIR="$ROOT/pairwork_$LABEL.$$"
LOG="$ROOT/fullgate_${LABEL}_${DBNAME}.log"
mkdir -p "$LIB" "$PAIR"
: > "$LOG"
echo "BIN=$BIN DB=$DB LIB=$LIB LABEL=$LABEL env: OFFICIAL_AETHER_MATCH_DAWN_KERNEL=${OFFICIAL_AETHER_MATCH_DAWN_KERNEL:-} OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS=${OFFICIAL_AETHER_MATCH_CHUNK_TARGET_MS:-}" | tee -a "$LOG"

# 1) each frame's descriptors extracted once ((i,i) pair; a.u8 is the frame)
for ((i=1;i<=MAXF;i++)); do
  d="$LIB/f$i"
  [ -s "$d/a.u8" ] && continue
  mkdir -p "$d"
  "$BIN/fair_match_extract_fixture" "$DB" "$d" "$i" "$i" >/dev/null 2>&1 || { echo "extract-skip $i" >> "$LOG"; rm -rf "$d"; }
done

# 2) temporal K12 pairs: i vs i-1..i-12; native and Dawn each 1 rep; compare pairs sha
pass=0; fail=0; skip=0
for ((i=2;i<=MAXF;i++)); do
  for ((j=i-1;j>=i-12 && j>=1;j--)); do
    [ -s "$LIB/f$i/a.u8" ] && [ -s "$LIB/f$j/a.u8" ] || { skip=$((skip+1)); continue; }
    rm -rf "$PAIR"; mkdir -p "$PAIR/n" "$PAIR/p"
    cp "$LIB/f$i/a.u8" "$PAIR/a.u8"; cp "$LIB/f$j/a.u8" "$PAIR/b.u8"
    python3 - "$LIB/f$i/manifest.json" "$LIB/f$j/manifest.json" "$PAIR" <<'PYEOF'
import json,sys,hashlib
mi=json.load(open(sys.argv[1])); mj=json.load(open(sys.argv[2])); d=sys.argv[3]
sha=lambda f: hashlib.sha256(open(f,'rb').read()).hexdigest()
json.dump({"rows_a":mi["rows_a"],"rows_b":mj["rows_a"],
           "sha256_a":sha(d+"/a.u8"),"sha256_b":sha(d+"/b.u8"),"cols":128},
          open(d+"/manifest.json","w"))
PYEOF
    na=$("$BIN/fair_match_native_arm" "$PAIR" "$PAIR/n" 1 0 0.7 2>/dev/null | grep -o '"pairs_sha256":"[a-f0-9]*"' | head -1)
    po=$("$BIN/fair_match_portable_arm" "$PAIR" "$PAIR/p" 1 0 0.7 "$LABEL" 2>"$PAIR/p/err.log" | grep -o '"pairs_sha256":"[a-f0-9]*"' | head -1)
    if [ -n "$na" ] && [ "$na" = "$po" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "MISMATCH i=$i j=$j na=$na po=$po err=$(tail -c 300 "$PAIR/p/err.log" | tr '\n' ' ')" >> "$LOG"; fi
  done
done
rm -rf "$PAIR"
echo "FULLGATE label=$LABEL db=$DBNAME pass=$pass fail=$fail skip=$skip" | tee -a "$LOG"
[ "$fail" -eq 0 ]
