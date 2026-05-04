# Gotchas

Edge cases and non-obvious behaviors discovered during development. Each entry explains what happened, why it was surprising, and how it was resolved.

| # | File | Summary |
|---|------|---------|
| G1 | [g01-client-blocks-after-hooks](gotchas/g01-client-blocks-after-hooks.md) | Client-side rate limiter fires after hooks, before API — schedule must exist before block |
| G2 | [g02-stop-failure-only-on-api-errors](gotchas/g02-stop-failure-only-on-api-errors.md) | StopFailure fires on API 429 only, not client blocks — it's a fallback, not primary path |
| G3 | [g03-overuse-hooks-fire-normally](gotchas/g03-overuse-hooks-fire-normally.md) | Overuse mode: hooks fire at 100% but session continues — needs `created_at_rate` detection |
| G4 | [g04-ralph-loop-bypasses-user-prompt](gotchas/g04-ralph-loop-bypasses-user-prompt.md) | Ralph loop skips UserPromptSubmit — Stop must handle overuse detection independently |
| G5 | [g05-subagent-stop-not-overuse-evidence](gotchas/g05-subagent-stop-not-overuse-evidence.md) | Parallel SubagentStop ≠ overuse — only Stop triggers overuse detection |
| G6 | [g06-stop-failure-must-lock-overuse](gotchas/g06-stop-failure-must-lock-overuse.md) | StopFailure sets `source: stop_failure` to lock schedule against false overuse deletion |
| G7 | [g07-pgrep-self-matching](gotchas/g07-pgrep-self-matching.md) | Daemon matches itself via pgrep — use `pgrep -x claude` + `ps -o args=` |
| G8 | [g08-jq-alternative-operator-false](gotchas/g08-jq-alternative-operator-false.md) | jq `//` treats `false` as empty — avoid boolean fields in state files |
| G9 | [g09-set-e-jq-silent-exit](gotchas/g09-set-e-jq-silent-exit.md) | `set -e` + jq failure = silent exit — always use `\|\| echo ""` fallback |
| G10 | [g10-stop-stopfailure-toctou-race](gotchas/g10-stop-stopfailure-toctou-race.md) | Stop/StopFailure race on source field — TOCTOU re-read before deletion |
| G11 | [g11-json-string-interpolation-vuln](gotchas/g11-json-string-interpolation-vuln.md) | Shell string interpolation → malformed JSON — use `jq -n --argjson` |
| G12 | [g12-active-session-kill-danger](gotchas/g12-active-session-kill-danger.md) | Killing active session loses user work — skip instead of kill |
| G13 | [g13-daemon-unbounded-blocking](gotchas/g13-daemon-unbounded-blocking.md) | `claude -p --resume` can hang forever — wrap with `timeout 3600` |
| G14 | [g14-shell-profile-dependency](gotchas/g14-shell-profile-dependency.md) | Shell profile not available in nohup — use explicit `find_claude_bin()` |
| G15 | [g15-resume-metadata-absence](gotchas/g15-resume-metadata-absence.md) | Auto-resumed session had no context — prepend wait-time metadata to prompt |
| G16 | [g16-stale-cache-subagent-overuse-false-positive](gotchas/g16-stale-cache-subagent-overuse-false-positive.md) | Stale cache + overuse false positive defeats subagent auto-resume — marker tracking via SubagentStart |

## Adding New Gotchas

Create a new file in `docs/gotchas/` following the naming pattern `g{NN}-{short-description}.md`:

```markdown
# G{N}: {Short Title}

**What**: {What happened or what the behavior is}

**Why it matters**: {Why this is surprising or what breaks without handling it}

**Resolution**: {How it was fixed}
```

Number sequentially. Update this index. Reference the relevant source file and line numbers if helpful.
