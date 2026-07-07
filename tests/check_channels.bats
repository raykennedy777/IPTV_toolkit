#!/usr/bin/env bats
# check-channels: reachable/unreachable, -catchup URL shape (both styles),
# all-channels default, subset, exit codes. Uses the stubbed ffprobe.

load helpers/common

setup() {
    export TZ=UTC
}

@test "check-channels requires -config" {
    run_toolkit check-channels
    assert_failure
    assert_output --partial "-config is required"
}

@test "check-channels probes all channels live by default and exits 0 when reachable" {
    run_toolkit check-channels -config test_query
    assert_success
    assert_output --partial "bbc_one"
    assert_output --partial "bbc_two"
    assert_output --partial "itv"
    assert_output --partial "OK"
    refute_output --partial "FAIL"
}

@test "check-channels reports resolution and codecs" {
    run_toolkit check-channels -config test_query -channel bbc_one
    assert_success
    assert_output --partial "1920x1080"
    assert_output --partial "h264/aac"
}

@test "check-channels reports the audio track count" {
    export FFPROBE_STUB_ATRACKS=2
    run_toolkit check-channels -config test_query -channel bbc_one
    assert_success
    assert_output --partial "(2a)"
}

@test "check-channels marks unreachable channels FAIL and exits non-zero" {
    export FFPROBE_STUB_UNREACHABLE=1002    # bbc_two stream id
    run_toolkit check-channels -config test_query
    assert_failure
    assert_output --partial "FAIL"
    assert_output --partial "one or more channels failed"
}

@test "check-channels honors an explicit -channel subset" {
    run_toolkit check-channels -config test_query -channel bbc_one,itv
    assert_success
    assert_output --partial "bbc_one"
    assert_output --partial "itv"
    refute_output --partial "bbc_two"
}

@test "check-channels errors on an invalid channel" {
    run_toolkit check-channels -config test_query -channel nope
    assert_failure
    assert_output --partial "Invalid channel 'nope'"
}

@test "check-channels -catchup probes the query-style timeshift URL" {
    export FFPROBE_STUB_LOG="$BATS_TEST_TMPDIR/probe.log"
    run_toolkit check-channels -config test_query -channel bbc_one -catchup
    assert_success
    run grep -F "timeshift.php?username=testuser" "$FFPROBE_STUB_LOG"
    assert_success
    run grep -F "stream=1001" "$FFPROBE_STUB_LOG"
    assert_success
}

@test "check-channels -catchup probes the path-style timeshift URL" {
    export FFPROBE_STUB_LOG="$BATS_TEST_TMPDIR/probe.log"
    run_toolkit check-channels -config test_path -channel cnn -catchup
    assert_success
    run grep -F "/live/timeshift/pathuser/pathpass/60/" "$FFPROBE_STUB_LOG"
    assert_success
}
