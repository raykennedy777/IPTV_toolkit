#!/usr/bin/env bash
# iptv_toolkit.sh — IPTV recording toolkit for Linux / Synology NAS
# Requires: bash 4+, ffmpeg, python3 (3.9+ for zoneinfo)
# Set FFMPEG_BIN in iptv_configs.sh to use a non-default binary (e.g. ffmpeg7)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/Settings/iptv_configs.sh"

[[ -f "$CONFIG_FILE" ]] || { echo "Error: Config not found at $CONFIG_FILE" >&2; exit 1; }
# shellcheck source=Settings/iptv_configs.sh
source "$CONFIG_FILE"

# Default to plain ffmpeg; config can override (e.g. FFMPEG_BIN=ffmpeg7)
FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

die() { echo "Error: $*" >&2; exit 1; }

load_config() {
    local name="$1"
    declare -gA CHANNEL_MAP=()
    type "config_${name}" &>/dev/null || die "Unknown config '$name'. Define config_${name}() in iptv_configs.sh."
    "config_${name}"
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
    -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1
    -reconnect_on_network_error 1 -reconnect_delay_max 30
    -rw_timeout 15000000 -err_detect ignore_err -fflags +genpts
)

# ---------------------------------------------------------------------------
# Core recording helpers
# ---------------------------------------------------------------------------

