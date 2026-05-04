# G8: jq `//` Operator Does Not Catch `false`

**What**: In jq, `false // "default"` returns `"default"`, not `false`. The `//` (alternative) operator treats both `null` and `false` as "empty".

**Why it matters**: If a JSON field is legitimately `false` (e.g., an `overage` boolean), `jq -r '.overage // "unknown"'` would return `"unknown"` instead of `"false"`.

**Resolution**: Use explicit `if .field == false then "false" else (.field // "default") end` for boolean fields. In practice, the v4 design avoids boolean fields in state files entirely, using numeric `created_at_rate` and string `source` instead.
