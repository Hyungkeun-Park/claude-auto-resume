# G15: Resume Metadata Absence

**What**: When a session was auto-resumed, there was no indication within the session itself that it had been resumed, or how long it waited.

**Why it matters**: The model (and user reviewing transcripts) couldn't distinguish a manual resume from an auto-resume, making debugging and behavior tuning harder.

**Resolution**: The daemon prepends `[Auto-resumed after {N}m wait for rate limit recovery]` to the prompt. This appears in the session transcript and gives the model context about the gap.
