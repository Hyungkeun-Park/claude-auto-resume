#!/usr/bin/env bash
# Run all or specific test suites
# Usage: ./tests/run-tests.sh [suite...]
# Examples:
#   ./tests/run-tests.sh                    # all tests
#   ./tests/run-tests.sh stop-hook overuse  # specific suites
#   ./tests/run-tests.sh --smoke            # quick health check
#   ./tests/run-tests.sh --contract         # contract tests only

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_COUNT=0
SUITES_PASS=0
SUITES_FAIL=0
SUITES_SKIP=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SMOKE_SUITES="stop-hook prompt-guard stop-failure lifecycle"
CONTRACT_SUITES="contract"
ALL_SUITES="stop-hook prompt-guard stop-failure multi-session special-chars edge-cases lifecycle overuse subagent-marker stale-cache forward-compat error-recovery hook-registration contract daemon security"

run_suite() {
    local file="$1"
    local name
    name=$(basename "$file" .sh | sed 's/^test-//')
    echo -e "\n${BLUE}══ Running: $name ══${NC}"

    if [ ! -f "$file" ]; then
        echo -e "  ${YELLOW}SKIP${NC}: file not found: $file"
        SUITES_SKIP=$((SUITES_SKIP + 1))
        return 0
    fi

    local output
    output=$(bash "$file" 2>&1)
    local exit_code=$?
    echo "$output"

    # Parse results from the summary line
    local pass fail total
    if echo "$output" | grep -q "PASSED:"; then
        pass=$(echo "$output" | grep "PASSED:" | grep -oP '\d+(?=/)' | tail -1)
        total=$(echo "$output" | grep "PASSED:" | grep -oP '(?<=/)\d+' | tail -1)
        fail=0
    elif echo "$output" | grep -q "FAILED:"; then
        pass=$(echo "$output" | grep "FAILED:" | grep -oP '\d+(?= passed)' | tail -1)
        fail=$(echo "$output" | grep "FAILED:" | grep -oP '\d+(?= failed)' | tail -1)
        total=$(echo "$output" | grep "FAILED:" | grep -oP '(?<=total )\d+' | tail -1)
    else
        pass=0; fail=0; total=0
    fi

    TOTAL_PASS=$((TOTAL_PASS + ${pass:-0}))
    TOTAL_FAIL=$((TOTAL_FAIL + ${fail:-0}))
    TOTAL_COUNT=$((TOTAL_COUNT + ${total:-0}))

    if [ "$exit_code" -eq 0 ]; then
        SUITES_PASS=$((SUITES_PASS + 1))
    else
        SUITES_FAIL=$((SUITES_FAIL + 1))
    fi
}

resolve_suites() {
    local suite_list="$1"
    local files=()
    for suite in $suite_list; do
        local file="$SCRIPT_DIR/test-${suite}.sh"
        files+=("$file")
    done
    echo "${files[@]}"
}

# ── Handle arguments ──
SUITES_TO_RUN=""

if [ $# -eq 0 ]; then
    SUITES_TO_RUN="$ALL_SUITES"
elif [ "$1" = "--smoke" ]; then
    SUITES_TO_RUN="$SMOKE_SUITES"
elif [ "$1" = "--contract" ]; then
    SUITES_TO_RUN="$CONTRACT_SUITES"
elif [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: $0 [suite...] [--smoke] [--contract]"
    echo ""
    echo "Available suites:"
    for s in $ALL_SUITES; do
        echo "  $s"
    done
    echo ""
    echo "Flags:"
    echo "  --smoke     Run quick health check (${SMOKE_SUITES})"
    echo "  --contract  Run contract tests only"
    echo "  --help      Show this help"
    exit 0
else
    SUITES_TO_RUN="$*"
fi

# ── Banner ──
echo "════════════════════════════════════════════════════════════"
echo " Claude Auto-Resume Test Suite"
echo "════════════════════════════════════════════════════════════"
echo -e " Suites: ${BLUE}$(echo "$SUITES_TO_RUN" | wc -w | tr -d ' ')${NC}"
echo ""

# ── Run suites ──
for suite in $SUITES_TO_RUN; do
    file="$SCRIPT_DIR/test-${suite}.sh"
    run_suite "$file"
done

# ── Final summary ──
echo ""
echo "════════════════════════════════════════════════════════════"
echo " FINAL RESULTS"
echo "════════════════════════════════════════════════════════════"
echo -e " Suites: ${GREEN}$SUITES_PASS passed${NC}, ${RED}$SUITES_FAIL failed${NC}, ${YELLOW}$SUITES_SKIP skipped${NC}"
echo -e " Assertions: ${GREEN}$TOTAL_PASS passed${NC}, ${RED}$TOTAL_FAIL failed${NC} (total $TOTAL_COUNT)"
echo "════════════════════════════════════════════════════════════"

[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
