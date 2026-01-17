# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bash-based SnapRAID metrics collector that parses output from `snapraid smart`, `scrub`, and `sync` commands and emits Prometheus-compatible metrics for the node-exporter textfile collector.

## Commands

```bash
make lint                    # shellcheck + shfmt
make test                    # fixture-backed parsing tests
make ci                      # lint + test
sudo make install            # install to /usr/local/bin
sudo make install-systemd    # install systemd service
docker build -t snapraid-collector .
```

Run tests locally:
```bash
SNAPRAID_COLLECTOR_SKIP_ROOT=true ./tests/run.sh
```

## Architecture

Single-file bash script (`snapraid_metrics_collector.sh`):

- **Argument parsing** (`parse_arguments`): CLI flags and environment variable overrides
- **Command dispatch** (`main`, `handle_command`): Routes `smart`/`scrub`/`sync` to their handlers
- **Metric extraction** (`extract_snapraid_smart`, `extract_*_metrics`): Parse SnapRAID output via awk/regex
- **Metric emission** (`emit_metric`): Buffers to `$metrics_buffer`, flushes atomically to `$TEXTFILE_PATH`

Key patterns:
- Metrics follow `snapraid_<command>_<metric_name>` naming convention
- `--dry-run` skips snapraid execution but exercises parsing
- `--redact-identifiers` hashes disk/serial/device labels via sha256 truncation
- Per-command defaults in `SUBCOMMAND_DEFAULTS` associative array (scrub defaults to `-p 10`)
- Symlinks `smart.log`, `scrub.log`, `sync.log` always point to latest run

## Testing

Tests use `tests/bin/fake_snapraid` returning canned fixtures from `tests/fixtures/`. Assertions in `tests/run.sh` verify metric parsing.

When changing parser logic: add fixtures to `tests/fixtures/` and assertions to `tests/run.sh`.

## Environment Variables

- `SNAPRAID_COLLECTOR_SKIP_ROOT=true` - bypass root requirement for testing
- `SNAPRAID_BIN` - alternate snapraid binary path
- `SNAPRAID_LOG_DIR` - log directory (default: `./logs`)
- `SNAPRAID_COLLECTOR_REDACT` - force identifier redaction
- `SNAPRAID_SMART_DEFAULTS`, `SNAPRAID_SCRUB_DEFAULTS`, `SNAPRAID_SYNC_DEFAULTS` - default args per command
