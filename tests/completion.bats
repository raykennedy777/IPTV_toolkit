#!/usr/bin/env bats
# Shell-completion extraction helpers: the config/channel parsers used by the
# bash + zsh completions must return the right names from a fixture, scoped to
# the requested provider, and parse the config with grep/sed/awk (not sourcing).

load helpers/common

setup() {
    # Sourcing the bash completion defines the extraction helpers and registers
    # `complete` (harmless here). Skip on the Linux-suite bash only if needed —
    # the helpers are plain grep/sed/awk and run under both.
    source "$REPO_ROOT/completions/iptv_toolkit.bash"
    CFG="$(fixture iptv_configs.sh)"
}

@test "config extraction lists all providers from the fixture" {
    run _iptv_toolkit_configs "$CFG"
    assert_success
    assert_line "test_query"
    assert_line "test_path"
}

@test "config extraction on a missing file yields nothing (commands/flags only)" {
    run _iptv_toolkit_configs "/no/such/config.sh"
    assert_success
    assert_output ""
}

@test "channel extraction is scoped to the query provider" {
    run _iptv_toolkit_channels "$CFG" test_query
    assert_success
    assert_line "bbc_one"
    assert_line "bbc_two"
    assert_line "itv"
    refute_line "cnn"
    refute_line "fox"
}

@test "channel extraction is scoped to the path provider" {
    run _iptv_toolkit_channels "$CFG" test_path
    assert_success
    assert_line "cnn"
    assert_line "fox"
    refute_line "bbc_one"
}

@test "channel extraction with an unknown provider yields nothing" {
    run _iptv_toolkit_channels "$CFG" nope
    assert_success
    assert_output ""
}

@test "completion offers subcommands at the first position" {
    COMP_WORDS=(iptv_toolkit.sh "")
    COMP_CWORD=1
    _iptv_toolkit_complete
    local joined="${COMPREPLY[*]}"
    [[ "$joined" == *record-live* ]]
    [[ "$joined" == *validate-config* ]]
    [[ "$joined" == *remove-channel* ]]
}

@test "completion offers provider names after -config" {
    export IPTV_CONFIG_FILE="$CFG"
    COMP_WORDS=(iptv_toolkit.sh record-live -config "")
    COMP_CWORD=3
    _iptv_toolkit_complete
    local joined="${COMPREPLY[*]}"
    [[ "$joined" == *test_query* ]]
    [[ "$joined" == *test_path* ]]
}

@test "completion offers channels scoped to the -config on the line" {
    export IPTV_CONFIG_FILE="$CFG"
    COMP_WORDS=(iptv_toolkit.sh record-live -config test_path -channel "")
    COMP_CWORD=5
    _iptv_toolkit_complete
    local joined="${COMPREPLY[*]}"
    [[ "$joined" == *cnn* ]]
    [[ "$joined" == *fox* ]]
    [[ "$joined" != *bbc_one* ]]
}

@test "completion offers per-command flags" {
    COMP_WORDS=(iptv_toolkit.sh check-channels -)
    COMP_CWORD=2
    _iptv_toolkit_complete
    local joined="${COMPREPLY[*]}"
    [[ "$joined" == *-catchup* ]]
    [[ "$joined" == *-config* ]]
}
