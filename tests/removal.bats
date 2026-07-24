#!/usr/bin/env bats
# remove-provider / remove-channel: confirm accept/decline, not-found errors,
# file left correct. Operates on a writable copy of the fixture config.

load helpers/common

setup() {
    writable_config "$(fixture iptv_configs.sh)" >/dev/null
    CFG="$IPTV_CONFIG_FILE"
}

@test "remove-channel deletes the entry after y confirmation" {
    run_toolkit_input "y" remove-channel -config test_query -channel bbc_two
    assert_success
    assert_output --partial "Removed channel 'bbc_two'"
    # The key is gone from the file; siblings remain.
    run grep -F '["bbc_two"]' "$CFG"
    assert_failure
    run grep -F '["bbc_one"]' "$CFG"
    assert_success
    run grep -F '["itv"]' "$CFG"
    assert_success
}

@test "remove-channel leaves the file unchanged when declined" {
    local before; before="$(cat "$CFG")"
    run_toolkit_input "n" remove-channel -config test_query -channel itv
    assert_success
    assert_output --partial "Aborted"
    assert_equal "$(cat "$CFG")" "$before"
}

@test "remove-channel leaves the file unchanged on empty (default N) input" {
    local before; before="$(cat "$CFG")"
    run_toolkit_input "" remove-channel -config test_query -channel itv
    assert_success
    assert_output --partial "Aborted"
    assert_equal "$(cat "$CFG")" "$before"
}

@test "remove-channel errors on an unknown channel and lists available" {
    run_toolkit_input "y" remove-channel -config test_query -channel nope
    assert_failure
    assert_output --partial "Channel 'nope' not found"
    assert_output --partial "bbc_one"
}

@test "remove-channel requires -channel" {
    run_toolkit_input "y" remove-channel -config test_query
    assert_failure
    assert_output --partial "-channel is required"
}

@test "remove-provider deletes the whole block after y confirmation" {
    run_toolkit_input "y" remove-provider -config test_path
    assert_success
    assert_output --partial "Removed provider 'test_path'"
    run grep -F 'config_test_path()' "$CFG"
    assert_failure
    # The other provider is untouched.
    run grep -F 'config_test_query()' "$CFG"
    assert_success
}

@test "remove-provider leaves the file unchanged when declined" {
    local before; before="$(cat "$CFG")"
    run_toolkit_input "n" remove-provider -config test_query
    assert_success
    assert_output --partial "Aborted"
    assert_equal "$(cat "$CFG")" "$before"
}

@test "remove-provider errors on an unknown provider and lists available" {
    run_toolkit_input "y" remove-provider -config nope
    assert_failure
    assert_output --partial "Provider 'nope' not found"
    assert_output --partial "test_query"
}

@test "config still validates after removing a provider" {
    run_toolkit_input "y" remove-provider -config test_path
    assert_success
    # Re-run against the same edited file.
    run_toolkit validate-config
    assert_success
    assert_output --partial "validate-config: OK"
}

@test "config still validates after removing a channel" {
    run_toolkit_input "y" remove-channel -config test_query -channel bbc_two
    assert_success
    run_toolkit validate-config -config test_query
    assert_success
    assert_output --partial "[test_query]"
}
