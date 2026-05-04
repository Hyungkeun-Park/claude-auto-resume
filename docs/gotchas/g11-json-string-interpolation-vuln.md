# G11: Statusline JSON String Interpolation Vulnerability

**What**: The original statusline wrapper used shell string interpolation to build JSON: `"{\"rate\":${value}}"`. If the parsed value contained unexpected characters, the JSON would be malformed.

**Why it matters**: Malformed `rate-limits.json` would cause all hooks to skip processing (jq parse failure → fallback to 0 → rate < 100% → exit).

**Resolution**: Replaced with `jq -n --argjson` for all JSON construction. jq handles escaping and type validation.
