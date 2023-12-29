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


# snapraid smart metrics
run_snapraid_smart() {
  snapraidSmartOutput=$(snapraid smart)
  smartExitStatus=$?

  if [ $smartExitStatus -eq 0 ]; then
      currentTimestamp=$(date +%s)
      echo "# HELP snapraid_smart_last_successful Timestamp of the last successful SnapRAID sync"
      echo "# TYPE snapraid_smart_last_successful gauge"
      echo "snapraid_smart_last_successful $currentTimestamp"
  fi

  resultTable="$(echo "$snapraidSmartOutput" | tail -n +6 | head -n -5)"
  disks=$(echo "$resultTable" | awk '{print $7}' | sort | xargs)
  echo "# HELP snapraid_smart_disk_fail_probability fail probability for individual failing disk within the next year based on SMART values calculated by snapraid"
  echo "# TYPE snapraid_smart_disk_fail_probability gauge"

  for disk in $disks
  do
    # parse probability value for each disk
    fp=$(echo "$resultTable" | grep "$disk" | awk '{print $4}')
    if [[ ${fp::-1} =~ ^[0-9]+$ ]]; then
      fp=${fp::-1}
    else
      fp=0
    fi

    echo "snapraid_smart_disk_fail_probability{disk=\"$disk\"} $fp"
  done

  echo "# HELP snapraid_smart_total_fail_probability fail probability for one disk failing withing the next year based on SMART values calculated by snapraid"
  echo "# TYPE snapraid_smart_total_fail_probability gauge"
  tfp="$(echo "$snapraidSmartOutput" | tail -n +6 | tail -n 1 | awk '{print $NF}' | grep -oP '[0-9]+')"
  echo "snapraid_smart_total_fail_probability $tfp"
}

extract_error_metrics() {
  local snapraidOutput="$1"
  local fileErrors ioErrors dataErrors completionPercent accessedMB

  fileErrors=$(echo "$snapraidOutput" | grep "file errors" | awk '{print $1}')
  fileErrors=${fileErrors:-0} # Default to 0 if not found

  ioErrors=$(echo "$snapraidOutput" | grep "io errors" | awk '{print $1}')
  ioErrors=${ioErrors:-0} # Default to 0 if not found

  dataErrors=$(echo "$snapraidOutput" | grep "data errors" | awk '{print $1}')
  dataErrors=${dataErrors:-0} # Default to 0 if not found

  local completedLine=$(echo "$snapraidOutput" | grep "completed")
  completionPercent=$(echo "$completedLine" | awk '{print $1}' | tr -d '%')
  accessedMB=$(echo "$completedLine" | awk '{print $3}')

  echo "$fileErrors $ioErrors $dataErrors $completionPercent $accessedMB"
}

run_snapraid_sync() {
  snapraidSyncOutput=$(sudo snapraid --force-zero sync)
  syncExitStatus=$?

  if [ $syncExitStatus -eq 0 ]; then
      currentTimestamp=$(date +%s)
      echo "# HELP snapraid_sync_last_successful Timestamp of the last successful SnapRAID sync"
      echo "# TYPE snapraid_sync_last_successful gauge"
      echo "snapraid_sync_last_successful $currentTimestamp"
  fi

  echo "$snapraidSyncOutput" | grep "^Verified" | while read -r line; do
      path=$(echo "$line" | awk '{print $2}')
      seconds=$(echo "$line" | awk '{print $4}')
      echo "# HELP snapraid_sync_verify_duration Time taken to verify each path in seconds"
      echo "# TYPE snapraid_sync_verify_duration gauge"
      echo "snapraid_sync_verify_duration{path=\"$path\"} $seconds"
  done

  read fileErrors ioErrors dataErrors completionPercent accessedMB <<< $(extract_error_metrics "$snapraidSyncOutput")
  echo "# HELP snapraid_sync_file_errors Number of file errors found during SnapRAID Sync"
  echo "# TYPE snapraid_sync_file_errors gauge"
  echo "snapraid_sync_file_errors $fileErrors"
  echo "# HELP snapraid_sync_io_errors Number of I/O errors found during SnapRAID Sync"
  echo "# TYPE snapraid_sync_io_errors gauge"
  echo "snapraid_sync_io_errors $ioErrors"
  echo "# HELP snapraid_sync_data_errors Number of data errors found during SnapRAID Sync"
  echo "# TYPE snapraid_sync_data_errors gauge"
  echo "snapraid_sync_data_errors $dataErrors"
  echo "# HELP snapraid_sync_completion_percent Completion percentage of the operation during SnapRAID Sync"
  echo "# TYPE snapraid_sync_completion_percent gauge"
  echo "snapraid_sync_completion_percent $completionPercent"
  echo "# HELP snapraid_sync_accessed_mb Amount of data accessed in MB during SnapRAID Sync"
  echo "# TYPE snapraid_sync_accessed_mb gauge"
  echo "snapraid_sync_accessed_mb $accessedMB"
}

run_snapraid_scrub() {
  snapraidScrubOutput=$(snapraid scrub)
  scrubExitStatus=$?

  if [ $scrubExitStatus -eq 0 ]; then
      currentTimestamp=$(date +%s)
      echo "# HELP snapraid_scrub_last_successful Timestamp of the last successful SnapRAID scrub"
      echo "# TYPE snapraid_scrub_last_successful gauge"
      echo "snapraid_scrub_last_successful $currentTimestamp"
  fi

  echo "$snapraidScrubOutput" | grep "^Verified" | while read -r line; do
      path=$(echo "$line" | awk '{print $2}')
      seconds=$(echo "$line" | awk '{print $4}')
      echo "# HELP snapraid_scrub_verify_duration Time taken to verify each path in seconds"
      echo "# TYPE snapraid_scrub_verify_duration gauge"
      echo "snapraid_scrub_verify_duration{path=\"$path\"} $seconds"
  done

  read fileErrors ioErrors dataErrors completionPercent accessedMB <<< $(extract_error_metrics "$snapraidScrubOutput")
  echo "# HELP snapraid_scrub_file_errors Number of file errors found during SnapRAID Scrub"
  echo "# TYPE snapraid_scrub_file_errors gauge"
  echo "snapraid_scrub_file_errors $fileErrors"
  echo "# HELP snapraid_scrub_io_errors Number of I/O errors found during SnapRAID Scrub"
  echo "# TYPE snapraid_scrub_io_errors gauge"
  echo "snapraid_scrub_io_errors $ioErrors"
  echo "# HELP snapraid_scrub_data_errors Number of data errors found during SnapRAID Scrub"
  echo "# TYPE snapraid_scrub_data_errors gauge"
  echo "snapraid_scrub_data_errors $dataErrors"
  echo "# HELP snapraid_scrub_completion_percent Completion percentage of the operation during SnapRAID Scrub"
  echo "# TYPE snapraid_scrub_completion_percent gauge"
  echo "snapraid_scrub_completion_percent $completionPercent"
  echo "# HELP snapraid_scrub_accessed_mb Amount of data accessed in MB during SnapRAID Scrub"
  echo "# TYPE snapraid_scrub_accessed_mb gauge"
  echo "snapraid_scrub_accessed_mb $accessedMB"
}

# Iterate over all arguments
for arg in "$@"; do
  case $arg in
    smart)
      run_snapraid_smart
      ;;
    scrub)
      run_snapraid_scrub
      ;;
    sync)
      run_snapraid_sync
      ;;
    *)
      echo "Invalid argument: $arg"
      ;;
  esac
done