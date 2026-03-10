# IPTV Toolkit — Linux / Synology NAS

Bash script for recording live and catch-up IPTV streams on Linux using ffmpeg.
Designed for headless use on a Synology NAS but works on any Linux system.

## Requirements

- bash 4+
- ffmpeg and ffprobe (on your PATH, or configured via `FFMPEG_BIN`/`FFPROBE_BIN`)
- Python 3.9+ (for `zoneinfo` — standard library, no extra packages needed)
- An IPTV provider with live and/or catch-up support

## Setup

### Option A — interactive wizard (recommended for first-time setup)

Make the script executable, then run the setup wizard:

```sh
chmod +x iptv_toolkit.sh
./iptv_toolkit.sh setup-config
```

You'll be asked for:
1. A provider name (e.g. `myprovider`)
2. A live stream URL for any channel — the wizard parses out the base URL, credentials, and stream ID automatically
3. A catch-up URL (optional) — format style is auto-detected
4. An IANA timezone for catch-up times (e.g. `Europe/London`)
5. A channel name — normalized to lowercase with underscores automatically

The config file is created if it doesn't exist. Run the wizard again with the same provider name to add more channels.

### Option B — manual setup

1. Copy the example config and fill in your provider details:
   ```sh
   cp Settings/iptv_configs.example.sh Settings/iptv_configs.sh
   ```
2. Edit `Settings/iptv_configs.sh` with your credentials and channel IDs.
3. Make the script executable:
   ```sh
   chmod +x iptv_toolkit.sh
   ```

`iptv_configs.sh` is gitignored — your credentials stay local.

## Configuration

`iptv_configs.sh` sets global variables and defines one function per provider.
The function name must be `config_<name>`, where `<name>` is what you pass to `-config`.

### Top-level variables

| Variable | Description |
|---|---|
| `OUTPUT_DIR` | Directory where recordings are saved |
| `FFMPEG_BIN` | ffmpeg binary to use (default: `ffmpeg`) |
| `FFPROBE_BIN` | ffprobe binary to use (default: `ffprobe`) |

### Per-provider fields (set inside `config_<name>()`)

| Field | Description |
|---|---|
| `USERNAME` / `PASSWORD` | Your provider credentials |
| `BASE_URL` | Live stream base URL (no trailing slash) |
| `CATCHUP_URL` | Timeshift/catch-up endpoint URL |
| `ADD_TS_SUFFIX` | Append `.ts` to live stream URLs (`true`/`false`) |
| `CATCHUP_FORMAT_STYLE` | URL format for catch-up: `"query"` or `"path"` (see below) |
| `CATCHUP_TIMEZONE` | IANA timezone the provider uses for catch-up timestamps (see below) |
| `CHANNEL_MAP` | Associative array mapping friendly names to provider stream IDs |

**CatchupFormatStyle values:**
- `"query"` — `CATCHUP_URL?username=...&password=...&stream=ID&start=TIME&duration=SECS`
- `"path"` — `BASE_URL/timeshift/username/password/SECS/TIME/ID.ts`

**CatchupTimezone:** The timezone the provider uses to index catch-up content. `-start-at` is entered in your local time and converted to this timezone for the URL. DST is handled automatically. Uses IANA timezone names — run the following to list all available values:
```sh
python3 -c "import zoneinfo; print(*sorted(zoneinfo.available_timezones()), sep='\n')"
```
Common values: `"Europe/Paris"`, `"Europe/Rome"`, `"UTC"`.

### Example config

```sh
OUTPUT_DIR="$HOME/recordings"

config_myprovider() {
    USERNAME="your_username"
    PASSWORD="your_password"
    BASE_URL="http://your.provider.url/live"
    CATCHUP_URL="http://your.provider.url/streaming/timeshift.php"
    ADD_TS_SUFFIX=false
    CATCHUP_FORMAT_STYLE="query"
    CATCHUP_TIMEZONE="Europe/Paris"
    declare -gA CHANNEL_MAP=(
        ["bbc_one"]="12345"
        ["itv1"]="67890"
    )
}
```

## Usage

### List all channels for a provider

```sh
./iptv_toolkit.sh list-channels -config myprovider
```

