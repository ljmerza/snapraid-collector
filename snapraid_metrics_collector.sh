#!/usr/bin/env bash

if [ "$UID" -ne "0" ]; then
  echo "Error: collector must be run as root. Running with uid: $UID"
  exit 1
fi
if [ -z "$(which snapraid)" ]; then
  echo "Error: Could not find snapraid binary. Make sure snapraid is available from $PATH"
  exit 1
fi

# Check if at least one argument is provided
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 smart|scrub|sync"
  exit 1
fi

extract_status_metrics(){
  local metricSuffix="$1"
  local exitStatus="$2"

  echo "# HELP snapraid_${metricSuffix}_exit_status Exit status of the last SnapRAID ${metricSuffix} run"
  echo "# TYPE snapraid_${metricSuffix}_exit_status gauge"
  echo "snapraid_${metricSuffix}_exit_status $exitStatus"

  currentTimestamp=$(date +%s%3N)
  echo "# HELP snapraid_${metricSuffix}_last_ran Timestamp of the last SnapRAID ${metricSuffix} run"
  echo "# TYPE snapraid_${metricSuffix}_last_ran gauge"
  echo "snapraid_${metricSuffix}_last_ran $currentTimestamp"
}

extract_snapraid_smart() {
  resultTable="$(echo "$snapraidSmartOutput" | tail -n +6 | head -n -5)"
  disks=$(echo "$resultTable" | awk '{print $7}' | xargs)
  echo "# HELP snapraid_smart_disk_fail_probability fail probability for individual failing disk within the next year based on SMART values calculated by snapraid"
  echo "# TYPE snapraid_smart_disk_fail_probability gauge"
  echo "# HELP snapraid_smart_disk_temperature temperature of each disk"
  echo "# TYPE snapraid_smart_disk_temperature gauge"
  echo "# HELP snapraid_smart_disk_power_on_days power on days for each disk"
  echo "# TYPE snapraid_smart_disk_power_on_days gauge"
  echo "# HELP snapraid_smart_disk_error_count error count for each disk"
  echo "# TYPE snapraid_smart_disk_error_count gauge"

  for disk in $disks
  do
    # Extract additional information
    device=$(echo "$resultTable" | grep "$disk" | awk '{print $8}')
    serial=$(echo "$resultTable" | grep "$disk" | awk '{print $6}')
    size=$(echo "$resultTable" | grep "$disk" | awk '{print $5}')

    # Check and echo failure probability
    fp=$(echo "$resultTable" | grep "$disk" | awk '{print $4}' | grep -oP '^[0-9]+')
    if [[ "$fp" != "" ]]; then
      echo "snapraid_smart_disk_fail_probability{disk=\"$disk\", device=\"$device\", serial=\"$serial\", size=\"$size\"} $fp"
    fi

    # Check and echo temperature
    temp=$(echo "$resultTable" | grep "$disk" | awk '{print $1}' | grep -oP '^[0-9]+')
    if [[ "$temp" != "" ]]; then
      echo "snapraid_smart_disk_temperature{disk=\"$disk\", device=\"$device\", serial=\"$serial\", size=\"$size\"} $temp"
    fi

    # Check and echo power on days
    power=$(echo "$resultTable" | grep "$disk" | awk '{print $2}' | grep -oP '^[0-9]+')
    if [[ "$power" != "" ]]; then
      echo "snapraid_smart_disk_power_on_days{disk=\"$disk\", device=\"$device\", serial=\"$serial\", size=\"$size\"} $power"
    fi

    # Check and echo error count
    error=$(echo "$resultTable" | grep "$disk" | awk '{print $3}' | grep -oP '^[0-9]+')
    if [[ "$error" != "" ]]; then
      echo "snapraid_smart_disk_error_count{disk=\"$disk\", device=\"$device\", serial=\"$serial\", size=\"$size\"} $error"
    fi
  done

  echo "# HELP snapraid_smart_total_fail_probability fail probability for one disk failing within the next year based on SMART values calculated by snapraid"
  echo "# TYPE snapraid_smart_total_fail_probability gauge"
  tfp="$(echo "$snapraidSmartOutput" | tail -n +6 | tail -n 1 | awk '{print $NF}' | grep -oP '^[0-9]+')"
  if [[ "$tfp" != "" ]]; then
    echo "snapraid_smart_total_fail_probability $tfp"
  fi
}

