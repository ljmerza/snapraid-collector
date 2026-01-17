#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COLLECTOR="$PROJECT_ROOT/snapraid_metrics_collector.sh"
FAKE_SNAPRAID="$PROJECT_ROOT/tests/bin/fake_snapraid"
FIXTURE_DIR="$PROJECT_ROOT/tests/fixtures"
TMP_DIR="$PROJECT_ROOT/tests/tmp"
LOG_DIR="$TMP_DIR/logs"

rm -rf "$TMP_DIR"
mkdir -p "$LOG_DIR"

failures=0

die() {
  echo "ERROR: $1" >&2
  exit 1
}

run_collector() {
  local textfile
  textfile=$(mktemp "$TMP_DIR/metrics.XXXXXX.prom")
  SNAPRAID_COLLECTOR_SKIP_ROOT=true "$COLLECTOR" \
    --snapraid-bin "$FAKE_SNAPRAID" \
    --log-dir "$LOG_DIR" \
    --textfile "$textfile" \
    "$@" >/dev/null 2>&1
  cat "$textfile"
}

run_collector_with_env() {
  local textfile
  textfile=$(mktemp "$TMP_DIR/metrics.XXXXXX.prom")
  SNAPRAID_COLLECTOR_SKIP_ROOT=true "$COLLECTOR" \
    --snapraid-bin "$FAKE_SNAPRAID" \
    --log-dir "$LOG_DIR" \
    --textfile "$textfile" \
    "$@" 2>&1 || true
  cat "$textfile"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if ! grep -qE "$needle" <<<"$haystack"; then
    echo "Assertion failed: $message" >&2
    echo "Expected pattern: $needle" >&2
    ((failures++))
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if grep -qE "$needle" <<<"$haystack"; then
    echo "Assertion failed: $message" >&2
    echo "Did not expect pattern: $needle" >&2
    ((failures++))
  fi
}

# Version metric
version_output=$(run_collector smart)
assert_contains "$version_output" 'snapraid_collector_info\{version="1\.1\.0"\} 1' "Version info metric"

# Smart metrics
smart_metrics=$(run_collector smart)
assert_contains "$smart_metrics" 'snapraid_smart_disk_fail_probability\{.*disk="data03".*\} 42' "SMART fail probability for data03"
assert_contains "$smart_metrics" 'snapraid_smart_total_fail_probability 34' "SMART total fail probability"
assert_contains "$smart_metrics" 'snapraid_smart_warning_count 1' "SMART warning count"

# Sync metrics
sync_metrics=$(run_collector sync)
assert_contains "$sync_metrics" 'snapraid_sync_completion_percent 100' "Sync completion percent"
assert_contains "$sync_metrics" 'snapraid_sync_accessed_bytes 18894000000' "Sync accessed bytes conversion"
assert_contains "$sync_metrics" 'snapraid_sync_items_updated 5' "Sync updated count"

# Scrub metrics
scrub_metrics=$(run_collector scrub)
assert_contains "$scrub_metrics" 'snapraid_scrub_completion_duration_seconds 5025' "Scrub duration parsing"
assert_contains "$scrub_metrics" 'snapraid_scrub_items_scrubbed 4' "Scrubbed item count"
assert_contains "$scrub_metrics" 'snapraid_scrub_data_errors 1' "Scrub data errors"

# Diff metrics
diff_metrics=$(run_collector diff)
assert_contains "$diff_metrics" 'snapraid_diff_files_equal 1024' "Diff equal files count"
assert_contains "$diff_metrics" 'snapraid_diff_files_added 15' "Diff added files count"
assert_contains "$diff_metrics" 'snapraid_diff_files_removed 3' "Diff removed files count"
assert_contains "$diff_metrics" 'snapraid_diff_files_updated 8' "Diff updated files count"
assert_contains "$diff_metrics" 'snapraid_diff_files_moved 2' "Diff moved files count"
assert_contains "$diff_metrics" 'snapraid_diff_files_copied 1' "Diff copied files count"
assert_contains "$diff_metrics" 'snapraid_diff_sync_required 0' "Diff sync required (exit 0)"

# Diff exit code 2 (sync required)
diff_sync_textfile=$(mktemp "$TMP_DIR/diff_sync.XXXXXX.prom")
SNAPRAID_COLLECTOR_SKIP_ROOT=true FAKE_SNAPRAID_EXIT=2 "$COLLECTOR" \
  --snapraid-bin "$FAKE_SNAPRAID" \
  --log-dir "$LOG_DIR" \
  --textfile "$diff_sync_textfile" \
  diff >/dev/null 2>&1
diff_sync_result=$?
diff_sync_metrics=$(cat "$diff_sync_textfile")
assert_contains "$diff_sync_metrics" 'snapraid_diff_sync_required 1' "Diff sync required (exit 2)"
if [[ $diff_sync_result -ne 0 ]]; then
  echo "Assertion failed: diff exit code 2 should not propagate as failure" >&2
  ((failures++))