### Record a live stream

```sh
# Record for 90 minutes
./iptv_toolkit.sh record-live -config myprovider -channel bbc_one -duration-minutes 90

# Skip remux (keep as .ts)
./iptv_toolkit.sh record-live -config myprovider -channel bbc_one -duration-minutes 90 -no-remux

# Wait until a specific time, then record (-start-at format: yyyy-MM-dd:HH-mm, your local time)
./iptv_toolkit.sh record-live -config myprovider -channel bbc_one -duration-minutes 90 -start-at "2026-03-01:20-00"

# Schedule via cron instead of waiting in the terminal
./iptv_toolkit.sh record-live -config myprovider -channel bbc_one -duration-minutes 90 -start-at "2026-03-01:20-00" -schedule

# Preview the ffmpeg command without running it
./iptv_toolkit.sh record-live -config myprovider -channel bbc_one -duration-minutes 90 -dry-run
```

Output files are saved to `OUTPUT_DIR` as `channelname_YYYYMMDD_HHmm.ts` (or `.mkv` after remux).

### Record a catch-up stream

Catch-up records a past broadcast by its original air time. `-start-at` uses your local time and is converted to the provider's timezone automatically.

```sh
# Single channel
./iptv_toolkit.sh record-catchup -config myprovider -channel bbc_one -start-at "2026-03-01:20-00" -duration-minutes 90

# Multiple channels — same time window, recorded sequentially
./iptv_toolkit.sh record-catchup -config myprovider -channel bbc_one,itv1 -start-at "2026-03-01:20-00" -duration-minutes 90

# Dry run
./iptv_toolkit.sh record-catchup -config myprovider -channel bbc_one -start-at "2026-03-01:20-00" -duration-minutes 90 -dry-run

# Custom timeshift window (default: 300 minutes)
./iptv_toolkit.sh record-catchup -config myprovider -channel bbc_one -start-at "2026-03-01:20-00" -duration-minutes 90 -custom-duration 600
```

> Note: multiple channels are recorded sequentially (not in parallel) to stay within single-stream provider limits.

> `-custom-duration` sets the timeshift window (in seconds) passed to the provider's catch-up URL. Increase it if recordings start mid-content or if your provider requires a larger buffer.

### Remove past scheduled jobs

```sh
./iptv_toolkit.sh remove-jobs
```

Removes any `IPTV_record_*`-tagged cron entries whose scheduled time has already passed.

## How retry works

If ffmpeg exits before the full duration is captured, the toolkit automatically retries from where it left off, saving each attempt as a numbered segment. Once the target duration is reached (or retries are exhausted), all segments are concatenated into a single output file.

## Logging

Each recording run writes a timestamped log file to the `logs/` folder in the script directory:
- `logs/record_live_{channel}_{timestamp}.log`
- `logs/record_catchup_{startAt}_{timestamp}.log`

## Synology NAS notes

### ffmpeg version

Synology DSM ships with an older ffmpeg (v4) used internally by packages like Video Station and Surveillance Station. Do not remove it from PATH or replace it — other packages depend on it.

Instead, install the **ffmpeg7** package from the Synology Package Center, then set the binary names in `iptv_configs.sh`:

```sh
FFMPEG_BIN="ffmpeg7"
FFPROBE_BIN="ffprobe7"
```

The toolkit will use ffmpeg7 for all recording operations while the system ffmpeg remains untouched.

### Python 3

Python 3.9+ is required for `zoneinfo`. On Synology DSM 7, install the **Python 3.11** (or later) package from the Package Center.

### Scheduling

Use `-schedule` to add a cron job via `crontab`. On Synology, you can also manage cron jobs through **Control Panel → Task Scheduler** — the entries added by this script will appear there.

### Running via SSH

```sh
ssh admin@your-nas-ip
cd /path/to/IPTV_toolkit
./iptv_toolkit.sh record-catchup -config myprovider -channel bbc_one -start-at "2026-03-01:20-00" -duration-minutes 90
```

To keep a recording running after you disconnect, use `nohup` or `screen`:

```sh
nohup ./iptv_toolkit.sh record-live -config myprovider -channel bbc_one -duration-minutes 180 &
```
