#!/usr/bin/env bash
# fair_match_parity_suite.sh — fail-closed constructed parity suite (H2).
#
# Fail-closed design (2026-08-01 user review): every case carries a FROZEN
# golden (expected native count + ordered-pairs SHA-256) captured from the
# accepted SR-3A-era native reference, so a silent generator or collective
# multi-arm drift turns the suite red instead of green. Work dirs are
# recreated from scratch each run so stale pair files can never be compared.
# Triple golden (2026-08-01 upgrade): pairs digest + OutAB ordered digest +
# OutBA ordered digest per case, so a two-direction drift whose intersection
# happens to be unchanged still turns the suite red. Direction goldens were
# captured from the accepted fusedr64 arm (all portable kernels must agree;
# the native ABI does not expose direction maps, so it is gated on pairs
# only).
# Key-index assertions: tie_xwg must be missing exactly A indices
# {5,7,125,129} (equal-dot ties reject through the >= ratio semantics and the
# mutual gate) and eq_best2 must not contain A index 10.
#
# usage: fair_match_parity_suite.sh <build_dir> <work_dir> [kernels...]
set -uo pipefail

BUILD="${1:-/private/tmp/aether-host-speed-h2-matcher/build}"
WORK="${2:-/private/tmp/aether-host-speed-h2-matcher/parity}"
shift 2 2>/dev/null || true
KERNELS=("${@:-}")
if [ -z "${KERNELS[0]:-}" ]; then
  KERNELS=(naive tiled mma fused fusedr64 fusedr128)
fi

# case:expected_count:expected_ordered_pairs_sha256 (frozen 2026-08-01,
# generator seed 0x9e3779b97f4a7c15, gen source SHA 20c5e760… + empty cases)
GOLDENS="
r63x129:63:113f782ffbfe223e00464a8a6d4dba2bdc217cbf24031a50e1fd5306d45bfacd:413d7cfd3a071c33af1045719d2d0224258fd3f637479c63f87efdea3fa4ec06:ff30c879358822f7702ccd72d26cbeb456878bc9694813080162941c702c31de
r65x127:65:5d843e39fb7944e5440e36e0648de879a805b02712b37b28f5a1ce95d0e577c4:fee16ec542015efdeec7654ea06333eb655815da008a8a349efad6d02e86ed35:fe9d8779c1038b2c85955ee9ff71c79031d47553fdffdfb5331f34e4ad24802c
r127x65:3:48307041a27b9493dbe95c05bf1767de9c65934a4f63c23fb8973b8ddd1bba01:5e4ffbe3b7841698d649a28cec4cfac15828d33b8ada2813e6b7585087d07c74:0c807e28357ebcb2e3ab254b4391de9c3f6399e63b6530a5516ff3111bc30ee3
r128x129:128:4b4f1d5f3c66e81ac1542951a5abd1fd733657fbe692ff72bb33939e684db548:1abb49eec50723c018c1197161b8cc46c61cab2dbfdd96287a7e3e20bbcdcc99:d28f6b44600cabf22392a20444c853bd477ee201fc6180f306a5ec53ba2fbfe9
r129x128:127:d70c57f4781d0c39d488ef91d7248179d68f65a379834d2e14e2e70e5ab6cf36:a77eb0662d54205fa8a8419523213f7e6a82bdb35bf921ff232714cfe14b4518:0aab5d68b9459e288782fce14c9e8bd89e75c2d9308cd022e8990494672551c7
c31:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855:47097790546ed204957e831bd47f436d548ef9ec0ce20c8eb1da697b41aed473:49400dd2502410d5b6c7222a4261c8dbfa17c8b96b1faf91df4f586761841d76
c32:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855:1928ee6c364c3358a4b772e7fc3c5c3526f49e93e5af0c9ca5ab2fc175e34890:e9175db65a9789096ca9cb5524d3abc2107df03e3c9ba3af1aca628f9c5d3bd2
c33:2:f3806398196e1df5da79cec0e1915576123dedf6c3ff5569add0f7cdee9634b4:2e9015e569eb805097ff5d567f39e2b54eaaf9c278b36ccbbd17198f71239cb0:debb2703af28d0bb0c1637b7f9a069016ca78f237a0e095bf14ae625b99d5067
tie_xwg:126:ba01bb97d4bb5ae585a4c2fab0b86287d5ffa5988ee0e20e77e3cd1ae03e08c0:e4b6629ccf0b345e486e01d06a52476c655d1087e03ce5b63054581b37fce4d0:1f678a95eac555caf3ba7960d017b710f892725569e92ac3068c23a09e516c3a
eq_best2:31:6e2e07a259908846acbef4408650547bd1590bf17e27fe201bdffeef3f451b7f:b8da979dfab28f161cd2c6a2c4644da55da6761f0cff54fd50255280d5f2aaef:71120fec4cc777e7468a28f211d1f322d0cd9c4bf3bc770802e0967cc64cdf93
tiny_1x1:1:af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc:df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119:df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119
tiny_1x2:1:af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc:df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119:5981693c8df83eea16da42a0f748facb299546688544a0c2887ed5ffbf086e86
tiny_2x2:1:af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc:5981693c8df83eea16da42a0f748facb299546688544a0c2887ed5ffbf086e86:5981693c8df83eea16da42a0f748facb299546688544a0c2887ed5ffbf086e86
zeros:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855:3d6876a0146de8576eb2395a858de1213d1b92c65b779df3a331cfd5a4584546:3d6876a0146de8576eb2395a858de1213d1b92c65b779df3a331cfd5a4584546
abs_gate:11:d959fee2ea6375904a9e616d9e23d84e73bda91f921fb5ce510b8d18e94c0b1e:7d5922fcc179e2683e8d2421a3e5517846e25690e070a403f217c465f1251337:7d5922fcc179e2683e8d2421a3e5517846e25690e070a403f217c465f1251337
ratio_gate:2:8fc9f3b191dbb36d5cb9124ad86626b9a6dc9637264f6fc2f98b4ed70203c84a:4d042ff4f63057de2e656ed5a46f52f299afd86b50c34fbb905a482b16fc5648:c9f5bb1f3cb7cd5e3584ab5ab3bc834beefd8dc96771cb22c832ad108be90c9a
empty_0x64:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855:NONE:NONE
empty_64x0:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855:NONE:NONE
empty_0x0:0:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855:NONE:NONE
"