fi

# Status metrics
status_metrics=$(run_collector status)
assert_contains "$status_metrics" 'snapraid_status_sync_in_progress 0' "Status sync not in progress"
assert_contains "$status_metrics" 'snapraid_status_scrub_oldest_days 45' "Status oldest scrub days"
assert_contains "$status_metrics" 'snapraid_status_unscrubbed_percent 15' "Status unscrubbed percent"
assert_contains "$status_metrics" 'snapraid_status_fragmentation_percent 1.2' "Status fragmentation percent"

# Chained commands
chained_metrics=$(run_collector smart sync)
assert_contains "$chained_metrics" 'snapraid_smart_total_fail_probability 34' "Chained: smart metrics present"
assert_contains "$chained_metrics" 'snapraid_sync_completion_percent 100' "Chained: sync metrics present"

# Redaction test
redact_textfile=$(mktemp "$TMP_DIR/redact.XXXXXX.prom")
SNAPRAID_COLLECTOR_SKIP_ROOT=true "$COLLECTOR" \
  --snapraid-bin "$FAKE_SNAPRAID" \
  --log-dir "$LOG_DIR" \
  --textfile "$redact_textfile" \
  --redact-identifiers \
  smart >/dev/null 2>&1
redact_metrics=$(cat "$redact_textfile")
assert_contains "$redact_metrics" 'disk="redacted_' "Redaction: disk label contains redacted_ prefix"
assert_contains "$redact_metrics" 'serial="redacted_' "Redaction: serial label contains redacted_ prefix"
assert_not_contains "$redact_metrics" 'disk="data0' "Redaction: original disk name not present"
assert_not_contains "$redact_metrics" 'serial="SERIAL' "Redaction: original serial not present"

# ANSI stripping test
ansi_textfile=$(mktemp "$TMP_DIR/ansi.XXXXXX.prom")
export FAKE_SNAPRAID_FIXTURE="$FIXTURE_DIR/smart_output_ansi.txt"
SNAPRAID_COLLECTOR_SKIP_ROOT=true "$COLLECTOR" \
  --snapraid-bin "$FAKE_SNAPRAID" \
  --log-dir "$LOG_DIR" \
  --textfile "$ansi_textfile" \
  smart >/dev/null 2>&1
ansi_metrics=$(cat "$ansi_textfile")
unset FAKE_SNAPRAID_FIXTURE
assert_contains "$ansi_metrics" 'snapraid_smart_disk_fail_probability\{.*disk="data03".*\} 42' "ANSI: parses correctly with escape codes"
assert_contains "$ansi_metrics" 'snapraid_smart_total_fail_probability 34' "ANSI: total fail probability still works"

# Empty smart output test
empty_textfile=$(mktemp "$TMP_DIR/empty.XXXXXX.prom")
export FAKE_SNAPRAID_FIXTURE="$FIXTURE_DIR/smart_output_empty.txt"
SNAPRAID_COLLECTOR_SKIP_ROOT=true "$COLLECTOR" \
  --snapraid-bin "$FAKE_SNAPRAID" \
  --log-dir "$LOG_DIR" \
  --textfile "$empty_textfile" \
  smart >/dev/null 2>&1
empty_metrics=$(cat "$empty_textfile")
unset FAKE_SNAPRAID_FIXTURE
assert_contains "$empty_metrics" 'snapraid_smart_exit_status 0' "Empty output: exit status present"
assert_contains "$empty_metrics" 'snapraid_smart_warning_count 0' "Empty output: warning count is 0"

# Timeout flag passes through (just check it doesn't crash)
timeout_textfile=$(mktemp "$TMP_DIR/timeout.XXXXXX.prom")
if SNAPRAID_COLLECTOR_SKIP_ROOT=true "$COLLECTOR" \
  --snapraid-bin "$FAKE_SNAPRAID" \
  --log-dir "$LOG_DIR" \
  --textfile "$timeout_textfile" \
  --timeout 60 \
  smart >/dev/null 2>&1; then
  : # success
else
  echo "Assertion failed: --timeout flag should not cause crash" >&2
  ((failures++))
fi

# Failure propagation
if SNAPRAID_COLLECTOR_SKIP_ROOT=true FAKE_SNAPRAID_FAIL=scrub "$COLLECTOR" --snapraid-bin "$FAKE_SNAPRAID" --log-dir "$LOG_DIR" scrub >/dev/null 2>&1; then
  echo "Assertion failed: scrub failure should propagate exit code" >&2
  ((failures++))
fi

# Version flag test
version_output=$("$COLLECTOR" --version 2>&1)
assert_contains "$version_output" 'snapraid_metrics_collector 1\.1\.0' "Version flag output"

if (( failures > 0 )); then
  echo "Tests failed: $failures failing assertion(s)." >&2
  exit 1
fi

echo "All tests passed."
