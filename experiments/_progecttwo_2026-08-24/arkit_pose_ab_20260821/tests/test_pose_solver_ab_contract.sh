#!/bin/sh

set -u

EXPECTED_DB_SHA256='6b7ec9ed765645e95c95df69d304c4e73321b0eac538e223463851fc9c5dcaf2'
COLMAP='/opt/homebrew/bin/colmap'

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s RUNNER INITIAL_DB RUN_DIR\n' "$0" >&2
  exit 64
}

extract_unsigned_metric() {
  metric_name=$1
  metric_line=$2

  /usr/bin/awk -v wanted="$metric_name" '
    {
      count = 0
      invalid = 0
      value = ""
      prefix = wanted "="
      for (i = 1; i <= NF; i++) {
        if (index($i, prefix) == 1) {
          candidate = substr($i, length(prefix) + 1)
          if (candidate ~ /^[0-9][0-9]*$/) {
            count++
            value = candidate
          } else {
            invalid = 1
          }
        }
      }
      if (!invalid && count == 1) {
        print value
        exit 0
      }
      exit 1
    }
  ' <<EOF
$metric_line
EOF
}

assert_metric_parser_rejects_extra_equals() {
  if extract_unsigned_metric registered 'RESULT registered=48=garbage' >/dev/null; then
    fail "metric parser accepted malformed token with extra '='"
  fi
}

assert_metric_parser_rejects_extra_equals

[ "$#" -eq 3 ] || usage

runner=$1
initial_db=$2
run_dir=$3

[ -f "$runner" ] && [ -x "$runner" ] || fail "runner is not executable: $runner"
[ -f "$initial_db" ] && [ -r "$initial_db" ] || fail "initial DB is not a readable file: $initial_db"
if [ -e "$run_dir" ] || [ -L "$run_dir" ]; then
  fail "run directory already exists: $run_dir"
fi

initial_sha=$(LC_ALL=C /usr/bin/shasum -a 256 "$initial_db" | /usr/bin/awk '{ print $1 }')
[ "$initial_sha" = "$EXPECTED_DB_SHA256" ] || \
  fail "initial DB SHA-256 mismatch: expected $EXPECTED_DB_SHA256, got ${initial_sha:-<unavailable>}"

[ -x "$COLMAP" ] || fail "COLMAP is not executable: $COLMAP"

/bin/mkdir "$run_dir" || fail "could not create run directory: $run_dir"
if ! run_dir_abs=$(CDPATH= cd -- "$run_dir" 2>/dev/null && /bin/pwd -P); then
  fail "could not resolve run directory: $run_dir"
fi
input_db_dir=$run_dir_abs
input_db="$input_db_dir/input.db"
sidecar="$input_db.arkit_pose_v1"
model_dir="$run_dir_abs/model"
runner_log="$run_dir_abs/runner.log"
runner_status_file="$run_dir_abs/runner.exit_code"
analyzer_log="$run_dir_abs/model_analyzer.log"

/bin/cp "$initial_db" "$input_db" || fail "could not copy initial DB to $input_db"
copied_sha=$(LC_ALL=C /usr/bin/shasum -a 256 "$input_db" | /usr/bin/awk '{ print $1 }')
[ "$copied_sha" = "$EXPECTED_DB_SHA256" ] || \
  fail "copied DB SHA-256 mismatch: expected $EXPECTED_DB_SHA256, got ${copied_sha:-<unavailable>}"

[ ! -e "$sidecar" ] && [ ! -L "$sidecar" ] || fail "B1 pose sidecar exists before run: $sidecar"

if ! pose_priors_table_count=$(CDPATH= cd -- "$input_db_dir" && \
  /usr/bin/sqlite3 'file:input.db?mode=ro&immutable=1' \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='pose_priors';"); then
  fail "could not inspect pose_priors table"
fi

case "$pose_priors_table_count" in
  0)
    pose_priors_count=0
    ;;
  1)
    if ! pose_priors_count=$(CDPATH= cd -- "$input_db_dir" && \
      /usr/bin/sqlite3 'file:input.db?mode=ro&immutable=1' \
        'SELECT count(*) FROM pose_priors;'); then
      fail "could not count pose_priors rows"
    fi
    ;;
  *)
    fail "unexpected pose_priors table count: $pose_priors_table_count"
    ;;
esac

case "$pose_priors_count" in
  ''|*[!0-9]*) fail "invalid pose_priors row count: $pose_priors_count" ;;
esac
[ "$pose_priors_count" -eq 0 ] || fail "pose_priors must contain 0 rows, found $pose_priors_count"

/usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin \
  LANG=C \
  LC_ALL=C \
  TMPDIR=/tmp \
  "$runner" visual "$input_db" "$model_dir" 48 >"$runner_log" 2>&1
runner_status=$?
printf '%s\n' "$runner_status" >"$runner_status_file" || fail "could not record runner exit status"

[ ! -e "$sidecar" ] && [ ! -L "$sidecar" ] || fail "B1 pose sidecar exists after run: $sidecar"
[ "$runner_status" -eq 0 ] || fail "runner exited with status $runner_status; see $runner_log"

if ! result_count=$(/usr/bin/awk '/^RESULT([[:space:]]|$)/ { count++ } END { print count + 0 }' "$runner_log"); then
  fail "could not inspect runner RESULT output"
fi
[ "$result_count" -eq 1 ] || fail "expected exactly one RESULT line, found $result_count; see $runner_log"
result_line=$(/usr/bin/awk '/^RESULT([[:space:]]|$)/ { print; exit }' "$runner_log")

if ! registered=$(extract_unsigned_metric registered "$result_line"); then
  fail "RESULT must contain one unsigned registered metric: $result_line"
fi
if ! raw_points=$(extract_unsigned_metric raw_points "$result_line"); then
  fail "RESULT must contain one unsigned raw_points metric: $result_line"
fi
if ! gravity_hits=$(extract_unsigned_metric gravity_hits "$result_line"); then
  fail "RESULT must contain one unsigned gravity_hits metric: $result_line"
fi

[ "$registered" -ge 48 ] || fail "registered must be >= 48, got $registered"
[ "$raw_points" -gt 0 ] || fail "raw_points must be > 0, got $raw_points"
[ "$gravity_hits" -eq 0 ] || fail "gravity_hits must be 0, got $gravity_hits"

for model_file in cameras.bin images.bin points3D.bin; do
  [ -s "$model_dir/$model_file" ] || fail "model file is missing or empty: $model_dir/$model_file"
done

"$COLMAP" model_analyzer --path "$model_dir" >"$analyzer_log" 2>&1
analyzer_status=$?
[ "$analyzer_status" -eq 0 ] || fail "COLMAP model_analyzer failed with status $analyzer_status; see $analyzer_log"

[ ! -e "$sidecar" ] && [ ! -L "$sidecar" ] || fail "B1 pose sidecar exists after validation: $sidecar"

printf 'PASS: registered=%s raw_points=%s gravity_hits=%s model=%s\n' \
  "$registered" "$raw_points" "$gravity_hits" "$model_dir"
