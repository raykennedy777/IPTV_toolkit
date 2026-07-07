#!/usr/bin/env bats
# Unit tests for the pure helper functions (sourced directly).

load helpers/common

setup() {
    source_toolkit
    export TZ=UTC          # make local-time conversions deterministic
}

@test "_normalize_channel_name lowercases, maps spaces to _, strips punctuation" {
    run _normalize_channel_name "BBC One!"
    assert_success
    assert_output "bbc_one"
}

@test "_normalize_channel_name handles mixed case and extra tokens" {
    run _normalize_channel_name "ITV 4 HD"
    assert_output "itv_4_hd"
}

@test "parse_start_to_epoch converts local (TZ=UTC) datetime to epoch" {
    run parse_start_to_epoch "2025-01-01:00-00"
    assert_output "1735689600"
}

@test "convert_to_provider_tz: local UTC to Paris winter (UTC+1)" {
    run convert_to_provider_tz "2025-01-01:00-00" "Europe/Paris"
    assert_output "2025-01-01:01-00"
}

@test "convert_to_provider_tz: DST spring-forward edge (Paris)" {
    # 2025-03-30 01:00 UTC is when EU DST starts (02:00->03:00 local).
    run convert_to_provider_tz "2025-03-30:01-30" "Europe/Paris"
    assert_output "2025-03-30:03-30"
}

@test "epoch_to_provider_tz: Paris winter (UTC+1)" {
    run epoch_to_provider_tz 1735689600 "Europe/Paris"
    assert_output "2025-01-01:01-00"
}

@test "epoch_to_provider_tz: Paris summer / DST (UTC+2)" {
    run epoch_to_provider_tz 1751328000 "Europe/Paris"
    assert_output "2025-07-01:02-00"
}

@test "epoch_to_provider_tz: America/New_York winter (UTC-5)" {
    run epoch_to_provider_tz 1735689600 "America/New_York"
    assert_output "2024-12-31:19-00"
}

@test "measure_duration reports the probed stream duration" {
    local f="$BATS_TEST_TMPDIR/seg.ts"
    printf 'x' > "$f"
    printf '123' > "$f.dur"     # sidecar the fake ffprobe reads
    run measure_duration "$f"
    assert_success
    assert_output "123"
}

@test "measure_duration falls back to a default when no duration is available" {
    local f="$BATS_TEST_TMPDIR/x.ts"
    printf 'x' > "$f"
    run measure_duration "$f"
    assert_output "300"
}
