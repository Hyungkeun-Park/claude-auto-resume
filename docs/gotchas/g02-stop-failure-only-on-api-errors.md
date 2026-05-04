# G2: StopFailure Only Fires on API Errors, Not Client Blocks

**What**: StopFailure fires on HTTP 429 from the API, but NOT when the client-side rate limiter blocks the request before it reaches the API.

**Why it matters**: You cannot rely on StopFailure as the sole scheduling mechanism. Many rate limit scenarios never produce a StopFailure event.

**Resolution**: StopFailure is a fallback, not the primary path. The primary scheduling happens in UserPromptSubmit (speculative) and Stop (confirmatory).

**Verified**: Production testing confirmed StopFailure never fires on client-side blocks.
