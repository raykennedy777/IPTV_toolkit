# Fixture with no OUTPUT_DIR set (top-level) — exercises the OUTPUT_DIR error
# in both validate-config and the fast load-guard. FAKE data only.

config_noout() {
    USERNAME="u"
    PASSWORD="p"
    BASE_URL="http://x.test/live"
    CATCHUP_URL="http://x.test/ts.php"
    ADD_TS_SUFFIX=false
    CATCHUP_FORMAT_STYLE="query"
    CATCHUP_TIMEZONE="Europe/Paris"
    declare -gA CHANNEL_MAP=(
        ["one"]="101"
    )
}
