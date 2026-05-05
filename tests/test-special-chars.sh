#!/usr/bin/env bash
# Special Characters in Prompt tests (T21-T26)
source "$(cd "$(dirname "$0")" && pwd)/test-framework.sh"

echo "════════════════════════════════════════════════════════"
echo " Special Characters in Prompt Tests (T21-T26)"
echo "════════════════════════════════════════════════════════"

# ─── T21: Double quotes in prompt ───────────────────────────────────────────
setup_test "T21_prompt_double_quotes"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-021" "$TEST_CWD" 'say "hello world"')")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-021)" '.prompt' 'say "hello world"'

# ─── T22: Single quotes in prompt ──────────────────────────────────────────
setup_test "T22_prompt_single_quotes"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-022" "$TEST_CWD" "it's a test")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-022)" '.prompt' "it's a test"

# ─── T23: Backslashes in prompt ────────────────────────────────────────────
setup_test "T23_prompt_backslash"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-023" "$TEST_CWD" 'c:\users\test')")
assert_exit_code "$EXIT" 0
TOTAL=$((TOTAL + 1))
ACTUAL=$(jq -r '.prompt' "$(resume_file_for sess-023)" 2>/dev/null)
if [ "$ACTUAL" = 'c:\users\test' ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC}: backslash prompt = '$ACTUAL'"; fi

# ─── T24: Newlines in prompt ───────────────────────────────────────────────
setup_test "T24_prompt_newline"
write_cache 100 57
PROMPT_NL=$(printf 'line1\nline2')
EXIT=$(run_prompt_guard "$(make_hook_input "sess-024" "$TEST_CWD" "$PROMPT_NL")")
assert_exit_code "$EXIT" 0
SAVED=$(jq -r '.prompt' "$(resume_file_for sess-024)")
if echo "$SAVED" | grep -q "line1"; then
    TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
else
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: newline prompt not preserved"
fi

# ─── T25: Korean text in prompt ────────────────────────────────────────────
setup_test "T25_prompt_korean"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-025" "$TEST_CWD" "한국어 테스트 프롬프트")")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-025)" '.prompt' "한국어 테스트 프롬프트"

# ─── T26: JSON-in-prompt ───────────────────────────────────────────────────
setup_test "T26_prompt_json"
write_cache 100 57
EXIT=$(run_prompt_guard "$(make_hook_input "sess-026" "$TEST_CWD" '{"key": "value", "num": 42}')")
assert_exit_code "$EXIT" 0
assert_json_field "$(resume_file_for sess-026)" '.prompt' '{"key": "value", "num": 42}'

print_summary "Special Characters in Prompt"
