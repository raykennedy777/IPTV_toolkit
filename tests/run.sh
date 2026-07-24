#!/usr/bin/env bash
# Test runner for the IPTV toolkit bats suite. No system install required —
# bats-core and its support libs are vendored under tests/vendor.
#
# Runs the suite twice, once per implementation:
#   - macOS suite  under system bash 3.2 (exercises the cm_* string-shim path)
#   - Linux suite  under bash 4+          (exercises the associative-array path)
#
# The Linux suite is skipped (with a clear message) when no bash 4+ is found,
# since iptv_toolkit.sh uses bash-4-only syntax that will not even parse under
# bash 3.2. Point IPTV_BASH4 at a bash 4+ binary to force it.
#
# Usage:
#   tests/run.sh                 # both suites (Linux skipped if no bash 4+)
#   tests/run.sh path/to.bats    # run specific file(s)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BATS="$REPO_ROOT/tests/vendor/bats-core/bin/bats"

# Test files: explicit args, else every *.bats under tests/
if (( $# > 0 )); then
    TEST_TARGETS=("$@")
else
    TEST_TARGETS=("$REPO_ROOT/tests"/*.bats)
fi

# Find a bash 4+ interpreter for the Linux suite.
find_bash4() {
    local candidates=(
        "${IPTV_BASH4:-}"
        /opt/homebrew/bin/bash
        /usr/local/bin/bash
        /usr/bin/bash
    )
    local b major
    for b in "${candidates[@]}"; do
        [[ -n "$b" && -x "$b" ]] || continue
        major="$("$b" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
        if (( major >= 4 )); then
            printf '%s' "$b"
            return 0
        fi
    done
    return 1
}

status=0

echo "=================================================================="
echo " macOS suite — iptv_toolkit_mac.sh under system bash 3.2 (shim)"
echo "=================================================================="
IPTV_SCRIPT="iptv_toolkit_mac.sh" IPTV_BASH="/bin/bash" \
    /bin/bash "$BATS" "${TEST_TARGETS[@]}" || status=1

echo
if bash4="$(find_bash4)"; then
    echo "=================================================================="
    echo " Linux suite — iptv_toolkit.sh under $bash4 (assoc arrays)"
    echo "=================================================================="
    IPTV_SCRIPT="iptv_toolkit.sh" IPTV_BASH="$bash4" \
        "$bash4" "$BATS" "${TEST_TARGETS[@]}" || status=1
else
    echo "=================================================================="
    echo " Linux suite — SKIPPED: no bash 4+ found."
    echo "   iptv_toolkit.sh uses bash-4-only syntax and cannot run under"
    echo "   bash 3.2. Install one (e.g. 'brew install bash') or set"
    echo "   IPTV_BASH4=/path/to/bash4 to run the Linux suite."
    echo "=================================================================="
fi

exit "$status"
