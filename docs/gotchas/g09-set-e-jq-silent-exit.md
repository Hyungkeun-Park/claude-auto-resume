# G9: `set -euo pipefail` + jq on Invalid JSON = Silent Exit

**What**: Under `set -e`, if jq fails to parse corrupted JSON, the script exits immediately with no error message. The hook silently disappears, and no schedule is created or updated.

**Why it matters**: A single corrupted state file could silently disable auto-resume for that session.

**Resolution**: Every jq read uses `jq ... 2>/dev/null || echo ""` (or `|| echo "0"` for numeric fields). This ensures the script continues even on corrupted input. The fallback values cause the hook to fall through to the "create new file" path.
