# SnapRAID Metrics Collector

This script collects various metrics from SnapRAID operations like `sync` and `scrub` and outputs them in a format compatible with Prometheus's textfile collector.

## Prerequisites

- SnapRAID installed and configured
- Node Exporter with textfile collector enabled

## Usage

To run the script, use the following command:

```bash
sudo ./snapraid_metrics_collector.sh <day-of-week>
```

Replace <day-of-week> with the desired day (e.g., Sun, Mon, Tue, etc.) to execute scrub-specific commands.

## Integration with Prometheus Node Exporter

Place the script in a directory, e.g., `/usr/local/bin.`

Make it executable: `chmod +x /usr/local/bin/snapraid_metrics_collector.sh.`

Configure a cron job to run the script periodically and output to a textfile collector directory:

```bash
* * * * * /usr/local/bin/snapraid_metrics_collector.sh <day-of-week> > /var/lib/node_exporter/textfile_collector/snapraid.prom
```

Adjust the cron schedule according to your requirements.

## Metrics

The script generates the following metrics:

| Metric | Description |
| ------ | ----------- |
| `snapraid_disk_fail_probability` | Fail probability for individual disks within the next year based on SMART values calculated by SnapRAID. |
| `snapraid_total_fail_probability` | Fail probability for any disk failing within the next year. |
| `snapraid_file_errors` | Number of file errors found during SnapRAID Sync. |
| `snapraid_io_errors` | Number of I/O errors found during SnapRAID Sync. |
| `snapraid_data_errors` | Number of data errors found during SnapRAID Sync. |
| `snapraid_completion_percent` | Completion percentage of the SnapRAID Sync operation. |
| `snapraid_accessed_mb` | Amount of data accessed during the operation, in MB. |
| `snapraid_verify_duration_seconds` | Time taken to verify each path during SnapRAID Sync, in seconds. |
| `snapraid_scrub_errors` | (Optional) Number of errors found during SnapRAID Scrub, only on the specified day. |