extract_scan_metrics() {
  local snapraidOutput="$1"
  local metricSuffix="$2"

  local itemName scanTime
  declare -A scanMetrics

  while read -r line; do
    if [[ "$line" == Scanned* ]]; then
      itemName=$(echo "$line" | awk '{print $2}')
      scanTime=$(echo "$line" | awk '{print $4}')
      scanMetrics["$itemName"]=$scanTime
    fi
  done <<< "$snapraidOutput"

  echo "# HELP snapraid_${metricSuffix}_scan_time_seconds Scan time for each item in seconds for SnapRAID ${metricSuffix}."
  echo "# TYPE snapraid_${metricSuffix}_scan_time_seconds gauge"
  for item in "${!scanMetrics[@]}"; do
    echo "snapraid_${metricSuffix}_scan_time_seconds{disk=\"$item\"} ${scanMetrics[$item]}"
  done
}

extract_error_metrics() {
  local snapraidOutput="$1"
  local metricSuffix="$2"

  fileErrors=$(echo "$snapraidOutput" | grep "file errors" | awk '{print $1}')
  fileErrors=${fileErrors:-0} # Default to 0 if not found

  ioErrors=$(echo "$snapraidOutput" | grep "io errors" | awk '{print $1}')
  ioErrors=${ioErrors:-0} # Default to 0 if not found

  dataErrors=$(echo "$snapraidOutput" | grep "data errors" | awk '{print $1}')
  dataErrors=${dataErrors:-0} # Default to 0 if not found

  echo "# HELP snapraid_${metricSuffix}_file_errors Number of file errors found during SnapRAID ${metricSuffix}"
  echo "# TYPE snapraid_${metricSuffix}_file_errors gauge"
  echo "snapraid_${metricSuffix}_file_errors $fileErrors"
  echo "# HELP snapraid_${metricSuffix}_io_errors Number of I/O errors found during SnapRAID ${metricSuffix}"
  echo "# TYPE snapraid_${metricSuffix}_io_errors gauge"
  echo "snapraid_${metricSuffix}_io_errors $ioErrors"
  echo "# HELP snapraid_${metricSuffix}_data_errors Number of data errors found during SnapRAID ${metricSuffix}"
  echo "# TYPE snapraid_${metricSuffix}_data_errors gauge"
  echo "snapraid_${metricSuffix}_data_errors $dataErrors"
}

extract_completion_metrics() {
  local snapraidOutput="$1"
  local metricSuffix="$2"

  completedLine=$(echo "$snapraidOutput" | grep "completed")
  completionPercent=$(echo "$completedLine" | awk '{print $1}' | tr -d '%' | grep -oP '^[0-9]+')
  accessedMB=$(echo "$completedLine" | awk '{print $3}' | grep -oP '^[0-9]+')

  echo "# HELP snapraid_${metricSuffix}_completion_percent Completion percentage of the operation during SnapRAID ${metricSuffix}"
  echo "# TYPE snapraid_${metricSuffix}_completion_percent gauge"
  if [[ "$completionPercent" != "" ]]; then
    echo "snapraid_${metricSuffix}_completion_percent $completionPercent"
  fi

  echo "# HELP snapraid_${metricSuffix}_accessed_mb Amount of data accessed in MB during SnapRAID ${metricSuffix}"
  echo "# TYPE snapraid_${metricSuffix}_accessed_mb gauge"
  if [[ "$accessedMB" != "" ]]; then
    echo "snapraid_${metricSuffix}_accessed_mb $accessedMB"
  fi
}


# Iterate over all arguments
for arg in "$@"; do
  case $arg in
    smart)
      snapraidSmartOutput=$(snapraid smart)
      exitStatus=$?
      echo "$(date)" > smart.log
      echo "$snapraidSmartOutput" >> smart.log
      extract_status_metrics "smart" "$exitStatus"
      extract_snapraid_smart "$snapraidSmartOutput"
      ;;
    scrub)
      snapraidScrubOutput=$(sudo snapraid scrub)
      exitStatus=$?
      echo "$(date)" > scrub.log
      echo "$snapraidScrubOutput" >> scrub.log
      extract_status_metrics "scrub" "$exitStatus"
      extract_scan_metrics "$snapraidScrubOutput" "scrub"
      extract_error_metrics "$snapraidScrubOutput" "scrub"
      extract_completion_metrics "$snapraidScrubOutput" "scrub"
      ;;
    sync)
      snapraidSyncOutput=$(sudo snapraid --force-zero sync)
      exitStatus=$?
      echo "$(date)" > sync.log
      echo "$snapraidSyncOutput" >> sync.log
      extract_status_metrics "sync" "$exitStatus"
      extract_scan_metrics "$snapraidSyncOutput" "sync"
      extract_error_metrics "$snapraidSyncOutput" "sync"
      extract_completion_metrics "$snapraidSyncOutput" "sync"
      ;;
    *)
      echo "Invalid argument: $arg"
      ;;
  esac
done