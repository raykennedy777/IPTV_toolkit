# Common setup for the IPTV toolkit bats suite.
#
# Sourced (via `load`) by every .bats file. Provides:
#   - path variables (REPO_ROOT, TOOLKIT, FIXTURE_CONFIG, stubs)
#   - bats-support / bats-assert
#   - source_toolkit  — source the script under test for unit tests (no dispatch)
#   - run_toolkit     — invoke the script as a subprocess for black-box tests
#
# The script under test is selected by $IPTV_SCRIPT (set by tests/run.sh):
#   iptv_toolkit_mac.sh  -> run under bash 3.2 (cm_* string-shim path)
#   iptv_toolkit.sh      -> run under bash 4+  (associative-array path)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

IPTV_SCRIPT="${IPTV_SCRIPT:-iptv_toolkit_mac.sh}"
TOOLKIT="$REPO_ROOT/$IPTV_SCRIPT"

FIXTURE_CONFIG="$REPO_ROOT/tests/fixtures/iptv_configs.sh"
STUBS_DIR="$REPO_ROOT/tests/stubs"

# The bash used to launch the script as a subprocess (matches the suite's bash).
IPTV_BASH="${IPTV_BASH:-bash}"

load "$REPO_ROOT/tests/vendor/bats-support/load"
load "$REPO_ROOT/tests/vendor/bats-assert/load"

# Prepend the ffmpeg/ffprobe stubs to PATH for the current (unit) process.
setup_stubs() {
    PATH="$STUBS_DIR:$PATH"
    export PATH
}

# Whether the script under test is the macOS (bash 3.2 shim) variant.
is_mac_script() {
    [[ "$IPTV_SCRIPT" == "iptv_toolkit_mac.sh" ]]
}

# Source the toolkit for unit testing. The main-guard means sourcing only
# defines functions (no dispatch). Points config at the fixture and loads the
# provider definitions so cm_*/CHANNEL_MAP helpers are usable.
source_toolkit() {
    export IPTV_CONFIG_FILE="${IPTV_CONFIG_FILE:-$FIXTURE_CONFIG}"
    export IPTV_TEST_OUTPUT_DIR="${BATS_TEST_TMPDIR:-/tmp}/iptv_out"
    setup_stubs
    # shellcheck disable=SC1090
    source "$TOOLKIT"
    # Load provider function definitions from the fixture ("list-channels" is any
    # non-setup-config command, so _bootstrap sources the config).
    _bootstrap list-channels
}

# Run the toolkit as a subprocess (black-box). Stubs on PATH, fixture config,
# output/log dirs redirected into the per-test temp dir.
run_toolkit() {
    run env \
        IPTV_CONFIG_FILE="${IPTV_CONFIG_FILE:-$FIXTURE_CONFIG}" \
        IPTV_TEST_OUTPUT_DIR="${BATS_TEST_TMPDIR:-/tmp}/iptv_out" \
        PATH="$STUBS_DIR:$PATH" \
        "$IPTV_BASH" "$TOOLKIT" "$@"
}

# Path to a named fixture file under tests/fixtures.
fixture() {
    printf '%s' "$REPO_ROOT/tests/fixtures/$1"
}

# Like run_toolkit, but feeds the first argument to the command's stdin (for
# interactive [y/N] confirmations). Remaining args are the toolkit args.
run_toolkit_input() {
    local input="$1"; shift
    run env \
        IPTV_CONFIG_FILE="${IPTV_CONFIG_FILE:-$FIXTURE_CONFIG}" \
        IPTV_TEST_OUTPUT_DIR="${BATS_TEST_TMPDIR:-/tmp}/iptv_out" \
        PATH="$STUBS_DIR:$PATH" \
        "$IPTV_BASH" "$TOOLKIT" "$@" <<< "$input"
}

# Copy a fixture into the per-test temp dir and point IPTV_CONFIG_FILE at the
# copy, so in-place edits (remove-provider/remove-channel) don't touch the
# committed fixtures. Echoes the copy path.
writable_config() {
    local src="$1" dst="${BATS_TEST_TMPDIR}/config_under_test.sh"
    cp "$src" "$dst"
    export IPTV_CONFIG_FILE="$dst"
    printf '%s' "$dst"
}
