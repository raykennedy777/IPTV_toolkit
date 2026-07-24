# IPTV Toolkit — Linux / Synology NAS

Bash script for recording live and catch-up IPTV streams on Linux using ffmpeg.
Designed for headless use on a Synology NAS but works on any Linux system.

`iptv_toolkit.sh` targets bash 4+; `iptv_toolkit_mac.sh` is the bash 3.2 port for
macOS and shares the same config file. [docs/parity.md](docs/parity.md) tracks
what each implementation (Linux, macOS, PowerShell) supports.

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

### Validate the config

Statically check the config file — offline, no network. Reports hard **errors**
(which block recording) and advisory **warnings**, grouped per provider.

```sh
# Validate every provider in the config file
./iptv_toolkit.sh validate-config

# Validate a single provider
./iptv_toolkit.sh validate-config -config myprovider
```

Exit code is non-zero if any provider has errors (scriptable), zero if only
warnings. Errors include: missing `USERNAME`/`PASSWORD`/`BASE_URL`, a
`CATCHUP_FORMAT_STYLE` other than `query`/`path`, an invalid IANA
`CATCHUP_TIMEZONE`, an empty `CHANNEL_MAP`, an empty stream ID, unset
`OUTPUT_DIR`, and duplicate `CHANNEL_MAP` keys (which resolve differently on
Linux vs macOS, so they are always flagged). Warnings include: an empty
`CATCHUP_URL` with `CATCHUP_FORMAT_STYLE=query`, non-normalized channel keys, a
trailing slash on `BASE_URL`, and an unresolvable `ffmpeg`/`ffprobe` binary.

A fast subset of these checks (required fields, format style, non-empty channel
map, `OUTPUT_DIR`) also runs automatically before every `record-*` command and
fails fast with a clear message.

### Check channel reachability

Probe streams with `ffprobe` **without recording** — a quick pre-flight before a
scheduled recording. Reports reachability plus resolution/codecs/audio-track
count in a table.

```sh
# Probe every channel's live stream
./iptv_toolkit.sh check-channels -config myprovider

# Probe specific channels
./iptv_toolkit.sh check-channels -config myprovider -channel bbc_one,itv1

# Also probe the catch-up endpoint (synthetic start of now − 2 hours)
./iptv_toolkit.sh check-channels -config myprovider -channel bbc_one -catchup
```

Channels are probed sequentially with a short `ffprobe` timeout. Exit code is
non-zero if any probed channel fails (scriptable). `-catchup` additionally
verifies the timeshift endpoint using the provider's `CATCHUP_FORMAT_STYLE`, so
you can confirm catch-up works with no date input. This never records — it only
runs `ffprobe`.

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

Output files are saved to `OUTPUT_DIR` as `channelname_YYYYMMDD_HHmm_config.ts` (or `.mkv` after remux). The config name is appended so simultaneous recordings of the same channel from different providers don't collide.

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

> `-custom-duration` sets the timeshift window (in minutes) passed to the provider's catch-up URL. Increase it if recordings start mid-content or if your provider requires a larger buffer.

### Remove a provider or channel

Mirror of `setup-config`'s two add-modes. Both edit `iptv_configs.sh` in place
after an interactive `[y/N]` confirmation (there is no backup file and no
`-dry-run` — the confirmation is the safeguard).

```sh
# Delete a whole provider (its config_<name>() block)
./iptv_toolkit.sh remove-provider -config myprovider

# Delete one channel from a provider's CHANNEL_MAP
./iptv_toolkit.sh remove-channel -config myprovider -channel bbc_one
```

The confirmation prompt shows exactly what will be removed (the provider block
summary, or the channel key + stream ID). If the named provider or channel does
not exist, the command errors and lists what is available.

### Remove past scheduled jobs

```sh
./iptv_toolkit.sh remove-jobs
```

Removes any `IPTV_record_*`-tagged cron entries whose scheduled time has already passed.

## Shell completion

Dynamic tab-completion is provided for both bash and zsh (in `completions/`).
It completes subcommands, per-command flags, `-config` values (provider names
parsed from your config file), and `-channel` values (scoped to the `-config`
already on the command line). Completion parses the config with grep/sed/awk and
never sources it. It is **not** auto-installed.

