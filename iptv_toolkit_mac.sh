#!/usr/bin/env bash
# iptv_toolkit_mac.sh — macOS / bash 3.2 compatible variant of iptv_toolkit.sh
# Requires: bash 3.2+ (system bash on macOS), ffmpeg, python3 (3.9+ for zoneinfo)
# Shares the same Settings/iptv_configs.sh as the Linux version.
# Set FFMPEG_BIN in iptv_configs.sh to use a non-default binary (e.g. ffmpeg7);
# on hosts where that binary is missing this script falls back to ffmpeg/ffprobe.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Config path is overridable via IPTV_CONFIG_FILE (used by the test harness);
# defaults to the shared Settings/iptv_configs.sh next to the script.
CONFIG_FILE="${IPTV_CONFIG_FILE:-$SCRIPT_DIR/Settings/iptv_configs.sh}"

# ---------------------------------------------------------------------------
# bash 3.2 compatibility shims
#
# bash 3.2 has no associative arrays, so the config's `declare -gA CHANNEL_MAP=(...)`
# is rewritten on the fly into a flat string (_CHANNEL_MAP_STR) holding the
# ["key"]="value" lines. The helpers below query it. This lets the same
# Settings/iptv_configs.sh (with bash 4 associative-array syntax) work here too.
# ---------------------------------------------------------------------------

# Lowercase a string (replaces the bash 4 ${var,,} expansion)
_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Resolve a binary name, falling back if the requested one isn't on this host
_resolve_bin() {
    local requested="$1" fallback="$2"
    if command -v "$requested" >/dev/null 2>&1; then
        printf '%s' "$requested"
    elif command -v "$fallback" >/dev/null 2>&1; then
        printf '%s' "$fallback"
    else
        printf '%s' "$requested"
    fi
}

# Re-emit the config with `declare -gA CHANNEL_MAP=(...)` turned into a string
# assignment, so it can be sourced under bash 3.2.
_config_to_bash3() {
    awk '
        /declare -gA CHANNEL_MAP=\(/ {
            sub(/declare -gA CHANNEL_MAP=\(/, "_CHANNEL_MAP_STR=\047")
            in_map = 1
            print
            next
        }
        in_map && /^[[:space:]]*\)[[:space:]]*$/ {
            print "\047"
            in_map = 0
            next
        }
        { print }
    ' "$1"
}

# Query helpers over _CHANNEL_MAP_STR
cm_keys() { sed -n 's/.*\["\([^"]*\)"\].*/\1/p' <<<"$_CHANNEL_MAP_STR"; }
cm_has()  { cm_keys | grep -qx "$1"; }
cm_get()  { sed -n "s/.*\[\"$1\"\]=\"\([^\"]*\)\".*/\1/p" <<<"$_CHANNEL_MAP_STR"; }

# Logging setup — write logs to $SCRIPT_DIR/logs with timestamps
LOG_DIR="${SCRIPT_DIR}/logs"
# Global log file path (set at start of each command)
LOG_FILE=""

log() {
    local level="${1:-INFO}"
    local msg="${2:->}"
    if [[ -n "$LOG_FILE" ]]; then
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" | tee -a "$LOG_FILE" >&2
    else
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >&2
    fi
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

die() { echo "Error: $*" >&2; exit 1; }

# Reset the channel map and run the provider's config function. No validation
# and no ffmpeg remap — the raw building block shared by load_config and
# validate-config.
_run_config_fn() {
    local name="$1"
    _CHANNEL_MAP_STR=""
    type "config_${name}" &>/dev/null || die "Unknown config '$name'. Define config_${name}() in iptv_configs.sh."
    "config_${name}"
}

# Fast, cheap load-guard run before every record command; fails fast with a
# clear message. Heavier checks (timezone validity, duplicate-key scan) live in
# validate-config only.
_load_guard() {
    local name="$1"
    local -a problems=()
    [[ -n "${USERNAME:-}" ]]   || problems+=("USERNAME is empty")
    [[ -n "${PASSWORD:-}" ]]   || problems+=("PASSWORD is empty")
    [[ -n "${BASE_URL:-}" ]]   || problems+=("BASE_URL is empty")
    [[ -n "${OUTPUT_DIR:-}" ]] || problems+=("OUTPUT_DIR is not set")
    case "${CATCHUP_FORMAT_STYLE:-}" in
        query|path) ;;
        *) problems+=("CATCHUP_FORMAT_STYLE must be 'query' or 'path' (got '${CATCHUP_FORMAT_STYLE:-}')") ;;
    esac
    local nkeys
    nkeys="$(cm_keys | grep -c .)"
    (( nkeys > 0 )) || problems+=("CHANNEL_MAP is empty")

    if (( ${#problems[@]} > 0 )); then
        local msg="Config '$name' is invalid:" p
        for p in "${problems[@]}"; do msg+=$'\n'"  - $p"; done
        msg+=$'\n'"Run 'validate-config -config $name' for the full report."
        die "$msg"
    fi
}

load_config() {
    local name="$1"
    _run_config_fn "$name"
    # Remap ffmpeg/ffprobe if the configured binary isn't present on this host
    FFMPEG_BIN="$(_resolve_bin "${FFMPEG_BIN:-ffmpeg}" ffmpeg)"
    FFPROBE_BIN="$(_resolve_bin "${FFPROBE_BIN:-ffprobe}" ffprobe)"
    _load_guard "$name"
}

# ---------------------------------------------------------------------------
# Stream URL builders (shared by record-live / record-catchup / check-channels)
# ---------------------------------------------------------------------------

# Build the live stream URL for a channel stream id.
_live_stream_url() {
    local code="$1" suffix=""
    [[ "$ADD_TS_SUFFIX" == true ]] && suffix=".ts"
    printf '%s/%s/%s/%s%s' "$BASE_URL" "$USERNAME" "$PASSWORD" "$code" "$suffix"
}

# Build the catch-up URL: <code> <encoded_start> <duration_secs>.
_catchup_stream_url() {
    local code="$1" encoded_start="$2" duration="$3"
    case "$CATCHUP_FORMAT_STYLE" in
        query) printf '%s?username=%s&password=%s&stream=%s&start=%s&duration=%s' \
                    "$CATCHUP_URL" "$USERNAME" "$PASSWORD" "$code" "$encoded_start" "$duration" ;;
        path)  printf '%s/timeshift/%s/%s/%s/%s/%s.ts' \
                    "$BASE_URL" "$USERNAME" "$PASSWORD" "$duration" "$encoded_start" "$code" ;;
        *)     die "Unknown CATCHUP_FORMAT_STYLE: $CATCHUP_FORMAT_STYLE" ;;
    esac
}