remux_ts_to_mkv() {
    local ts_file="$1"
    local mkv_file="${ts_file%.ts}.mkv"
    echo "Remuxing to $mkv_file ..."
    if "$FFMPEG_BIN" -err_detect ignore_err -fflags +genpts \
              -i "$ts_file" -map 0 -c copy -avoid_negative_ts make_zero \
              "$mkv_file"; then
        rm "$ts_file"
        echo "Remux successful. Deleted original .ts file."
    else
        echo "Warning: Remux failed. .ts file kept." >&2
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
    echo "Concatenating ${#resolved[@]} segments..."
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

ffmpeg_with_retry() {
    # Usage: ffmpeg_with_retry <output_path> <total_secs> <build_retry_func> <initial_ffmpeg_args...>
    local output_path="$1"
    local total_secs="$2"
    local build_retry_func="$3"
    shift 3
    local -a initial_args=("$@")

    local start_epoch
    start_epoch="$(date +%s)"

    # Run initial ffmpeg
    if ! "$FFMPEG_BIN" "${initial_args[@]}"; then
        echo "Error: initial ffmpeg failed." >&2
        return 1
    fi

    local elapsed=$(( $(date +%s) - start_epoch ))
    local total_i="$total_secs"

    if (( elapsed >= total_i - 2 )); then
        return 0
    fi

    local dir base
    dir="$(dirname "$output_path")"
    base="$(basename "${output_path%.ts}")"

    local -a segments=("$output_path")
    local max_retries=5

    for (( retry=1; retry<=max_retries; retry++ )); do
        local remaining=$(( total_i - elapsed ))
        if (( remaining < 10 )); then
            echo "Only ${remaining}s remaining — skipping retry."
            break
        fi

        echo "Retry $retry/$max_retries — ${remaining}s remaining..."

        local seg_path="$dir/${base}_seg${retry}.ts"
        "$build_retry_func" "$remaining" "$seg_path" "$elapsed"

        local seg_start seg_elapsed
        seg_start="$(date +%s)"
        if ! "$FFMPEG_BIN" "${_RETRY_FFMPEG_ARGS[@]}"; then
            echo "Error: retry ffmpeg failed." >&2
            break
        fi
        seg_elapsed=$(( $(date +%s) - seg_start ))

        # Check segment file exists and non-empty
        if [[ ! -s "$seg_path" ]]; then
            echo "Warning: Retry $retry produced empty file — stopping retries." >&2
            rm -f "$seg_path"
            break
        fi

        segments+=("$seg_path")
        elapsed=$(( elapsed + seg_elapsed ))

        if (( elapsed >= total_i - 2 )); then
            echo "Target duration reached after retry $retry."
            break
        fi
    done

    if (( ${#segments[@]} > 1 )); then
        merge_ts_segments "$output_path" "${segments[@]}"
    fi
}

# ---------------------------------------------------------------------------
# record-live
# ---------------------------------------------------------------------------

# _live_url is set by record_live and read by this retry builder
_live_url=""

_build_live_retry() {
    local remaining="$1" seg_path="$2"
    _RETRY_FFMPEG_ARGS=(
        "${_LIVE_ARGS[@]}"
        -i "$_live_url"
        -map "0:v?" -map "0:a?"
        -t "$remaining"
        -c copy "$seg_path"
    )
}

record_live() {
    local config="" channel="" duration_mins="" start_at=""
    local no_remux=false dry_run=false schedule=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -config)           config="$2";        shift 2 ;;
            -channel)          channel="$2";       shift 2 ;;
            -duration-minutes) duration_mins="$2"; shift 2 ;;
            -start-at)         start_at="$2";      shift 2 ;;
            -no-remux)         no_remux=true;      shift   ;;
            -dry-run)          dry_run=true;       shift   ;;
            -schedule)         schedule=true;      shift   ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$config" ]]        || die "-config is required"
    [[ -n "$channel" ]]       || die "-channel is required"
    [[ -n "$duration_mins" ]] || die "-duration-minutes is required"

    load_config "$config"
    [[ -v "CHANNEL_MAP[$channel]" ]] || die "Invalid channel '$channel'. Valid: ${!CHANNEL_MAP[*]}"

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
        echo ""
        echo "[Schedule] Adding cron job:"
        echo "  $cron_entry"
        ( crontab -l 2>/dev/null; echo "$cron_entry" ) | crontab -
        echo "Scheduled. Run 'crontab -l' to verify."
        return
    fi

    # --- Wait until start_at if specified ---
    if [[ -n "$start_at" ]]; then
        local start_epoch now_epoch
        start_epoch="$(parse_start_to_epoch "$start_at")"
        now_epoch="$(date +%s)"
        (( start_epoch > now_epoch )) || die "Start time is in the past."

        echo "Current time:   $(epoch_to_str "$now_epoch")"
        echo "Scheduled time: $(epoch_to_str "$start_epoch")"
        echo "Waiting to record [$channel] for [$duration_mins] minute(s)..."

        while true; do
            now_epoch="$(date +%s)"
            local remaining=$(( start_epoch - now_epoch ))
            (( remaining <= 0 )) && break
            printf "\rStarting in %02d:%02d...  " "$(( remaining / 60 ))" "$(( remaining % 60 ))"
            sleep 1
        done
        printf "\rStarting now!             \n"
    fi

    # --- Build URL and run ---
    local code="${CHANNEL_MAP[$channel]}"
    local suffix=""
    [[ "$ADD_TS_SUFFIX" == true ]] && suffix=".ts"
    _live_url="${BASE_URL}/${USERNAME}/${PASSWORD}/${code}${suffix}"

    echo ""
    echo "URL: $_live_url"

    mkdir -p "$OUTPUT_DIR"
    local output_path="${OUTPUT_DIR}/${channel}_$(date '+%Y%m%d_%H%M').ts"

    local -a initial_args=(
        "${_LIVE_ARGS[@]}"
        -i "$_live_url"
        -map "0:v?" -map "0:a?"
        -t "$duration_secs"
        -c copy "$output_path"
    )

    if [[ "$dry_run" == true ]]; then
        echo ""
        echo "[DryRun] Would run: $FFMPEG_BIN ${initial_args[*]}"
        return
    fi

    echo "Recording $channel for $duration_mins minute(s)..."
    ffmpeg_with_retry "$output_path" "$duration_secs" _build_live_retry "${initial_args[@]}"

    if [[ "$no_remux" == false ]]; then
        remux_ts_to_mkv "$output_path"
    else
        echo "NoRemux: skipping remux."
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

    case "$CATCHUP_FORMAT_STYLE" in
        query) retry_url="${CATCHUP_URL}?username=${USERNAME}&password=${PASSWORD}&stream=${_catchup_code}&start=${new_encoded_start}&duration=${_catchup_custom_duration}" ;;
        path)  retry_url="${BASE_URL}/timeshift/${USERNAME}/${PASSWORD}/${_catchup_custom_duration}/${new_encoded_start}/${_catchup_code}.ts" ;;
    esac

    _RETRY_FFMPEG_ARGS=("${_CATCHUP_ARGS[@]}" -i "$retry_url")
    (( ss_offset > 0 )) && _RETRY_FFMPEG_ARGS+=(-ss "$ss_offset")
    _RETRY_FFMPEG_ARGS+=(-map "0:v?" -map "0:a?" -t "$remaining" -c copy "$seg_path")
}

