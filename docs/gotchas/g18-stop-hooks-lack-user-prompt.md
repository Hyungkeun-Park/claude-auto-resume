# G18: Stop/StopFailure Hooks Lack User Prompt

**What**: Stop and StopFailure hooks receive `session_id` and `cwd` in hook input but NOT the user's original prompt. When creating a new resume file, they used a hardcoded generic prompt ("re-launch agents..."). If rate limit hit 100% mid-conversation (not at prompt submission time), the UPS hook had already exited early (rate < 100%), so the user's prompt was never saved anywhere.

**Why it matters**: The resumed session received a generic "re-launch agents" prompt instead of the user's actual task (e.g., "@NEXT-STEPS.md 을 참고해서 다음 스텝들을 끝날때까지 진행해줘"). This caused the resumed session to lose context about what the user was working on.

**Resolution**: UPS now always saves the user prompt to a side file (`prompts/<session-id>.prompt`) regardless of rate status — the prompt is saved before the rate gate. Stop/StopFailure hooks read this side file when creating or updating resume files. Subagent marker presence determines prompt selection:
- No markers → use saved user prompt (direct user task interrupted)
- Markers exist → use fixed prompt (subagent relaunch needed)

Cleanup: Stop hook deletes the prompt side file on rate recovery (rate < 100%).

**Files modified**: `rate-limit-prompt-guard.sh`, `rate-limit-stop.sh`, `rate-limit-stop-failure.sh`, `lib-resume-file.sh`