# ---------------------------------------------------------------------------
# URL parsing helpers (used by setup-config)
# ---------------------------------------------------------------------------

_py_parse_live_url() {
    python3 - "$1" <<'PYEOF'
import sys
from urllib.parse import urlparse, urlunparse

url = sys.argv[1]
parsed = urlparse(url)
parts = [p for p in parsed.path.split('/') if p]
if len(parts) < 3:
    print("ERROR: URL needs at least 3 path segments (username/password/stream_id)", file=sys.stderr)
    sys.exit(1)

stream_seg = parts[-1]
has_ts = stream_seg.endswith('.ts')
stream_id = stream_seg[:-3] if has_ts else stream_seg
password = parts[-2]
username = parts[-3]
base_parts = parts[:-3]
base_path = ('/' + '/'.join(base_parts)) if base_parts else ''
base_url = urlunparse((parsed.scheme, parsed.netloc, base_path, '', '', ''))

print(base_url)
print(username)
print(password)
print(stream_id)
print('true' if has_ts else 'false')
PYEOF
}

_py_parse_catchup_url() {
    python3 - "$1" <<'PYEOF'
import sys
from urllib.parse import urlparse, urlunparse

url = sys.argv[1]
parsed = urlparse(url)
if parsed.query:
    catchup_url = urlunparse((parsed.scheme, parsed.netloc, parsed.path, '', '', ''))
    print('query')
    print(catchup_url)
elif '/timeshift/' in parsed.path:
    print('path')
    print('')
else:
    print('query')
    print(url)
PYEOF
}

_normalize_channel_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_'
}



parse_start_to_epoch() {
    # Parses yyyy-MM-dd:HH-mm (local time) to Unix epoch
    python3 -c "
from datetime import datetime
s = '${1}'
date_part, time_part = s.split(':', 1)
y, mo, d = map(int, date_part.split('-'))
h, mi = map(int, time_part.split('-'))
print(int(datetime(y, mo, d, h, mi).astimezone().timestamp()))
"
}

epoch_to_str() {
    # Formats a Unix epoch as a human-readable local datetime string
    python3 -c "from datetime import datetime; print(datetime.fromtimestamp(${1}).strftime('%Y-%m-%d %H:%M:%S'))"
}

convert_to_provider_tz() {
    # Converts yyyy-MM-dd:HH-mm (local time) to the provider's IANA timezone
    python3 -c "
from datetime import datetime
from zoneinfo import ZoneInfo
s = '${1}'
date_part, time_part = s.split(':', 1)
y, mo, d = map(int, date_part.split('-'))
h, mi = map(int, time_part.split('-'))
local_dt = datetime(y, mo, d, h, mi).astimezone()
provider_dt = local_dt.astimezone(ZoneInfo('${2}'))
print(provider_dt.strftime('%Y-%m-%d:%H-%M'))
"
}

epoch_to_provider_tz() {
    # Converts a Unix epoch to yyyy-MM-dd:HH-mm in the provider's IANA timezone
    python3 -c "
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
dt = datetime.fromtimestamp(${1}, tz=timezone.utc).astimezone(ZoneInfo('${2}'))
print(dt.strftime('%Y-%m-%d:%H-%M'))
"
}

# ---------------------------------------------------------------------------
# ffmpeg base args (without -i and output path)
# ---------------------------------------------------------------------------

readonly -a _LIVE_ARGS=(
    -analyzeduration 20000000 -probesize 20000000 -rtbufsize 200M
    -user_agent "Mozilla/5.0"
    -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1
    -reconnect_on_network_error 1 -reconnect_delay_max 30
    -rw_timeout 15000000 -err_detect ignore_err -fflags +genpts
)

readonly -a _CATCHUP_ARGS=(
    -analyzeduration 20000000 -probesize 20000000 -rtbufsize 400M
    -user_agent "Mozilla/5.0"
    -reconnect 1 -reconnect_streamed 1
    -reconnect_on_network_error 1 -reconnect_delay_max 30
    -rw_timeout 15000000 -err_detect ignore_err -fflags +genpts
)

# ---------------------------------------------------------------------------
# Core recording helpers
# ---------------------------------------------------------------------------

remux_ts_to_mkv() {
    local ts_file="$1"
    local mkv_file="${ts_file%.ts}.mkv"
    log "INFO" "Remuxing to $mkv_file ..."
    if "$FFMPEG_BIN" -err_detect ignore_err -fflags +genpts \
              -i "$ts_file" -map 0 -c copy -avoid_negative_ts make_zero \
              "$mkv_file"; then
        rm "$ts_file"
        log "SUCCESS" "Remux successful. Deleted original .ts file."
    else
        log "ERROR" "Remux failed. .ts file kept."
    fi
}

merge_ts_segments() {
    local final_output="$1"; shift
    local -a segments=("$@")
    local dir base concat_list
    dir="$(dirname "$final_output")"
    base="$(basename "${final_output%.ts}")"
    concat_list="$dir/${base}_concat.txt"

    # Rename first segment if it collides with the final output path
    local -a resolved=()
    for seg in "${segments[@]}"; do
        if [[ "$seg" == "$final_output" ]]; then
            local renamed="$dir/${base}_seg0.ts"
            mv "$seg" "$renamed"
            resolved+=("$renamed")
        else
            resolved+=("$seg")
        fi
    done

    printf "file '%s'\n" "${resolved[@]}" > "$concat_list"
    log "INFO" "Concatenating ${#resolved[@]} segments..."
    "$FFMPEG_BIN" -f concat -safe 0 -i "$concat_list" -c copy "$final_output"
    local rc=$?
    for seg in "${resolved[@]}"; do
        [[ "$seg" != "$final_output" && -f "$seg" ]] && rm -f "$seg"
    done
    rm -f "$concat_list"
    return $rc
}

# Populated by the caller-supplied build_retry_func before each retry
_RETRY_FFMPEG_ARGS=()