rm -rf "$WORK"
mkdir -p "$WORK"
fail=0

check_indices() {
  python3 - "$1" "$2" <<'EOF'
import struct, sys
path, case = sys.argv[1], sys.argv[2]
d = open(path, 'rb').read()
pairs = [struct.unpack_from('<II', d, i * 8) for i in range(len(d) // 8)]
a_idx = {p[0] for p in pairs}
if case == 'tie_xwg':
    missing = sorted(i for i in range(130) if i not in a_idx)
    sys.exit(0 if missing == [5, 7, 125, 129] else 1)
if case == 'eq_best2':
    sys.exit(0 if 10 not in a_idx else 1)
sys.exit(0)
EOF
}

for entry in $GOLDENS; do
  case="${entry%%:*}"; rest="${entry#*:}"
  want_count="${rest%%:*}"; rest="${rest#*:}"
  want_sha="${rest%%:*}"; rest="${rest#*:}"
  want_ab="${rest%%:*}"; want_ba="${rest#*:}"
  cd="$WORK/$case"
  rm -rf "$cd"; mkdir -p "$cd"
  "$BUILD/fair_match_gen_fixture" "$cd" "$case" >/dev/null || { echo "GEN-FAIL $case"; fail=1; continue; }
  if ! "$BUILD/fair_match_native_arm" "$cd" "$cd" 1 0 0.7 >"$cd/native.log" 2>&1; then
    echo "NATIVE-FAIL $case (see $cd/native.log)"; fail=1; continue
  fi
  count=$(grep -o '"count":[0-9]*' "$cd/native.log" | head -1 | cut -d: -f2)
  sha=$(shasum -a 256 "$cd/native_pairs.bin" | awk '{print $1}')
  line="$case:"
  if [ "$count" != "$want_count" ] || [ "$sha" != "$want_sha" ]; then
    line="$line native=GOLDEN-DIFF(count=$count sha=${sha:0:12})"; fail=1
  else
    line="$line native=GOLDEN-OK($count)"
  fi
  if ! check_indices "$cd/native_pairs.bin" "$case"; then
    line="$line index-assert=FAIL"; fail=1
  fi
  for k in "${KERNELS[@]}"; do
    if ! "$BUILD/fair_match_portable_arm" "$cd" "$cd" 1 0 0.7 "$k" >"$cd/$k.log" 2>&1; then
      line="$line $k=RUN-FAIL"; fail=1; continue
    fi
    ksha=$(shasum -a 256 "$cd/portable_${k}_pairs.bin" | awk '{print $1}')
    kab=$(grep -o '"outab_sha256":"[a-f0-9]*"' "$cd/$k.log" | cut -d'"' -f4)
    kba=$(grep -o '"outba_sha256":"[a-f0-9]*"' "$cd/$k.log" | cut -d'"' -f4)
    kab="${kab:-NONE}"; kba="${kba:-NONE}"
    if [ "$ksha" = "$want_sha" ] && [ "$kab" = "$want_ab" ] && [ "$kba" = "$want_ba" ]; then
      line="$line $k=PASS"
    else
      line="$line $k=GOLDEN-DIFF(p:${ksha:0:6} ab:${kab:0:6} ba:${kba:0:6})"; fail=1
    fi
  done
  echo "$line"
done
[ $fail -eq 0 ] && echo "PARITY_SUITE_PASS" || echo "PARITY_SUITE_FAIL"
exit $fail
