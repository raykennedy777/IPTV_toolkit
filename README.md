# IPTV Toolkit

PowerShell scripts for recording live and catch-up IPTV streams on Windows using ffmpeg. A bash version for Linux is also available — see [README_linux.md](README_linux.md).

## Features

- **Interactive setup wizard** — generate a config from a live stream URL
- Record a live stream for a set duration
- Wait until a specific time, then record
- Schedule a recording via Windows Task Scheduler
- Record catch-up/timeshift streams based on broadcast time
- Record the same time window across multiple channels simultaneously
- Automatic retry with segment stitching if the stream drops
- Optional remux from `.ts` to `.mkv` after recording

## Requirements

- [PowerShell 7](https://github.com/PowerShell/PowerShell/releases)
- [ffmpeg](https://ffmpeg.org/download.html) (must be on your PATH)
- An IPTV provider with live and/or catch-up support

## Setup

### Option A — interactive wizard (recommended for first-time setup)

Run the setup wizard and follow the prompts. It will create the config file and walk you through adding your first provider and channel:

```powershell
.\IPTV_toolkit.ps1 -Command setup-config
```

You'll be asked for:
1. A provider name (e.g. `myprovider`)
2. A live stream URL for any channel — the wizard parses out the base URL, credentials, and stream ID automatically
3. A catch-up URL (optional) — format style is auto-detected
4. A timezone for catch-up times
5. A channel name — normalized to lowercase with underscores automatically

Run the wizard again with the same provider name to add more channels.

### Option B — manual setup

1. Copy the example config and fill in your provider details:
   ```
   copy Settings\IPTVConfigs.example.ps1 Settings\IPTVConfigs.ps1
   ```
2. Edit `Settings\IPTVConfigs.ps1` with your credentials and channel IDs

`IPTVConfigs.ps1` is gitignored — your credentials never leave your machine.

## Configuration

Each provider is a named entry in `$Global:IPTVConfigs`. The key is what you pass to `-Config`.

| Field | Description |
|---|---|
| `Username` / `Password` | Your provider credentials |
| `BaseUrl` | Live stream base URL (no trailing slash) |
| `CatchupUrl` | Timeshift/catch-up endpoint URL |
| `AddTsSuffix` | Append `.ts` to live stream URLs (`$true`/`$false`) |
| `CatchupFormatStyle` | URL format for catch-up: `"query"` or `"path"` (see below) |
| `CatchupTimezone` | Windows timezone ID for the provider's catch-up timestamps (see below) |
| `ChannelMap` | Hashtable mapping friendly names to provider stream IDs |

**CatchupFormatStyle values:**
- `"query"` — `CatchupUrl?username=...&password=...&stream=ID&start=TIME&duration=SECS`
- `"path"` — `BaseUrl/timeshift/username/password/SECS/TIME/ID.ts`

**CatchupTimezone:** The timezone the provider uses to index catch-up content. `-StartAt` is entered in your local time and converted to this timezone for the URL. DST is handled automatically for both your local timezone and the provider's. Use a Windows timezone ID — run `[System.TimeZoneInfo]::GetSystemTimeZones()` to list all available IDs. Common values: `"Central European Standard Time"` (CET/CEST), `"UTC"`, `"AUS Eastern Standard Time"` (AEST/AEDT).

## Usage

The script is dot-sourced so you can call functions interactively, or run it directly with `-Command`.

### Dot-source for interactive use

```powershell
. .\IPTV_toolkit.ps1
```

### List all channels for a provider

```powershell
# Via -Command
.\IPTV_toolkit.ps1 -Command list-channels -Config myprovider

# Or after dot-sourcing
List-IPTVChannels -Config myprovider
```

### Record a live stream

```powershell
# Record for 90 minutes
Record-LiveIPTV -Config myprovider -Channel bbc_one -DurationMinutes 90

# Skip remux (keep as .ts)
Record-LiveIPTV -Config myprovider -Channel bbc_one -DurationMinutes 90 -NoRemux

# Wait until a specific time, then record (-StartAt format: yyyy-MM-dd:HH-mm, your local time)
Record-LiveIPTV -Config myprovider -Channel bbc_one -DurationMinutes 90 -StartAt "2025-06-01:20-00"

# Schedule via Windows Task Scheduler instead of waiting in the terminal
Record-LiveIPTV -Config myprovider -Channel bbc_one -DurationMinutes 90 -StartAt "2025-06-01:20-00" -Schedule

# Preview the ffmpeg command without running it
Record-LiveIPTV -Config myprovider -Channel bbc_one -DurationMinutes 90 -DryRun
```

Output files are saved to `~\Videos\` as `channelname_YYYYMMDD_HHmm.ts` (or `.mkv` after remux).

### Record a catch-up stream

Catch-up records a past broadcast by its original air time. `-StartAt` uses your local time (format: `yyyy-MM-dd:HH-mm`) and is converted to the provider's timezone automatically.

```powershell
# Single channel
Record-CatchupIPTV -Config myprovider -Channel bbc_one -StartAt "2025-06-01:20-00" -DurationMinutes 90

# Multiple channels — same time window, recorded sequentially
Record-CatchupIPTV -Config myprovider -Channel bbc_one,itv1 -StartAt "2025-06-01:20-00" -DurationMinutes 90

# Dry run
Record-CatchupIPTV -Config myprovider -Channel bbc_one -StartAt "2025-06-01:20-00" -DurationMinutes 90 -DryRun

# Custom timeshift window (default: 300 minutes)
Record-CatchupIPTV -Config myprovider -Channel bbc_one -StartAt "2025-06-01:20-00" -DurationMinutes 90 -CustomDuration 600
```

> Note: multiple channels are recorded sequentially (not in parallel) to stay within single-stream provider limits.

> `-CustomDuration` sets the timeshift window (in seconds) passed to the provider's catch-up URL. Increase it if recordings start mid-content or if your provider requires a larger buffer.

### Clean up completed scheduled tasks

```powershell
Remove-Recording-Tasks
```

Deletes any `Record-LiveIPTV_*` tasks in Windows Task Scheduler that have already run.

## How retry works

If ffmpeg exits before the full duration is captured, the toolkit automatically retries from where it left off, saving each attempt as a numbered segment. Once the target duration is reached (or retries are exhausted), all segments are concatenated into a single output file.

## Logging

Each recording run writes a timestamped log file to the `logs\` folder in the script directory:
- `logs\record_live_{channel}_{timestamp}.log`
- `logs\record_catchup_{startAt}_{timestamp}.log`
- `logs\remove_tasks_{timestamp}.log`
