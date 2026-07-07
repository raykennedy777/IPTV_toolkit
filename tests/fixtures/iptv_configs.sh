# Test fixture config for the IPTV toolkit bats suite.
# FAKE credentials only. Loaded via IPTV_CONFIG_FILE — never the real config.
# Uses the shared bash-4 associative-array format so both scripts consume it
# (the macOS script rewrites `declare -gA CHANNEL_MAP` on the fly under bash 3.2).

OUTPUT_DIR="${IPTV_TEST_OUTPUT_DIR:-/tmp/iptv_test_out}"

# Query-style catch-up provider.
config_test_query() {
    USERNAME="testuser"
    PASSWORD="testpass"
    BASE_URL="http://provider.test/live"
    CATCHUP_URL="http://provider.test/streaming/timeshift.php"
    ADD_TS_SUFFIX=false
    CATCHUP_FORMAT_STYLE="query"
    CATCHUP_TIMEZONE="Europe/Paris"
    declare -gA CHANNEL_MAP=(
        ["bbc_one"]="1001"
        ["bbc_two"]="1002"
        ["itv"]="1003"
    )
}

# Path-style catch-up provider, with the .ts suffix on live URLs.
config_test_path() {
    USERNAME="pathuser"
    PASSWORD="pathpass"
    BASE_URL="http://path.test/live"
    CATCHUP_URL=""
    ADD_TS_SUFFIX=true
    CATCHUP_FORMAT_STYLE="path"
    CATCHUP_TIMEZONE="America/New_York"
    declare -gA CHANNEL_MAP=(
        ["cnn"]="2001"
        ["fox"]="2002"
    )
}
