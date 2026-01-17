#!/usr/bin/env bash

set -o pipefail

usage() {
  cat <<'EOF'
Usage: snapraid_metrics_collector.sh [options] command [args] [command [args] ...]

Commands:
  smart                Run `snapraid smart`
  scrub                Run `snapraid scrub`
  sync                 Run `snapraid sync`
  diff                 Run `snapraid diff`
  status               Run `snapraid status`

Options:
  --textfile PATH             Write metrics atomically to PATH instead of stdout
  --snapraid-bin PATH         Use PATH as the snapraid executable
  --log-dir PATH              Write logs under PATH (defaults to ./logs)
  --dry-run                   Skip snapraid execution (override root requirement)
  --verbose                   Mirror snapraid stdout/stderr to collector stderr
  --redact-identifiers        Redact disk identifiers in metric labels
  --timeout SECONDS           Timeout for each snapraid command (0 = disabled)
  --debug                     Print parsed values to stderr before metric emission
  --smart-defaults "ARGS"     Default arguments appended to `snapraid smart`
  --scrub-defaults "ARGS"     Default arguments appended to `snapraid scrub`
  --sync-defaults "ARGS"      Default arguments appended to `snapraid sync`
  --diff-defaults "ARGS"      Default arguments appended to `snapraid diff`
  --status-defaults "ARGS"    Default arguments appended to `snapraid status`
  -h, --help                  Show this message
  --version                   Show version information

Environment overrides:
  SNAPRAID_BIN, SNAPRAID_LOG_DIR, SNAPRAID_SMART_DEFAULTS,
  SNAPRAID_SCRUB_DEFAULTS, SNAPRAID_SYNC_DEFAULTS, SNAPRAID_DIFF_DEFAULTS,
  SNAPRAID_STATUS_DEFAULTS, SNAPRAID_COLLECTOR_REDACT, SNAPRAID_TIMEOUT,
  SNAPRAID_COLLECTOR_SKIP_ROOT

You can provide multiple commands in one invocation; arguments following a command
are passed directly to SnapRAID until the next command keyword. Use `--` to force
subsequent tokens to be treated as arguments rather than command keywords.
EOF
}

COLLECTOR_VERSION="1.1.0"

TEXTFILE_PATH=""
DRY_RUN=false
VERBOSE=false
DEBUG=false
TIMEOUT=${SNAPRAID_TIMEOUT:-0}
REDACT_IDENTIFIERS=${SNAPRAID_COLLECTOR_REDACT:-false}
SNAPRAID_BIN=${SNAPRAID_BIN:-snapraid}
LOG_DIR=${SNAPRAID_LOG_DIR:-./logs}

declare -A SUBCOMMAND_DEFAULTS
SUBCOMMAND_DEFAULTS["smart"]="${SNAPRAID_SMART_DEFAULTS:-}"
SUBCOMMAND_DEFAULTS["scrub"]="${SNAPRAID_SCRUB_DEFAULTS:--p 10}"
SUBCOMMAND_DEFAULTS["sync"]="${SNAPRAID_SYNC_DEFAULTS:-}"
SUBCOMMAND_DEFAULTS["diff"]="${SNAPRAID_DIFF_DEFAULTS:-}"
SUBCOMMAND_DEFAULTS["status"]="${SNAPRAID_STATUS_DEFAULTS:-}"

declare -A REDACTION_CACHE=()

metrics_buffer=""
TEMP_DIR=""

