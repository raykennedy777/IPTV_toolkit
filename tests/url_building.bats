#!/usr/bin/env bats
# Black-box tests: invoke the script with -dry-run and assert the emitted
# ffmpeg command + URL for both catch-up styles.

load helpers/common

setup() {
    export TZ=UTC          # deterministic timezone conversion
}

@test "record-live query style builds the live URL (no .ts suffix)" {
    run_toolkit record-live -config test_query -channel bbc_one -duration-minutes 5 -dry-run
    assert_success
    assert_output --partial "-i http://provider.test/live/testuser/testpass/1001 -map 0:v? -map 0:a:0 -t 300 -c copy"
}

@test "record-live path style adds .ts suffix; -first-audio-only maps audio only" {
    run_toolkit record-live -config test_path -channel cnn -duration-minutes 5 -dry-run -first-audio-only
    assert_success
    assert_output --partial "-i http://path.test/live/pathuser/pathpass/2001.ts -map 0:a:0 -t 300 -c copy"
}

@test "record-catchup query style builds the timeshift.php URL in provider tz" {
    run_toolkit record-catchup -config test_query -channel bbc_one -start-at 2026-07-01:12-00 -duration-minutes 5 -dry-run
    assert_success
    assert_output --partial "-i http://provider.test/streaming/timeshift.php?username=testuser&password=testpass&stream=1001&start=2026-07-01:14-00&duration=300"
}

@test "record-catchup path style builds the /timeshift/ URL in provider tz" {
    run_toolkit record-catchup -config test_path -channel cnn -start-at 2026-07-01:12-00 -duration-minutes 5 -dry-run
    assert_success
    # test_path uses America/New_York: 12:00 UTC -> 08:00 EDT (summer)
    assert_output --partial "-i http://path.test/live/timeshift/pathuser/pathpass/300/2026-07-01:08-00/2001.ts"
}

@test "record-catchup honors -custom-duration in the built URL" {
    run_toolkit record-catchup -config test_query -channel bbc_one -start-at 2026-07-01:12-00 -duration-minutes 5 -custom-duration 600 -dry-run
    assert_success
    assert_output --partial "stream=1001&start=2026-07-01:14-00&duration=600"
}

@test "record-live output file name ends with the config name" {
    run_toolkit record-live -config test_query -channel bbc_one -duration-minutes 5 -dry-run
    assert_success
    assert_output --regexp "/bbc_one_[0-9]{8}_[0-9]{4}_test_query\\.ts"
}

@test "record-catchup output file name ends with the config name" {
    run_toolkit record-catchup -config test_path -channel cnn -start-at 2026-07-01:12-00 -duration-minutes 5 -dry-run
    assert_success
    assert_output --regexp "/cnn_[0-9]{8}_[0-9]{4}_test_path\\.ts"
}
