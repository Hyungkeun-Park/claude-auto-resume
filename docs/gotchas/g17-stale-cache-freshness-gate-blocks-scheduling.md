# G17: Stale Cache Freshness Gate Blocks Scheduling at 100%

**What**: When overuse turns off and the client-side rate limiter blocks the prompt, the statusline stops updating (no API calls = no new headers). The rate cache becomes stale (>5 minutes old), and all three hooks (Stop, UserPromptSubmit, StopFailure) exit silently at the freshness check — even though the cached rate is ≥100%.

**Why it matters**: This completely defeats auto-resume in the overuse→block transition scenario. The user is rate-limited, but no schedule is created because the hooks don't trust the "stale" cache — despite the fact that rate percentages can only decrease (reset downward), never increase without API calls.

**Observed production sequence**:
```
Overuse active:  cache=101%, hooks fire, overuse detection deletes schedules (correct)
Overuse turns off: client blocks → no API calls → statusline stops updating
Next prompt:     cache=101% (10min old) → freshness check → exit 0 → NO schedule created
```

**Root cause**: The freshness check was unconditional — `cache_age > 300 → exit 0` — without considering what the cached rate value was. A stale cache showing ≥100% is actually trustworthy for scheduling because rate only resets downward.

**Resolution (v1.2.1)**: Combined freshness + rate gate in all three hooks. The freshness check now only exits when BOTH conditions are true: cache is stale AND rate is below 100%.

```bash
# Before (buggy): unconditional exit on stale cache
[ $((NOW - LAST_UPDATED)) -gt 300 ] && exit 0

# After (fixed): rate data read first, then combined gate
if [ "$CACHE_AGE" -gt 300 ] && [ "$FIVE_INT" -lt 100 ] && [ "$SEVEN_INT" -lt 100 ]; then
    exit 0
fi
```

**Trade-off**: A stale cache at ≥100% might be wrong (rate could have recovered while cache was stale). Creating a schedule in that case is a false positive — but the Stop hook will detect rate recovery and clean it up. Not creating a schedule when the rate is actually at limit is a false negative that defeats the feature entirely. False positives are harmless; false negatives are fatal.

**Affected hooks**: `rate-limit-prompt-guard.sh`, `rate-limit-stop.sh`, `rate-limit-stop-failure.sh`

**Test cases**: T05, T11, T17 (updated), T67-T72 (new)
