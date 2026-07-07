#!/usr/bin/env bats
# validate-config: each error/warning branch, -config vs all, exit codes.

load helpers/common

# Point the toolkit at the deliberately-broken fixture for most tests.
use_invalid() { export IPTV_CONFIG_FILE="$(fixture iptv_configs_invalid.sh)"; }

@test "valid provider reports OK and exits 0" {
    use_invalid
    run_toolkit validate-config -config good
    assert_success
    assert_output --partial "[good]"
    assert_output --partial "OK"
}

@test "missing credentials are hard errors" {
    use_invalid
    run_toolkit validate-config -config missing_creds
    assert_failure
    assert_output --partial "USERNAME is missing or empty"
    assert_output --partial "PASSWORD is missing or empty"
    assert_output --partial "BASE_URL is missing or empty"
}

@test "invalid CATCHUP_FORMAT_STYLE is a hard error" {
    use_invalid
    run_toolkit validate-config -config bad_style
    assert_failure
    assert_output --partial "CATCHUP_FORMAT_STYLE must be 'query' or 'path'"
}

@test "invalid IANA timezone is a hard error" {
    use_invalid
    run_toolkit validate-config -config bad_tz
    assert_failure
    assert_output --partial "is not a valid IANA timezone"
}

@test "empty CHANNEL_MAP is a hard error" {
    use_invalid
    run_toolkit validate-config -config empty_map
    assert_failure
    assert_output --partial "CHANNEL_MAP is empty"
}

@test "empty stream ID is a hard error" {
    use_invalid
    run_toolkit validate-config -config empty_streamid
    assert_failure
    assert_output --partial "channel 'blank' has an empty stream ID"
}

@test "duplicate CHANNEL_MAP keys are a hard error" {
    use_invalid
    run_toolkit validate-config -config dupkey
    assert_failure
    assert_output --partial "duplicate CHANNEL_MAP key(s): dup"
}

@test "OUTPUT_DIR unset is a hard error" {
    export IPTV_CONFIG_FILE="$(fixture iptv_configs_no_output.sh)"
    run_toolkit validate-config -config noout
    assert_failure
    assert_output --partial "OUTPUT_DIR is not set"
}

@test "warnings-only provider exits 0" {
    use_invalid
    run_toolkit validate-config -config warnings
    assert_success
    assert_output --partial "CATCHUP_URL is empty but CATCHUP_FORMAT_STYLE=query"
    assert_output --partial "BASE_URL has a trailing slash"
    assert_output --partial "not normalized"
}

@test "unresolvable ffmpeg/ffprobe binaries are warnings" {
    use_invalid
    run_toolkit validate-config -config bad_ffmpeg
    assert_success
    assert_output --partial "ffmpeg binary 'ffmpeg_definitely_missing_xyz' not resolvable"
    assert_output --partial "ffprobe binary 'ffprobe_definitely_missing_xyz' not resolvable"
}

@test "validate-config with no -config validates all providers and fails if any error" {
    use_invalid
    run_toolkit validate-config
    assert_failure
    assert_output --partial "[good]"
    assert_output --partial "[missing_creds]"
    assert_output --partial "FAILED"
}

@test "validate-config on the valid fixture passes for all providers" {
    run_toolkit validate-config
    assert_success
    assert_output --partial "[test_query]"
    assert_output --partial "[test_path]"
    assert_output --partial "validate-config: OK"
}

@test "validate-config on an unknown -config errors" {
    run_toolkit validate-config -config nope
    assert_failure
    assert_output --partial "Unknown config 'nope'"
}

@test "fast load-guard blocks record-live on an invalid provider" {
    use_invalid
    run_toolkit record-live -config missing_creds -channel one -duration-minutes 5 -dry-run
    assert_failure
    assert_output --partial "is invalid"
    assert_output --partial "USERNAME is empty"
}