# Probe media file to get its content duration in seconds (integer)
measure_duration() {
    local file="$1"
    local dur

    # Try video stream duration, then format-level duration
    dur="$("$FFPROBE_BIN" -v error -select_streams v:0 -show_entries stream=duration \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)"
    if [[ -z "$dur" || "$dur" == "N/A" ]]; then
        dur="$("$FFPROBE_BIN" -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)"
    fi

    # Last resort: count video packets ÷ frame rate — works for live IPTV .ts files
    # where duration is not stored in the container headers (Duration: N/A from source)
    if [[ -z "$dur" || "$dur" == "N/A" ]]; then
        local pkt_info packets fps
        pkt_info="$("$FFPROBE_BIN" -v error -select_streams v:0 -count_packets \
            -show_entries stream=nb_read_packets,r_frame_rate \
            -of csv=p=0 "$file" 2>/dev/null)"
        packets="$(echo "$pkt_info" | cut -d, -f1)"
        fps="$(echo "$pkt_info" | cut -d, -f2)"  # e.g. "50/1"
        if [[ -n "$packets" && "$packets" -gt 0 && -n "$fps" ]]; then
            dur="$(awk "BEGIN { split(\"$fps\", a, \"/\"); if (a[2]+0 > 0) printf \"%.3f\", $packets * a[2] / a[1] }")"
        fi
    fi

    if [[ -z "$dur" || "$dur" == "N/A" ]]; then
        echo 0
    else
        awk "BEGIN {printf \"%d\", ${dur}+0}"
    fi
}

ffmpeg_with_retry() {
    # Usage: ffmpeg_with_retry <output_path> <total_secs> <build_retry_func> <initial_ffmpeg_args...>
    local output_path="$1"
    local total_secs="$2"
    local build_retry_func="$3"
    shift 3
    local -a initial_args=("$@")

    log "INFO" "Starting recording: $output_path (target: ${total_secs}s)"

    local -a segments=("$output_path")
    local accumulated=0
    local retry=0
    local max_retries=5

    while (( retry < max_retries )); do
        local remaining=$(( total_secs - accumulated ))
        if (( remaining <= 0 )); then
            log "SUCCESS" "Target already reached."
            break
        fi

        local -a args
        local seg_file=""

        if (( retry == 0 )); then
            args=("${initial_args[@]}")
            seg_file="$output_path"
        else
            local dir base
            dir="$(dirname "$output_path")"
            base="$(basename "${output_path%.ts}")"
            seg_file="${dir}/${base}_seg${retry}.ts"
            "$build_retry_func" "$remaining" "$seg_file" "$accumulated"
            args=("${_RETRY_FFMPEG_ARGS[@]}")
        fi

        log "INFO" "Attempt $((retry+1)): requesting ${remaining}s of content"
        if ! "$FFMPEG_BIN" "${args[@]}"; then
            log "ERROR" "ffmpeg failed (exit $?)."
            ((retry++))
            continue
        fi

        # Verify segment file exists and is non-empty
        if [[ ! -s "$seg_file" ]]; then
            log "ERROR" "Segment file empty or missing — treating as failure."
            ((retry++))
            continue
        fi

        local dur_secs
        dur_secs="$(measure_duration "$seg_file")"
        log "INFO" "Measured duration: ${dur_secs}s (requested: ${remaining}s)"

        if (( dur_secs > 0 )); then
            accumulated=$(( accumulated + dur_secs ))
            if (( retry > 0 )); then
                segments+=("$seg_file")
            fi
            log "INFO" "Segment added. Accumulated: ${accumulated}s / ${total_secs}s"

            if (( accumulated >= total_secs - 2 )); then
                log "SUCCESS" "Target reached within tolerance."
                break
            fi
        else
            # Probe failed — assume the segment achieved its requested duration (ffmpeg exited 0, file non-empty)
            log "WARNING" "Could not measure duration; assuming requested ${remaining}s was achieved."
            accumulated=$(( accumulated + remaining ))
            if (( retry > 0 )); then
                segments+=("$seg_file")
            fi
            log "INFO" "Segment added (assumed). Accumulated: ${accumulated}s / ${total_secs}s"

            if (( accumulated >= total_secs - 2 )); then
                log "SUCCESS" "Target reached within tolerance (assumed)."
                break
            fi
        fi

        ((retry++))
    done

    if (( accumulated < total_secs - 2 )); then
        log "ERROR" "Failed to reach target after ${retry} attempts. Final accumulated: ${accumulated}s"
    fi

    if (( ${#segments[@]} > 1 )); then
        log "INFO" "Concatenating ${#segments[@]} segments..."
        merge_ts_segments "$output_path" "${segments[@]}"
        log "SUCCESS" "Concatenation complete: $output_path"
    else
        log "INFO" "No retries needed — single segment used."
    fi

    log "SUCCESS" "Recording finished."
}

# ---------------------------------------------------------------------------
# record-live
# ---------------------------------------------------------------------------

# _live_url is set by record_live and read by this retry builder
_live_url=""
_first_audio_only=false

_build_live_retry() {
    local remaining="$1" seg_path="$2"
    local -a map_args=(-map "0:v?" -map "0:a:0")
    [[ "$_first_audio_only" == true ]] && map_args=(-map "0:a:0")
    _RETRY_FFMPEG_ARGS=(
        "${_LIVE_ARGS[@]}"
        -i "$_live_url"
        "${map_args[@]}"
        -t "$remaining"
        -c copy "$seg_path"
    )
}

record_live() {
    local config="" channel="" duration_mins="" start_at=""
    local no_remux=false dry_run=false schedule=false
    _first_audio_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -config)           config="$2";        shift 2 ;;
            -channel)          channel="$2";       shift 2 ;;
            -duration-minutes) duration_mins="$2"; shift 2 ;;
            -start-at)         start_at="$2";      shift 2 ;;
            -no-remux)         no_remux=true;      shift   ;;
            -dry-run)          dry_run=true;       shift   ;;
            -schedule)         schedule=true;      shift   ;;
            -first-audio-only)       _first_audio_only=true;   shift   ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$config" ]]        || die "-config is required"
    [[ -n "$channel" ]]       || die "-channel is required"
    [[ -n "$duration_mins" ]] || die "-duration-minutes is required"

    # Initialize log file
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    LOG_FILE="${LOG_DIR}/record_live_${channel}_${timestamp}.log"

    load_config "$config"
    cm_has "$channel" || die "Invalid channel '$channel'. Valid: $(cm_keys)"

    local duration_secs=$(( duration_mins * 60 ))

    # --- Schedule via cron ---
    if [[ "$schedule" == true ]]; then
        [[ -n "$start_at" ]] || die "-start-at is required with -schedule (format: yyyy-MM-dd:HH-mm)"

        local date_part="${start_at%%:*}"
        local time_part="${start_at#*:}"
        local cron_hour="${time_part%%-*}"
        local cron_min="${time_part#*-}"
        local cron_day cron_month
        cron_day="$(cut  -d- -f3 <<< "$date_part")"
        cron_month="$(cut -d- -f2 <<< "$date_part")"

        local tag="IPTV_record_${channel}_${date_part//-/}_${time_part//-/}"
        local cron_cmd="$SCRIPT_DIR/iptv_toolkit.sh record-live -config $config -channel $channel -duration-minutes $duration_mins"
        [[ "$no_remux" == true ]] && cron_cmd+=" -no-remux"

        local cron_entry="$cron_min $cron_hour $cron_day $cron_month * $cron_cmd # $tag"
        log "INFO" ""
        log "INFO" "[Schedule] Adding cron job:"
        log "INFO" "  $cron_entry"
        ( crontab -l 2>/dev/null; echo "$cron_entry" ) | crontab -
        log "SUCCESS" "Scheduled. Run 'crontab -l' to verify."
        return
    fi

    # --- Wait until start_at if specified ---
    if [[ -n "$start_at" ]]; then
        local start_epoch now_epoch
        start_epoch="$(parse_start_to_epoch "$start_at")"
        now_epoch="$(date +%s)"
        (( start_epoch > now_epoch )) || die "Start time is in the past."

        log "INFO" "Current time:   $(epoch_to_str "$now_epoch")"
        log "INFO" "Scheduled time: $(epoch_to_str "$start_epoch")"
        log "INFO" "Waiting to record [$channel] for [$duration_mins] minute(s)..."

        while true; do
            now_epoch="$(date +%s)"
            local remaining=$(( start_epoch - now_epoch ))
            (( remaining <= 0 )) && break
            printf "\rStarting in %02d:%02d...  " "$(( remaining / 60 ))" "$(( remaining % 60 ))"
            sleep 1
        done
        printf "\rStarting now!             \n"
        log "INFO" "Starting now."
    fi

    # --- Build URL and run ---
    local code="$(cm_get "$channel")"
    _live_url="$(_live_stream_url "$code")"

    log "INFO" "URL: $_live_url"

    mkdir -p "$OUTPUT_DIR"
    local output_path="${OUTPUT_DIR}/${channel}_$(date '+%Y%m%d_%H%M').ts"

    local -a map_args=(-map "0:v?" -map "0:a:0")
    [[ "$_first_audio_only" == true ]] && map_args=(-map "0:a:0")

    local -a initial_args=(
        "${_LIVE_ARGS[@]}"
        -i "$_live_url"
        "${map_args[@]}"
        -t "$duration_secs"
        -c copy "$output_path"
    )

    if [[ "$dry_run" == true ]]; then
        log "INFO" ""
        log "DRY-RUN" "Would run: $FFMPEG_BIN ${initial_args[*]}"
        return
    fi

    log "INFO" "Recording $channel for $duration_mins minute(s)..."
    ffmpeg_with_retry "$output_path" "$duration_secs" _build_live_retry "${initial_args[@]}"

    if [[ "$no_remux" == false ]]; then
        remux_ts_to_mkv "$output_path"
    else
        log "INFO" "NoRemux: skipping remux."
    fi
}