record_catchup() {
    local config="" duration_mins="" start_at=""
    local -a channels=()
    local no_remux=false dry_run=false
    _catchup_custom_duration=300

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -config)           config="$2";                          shift 2 ;;
            -channel)          IFS=',' read -ra channels <<< "$2";  shift 2 ;;
            -duration-minutes) duration_mins="$2";                   shift 2 ;;
            -start-at)         start_at="$2";                        shift 2 ;;
            -no-remux)         no_remux=true;                        shift   ;;
            -dry-run)          dry_run=true;                         shift   ;;
            -custom-duration)  _catchup_custom_duration="$2";        shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$config" ]]        || die "-config is required"
    (( ${#channels[@]} > 0 )) || die "-channel is required"
    [[ -n "$duration_mins" ]] || die "-duration-minutes is required"
    [[ -n "$start_at" ]]      || die "-start-at is required (format: yyyy-MM-dd:HH-mm, your local time)"

    load_config "$config"
    for chan in "${channels[@]}"; do
        [[ -v "CHANNEL_MAP[$chan]" ]] || die "Invalid channel '$chan'. Valid: ${!CHANNEL_MAP[*]}"
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
    last_chan="${channels[-1]}"

    for chan in "${channels[@]}"; do
        _catchup_code="${CHANNEL_MAP[$chan]}"
        local output_path="${OUTPUT_DIR}/${chan}_${timestamp}.ts"
        local url

        case "$CATCHUP_FORMAT_STYLE" in
            query) url="${CATCHUP_URL}?username=${USERNAME}&password=${PASSWORD}&stream=${_catchup_code}&start=${encoded_start}&duration=${_catchup_custom_duration}" ;;
            path)  url="${BASE_URL}/timeshift/${USERNAME}/${PASSWORD}/${_catchup_custom_duration}/${encoded_start}/${_catchup_code}.ts" ;;
            *)     die "Unknown CATCHUP_FORMAT_STYLE: $CATCHUP_FORMAT_STYLE" ;;
        esac

        local -a initial_args=(
            "${_CATCHUP_ARGS[@]}"
            -i "$url"
            -map "0:v?" -map "0:a?"
            -t "$duration_secs"
            -c copy "$output_path"
        )

        if [[ "$dry_run" == true ]]; then
            echo ""
            echo "[DryRun] Would run: $FFMPEG_BIN ${initial_args[*]}"
        else
            echo ""
            echo "Catch-up URL: $url"
            echo "Recording $chan (start: $encoded_start) for $duration_mins minute(s)..."
            ffmpeg_with_retry "$output_path" "$duration_secs" _build_catchup_retry "${initial_args[@]}"
            if [[ "$no_remux" == false ]]; then
                remux_ts_to_mkv "$output_path"
            else
                echo "NoRemux: skipping remux."
            fi
        fi

        [[ "$chan" != "$last_chan" ]] && sleep 3
    done
}

# ---------------------------------------------------------------------------
# remove-jobs — remove past IPTV cron entries
# ---------------------------------------------------------------------------

remove_jobs() {
    local current_crontab
    current_crontab="$(crontab -l 2>/dev/null)" || { echo "No crontab entries found."; return; }

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
        echo "No completed IPTV recording jobs to remove."
        return
    fi

    local new_crontab="$current_crontab"
    for line in "${to_remove[@]}"; do
        echo "Removing: $line"
        new_crontab="$(grep -Fv "$line" <<< "$new_crontab" || true)"
    done

    echo "$new_crontab" | crontab -
    echo "${#to_remove[@]} job(s) removed."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  record-live     Record a live stream"
    echo "  record-catchup  Record a catch-up/timeshift stream"
    echo "  remove-jobs     Remove past scheduled IPTV cron entries"
    echo ""
    echo "record-live options:"
    echo "  -config NAME            Provider config name (required)"
    echo "  -channel NAME           Channel name (required)"
    echo "  -duration-minutes N     Recording duration in minutes (required)"
    echo "  -start-at DATETIME      Wait until this local time before recording"
    echo "  -schedule               Add a cron job instead of waiting in the terminal"
    echo "  -no-remux               Keep output as .ts (skip remux to .mkv)"
    echo "  -dry-run                Print the ffmpeg command without running it"
    echo ""
    echo "record-catchup options:"
    echo "  -config NAME            Provider config name (required)"
    echo "  -channel NAME[,NAME...] One or more channel names (required)"
    echo "  -start-at DATETIME      Broadcast start time in your local time (required)"
    echo "  -duration-minutes N     Duration in minutes (required)"
    echo "  -no-remux               Keep output as .ts"
    echo "  -dry-run                Print ffmpeg command without running"
    echo "  -custom-duration N      Timeshift window in seconds (default: 300)"
    echo ""
    echo "DateTime format: yyyy-MM-dd:HH-mm  (e.g. 2026-03-01:20-00)"
}

[[ $# -gt 0 ]] || { usage; exit 1; }

command="$1"; shift
case "$command" in
    record-live)    record_live    "$@" ;;
    record-catchup) record_catchup "$@" ;;
    remove-jobs)    remove_jobs ;;
    help|--help|-h) usage ;;
    *) die "Unknown command '$command'. Run '$0 help' for usage." ;;
esac
