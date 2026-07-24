#!/usr/bin/env bats
# Argument parsing, required-flag validation, and exit codes (black box).

load helpers/common

@test "record-live requires -config" {
    run_toolkit record-live -channel bbc_one -duration-minutes 5
    assert_failure
    assert_output --partial "-config is required"
}

@test "record-live requires -channel" {
    run_toolkit record-live -config test_query -duration-minutes 5
    assert_failure
    assert_output --partial "-channel is required"
}

@test "record-live requires -duration-minutes" {
    run_toolkit record-live -config test_query -channel bbc_one
    assert_failure
    assert_output --partial "-duration-minutes is required"
}

@test "record-live rejects an unknown option" {
    run_toolkit record-live -config test_query -channel bbc_one -duration-minutes 5 -bogus
    assert_failure
    assert_output --partial "Unknown option: -bogus"
}

@test "unknown config name errors" {
    run_toolkit record-live -config nope -channel bbc_one -duration-minutes 5
    assert_failure
    assert_output --partial "Unknown config 'nope'"
}

@test "invalid channel errors and lists valid channels" {
    run_toolkit record-live -config test_query -channel nope -duration-minutes 5
    assert_failure
    assert_output --partial "Invalid channel 'nope'"
}

@test "record-catchup requires -start-at" {
    run_toolkit record-catchup -config test_query -channel bbc_one -duration-minutes 5
    assert_failure
    assert_output --partial "-start-at is required"
}

@test "record-catchup rejects a future start time" {
    run_toolkit record-catchup -config test_query -channel bbc_one -duration-minutes 5 -start-at 2099-01-01:00-00
    assert_failure
    assert_output --partial "must be in the past"
}

@test "no command prints usage and exits non-zero" {
    run_toolkit
    assert_failure
    assert_output --partial "Usage:"
}

@test "help prints usage and exits zero" {
    run_toolkit help
    assert_success
    assert_output --partial "Commands:"
}

@test "unknown command errors" {
    run_toolkit frobnicate
    assert_failure
    assert_output --partial "Unknown command"
}
