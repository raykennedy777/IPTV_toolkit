# IPTV Toolkit config — Linux / Synology NAS version
# Copy this file to iptv_configs.sh and fill in your provider details.
# iptv_configs.sh is gitignored — your credentials stay local.

# Directory where recordings are saved
OUTPUT_DIR="$HOME/recordings"

# Optional: override the ffmpeg/ffprobe binaries used by the script.
# Useful on Synology DSM where the newer ffmpeg7 package installs as "ffmpeg7"/"ffprobe7"
# while the system "ffmpeg" is an older version used by other packages.
# Defaults to "ffmpeg" / "ffprobe" if not set.
#FFMPEG_BIN="ffmpeg7"
#FFPROBE_BIN="ffprobe7"

# Each provider is defined as a config_<name>() function.
# Pass the name with -config (e.g. -config myprovider).
#
# All variables set inside the function become available to the main script.

config_myprovider() {
    USERNAME="your_username"
    PASSWORD="your_password"

    # Base URL for live streams (no trailing slash)
    BASE_URL="http://your.provider.url/live"

    # URL for catch-up/timeshift requests
    CATCHUP_URL="http://your.provider.url/streaming/timeshift.php"

    # Set to true if live stream URLs should end in .ts
    ADD_TS_SUFFIX=false

    # Catch-up URL format:
    #   "query" -> CATCHUP_URL?username=...&password=...&stream=ID&start=TIME&duration=SECS
    #   "path"  -> BASE_URL/timeshift/username/password/SECS/TIME/ID.ts
    CATCHUP_FORMAT_STYLE="query"

    # IANA timezone the provider uses for catch-up timestamps.
    # -start-at is entered in your local time and converted to this timezone.
    # List available timezones: python3 -c "import zoneinfo; print(*sorted(zoneinfo.available_timezones()), sep='\n')"
    # Common values: "Europe/Paris", "Europe/Rome", "UTC"
    CATCHUP_TIMEZONE="Europe/Paris"

    # Map of friendly channel names to provider stream IDs
    declare -gA CHANNEL_MAP=(
        ["channel_name_1"]="stream_id_1"
        ["channel_name_2"]="stream_id_2"
    )
}

# Add more providers below, e.g.:
# config_anotherprovider() {
#     USERNAME="..."
#     PASSWORD="..."
#     BASE_URL="http://..."
#     CATCHUP_URL="http://..."
#     ADD_TS_SUFFIX=true
#     CATCHUP_FORMAT_STYLE="path"
#     CATCHUP_TIMEZONE="Europe/Paris"
#     declare -gA CHANNEL_MAP=(
#         ["channel_a"]="12345"
#     )
# }