cleanup() {
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

validate_textfile_path() {
  if [[ -z $TEXTFILE_PATH ]]; then
    return
  fi
  local dir
  dir=$(dirname "$TEXTFILE_PATH")
  if [[ ! -d $dir ]]; then
    echo "Error: textfile directory $dir does not exist" >&2
    exit 1
  fi
  if [[ ! -w $dir ]]; then
    echo "Error: textfile directory $dir is not writable" >&2
    exit 1
  fi
}

emit_metric() {
  local line="$1"
  metrics_buffer+="$line"$'\n'
  if [[ -z $TEXTFILE_PATH ]]; then
    printf '%s\n' "$line"
  fi
}

current_time_iso() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

ensure_log_dir() {
  mkdir -p "$LOG_DIR"
}

prepare_log_file() {
  local command="$1"
  ensure_log_dir
  local timestamp
  timestamp=$(date '+%Y%m%dT%H%M%S')
  local log_file="${LOG_DIR}/${command}-${timestamp}.log"
  : > "$log_file"
  ln -sfn "$(basename "$log_file")" "${LOG_DIR}/${command}.latest.log"
  ln -sfn "$log_file" "./${command}.log"
  printf '%s\n' "$log_file"
}

log_message() {
  local log_file="$1"
  local label="$2"
  shift 2
  local message="$*"
  printf '%s [%s] %s\n' "$(current_time_iso)" "$label" "$message" >> "$log_file"
  if [[ $VERBOSE == true ]]; then
    printf '%s [%s] %s\n' "$(current_time_iso)" "$label" "$message" >&2
  fi
}

log_stream() {
  local log_file="$1"
  local label="$2"
  local source_file="$3"

  if [[ ! -s $source_file ]]; then
    return
  fi

  while IFS= read -r line || [[ -n $line ]]; do
    printf '%s [%s] %s\n' "$(current_time_iso)" "$label" "$line" >> "$log_file"
    if [[ $VERBOSE == true ]]; then
      printf '%s [%s] %s\n' "$(current_time_iso)" "$label" "$line" >&2
    fi
  done < "$source_file"
}

format_command_args() {
  local formatted=""
  local arg
  for arg in "$@"; do
    if [[ -z $formatted ]]; then
      formatted=$(printf '%q' "$arg")
    else
      formatted+=" $(printf '%q' "$arg")"
    fi
  done
  printf '%s' "$formatted"
}

require_snapraid_binary() {
  if [[ $DRY_RUN == true ]]; then
    return
  fi
  if ! command -v "$SNAPRAID_BIN" >/dev/null 2>&1; then
    echo "Error: Could not find snapraid binary at '$SNAPRAID_BIN' or in PATH" >&2
    exit 1
  fi
}

collect_timestamp_ms() {
  date '+%s%3N'
}

emit_status_metrics() {
  local metric_suffix="$1"
  local exit_status="$2"

  emit_metric "# HELP snapraid_${metric_suffix}_exit_status Exit status of the last SnapRAID ${metric_suffix} run"
  emit_metric "# TYPE snapraid_${metric_suffix}_exit_status gauge"
  emit_metric "snapraid_${metric_suffix}_exit_status $exit_status"

  local current_timestamp
  current_timestamp=$(collect_timestamp_ms)
  emit_metric "# HELP snapraid_${metric_suffix}_last_ran Timestamp (ms) of the last SnapRAID ${metric_suffix} run"
  emit_metric "# TYPE snapraid_${metric_suffix}_last_ran gauge"
  emit_metric "snapraid_${metric_suffix}_last_ran $current_timestamp"
}

emit_duration_metric() {
  local metric_suffix="$1"
  local duration_ms="$2"

  emit_metric "# HELP snapraid_${metric_suffix}_duration_seconds Duration of the SnapRAID ${metric_suffix} run in seconds"
  emit_metric "# TYPE snapraid_${metric_suffix}_duration_seconds gauge"
  local duration_seconds
  duration_seconds=$(awk -v ms="$duration_ms" 'BEGIN { printf "%.3f", ms / 1000 }')
  emit_metric "snapraid_${metric_suffix}_duration_seconds $duration_seconds"
}

redact_value() {
  local value="$1"
  if [[ $REDACT_IDENTIFIERS != true ]]; then
    printf '%s' "$value"
    return
  fi

  if [[ -z $value ]]; then
    printf '%s' "$value"
    return
  fi

  if [[ -z ${REDACTION_CACHE[$value]+_} ]]; then
    local digest
    digest=$(printf '%s' "$value" | sha256sum | awk '{print $1}' | cut -c1-12)
    REDACTION_CACHE["$value"]="redacted_${digest}"
  fi
  printf '%s' "${REDACTION_CACHE[$value]}"
}

truncate_decimal() {
  local value="$1"
  if [[ $value =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$value"
  fi
}

normalize_size_to_bytes() {
  local numeric="$1"
  local unit="$2"

  if [[ -z $numeric || -z $unit ]]; then
    printf '0'
    return
  fi

  local multiplier=1
  case "$unit" in
    B) multiplier=1 ;;
    kB|KB) multiplier=1000 ;;
    K|KiB) multiplier=1024 ;;
    MB) multiplier=1000
        multiplier=$((multiplier * 1000))
        ;;
    M|MiB) multiplier=1024
           multiplier=$((multiplier * 1024))
           ;;
    GB) multiplier=1000
        multiplier=$((multiplier * 1000 * 1000))
        ;;
    G|GiB) multiplier=1024
           multiplier=$((multiplier * 1024 * 1024))
           ;;
    TB) multiplier=1000
        multiplier=$((multiplier * 1000 * 1000 * 1000))
        ;;
    T|TiB) multiplier=1024
           multiplier=$((multiplier * 1024 * 1024 * 1024))
           ;;
    *) multiplier=1 ;;
  esac

  if [[ $numeric == *.* ]]; then
    awk -v value="$numeric" -v mult="$multiplier" 'BEGIN { printf "%.0f", value * mult }'
  else
    printf '%s' "$((numeric * multiplier))"
  fi
}

