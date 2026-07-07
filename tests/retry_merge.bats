#!/usr/bin/env bats
# Retry / segment-stitching path, exercised through the ffmpeg/ffprobe stubs.

load helpers/common

@test "record-live retries and concatenates when segments fall short" {
    export TZ=UTC
    export FFPROBE_STUB_DURATION=60          # each segment "achieves" only 60s
    export FFMPEG_STUB_LOG="$BATS_TEST_TMPDIR/ffmpeg.log"

    # 5-minute target at 60s/segment forces several recording attempts + a concat.
    run_toolkit record-live -config test_query -channel bbc_one -duration-minutes 5 -no-remux
    assert_success

    assert [ -f "$FFMPEG_STUB_LOG" ]

    # Multiple recording invocations (each has the live URL as its -i input).
    run grep -c -- "-i http://provider.test" "$FFMPEG_STUB_LOG"
    assert [ "$output" -ge 2 ]

    # A final concat/merge pass stitches the segments together.
    run grep -F -- "-f concat -safe 0" "$FFMPEG_STUB_LOG"
    assert_success
}

@test "record-live single segment: no concat when the first attempt reaches target" {
    export TZ=UTC
    export FFPROBE_STUB_DURATION=300         # first segment already meets the 5-min target
    export FFMPEG_STUB_LOG="$BATS_TEST_TMPDIR/ffmpeg.log"

    run_toolkit record-live -config test_query -channel bbc_one -duration-minutes 5 -no-remux
    assert_success

    run grep -c -- "-i http://provider.test" "$FFMPEG_STUB_LOG"
    assert_equal "$output" "1"

    run grep -cF -- "-f concat" "$FFMPEG_STUB_LOG"
    assert_equal "$output" "0"
}