# ---------------------------------------------------------------------------
# record-catchup
# ---------------------------------------------------------------------------

# These are set per-channel inside record_catchup and read by the retry builder
_catchup_start_epoch=0
_catchup_code=""
_catchup_custom_duration=300

_build_catchup_retry() {
    local remaining="$1" seg_path="$2" elapsed="$3"
    local new_epoch ss_offset retry_url
    new_epoch=$(( _catchup_start_epoch + elapsed ))
    ss_offset=$(( elapsed % 60 ))

    local new_encoded_start
    new_encoded_start="$(epoch_to_provider_tz "$new_epoch" "$CATCHUP_TIMEZONE")"
    retry_url="$(_catchup_stream_url "$_catchup_code" "$new_encoded_start" "$_catchup_custom_duration")"

    local -a map_args=(-map "0:v?" -map "0:a:0")
    [[ "$_first_audio_only" == true ]] && map_args=(-map "0:a:0")
    _RETRY_FFMPEG_ARGS=("${_CATCHUP_ARGS[@]}" -i "$retry_url")
    (( ss_offset > 0 )) && _RETRY_FFMPEG_ARGS+=(-ss "$ss_offset")
    _RETRY_FFMPEG_ARGS+=("${map_args[@]}" -t "$remaining" -c copy "$seg_path")
}