parse_duration_to_seconds() {
  local duration_string="$1"
  if [[ -z $duration_string ]]; then
    printf '0'
    return
  fi

  IFS=':' read -r -a parts <<< "$duration_string"
  local count=${#parts[@]}

  if (( count == 2 )); then
    local minutes=${parts[0]}
    local seconds=${parts[1]}
    awk -v m="$minutes" -v s="$seconds" 'BEGIN { printf "%.0f", (m * 60) + s }'
  elif (( count == 3 )); then
    local hours=${parts[0]}
    local minutes=${parts[1]}
    local seconds=${parts[2]}
    awk -v h="$hours" -v m="$minutes" -v s="$seconds" 'BEGIN { printf "%.0f", (h * 3600) + (m * 60) + s }'
  else
    printf '%s' "$duration_string"
  fi
}

extract_snapraid_smart() {
  local snapraid_output="$1"

  emit_metric "# HELP snapraid_smart_disk_fail_probability Fail probability for individual disks (%) within the next year based on SnapRAID SMART data"
  emit_metric "# TYPE snapraid_smart_disk_fail_probability gauge"
  emit_metric "# HELP snapraid_smart_disk_temperature Disk temperature in Celsius"
  emit_metric "# TYPE snapraid_smart_disk_temperature gauge"
  emit_metric "# HELP snapraid_smart_disk_power_on_days Disk power-on days"
  emit_metric "# TYPE snapraid_smart_disk_power_on_days gauge"
  emit_metric "# HELP snapraid_smart_disk_error_count Reported SMART error count for each disk"
  emit_metric "# TYPE snapraid_smart_disk_error_count gauge"

  while IFS=$'\t' read -r temp power error fp size serial device disk; do
    if [[ -z $disk || $disk == "-" || -z $device || $device == "-" ]]; then
      continue
    fi

    local disk_label device_label serial_label size_label
    disk_label=$(redact_value "$disk")
    device_label=$(redact_value "$device")
    serial_label=$(redact_value "$serial")
    size_label="$size"

    local labels="disk=\"$disk_label\",device=\"$device_label\",serial=\"$serial_label\",size=\"$size_label\""

    local fp_value=${fp%\%}
    fp_value=$(truncate_decimal "$fp_value")
    if [[ -n $fp_value ]]; then
      emit_metric "snapraid_smart_disk_fail_probability{$labels} $fp_value"
    fi

    if [[ $temp =~ ^-?[0-9]+$ ]]; then
      emit_metric "snapraid_smart_disk_temperature{$labels} $temp"
    fi

    if [[ $power =~ ^[0-9]+$ ]]; then
      emit_metric "snapraid_smart_disk_power_on_days{$labels} $power"
    fi

    if [[ $error =~ ^[0-9]+$ ]]; then
      emit_metric "snapraid_smart_disk_error_count{$labels} $error"
    fi
  done < <(printf '%s\n' "$snapraid_output" | awk '
    function strip_ansi(str) {
      gsub(/\033\[[0-9;]*m/, "", str)
      return str
    }
    {
      $0 = strip_ansi($0)
    }
    /^[[:space:]]+[0-9-]/ && NF >= 8 {
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, $6, $7, $8
    }
  ')

  emit_metric "# HELP snapraid_smart_total_fail_probability Probability (%) that at least one disk fails within the next year"
  emit_metric "# TYPE snapraid_smart_total_fail_probability gauge"
  local total_fail_probability
  total_fail_probability=$(printf '%s\n' "$snapraid_output" | awk '
    /Probability that at least one disk/ {
      for (i = 1; i <= NF; ++i) {
        if ($i ~ /[0-9.]+%/) {
          value = $i
          gsub(/[^0-9.]/, "", value)
          if (value != "") {
            print value
            exit
          }
        }
      }
    }
  ')
  total_fail_probability=${total_fail_probability%.}
  total_fail_probability=$(truncate_decimal "$total_fail_probability")
  if [[ -n $total_fail_probability ]]; then
    emit_metric "snapraid_smart_total_fail_probability $total_fail_probability"
  fi

  emit_metric "# HELP snapraid_smart_warning_count Count of SMART warnings reported in the last run"
  emit_metric "# TYPE snapraid_smart_warning_count gauge"
  local smart_warnings
  smart_warnings=$(printf '%s\n' "$snapraid_output" | grep -ciE 'warning|alert|critical' || true)
  emit_metric "snapraid_smart_warning_count $smart_warnings"
}

extract_scan_metrics() {
  local snapraid_output="$1"
  local metric_suffix="$2"

  declare -A scan_metrics=()

  while IFS= read -r line; do
    if [[ $line == Scanned* ]]; then
      local item_name scan_time
      item_name=$(echo "$line" | awk '{print $2}')
      scan_time=$(echo "$line" | awk '{print $4}')
      scan_metrics["$item_name"]=$scan_time
    fi
  done <<< "$snapraid_output"

  emit_metric "# HELP snapraid_${metric_suffix}_scan_time_seconds Scan time for each item in seconds during SnapRAID ${metric_suffix}"
  emit_metric "# TYPE snapraid_${metric_suffix}_scan_time_seconds gauge"
  for item in "${!scan_metrics[@]}"; do
    local sanitized_item
    sanitized_item=$(redact_value "$item")
    emit_metric "snapraid_${metric_suffix}_scan_time_seconds{disk=\"$sanitized_item\"} ${scan_metrics[$item]}"
  done
}

extract_error_metrics() {
  local snapraid_output="$1"
  local metric_suffix="$2"

  local file_errors io_errors data_errors
  file_errors=$(printf '%s\n' "$snapraid_output" | grep -Em1 'file errors' | awk '{print $1}')
  io_errors=$(printf '%s\n' "$snapraid_output" | grep -Em1 'io errors' | awk '{print $1}')
  data_errors=$(printf '%s\n' "$snapraid_output" | grep -Em1 'data errors' | awk '{print $1}')

  file_errors=${file_errors:-0}
  io_errors=${io_errors:-0}
  data_errors=${data_errors:-0}

  emit_metric "# HELP snapraid_${metric_suffix}_file_errors Number of file errors found during SnapRAID ${metric_suffix}"
  emit_metric "# TYPE snapraid_${metric_suffix}_file_errors gauge"
  emit_metric "snapraid_${metric_suffix}_file_errors $file_errors"

  emit_metric "# HELP snapraid_${metric_suffix}_io_errors Number of I/O errors found during SnapRAID ${metric_suffix}"
  emit_metric "# TYPE snapraid_${metric_suffix}_io_errors gauge"
  emit_metric "snapraid_${metric_suffix}_io_errors $io_errors"

  emit_metric "# HELP snapraid_${metric_suffix}_data_errors Number of data errors found during SnapRAID ${metric_suffix}"
  emit_metric "# TYPE snapraid_${metric_suffix}_data_errors gauge"
  emit_metric "snapraid_${metric_suffix}_data_errors $data_errors"
}

extract_completion_metrics() {
  local snapraid_output="$1"
  local metric_suffix="$2"

  local completion_line
  completion_line=$(printf '%s\n' "$snapraid_output" | awk '/completed/ {print; exit}')

  emit_metric "# HELP snapraid_${metric_suffix}_completion_percent Completion percentage of the SnapRAID ${metric_suffix} operation"
  emit_metric "# TYPE snapraid_${metric_suffix}_completion_percent gauge"

  local completion_percent=""
  if [[ $completion_line =~ ([0-9]+([.][0-9]+)?)% ]]; then
    completion_percent="${BASH_REMATCH[1]}"
  fi

  if [[ -n $completion_percent ]]; then
    emit_metric "snapraid_${metric_suffix}_completion_percent $completion_percent"
  else
    emit_metric "snapraid_${metric_suffix}_completion_percent 0"
  fi

  emit_metric "# HELP snapraid_${metric_suffix}_accessed_bytes Amount of data accessed during SnapRAID ${metric_suffix} in bytes"
  emit_metric "# TYPE snapraid_${metric_suffix}_accessed_bytes gauge"

  local accessed_numeric accessed_unit
  if [[ $completion_line =~ ,[[:space:]]*([0-9]+([.][0-9]+)?)?[[:space:]]*([A-Za-z]+)[[:space:]]+accessed ]]; then
    accessed_numeric="${BASH_REMATCH[1]}"
    accessed_unit="${BASH_REMATCH[3]}"
  fi

  local accessed_bytes
  accessed_bytes=$(normalize_size_to_bytes "$accessed_numeric" "$accessed_unit")
  emit_metric "snapraid_${metric_suffix}_accessed_bytes $accessed_bytes"

  emit_metric "# HELP snapraid_${metric_suffix}_completion_duration_seconds Reported SnapRAID ${metric_suffix} duration in seconds"
  emit_metric "# TYPE snapraid_${metric_suffix}_completion_duration_seconds gauge"

  local duration_string duration_seconds
  if [[ $completion_line =~ accessed[[:space:]]+in[[:space:]]+([0-9:]+) ]]; then
    duration_string="${BASH_REMATCH[1]}"
  fi
  duration_seconds=$(parse_duration_to_seconds "$duration_string")
  emit_metric "snapraid_${metric_suffix}_completion_duration_seconds $duration_seconds"
}

extract_summary_metrics() {
  local snapraid_output="$1"
  local metric_suffix="$2"

  declare -A summary_map=(
    ["updated"]="snapraid_${metric_suffix}_items_updated"
    ["removed"]="snapraid_${metric_suffix}_items_removed"
    ["added"]="snapraid_${metric_suffix}_items_added"
    ["copied"]="snapraid_${metric_suffix}_items_copied"
    ["restored"]="snapraid_${metric_suffix}_items_restored"
    ["scrubbed"]="snapraid_${metric_suffix}_items_scrubbed"
    ["verified"]="snapraid_${metric_suffix}_items_verified"
  )

  for keyword in "${!summary_map[@]}"; do
    local pattern value_line value
    pattern="^[[:space:]]*[0-9]+[[:space:]]+${keyword}( |$)"
    value_line=$(printf '%s\n' "$snapraid_output" | grep -Em1 "$pattern" || true)
    value=$(echo "$value_line" | awk '{print $1}')
    value=${value//[^0-9]/}
    value=${value:-0}

    emit_metric "# HELP ${summary_map[$keyword]} Count of ${keyword} items during SnapRAID ${metric_suffix}"
    emit_metric "# TYPE ${summary_map[$keyword]} gauge"
    emit_metric "${summary_map[$keyword]} $value"
  done
}

extract_diff_metrics() {
  local snapraid_output="$1"
  local sync_required="$2"

  local files_equal files_added files_removed files_updated files_moved files_copied
  files_equal=$(printf '%s\n' "$snapraid_output" | grep -Em1 '^[[:space:]]*[0-9]+[[:space:]]+equal' | awk '{print $1}')
  files_added=$(printf '%s\n' "$snapraid_output" | grep -Em1 '^[[:space:]]*[0-9]+[[:space:]]+added' | awk '{print $1}')
  files_removed=$(printf '%s\n' "$snapraid_output" | grep -Em1 '^[[:space:]]*[0-9]+[[:space:]]+removed' | awk '{print $1}')
  files_updated=$(printf '%s\n' "$snapraid_output" | grep -Em1 '^[[:space:]]*[0-9]+[[:space:]]+updated' | awk '{print $1}')
  files_moved=$(printf '%s\n' "$snapraid_output" | grep -Em1 '^[[:space:]]*[0-9]+[[:space:]]+moved' | awk '{print $1}')
  files_copied=$(printf '%s\n' "$snapraid_output" | grep -Em1 '^[[:space:]]*[0-9]+[[:space:]]+copied' | awk '{print $1}')

  files_equal=${files_equal:-0}
  files_added=${files_added:-0}
  files_removed=${files_removed:-0}
  files_updated=${files_updated:-0}
  files_moved=${files_moved:-0}
  files_copied=${files_copied:-0}

  if [[ $DEBUG == true ]]; then
    echo "DEBUG: files_equal=$files_equal files_added=$files_added files_removed=$files_removed files_updated=$files_updated files_moved=$files_moved files_copied=$files_copied sync_required=$sync_required" >&2
  fi

  emit_metric "# HELP snapraid_diff_files_equal Number of equal files reported by SnapRAID diff"
  emit_metric "# TYPE snapraid_diff_files_equal gauge"
  emit_metric "snapraid_diff_files_equal $files_equal"

  emit_metric "# HELP snapraid_diff_files_added Number of added files reported by SnapRAID diff"
  emit_metric "# TYPE snapraid_diff_files_added gauge"
  emit_metric "snapraid_diff_files_added $files_added"

  emit_metric "# HELP snapraid_diff_files_removed Number of removed files reported by SnapRAID diff"
  emit_metric "# TYPE snapraid_diff_files_removed gauge"
  emit_metric "snapraid_diff_files_removed $files_removed"

  emit_metric "# HELP snapraid_diff_files_updated Number of updated files reported by SnapRAID diff"
  emit_metric "# TYPE snapraid_diff_files_updated gauge"
  emit_metric "snapraid_diff_files_updated $files_updated"

  emit_metric "# HELP snapraid_diff_files_moved Number of moved files reported by SnapRAID diff"
  emit_metric "# TYPE snapraid_diff_files_moved gauge"
  emit_metric "snapraid_diff_files_moved $files_moved"

  emit_metric "# HELP snapraid_diff_files_copied Number of copied files reported by SnapRAID diff"
  emit_metric "# TYPE snapraid_diff_files_copied gauge"
  emit_metric "snapraid_diff_files_copied $files_copied"

  emit_metric "# HELP snapraid_diff_sync_required Whether a sync is required (1 = yes, 0 = no)"
  emit_metric "# TYPE snapraid_diff_sync_required gauge"
  emit_metric "snapraid_diff_sync_required $sync_required"
}

extract_status_metrics() {
  local snapraid_output="$1"

  local sync_in_progress=0
  if printf '%s\n' "$snapraid_output" | grep -qE 'sync in progress'; then
    sync_in_progress=1
  fi

  local scrub_oldest_days unscrubbed_percent fragmentation_percent

  # Parse "the oldest block was scrubbed N days ago"
  scrub_oldest_days=$(printf '%s\n' "$snapraid_output" | awk '/oldest block was scrubbed/ { for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1) ~ /days?/) { print $i; exit } }')
  scrub_oldest_days=${scrub_oldest_days:-0}

  # Parse unscrubbed percentage
  unscrubbed_percent=$(printf '%s\n' "$snapraid_output" | awk '/unscrubbed/ { for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+%$/) { gsub(/%/,"",$i); print $i; exit } }')
  unscrubbed_percent=${unscrubbed_percent:-0}

  # Parse fragmentation percentage
  fragmentation_percent=$(printf '%s\n' "$snapraid_output" | awk '/fragmented/ { for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+%$/) { gsub(/%/,"",$i); print $i; exit } }')
  fragmentation_percent=${fragmentation_percent:-0}

  if [[ $DEBUG == true ]]; then
    echo "DEBUG: sync_in_progress=$sync_in_progress scrub_oldest_days=$scrub_oldest_days unscrubbed_percent=$unscrubbed_percent fragmentation_percent=$fragmentation_percent" >&2
  fi

  emit_metric "# HELP snapraid_status_sync_in_progress Whether a sync is currently in progress (1 = yes, 0 = no)"
  emit_metric "# TYPE snapraid_status_sync_in_progress gauge"
  emit_metric "snapraid_status_sync_in_progress $sync_in_progress"

  emit_metric "# HELP snapraid_status_scrub_oldest_days Age of oldest unscrubbed block in days"
  emit_metric "# TYPE snapraid_status_scrub_oldest_days gauge"
  emit_metric "snapraid_status_scrub_oldest_days $scrub_oldest_days"

  emit_metric "# HELP snapraid_status_unscrubbed_percent Percentage of array that has not been scrubbed"
  emit_metric "# TYPE snapraid_status_unscrubbed_percent gauge"
  emit_metric "snapraid_status_unscrubbed_percent $unscrubbed_percent"

  emit_metric "# HELP snapraid_status_fragmentation_percent Fragmentation percentage of the array"
  emit_metric "# TYPE snapraid_status_fragmentation_percent gauge"
  emit_metric "snapraid_status_fragmentation_percent $fragmentation_percent"
}

is_snapraid_command() {
  case "$1" in
    smart|scrub|sync|diff|status)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_snapraid_command() {
  local subcommand="$1"
  local log_file="$2"
  shift 2
  local -a subargs=("$@")

  if [[ $DRY_RUN == true ]]; then
    log_message "$log_file" "DRYRUN" "Skipping execution of snapraid $subcommand (dry-run enabled)"
    printf ''
    return 0
  fi

  [[ -z "$TEMP_DIR" ]] && TEMP_DIR=$(mktemp -d)
  local stdout_file="$TEMP_DIR/stdout.$$.$RANDOM"
  local stderr_file="$TEMP_DIR/stderr.$$.$RANDOM"

  local status
  local -a cmd_prefix=()
  if [[ $TIMEOUT -gt 0 ]]; then
    cmd_prefix=(timeout "$TIMEOUT")
  fi

  if "${cmd_prefix[@]}" "$SNAPRAID_BIN" "$subcommand" "${subargs[@]}" >"$stdout_file" 2>"$stderr_file"; then
    status=0
  else
    status=$?
  fi

  if [[ $status -eq 124 ]]; then
    log_message "$log_file" "TIMEOUT" "Command timed out after ${TIMEOUT}s"
  fi

  log_stream "$log_file" "stdout" "$stdout_file"
  log_stream "$log_file" "stderr" "$stderr_file"

  cat "$stdout_file"
  rm -f "$stdout_file" "$stderr_file"

  return $status
}

handle_command() {
  local command="$1"
  shift
  local -a command_args=("$@")

  local log_file
  log_file=$(prepare_log_file "$command")

  local -a default_args=()
  if [[ -n ${SUBCOMMAND_DEFAULTS[$command]} ]]; then
    read -r -a default_args <<< "${SUBCOMMAND_DEFAULTS[$command]}"
  fi

  local -a combined_args=("${default_args[@]}" "${command_args[@]}")

  local command_line
  command_line="$SNAPRAID_BIN $command"
  if (( ${#combined_args[@]} > 0 )); then
    command_line+=" $(format_command_args "${combined_args[@]}")"
  fi

  log_message "$log_file" "START" "$command_line"
  if [[ $DRY_RUN == false ]]; then
    printf 'Starting SnapRAID %s...\n' "$command" >&2
  else
    printf 'Dry running SnapRAID %s...\n' "$command" >&2
  fi

  local start_ms end_ms duration_ms
  start_ms=$(collect_timestamp_ms)

  local exit_status=0
  local snapraid_output

  snapraid_output=$(run_snapraid_command "$command" "$log_file" "${combined_args[@]}")
  exit_status=$?

  # Handle diff exit code 2 (sync required) as success
  local sync_required=0
  if [[ $command == "diff" && $exit_status -eq 2 ]]; then
    sync_required=1
    exit_status=0
  fi

  end_ms=$(collect_timestamp_ms)
  duration_ms=$((end_ms - start_ms))

  log_message "$log_file" "END" "$command_line exit=$exit_status"

  emit_status_metrics "$command" "$exit_status"
  emit_duration_metric "$command" "$duration_ms"

  case $command in
    smart)
      extract_snapraid_smart "$snapraid_output"
      ;;
    scrub)
      extract_scan_metrics "$snapraid_output" "scrub"
      extract_error_metrics "$snapraid_output" "scrub"
      extract_completion_metrics "$snapraid_output" "scrub"
      extract_summary_metrics "$snapraid_output" "scrub"
      ;;
    sync)
      extract_scan_metrics "$snapraid_output" "sync"
      extract_error_metrics "$snapraid_output" "sync"
      extract_completion_metrics "$snapraid_output" "sync"
      extract_summary_metrics "$snapraid_output" "sync"
      ;;
    diff)
      extract_diff_metrics "$snapraid_output" "$sync_required"
      ;;
    status)
      extract_status_metrics "$snapraid_output"
      ;;
  esac

  return $exit_status
}

write_textfile_if_needed() {
  if [[ -z $TEXTFILE_PATH ]]; then
    return
  fi

  local textfile_dir
  textfile_dir=$(dirname "$TEXTFILE_PATH")
  if [[ ! -d $textfile_dir ]]; then
    echo "Error: directory $textfile_dir does not exist" >&2
    exit 1
  fi
  local tmp_target
  tmp_target=$(mktemp "$textfile_dir/$(basename "$TEXTFILE_PATH").XXXXXX") || exit 1
  printf '%s' "$metrics_buffer" > "$tmp_target"
  mv "$tmp_target" "$TEXTFILE_PATH"
}

parse_arguments() {
  declare -a positionals=()

  while (( $# > 0 )); do
    case "$1" in
      --textfile)
        if (( $# < 2 )); then
          echo "Error: --textfile requires a path argument" >&2
          exit 1
        fi
        TEXTFILE_PATH="$2"
        shift 2
        ;;
      --snapraid-bin)
        if (( $# < 2 )); then
          echo "Error: --snapraid-bin requires a path argument" >&2
          exit 1
        fi
        SNAPRAID_BIN="$2"
        shift 2
        ;;
      --log-dir)
        if (( $# < 2 )); then
          echo "Error: --log-dir requires a path argument" >&2
          exit 1
        fi
        LOG_DIR="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      --redact-identifiers)
        REDACT_IDENTIFIERS=true
        shift
        ;;
      --smart-defaults)
        if (( $# < 2 )); then
          echo "Error: --smart-defaults requires an argument string" >&2
          exit 1
        fi
        SUBCOMMAND_DEFAULTS["smart"]="$2"
        shift 2
        ;;
      --scrub-defaults)
        if (( $# < 2 )); then
          echo "Error: --scrub-defaults requires an argument string" >&2
          exit 1
        fi
        SUBCOMMAND_DEFAULTS["scrub"]="$2"
        shift 2
        ;;
      --sync-defaults)
        if (( $# < 2 )); then
          echo "Error: --sync-defaults requires an argument string" >&2
          exit 1
        fi
        SUBCOMMAND_DEFAULTS["sync"]="$2"
        shift 2
        ;;
      --diff-defaults)
        if (( $# < 2 )); then
          echo "Error: --diff-defaults requires an argument string" >&2
          exit 1
        fi
        SUBCOMMAND_DEFAULTS["diff"]="$2"
        shift 2
        ;;
      --status-defaults)
        if (( $# < 2 )); then
          echo "Error: --status-defaults requires an argument string" >&2
          exit 1
        fi
        SUBCOMMAND_DEFAULTS["status"]="$2"
        shift 2
        ;;
      --timeout)
        if (( $# < 2 )); then
          echo "Error: --timeout requires a number of seconds" >&2
          exit 1
        fi
        TIMEOUT="$2"
        shift 2
        ;;
      --debug)
        DEBUG=true
        shift
        ;;
      --version)
        echo "snapraid_metrics_collector $COLLECTOR_VERSION"
        exit 0
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        while (( $# > 0 )); do
          positionals+=("$1")
          shift
        done
        break
        ;;
      *)
        positionals+=("$1")
        shift
        ;;
    esac
  done

  if (( ${#positionals[@]} == 0 )); then
    usage
    exit 1
  fi

  remaining_args=("${positionals[@]}")
}

check_root_requirement() {
  if [[ ${SNAPRAID_COLLECTOR_SKIP_ROOT:-} =~ ^(1|true|yes)$ ]]; then
    return
  fi
  if [[ $DRY_RUN == true ]]; then
    return
  fi
  local uid_value="${UID:-$(id -u)}"
  if [[ $uid_value -ne 0 ]]; then
    echo "Error: collector must be run as root. Running with uid: $uid_value" >&2
    exit 1
  fi
}

main() {
  parse_arguments "$@"
  validate_textfile_path
  check_root_requirement
  require_snapraid_binary

  emit_metric "# HELP snapraid_collector_info Collector version information"
  emit_metric "# TYPE snapraid_collector_info gauge"
  emit_metric "snapraid_collector_info{version=\"$COLLECTOR_VERSION\"} 1"

  local args=("${remaining_args[@]}")
  local arg_count=${#args[@]}
  local index=0
  local overall_status=0

  while (( index < arg_count )); do
    local token="${args[$index]}"
    ((index++))

    if is_snapraid_command "$token"; then
      local -a command_args=()
      while (( index < arg_count )); do
        local next_token="${args[$index]}"
        if [[ $next_token == "--" ]]; then
          ((index++))
          while (( index < arg_count )); do
            command_args+=("${args[$index]}")
            ((index++))
          done
          break
        fi
        if is_snapraid_command "$next_token"; then
          break
        fi
        command_args+=("$next_token")
        ((index++))
      done

      if handle_command "$token" "${command_args[@]}"; then
        :
      else
        local status=$?
        overall_status=$status
      fi
    else
      echo "Invalid argument: $token" >&2
      overall_status=1
      break
    fi
  done

  write_textfile_if_needed
  exit "$overall_status"
}

main "$@"
