#!/usr/bin/env bats
# Channel-map queries under both idioms: the bash-3.2 cm_* string shim (macOS)
# and native associative arrays (Linux, bash 4+).

load helpers/common

setup() {
    source_toolkit
    load_config test_query
}

@test "channel map resolves a known channel to its stream id" {
    if is_mac_script; then
        assert_equal "$(cm_get bbc_one)" "1001"
    else
        assert_equal "${CHANNEL_MAP[bbc_one]}" "1001"
    fi
}

@test "channel map membership: known present, unknown absent" {
    if is_mac_script; then
        cm_has bbc_one
        run cm_has nope
        assert_failure
    else
        # Portable membership check (parses under bash 3.2 too, though this
        # branch only ever runs under bash 4+ against the associative array).
        [[ -n "${CHANNEL_MAP[bbc_one]+x}" ]]
        [[ -z "${CHANNEL_MAP[nope]+x}" ]]
    fi
}

@test "channel map lists all keys for the provider" {
    local keys
    if is_mac_script; then
        keys="$(cm_keys | sort | tr '\n' ' ')"
    else
        keys="$(printf '%s\n' "${!CHANNEL_MAP[@]}" | sort | tr '\n' ' ')"
    fi
    assert_equal "$keys" "bbc_one bbc_two itv "
}

@test "list-channels (black box) prints channels and stream ids" {
    run_toolkit list-channels -config test_query
    assert_success
    assert_output --partial "bbc_one"
    assert_output --partial "1001"
    assert_output --partial "itv"
    assert_output --partial "1003"
}
