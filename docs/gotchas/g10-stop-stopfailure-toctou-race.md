# G10: Race Window Between Stop and StopFailure (TOCTOU)

**What**: Stop and StopFailure can both read the same state file. If Stop reads `source=user_prompt`, then StopFailure writes `source=stop_failure`, then Stop deletes based on its stale read — the lock is defeated.

**Why it matters**: A genuine API error could have its schedule incorrectly classified as overuse and deleted.

**Resolution**: Stop re-reads the `source` field immediately before deletion (TOCTOU guard). If the re-read shows `stop_failure`, the deletion is aborted. The window is now reduced to the time between the re-read and the `rm` — effectively negligible.

**Practical risk**: Very low. Claude hooks fire sequentially within a session's event lifecycle. This race requires concurrent hook execution for the same session across different events.
