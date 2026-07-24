# Deliberately-broken fixture config for validate-config tests. FAKE data only.
# Each provider exercises a specific error or warning branch.

OUTPUT_DIR="${IPTV_TEST_OUTPUT_DIR:-/tmp/iptv_test_out}"

# Fully valid provider (control / "OK" case).
config_good() {
    USERNAME="u"
    PASSWORD="p"
    BASE_URL="http://ok.test/live"
    CATCHUP_URL="http://ok.test/timeshift.php"
    ADD_TS_SUFFIX=false
    CATCHUP_FORMAT_STYLE="query"
    CATCHUP_TIMEZONE="Europe/Paris"
    declare -gA CHANNEL_MAP=(
        ["one"]="101"
        ["two"]="102"
    )
}

# Missing credentials (USERNAME/PASSWORD/BASE_URL empty).
config_missing_creds() {
    USERNAME=""
    PASSWORD=""
    BASE_URL=""
    CATCHUP_URL="http://x.test/ts.php"
    ADD_TS_SUFFIX=false
    CATCHUP_FORMAT_STYLE="query"
    CATCHUP_TIMEZONE="Europe/Paris"
    declare -gA CHANNEL_MAP=(
        ["one"]="101"
    )
}

# Invalid CATCHUP_FORMAT_STYLE.
config_bad_style() {
    USERNAME="u"
    PASSWORD="p"
    BASE_URL="http://x.test/live"
    CATCHUP_URL="http://x.test/ts.php"
    ADD_TS_SUFFIX=false
    CATCHUP_FORMAT_STYLE="sideways"
    CATCHUP_TIMEZONE="Europe/Paris"
    declare -gA CHANNEL_MAP=(
        ["one"]="101"
    )
}

# Invalid IANA timezone.
config_bad_tz() {
    USERNAME="u"
    PASSWORD="p"
    BASE_URL="http://x.test/live"
    CATCHUP_URL="http://x.test/ts.php"
    ADD_TS_SUFFIX=false
    CATCHUP_FORMAT_STYLE="query"
    CATCHUP_TIMEZONE="Mars/Olympus_Mons"
    declare -gA CHANNEL_MAP=(
        ["one"]="101"
    )
}

# Empty CHANNEL_MAP.
config_empty_map() {
    USERNAME="u"
    PASSWORD="p"
    BASE_URL="http://x.test/live"
    CATCHUP_URL="http://x.test/ts.php"
    ADD_TS_SUFFIX=false
    CATCHUP_FORMAT_STYLE="query"
    CATCHUP_TIMEZONE="Europe/Paris"
    declare -gA CHANNEL_MAP=(
    )
}

# A channel with an empty stream ID.
config_empty_streamid() {
    USERNAME="u"
    PASSWORD="p"
    BASE_URL="http://x.test/live"
    CATCHUP_URL="http://x.test/ts.php"
    ADD_TS_SUFFIX=false
    CATCHUP_FORMAT_STYLE="query"
    CATCHUP_TIMEZONE="Europe/Paris"
    declare -gA CHANNEL_MAP=(
        ["good"]="101"
        ["blank"]=""
    )
}

# Duplicate CHANNEL_MAP keys (detected from the config text).
config_dupkey() {
    USERNAME="u"
    PASSWORD="p"
    BASE_URL="http://x.test/live"
    CATCHUP_URL="http://x.test/ts.php"
    ADD_TS_SUFFIX=false
    CATCHUP_FORMAT_STYLE="query"
    CATCHUP_TIMEZONE="Europe/Paris"
    declare -gA CHANNEL_MAP=(
        ["dup"]="101"
        ["dup"]="102"
        ["unique"]="103"
    )
}

# Warnings only (should still exit 0 when validated alone): query style with an
# empty CATCHUP_URL, a trailing-slash BASE_URL, and a non-normalized key.
config_warnings() {
    USERNAME="u"
    PASSWORD="p"
    BASE_URL="http://warn.test/live/"
    CATCHUP_URL=""
    ADD_TS_SUFFIX=false
    CATCHUP_FORMAT_STYLE="query"
    CATCHUP_TIMEZONE="Europe/Paris"
    declare -gA CHANNEL_MAP=(
        ["Not Normalized"]="201"
    )
}

# A per-provider ffmpeg binary that does not exist (resolvability warning).
config_bad_ffmpeg() {
    USERNAME="u"
    PASSWORD="p"
    BASE_URL="http://x.test/live"
    CATCHUP_URL="http://x.test/ts.php"
    ADD_TS_SUFFIX=false
    CATCHUP_FORMAT_STYLE="query"
    CATCHUP_TIMEZONE="Europe/Paris"
    FFMPEG_BIN="ffmpeg_definitely_missing_xyz"
    FFPROBE_BIN="ffprobe_definitely_missing_xyz"
    declare -gA CHANNEL_MAP=(
        ["one"]="101"
    )
}
