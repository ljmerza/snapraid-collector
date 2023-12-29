#!/usr/bin/env bash

if [ "$UID" -ne "0" ]; then
  echo "Error: collector must be run as root. Running with uid: $UID"
  exit 1
fi
if [ -z "$(which snapraid)" ]; then
  echo "Error: Could not find snapraid binary. Make sure snapraid is available from $PATH"
  exit 1
fi

# Check if a day argument is provided
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <day-of-week>"
  echo "Example: $0 Sun" 
  exit 1
fi

# call snapraid smart to get probability values
snapraidOutput=$(snapraid smart)
# truncate output
resultTable="$(echo "$snapraidOutput" | tail -n +6 | head -n -5)"
# get list of hard drives
disks=$(echo "$resultTable" | awk '{print $7}' | sort | xargs)

# get fail probability for each disk
echo "# HELP snapraid_disk_fail_probability fail probability for individual failing disk within the next year based on SMART vals calculated by snapraid"
echo "# TYPE snapraid_disk_fail_probability gauge"

for disk in $disks
do
  # parse probability value for each disk
  fp=$(echo "$resultTable" | grep "$disk" | awk '{print $4}')
  if [[ ${fp::-1} =~ ^[0-9]+$ ]]; then
    fp=${fp::-1}
  else
    fp=0
  fi

  echo "snapraid_disk_fail_probability{disk=\"$disk\"} $fp"
done

# get total fail probability metrics
echo "# HELP snapraid_total_fail_probability fail probability for one disk failing withing the next year"
echo "# TYPE snapraid_total_fail_probability gauge"
tfp="$(echo "$snapraidOutput" | tail -n +6 | tail -n 1 | awk '{print $NF}' | grep -oP '[0-9]+')"
echo "snapraid_total_fail_probability $tfp"


# Execute snapraid sync
snapraidSyncOutput=$(sudo snapraid --force-zero sync)

# Extract the error metrics
fileErrors=$(echo "$snapraidSyncOutput" | grep "file errors" | awk '{print $1}')
fileErrors=${fileErrors:-0} # Default to 0 if not found
ioErrors=$(echo "$snapraidSyncOutput" | grep "io errors" | awk '{print $1}')
ioErrors=${ioErrors:-0} # Default to 0 if not found
dataErrors=$(echo "$snapraidSyncOutput" | grep "data errors" | awk '{print $1}')
dataErrors=${dataErrors:-0} # Default to 0 if not found
echo "# HELP snapraid_file_errors Number of file errors found during SnapRAID Sync"
echo "# TYPE snapraid_file_errors gauge"
echo "snapraid_file_errors $fileErrors"
echo "# HELP snapraid_io_errors Number of I/O errors found during SnapRAID Sync"
echo "# TYPE snapraid_io_errors gauge"
echo "snapraid_io_errors $ioErrors"
echo "# HELP snapraid_data_errors Number of data errors found during SnapRAID Sync"
echo "# TYPE snapraid_data_errors gauge"
echo "snapraid_data_errors $dataErrors"

# Extract the completion percentage and MB accessed metrics
completedLine=$(echo "$snapraidSyncOutput" | grep "completed")
completionPercent=$(echo "$completedLine" | awk '{print $1}' | tr -d '%')
accessedMB=$(echo "$completedLine" | awk '{print $3}')
echo "# HELP snapraid_completion_percent Completion percentage of the operation"
echo "# TYPE snapraid_completion_percent gauge"
echo "snapraid_completion_percent $completionPercent"
echo "# HELP snapraid_accessed_mb Amount of data accessed in MB"
echo "# TYPE snapraid_accessed_mb gauge"
echo "snapraid_accessed_mb $accessedMB"

# Report "Verified" metrics
echo "$snapraidSyncOutput" | grep "^Verified" | while read -r line; do
    # Extract the path and the time in seconds
    path=$(echo "$line" | awk '{print $2}')
    seconds=$(echo "$line" | awk '{print $4}')

    # Report metrics
    echo "# HELP snapraid_verify_duration_seconds Time taken to verify each path in seconds"
    echo "# TYPE snapraid_verify_duration_seconds gauge"
    echo "snapraid_verify_duration_seconds{path=\"$path\"} $seconds"
done

# run scrub commands but only on sundays
# Day argument (e.g., Sun, Mon, Tue, etc.)
dayArg=$1

# Get the current day of the week
today=$(date +%a)

# Compare the current day with the provided argument
if [ "$today" = "$dayArg" ]; then
  snapraidScrubOutput=$(snapraid scrub)
  # extract scrub metrics
  scrubErrors=$(echo "$snapraidScrubOutput" | grep "errors" | awk '{print $1}')
fi