record_catchup() {
    local config="" duration_mins="" start_at=""
    local -a channels=()
    local no_remux=false dry_run=false
    _catchup_custom_duration=300
    _first_audio_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -config)           config="$2";                          shift 2 ;;
            -channel)          IFS=',' read -ra channels <<< "$2";  shift 2 ;;
            -duration-minutes) duration_mins="$2";                   shift 2 ;;
            -start-at)         start_at="$2";                        shift 2 ;;
            -no-remux)         no_remux=true;                        shift   ;;
            -dry-run)          dry_run=true;                         shift   ;;
            -custom-duration)  _catchup_custom_duration="$2";        shift 2 ;;
            -first-audio-only)       _first_audio_only=true;                     shift   ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$config" ]]        || die "-config is required"
    (( ${#channels[@]} > 0 )) || die "-channel is required"
    [[ -n "$duration_mins" ]] || die "-duration-minutes is required"
    [[ -n "$start_at" ]]      || die "-start-at is required (format: yyyy-MM-dd:HH-mm, your local time)"

    # Initialize log file
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    LOG_FILE="${LOG_DIR}/record_catchup_${start_at//[:,-]/_}_${timestamp}.log"

    load_config "$config"
    for chan in "${channels[@]}"; do
        cm_has "$chan" || die "Invalid channel '$chan'. Valid: $(cm_keys)"
    done

    local duration_secs=$(( duration_mins * 60 ))
    local now_epoch start_epoch
    now_epoch="$(date +%s)"
    start_epoch="$(parse_start_to_epoch "$start_at")"
    (( start_epoch < now_epoch )) || die "Start time must be in the past for catch-up recording."

    _catchup_start_epoch="$start_epoch"

    local encoded_start
    encoded_start="$(convert_to_provider_tz "$start_at" "$CATCHUP_TIMEZONE")"

    mkdir -p "$OUTPUT_DIR"
    local timestamp last_chan
    timestamp="$(date '+%Y%m%d_%H%M')"
    last_chan="${channels[${#channels[@]}-1]}"

    for chan in "${channels[@]}"; do
        _catchup_code="$(cm_get "$chan")"
        local output_path="${OUTPUT_DIR}/${chan}_${timestamp}.ts"
        local url
        url="$(_catchup_stream_url "$_catchup_code" "$encoded_start" "$_catchup_custom_duration")"

        local -a map_args=(-map "0:v?" -map "0:a:0")
        [[ "$_first_audio_only" == true ]] && map_args=(-map "0:a:0")

        local -a initial_args=(
            "${_CATCHUP_ARGS[@]}"
            -i "$url"
            "${map_args[@]}"
            -t "$duration_secs"
            -c copy "$output_path"
        )

        if [[ "$dry_run" == true ]]; then
            log "INFO" ""
            log "DRY-RUN" "Would run: $FFMPEG_BIN ${initial_args[*]}"
        else
            log "INFO" ""
            log "INFO" "Catch-up URL: $url"
            log "INFO" "Recording $chan (start: $encoded_start) for $duration_mins minute(s)..."
            ffmpeg_with_retry "$output_path" "$duration_secs" _build_catchup_retry "${initial_args[@]}"
            if [[ "$no_remux" == false ]]; then
                remux_ts_to_mkv "$output_path"
            else
                log "INFO" "NoRemux: skipping remux."
            fi
        fi

        [[ "$chan" != "$last_chan" ]] && sleep 3
    done
    return 0
}

# ---------------------------------------------------------------------------
# remove-jobs — remove past IPTV cron entries
# ---------------------------------------------------------------------------

remove_jobs() {
    local current_crontab
    current_crontab="$(crontab -l 2>/dev/null)" || { log "INFO" "No crontab entries found."; return; }

    local -a to_remove=()
    local now_epoch
    now_epoch="$(date +%s)"

    while IFS= read -r line; do
        [[ "$line" == *"# IPTV_record_"* ]] || continue

        # Extract date/time from the tag comment (format: IPTV_record_CHANNEL_YYYYMMDD_HHmm)
        if [[ "$line" =~ IPTV_record_[^_]+_([0-9]{8})_([0-9]{4}) ]]; then
            local date_str="${BASH_REMATCH[1]}"  # YYYYMMDD
            local time_str="${BASH_REMATCH[2]}"  # HHmm
            local job_epoch
            job_epoch="$(python3 -c "
from datetime import datetime
try:
    print(int(datetime(int('${date_str:0:4}'), int('${date_str:4:2}'), int('${date_str:6:2}'),
                       int('${time_str:0:2}'), int('${time_str:2:2}')).astimezone().timestamp()))
except Exception:
    print(0)" 2>/dev/null)"
            (( job_epoch > 0 && job_epoch < now_epoch )) && to_remove+=("$line")
        fi
    done <<< "$current_crontab"

    if (( ${#to_remove[@]} == 0 )); then
        log "INFO" "No completed IPTV recording jobs to remove."
        return
    fi

    local new_crontab="$current_crontab"
    for line in "${to_remove[@]}"; do
        log "INFO" "Removing: $line"
        new_crontab="$(grep -Fv "$line" <<< "$new_crontab" || true)"
    done

    echo "$new_crontab" | crontab -
    log "SUCCESS" "${#to_remove[@]} job(s) removed."
}

# ---------------------------------------------------------------------------
# list-channels — list all channels for a config
# ---------------------------------------------------------------------------

list_channels() {
    local config=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -config) config="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -n "$config" ]] || die "-config is required"
    load_config "$config"
    echo ""
    echo "Channels for '$config':"
    echo ""
    printf '  %-35s %s\n' "Channel name" "Stream ID"
    printf '  %-35s %s\n' "------------" "---------"
    for key in $(cm_keys | sort); do
        printf '  %-35s %s\n' "$key" "$(cm_get "$key")"
    done
    echo ""
}

# ---------------------------------------------------------------------------
# setup-config — interactive wizard to add a provider or channel
# ---------------------------------------------------------------------------

setup_config() {
    echo ""
    echo "=== IPTV Config Setup Wizard ==="
    echo "Adds a new provider config or a channel to an existing provider."
    echo ""

    # Create config file if it doesn't exist
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Config file not found — creating: $CONFIG_FILE"
        mkdir -p "$(dirname "$CONFIG_FILE")"
        cat > "$CONFIG_FILE" <<'CFGEOF'
# IPTV Toolkit config — Linux / Synology NAS version
# Generated by setup-config. Credentials stay local (gitignored).

OUTPUT_DIR="$HOME/recordings"
#FFMPEG_BIN="ffmpeg7"
#FFPROBE_BIN="ffprobe7"

CFGEOF
        echo "Config file created."
        echo ""
    fi

    # --- Provider name ---
    read -rp "Provider config name (e.g. myprovider): " _input_provider
    local provider_name
    provider_name="$(_normalize_channel_name "$_input_provider")"
    [[ -n "$provider_name" ]] || die "Provider name cannot be empty."

    local existing=false
    if grep -qF "config_${provider_name}()" "$CONFIG_FILE" 2>/dev/null; then
        existing=true
        echo "Provider '$provider_name' already exists — a new channel will be added to it."
    fi

    # --- Live URL ---
    echo ""
    echo "Enter a live stream URL for one channel."
    echo "Expected format: http://provider.com[:port][/path]/USERNAME/PASSWORD/STREAM_ID[.ts]"
    read -rp "Live URL: " _live_url_input
    [[ -n "$_live_url_input" ]] || die "Live URL is required."

    local _parse_out
    if ! _parse_out="$(_py_parse_live_url "$_live_url_input")"; then
        die "Could not parse live URL. Ensure it follows the format shown above."
    fi

    local det_base det_user det_pass det_id det_ts
    IFS=$'\n' read -r det_base det_user det_pass det_id det_ts <<< "$_parse_out"

    echo ""
    echo "Detected from URL:"
    printf '  %-12s %s\n' "Base URL:"   "$det_base"
    printf '  %-12s %s\n' "Username:"   "$det_user"
    printf '  %-12s %s\n' "Password:"   "$det_pass"
    printf '  %-12s %s\n' "Stream ID:"  "$det_id"
    printf '  %-12s %s\n' ".ts suffix:" "$det_ts"
    echo ""
    read -rp "Are these correct? [Y/n]: " _yn

    local base_url="$det_base" username="$det_user" password="$det_pass"
    local stream_id="$det_id" add_ts="$det_ts"

    if [[ "$(_lc "$_yn")" == "n" ]]; then
        read -rp "  Base URL [$det_base]: " _in;  [[ -n "$_in" ]] && base_url="$_in"
        read -rp "  Username [$det_user]: " _in;  [[ -n "$_in" ]] && username="$_in"
        read -rp "  Password [$det_pass]: " _in;  [[ -n "$_in" ]] && password="$_in"
        read -rp "  Add .ts suffix to live URLs? [y/N]: " _ts_yn
        [[ "$(_lc "$_ts_yn")" == "y" ]] && add_ts="true" || add_ts="false"
    fi

    # --- Catchup URL (new providers only) ---
    local _default_tz="Europe/Paris"
    local catchup_url="" format_style="query" timezone="$_default_tz"
    if [[ "$existing" == false ]]; then
        echo ""
        echo "Enter the catch-up (timeshift) URL for this channel, or press Enter to skip."
        echo "  Query style: http://provider.com/timeshift.php?username=...&password=...&stream=ID&start=DATE&duration=SECS"
        echo "  Path style:  http://provider.com/live/timeshift/username/password/duration/start/stream_id.ts"
        read -rp "Catch-up URL (optional): " _catchup_input

        if [[ -n "$_catchup_input" ]]; then
            local _catchup_out
            if _catchup_out="$(_py_parse_catchup_url "$_catchup_input")"; then
                IFS=$'\n' read -r format_style catchup_url <<< "$_catchup_out"
                echo ""
                echo "Detected: format=$format_style${catchup_url:+, URL=$catchup_url}"
                read -rp "Correct? [Y/n]: " _yn2
                if [[ "$(_lc "$_yn2")" == "n" ]]; then
                    read -rp "  Catch-up URL: " catchup_url
                    read -rp "  Format style (query/path): " format_style
                fi
            fi
        fi

        echo ""
        echo "What timezone does this provider use for catch-up times?"
        echo "Use IANA names — e.g. UTC, Europe/London, America/New_York, Europe/Paris"
        echo "List available: python3 -c \"import zoneinfo; print(*sorted(zoneinfo.available_timezones()), sep='\\\n')\""
        read -rp "Timezone [press Enter for '$_default_tz', or type another]: " _tz_input
        timezone="${_tz_input:-$_default_tz}"
    fi

    # --- Channel name ---
    echo ""
    read -rp "What is this channel called? (e.g. 'BBC One'): " _channel_input
    [[ -n "$_channel_input" ]] || die "Channel name is required."
    local channel_name
    channel_name="$(_normalize_channel_name "$_channel_input")"
    echo "Channel key will be: $channel_name"

    # --- Write to config file ---
    echo ""
    if [[ "$existing" == true ]]; then
        if python3 - "$CONFIG_FILE" "$provider_name" "$channel_name" "$stream_id" <<'PYEOF'
import sys, re

config_file, provider, channel, stream_id = sys.argv[1:5]
with open(config_file) as f:
    content = f.read()

func_pos = content.find(f'config_{provider}()')
if func_pos == -1:
    print(f"ERROR: config_{provider}() not found", file=sys.stderr); sys.exit(1)

map_pos = content.find('declare -gA CHANNEL_MAP=(', func_pos)
if map_pos == -1:
    print("ERROR: CHANNEL_MAP not found", file=sys.stderr); sys.exit(1)

close_match = re.search(r'\n    \)', content[map_pos:])
if not close_match:
    print("ERROR: closing ) not found", file=sys.stderr); sys.exit(1)

insert_pos = map_pos + close_match.start()
new_entry = f'\n        ["{channel}"]="{stream_id}"'
new_content = content[:insert_pos] + new_entry + content[insert_pos:]

with open(config_file, 'w') as f:
    f.write(new_content)
PYEOF
        then
            echo "Added channel '$channel_name' (ID: $stream_id) to '$provider_name'."
        else
            echo "Could not update config automatically. Add this line manually inside config_${provider_name}():"
            echo "        [\"$channel_name\"]=\"$stream_id\""
        fi
    else
        python3 - "$CONFIG_FILE" "$provider_name" "$username" "$password" \
                  "$base_url" "$catchup_url" "$add_ts" "$format_style" \
                  "$timezone" "$channel_name" "$stream_id" <<'PYEOF'
import sys

(config_file, provider, username, password,
 base_url, catchup_url, add_ts, format_style,
 timezone, channel, stream_id) = sys.argv[1:12]

block = f"""
config_{provider}() {{
    USERNAME="{username}"
    PASSWORD="{password}"
    BASE_URL="{base_url}"
    CATCHUP_URL="{catchup_url}"
    ADD_TS_SUFFIX={add_ts}
    CATCHUP_FORMAT_STYLE="{format_style}"
    CATCHUP_TIMEZONE="{timezone}"
    declare -gA CHANNEL_MAP=(
        ["{channel}"]="{stream_id}"
    )
}}
"""

with open(config_file, 'a') as f:
    f.write(block)
PYEOF
        echo "Provider '$provider_name' added with channel '$channel_name' (ID: $stream_id)."
        echo "Config: $CONFIG_FILE"
    fi

    echo ""
    echo "Done! Try it with:"
    echo "  $0 record-live -config $provider_name -channel $channel_name -duration-minutes 5 -dry-run"
    echo "  $0 list-channels -config $provider_name"
    echo ""
    echo "To add more channels, run setup-config again with the same provider name."
}

# ---------------------------------------------------------------------------
# validate-config — static, offline validation of the config file
# ---------------------------------------------------------------------------

# List provider names (config_NAME) defined in the config file text.
_list_providers() {
    grep -oE '^config_[A-Za-z0-9_]+[[:space:]]*\(\)' "$CONFIG_FILE" 2>/dev/null \
        | sed -E 's/[[:space:]]*\(\)$//; s/^config_//'
}

# Print duplicate CHANNEL_MAP keys for a provider by scanning the config text.
# bash-4 keeps the LAST duplicate; the mac cm_get shim returns the FIRST — a
# real cross-script divergence, so a duplicate key is always an error.
_dup_channel_keys() {
    python3 - "$CONFIG_FILE" "$1" <<'PYEOF'
import sys, re
try:
    content = open(sys.argv[1]).read()
except OSError:
    sys.exit(0)
provider = sys.argv[2]
m = re.search(r'^config_%s\s*\(\)' % re.escape(provider), content, re.M)
if not m:
    sys.exit(0)
mm = re.search(r'declare -gA CHANNEL_MAP=\(', content[m.end():])
if not mm:
    sys.exit(0)
start = m.end() + mm.end()
cm = re.search(r'\n\s*\)', content[start:])
region = content[start:start + cm.start()] if cm else content[start:]
keys = re.findall(r'\[\s*"([^"]*)"\s*\]\s*=', region)
seen = {}
for k in keys:
    seen[k] = seen.get(k, 0) + 1
dups = sorted(k for k, c in seen.items() if c > 1)
if dups:
    print(",".join(dups))
PYEOF
}

# Validate one provider. Prints a per-provider report; sets _VALIDATE_ERRORS.
_VALIDATE_ERRORS=0
_validate_one() {
    local name="$1"
    local -a errors=() warnings=()

    # Reset ffmpeg binaries to the baseline so a per-provider override is judged
    # on its own and does not leak into the next provider.
    FFMPEG_BIN="${_BASE_FFMPEG_BIN:-ffmpeg}"
    FFPROBE_BIN="${_BASE_FFPROBE_BIN:-ffprobe}"
    _run_config_fn "$name"

    # --- Hard errors ---
    [[ -n "${USERNAME:-}" ]]   || errors+=("USERNAME is missing or empty")
    [[ -n "${PASSWORD:-}" ]]   || errors+=("PASSWORD is missing or empty")
    [[ -n "${BASE_URL:-}" ]]   || errors+=("BASE_URL is missing or empty")
    [[ -n "${OUTPUT_DIR:-}" ]] || errors+=("OUTPUT_DIR is not set (top-level in the config file)")

    case "${CATCHUP_FORMAT_STYLE:-}" in
        query|path) ;;
        *) errors+=("CATCHUP_FORMAT_STYLE must be 'query' or 'path' (got '${CATCHUP_FORMAT_STYLE:-}')") ;;
    esac

    if [[ -z "${CATCHUP_TIMEZONE:-}" ]]; then
        errors+=("CATCHUP_TIMEZONE is empty")
    elif ! python3 -c 'import sys, zoneinfo; zoneinfo.ZoneInfo(sys.argv[1])' "$CATCHUP_TIMEZONE" 2>/dev/null; then
        errors+=("CATCHUP_TIMEZONE '$CATCHUP_TIMEZONE' is not a valid IANA timezone")
    fi

    local -a keys=()
    local k
    while IFS= read -r k; do [[ -n "$k" ]] && keys+=("$k"); done < <(cm_keys)
    if (( ${#keys[@]} == 0 )); then
        errors+=("CHANNEL_MAP is empty")
    else
        local val norm
        for k in "${keys[@]}"; do
            val="$(cm_get "$k")"
            [[ -n "$val" ]] || errors+=("channel '$k' has an empty stream ID")
            norm="$(_normalize_channel_name "$k")"
            [[ "$k" == "$norm" ]] || warnings+=("channel key '$k' is not normalized (suggest '$norm')")
        done
    fi

    local dups
    dups="$(_dup_channel_keys "$name")"
    [[ -n "$dups" ]] && errors+=("duplicate CHANNEL_MAP key(s): $dups")

    # --- Warnings ---
    if [[ "${CATCHUP_FORMAT_STYLE:-}" == "query" && -z "${CATCHUP_URL:-}" ]]; then
        warnings+=("CATCHUP_URL is empty but CATCHUP_FORMAT_STYLE=query — record-catchup will fail")
    fi
    [[ "${BASE_URL:-}" == */ ]] && warnings+=("BASE_URL has a trailing slash")
    command -v "${FFMPEG_BIN:-ffmpeg}"   >/dev/null 2>&1 || warnings+=("ffmpeg binary '${FFMPEG_BIN:-ffmpeg}' not resolvable on this host")
    command -v "${FFPROBE_BIN:-ffprobe}" >/dev/null 2>&1 || warnings+=("ffprobe binary '${FFPROBE_BIN:-ffprobe}' not resolvable on this host")

    # --- Report ---
    echo "[$name]"
    local e w
    for e in "${errors[@]}";   do echo "  ERROR:   $e"; done
    for w in "${warnings[@]}"; do echo "  WARNING: $w"; done
    if (( ${#errors[@]} == 0 && ${#warnings[@]} == 0 )); then
        echo "  OK"
    else
        echo "  -> ${#errors[@]} error(s), ${#warnings[@]} warning(s)"
    fi
    echo ""

    _VALIDATE_ERRORS=${#errors[@]}
}

validate_config() {
    local only=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -config) only="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    local -a providers=()
    if [[ -n "$only" ]]; then
        type "config_${only}" &>/dev/null || die "Unknown config '$only'. Available: $(_list_providers | tr '\n' ' ')"
        providers=("$only")
    else
        local p
        while IFS= read -r p; do [[ -n "$p" ]] && providers+=("$p"); done < <(_list_providers)
        (( ${#providers[@]} > 0 )) || die "No providers defined in $CONFIG_FILE"
    fi

    echo ""
    echo "Validating $CONFIG_FILE"
    echo ""

    local total_err=0 prov
    for prov in "${providers[@]}"; do
        _validate_one "$prov"
        total_err=$(( total_err + _VALIDATE_ERRORS ))
    done

    if (( total_err > 0 )); then
        echo "validate-config: FAILED — $total_err error(s) across ${#providers[@]} provider(s)."
        return 1
    fi
    echo "validate-config: OK — ${#providers[@]} provider(s) valid."
    return 0
}

# ---------------------------------------------------------------------------
# check-channels — probe stream reachability with ffprobe (no recording)
# ---------------------------------------------------------------------------

# Probe a URL with ffprobe. On success echoes "resolution|codecs" and returns 0;
# on failure returns 1. ffprobe only — never records.
_probe_stream() {
    local url="$1" out
    out="$("$FFPROBE_BIN" -v error -user_agent "Mozilla/5.0" -rw_timeout 15000000 \
            -show_entries stream=codec_type,codec_name,width,height \
            -of csv=p=0 "$url" 2>/dev/null)" || return 1
    [[ -n "$out" ]] || return 1

    local vcodec="" acodec="" resolution="" atracks=0
    local ctype cname w h
    while IFS=, read -r ctype cname w h; do
        [[ -z "$ctype" ]] && continue
        case "$ctype" in
            video) vcodec="$cname"; [[ -n "$w" && -n "$h" ]] && resolution="${w}x${h}" ;;
            audio) atracks=$(( atracks + 1 )); [[ -z "$acodec" ]] && acodec="$cname" ;;
        esac
    done <<< "$out"

    local codecs="$vcodec"
    [[ -n "$acodec" ]] && codecs="${codecs:+$codecs/}$acodec"
    (( atracks > 0 )) && codecs="${codecs} (${atracks}a)"
    printf '%s|%s' "${resolution:-?}" "${codecs:-?}"
    return 0
}

check_channels() {
    local config="" catchup=false
    local -a channels=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -config)  config="$2"; shift 2 ;;
            -channel) IFS=',' read -ra channels <<< "$2"; shift 2 ;;
            -catchup) catchup=true; shift ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ -n "$config" ]] || die "-config is required"
    load_config "$config"

    # No -channel -> all channels for the provider (sorted).
    if (( ${#channels[@]} == 0 )); then
        local k
        while IFS= read -r k; do [[ -n "$k" ]] && channels+=("$k"); done < <(cm_keys | sort)
    else
        local chan
        for chan in "${channels[@]}"; do
            cm_has "$chan" || die "Invalid channel '$chan'. Valid: $(cm_keys | tr '\n' ' ')"
        done
    fi

    # Synthetic catch-up start: now - 2h, short window.
    local now_epoch start_epoch encoded_start probe_window=60
    now_epoch="$(date +%s)"
    start_epoch=$(( now_epoch - 7200 ))
    encoded_start="$(epoch_to_provider_tz "$start_epoch" "$CATCHUP_TIMEZONE")"

    local scope="live"
    [[ "$catchup" == true ]] && scope="live + catch-up"
    echo ""
    echo "Checking channels for '$config' ($scope):"
    echo ""
    printf '  %-25s %-8s %-8s %-12s %s\n' "Channel" "Kind" "Status" "Resolution" "Codecs"
    printf '  %-25s %-8s %-8s %-12s %s\n' "-------" "----" "------" "----------" "------"

    local any_fail=0 chan code url info
    for chan in "${channels[@]}"; do
        code="$(cm_get "$chan")"

        url="$(_live_stream_url "$code")"
        if info="$(_probe_stream "$url")"; then
            printf '  %-25s %-8s %-8s %-12s %s\n' "$chan" "live" "OK" "${info%%|*}" "${info#*|}"
        else
            printf '  %-25s %-8s %-8s %-12s %s\n' "$chan" "live" "FAIL" "-" "-"
            any_fail=1
        fi

        if [[ "$catchup" == true ]]; then
            url="$(_catchup_stream_url "$code" "$encoded_start" "$probe_window")"
            if info="$(_probe_stream "$url")"; then
                printf '  %-25s %-8s %-8s %-12s %s\n' "$chan" "catchup" "OK" "${info%%|*}" "${info#*|}"
            else
                printf '  %-25s %-8s %-8s %-12s %s\n' "$chan" "catchup" "FAIL" "-" "-"
                any_fail=1
            fi
        fi
    done
    echo ""

    if (( any_fail != 0 )); then
        echo "check-channels: one or more channels failed."
        return 1
    fi
    echo "check-channels: all probed channels reachable."
    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  setup-config    Interactive wizard to add a provider config or channel"
    echo "  list-channels   List all channels for a provider config"
    echo "  validate-config Statically validate the config file (offline)"
    echo "  check-channels  Probe stream reachability with ffprobe (no recording)"
    echo "  record-live     Record a live stream"
    echo "  record-catchup  Record a catch-up/timeshift stream"
    echo "  remove-jobs     Remove past scheduled IPTV cron entries"
    echo ""
    echo "setup-config:"
    echo "  (no options — fully interactive)"
    echo ""
    echo "list-channels options:"
    echo "  -config NAME            Provider config name (required)"
    echo ""
    echo "validate-config options:"
    echo "  -config NAME            Validate one provider (default: all providers)"
    echo ""
    echo "check-channels options:"
    echo "  -config NAME            Provider config name (required)"
    echo "  -channel NAME[,NAME...] Channels to probe (default: all)"
    echo "  -catchup                Also probe the catch-up endpoint (now - 2h)"
    echo ""
    echo "record-live options:"
    echo "  -config NAME            Provider config name (required)"
    echo "  -channel NAME           Channel name (required)"
    echo "  -duration-minutes N     Recording duration in minutes (required)"
    echo "  -start-at DATETIME      Wait until this local time before recording"
    echo "  -schedule               Add a cron job instead of waiting in the terminal"
    echo "  -no-remux               Keep output as .ts (skip remux to .mkv)"
    echo "  -first-audio-only       Record first audio track only (no video)"
    echo "  -dry-run                Print the ffmpeg command without running it"
    echo ""
    echo "record-catchup options:"
    echo "  -config NAME            Provider config name (required)"
    echo "  -channel NAME[,NAME...] One or more channel names (required)"
    echo "  -start-at DATETIME      Broadcast start time in your local time (required)"
    echo "  -duration-minutes N     Duration in minutes (required)"
    echo "  -no-remux               Keep output as .ts"
    echo "  -first-audio-only       Record first audio track only (no video)"
    echo "  -dry-run                Print ffmpeg command without running"
    echo "  -custom-duration N      Timeshift window in seconds (default: 300)"
    echo ""
    echo "DateTime format: yyyy-MM-dd:HH-mm  (e.g. 2026-03-01:20-00)"
}

# Load the provider config file and apply ffmpeg/ffprobe defaults. The config
# is rewritten on the fly (declare -gA -> _CHANNEL_MAP_STR) so the shared
# bash-4 config format is sourceable under bash 3.2. Skipped for setup-config,
# which may need to create the config file first.
_bootstrap() {
    local cmd="${1:-}"
    if [[ "$cmd" != "setup-config" ]]; then
        [[ -f "$CONFIG_FILE" ]] || { echo "Error: Config not found at $CONFIG_FILE" >&2; exit 1; }
        # shellcheck source=Settings/iptv_configs.sh
        _CONFIG_TMP="$(mktemp "${TMPDIR:-/tmp}/iptv_cfg.XXXXXX.sh")"
        _config_to_bash3 "$CONFIG_FILE" > "$_CONFIG_TMP"
        source "$_CONFIG_TMP"
        rm -f "$_CONFIG_TMP"
    fi
    # Default to plain ffmpeg/ffprobe; config can override (load_config may remap these)
    FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"
    FFPROBE_BIN="${FFPROBE_BIN:-ffprobe}"
    # Baseline for per-provider validation (before any load_config remap).
    _BASE_FFMPEG_BIN="$FFMPEG_BIN"
    _BASE_FFPROBE_BIN="$FFPROBE_BIN"
}

main() {
    [[ $# -gt 0 ]] || { usage; exit 1; }

    local command="$1"; shift
    _bootstrap "$command"
    mkdir -p "$LOG_DIR"
    case "$command" in
        setup-config)    setup_config ;;
        list-channels)   list_channels   "$@" ;;
        validate-config) validate_config "$@" ;;
        check-channels)  check_channels  "$@" ;;
        record-live)     record_live     "$@" ;;
        record-catchup)  record_catchup  "$@" ;;
        remove-jobs)     remove_jobs ;;
        help|--help|-h)  usage ;;
        *) die "Unknown command '$command'. Run '$0 help' for usage." ;;
    esac
}

# Run only when executed directly, not when sourced (e.g. by the test harness).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