**bash** — source it from `~/.bashrc`, or symlink into your bash-completion dir:

```sh
# Quick: source directly
echo "source $PWD/completions/iptv_toolkit.bash" >> ~/.bashrc

# Or symlink into the completion directory
ln -s "$PWD/completions/iptv_toolkit.bash" /etc/bash_completion.d/iptv_toolkit          # Linux
ln -s "$PWD/completions/iptv_toolkit.bash" /usr/local/etc/bash_completion.d/iptv_toolkit # macOS/Homebrew
```

**zsh** — put it on your `$fpath` as `_iptv_toolkit`, then run `compinit`:

```sh
mkdir -p ~/.zsh/completions
ln -s "$PWD/completions/iptv_toolkit.zsh" ~/.zsh/completions/_iptv_toolkit
# In ~/.zshrc, before compinit:
#   fpath=(~/.zsh/completions $fpath)
#   autoload -Uz compinit && compinit
```

Both are registered for `iptv_toolkit.sh` and `iptv_toolkit_mac.sh`. If no config
file exists yet, completion still offers commands and flags. Set
`IPTV_CONFIG_FILE` to complete against a non-default config path.

## How retry works

If ffmpeg exits before the full duration is captured, the toolkit automatically retries from where it left off, saving each attempt as a numbered segment. Once the target duration is reached (or retries are exhausted), all segments are concatenated into a single output file.

## Logging

Each recording run writes a timestamped log file to the `logs/` folder in the script directory:
- `logs/record_live_{channel}_{timestamp}_{config}.log`
- `logs/record_catchup_{startAt}_{timestamp}_{config}.log`

## Development / Testing

The toolkit ships with a [bats](https://github.com/bats-core/bats-core) test suite.
bats-core and its support libraries are **vendored** under `tests/vendor/`, so no
system install is required — you only need `bash`, `python3`, and the standard
tools already needed to run the toolkit. `ffmpeg`/`ffprobe` are stubbed during
tests (real ffmpeg never runs and nothing touches the network).

Run the full suite:

```sh
./tests/run.sh
# or
make test
```

`run.sh` runs the suite twice, once per implementation:

- **macOS suite** — `iptv_toolkit_mac.sh` under the system bash 3.2, exercising
  the `cm_*` string-shim channel-map path.
- **Linux suite** — `iptv_toolkit.sh` under bash 4+, exercising the native
  associative-array path.

`iptv_toolkit.sh` uses bash-4-only syntax and cannot run under bash 3.2, so on a
stock macOS host the Linux suite is **skipped** with a message unless a bash 4+
is available. Install one with `brew install bash` (it lands at
`/opt/homebrew/bin/bash` and leaves the system bash untouched), or point the
runner at any bash 4+ with `IPTV_BASH4=/path/to/bash`.

Run a single test file:

```sh
./tests/run.sh tests/url_building.bats
```

Optional lint (if `shellcheck` is installed):

```sh
make lint
```

### Test layout

| Path | Purpose |
|---|---|
| `tests/run.sh` | Runner — drives both bash versions |
| `tests/*.bats` | Test files (helpers, channel map, URL building, arg parsing, retry/merge, validate-config, check-channels, removal, completion) |
| `tests/helpers/common.bash` | Shared setup (`source_toolkit`, `run_toolkit`, stubs) |
| `tests/fixtures/iptv_configs.sh` | Fixture config with fake credentials (query + path styles) |
| `tests/fixtures/iptv_configs_invalid.sh`, `tests/fixtures/iptv_configs_no_output.sh` | Deliberately broken configs for the `validate-config` tests |
| `tests/stubs/ffmpeg`, `tests/stubs/ffprobe` | Fake binaries put on `PATH` during tests |
| `tests/vendor/` | Vendored bats-core + bats-support + bats-assert |

The test harness points the toolkit at the fixture config via the
`IPTV_CONFIG_FILE` environment variable (which overrides the default
`Settings/iptv_configs.sh`), and both scripts are written so that `source`-ing
them defines functions only — the command dispatch runs solely when the script
is executed directly.

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
