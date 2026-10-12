---
name: status
description: Show whether claffeinate is keeping this Mac awake for this Claude Code tab, and what every other tab's instance is doing.
disable-model-invocation: true
---

Run `claffeinate status` with the Bash tool. The plugin puts `claffeinate` on
the Bash tool's `PATH`.

Each row is one instance: `PID TERM_SESSION_ID SSE_PORT DIR alive|dead
CLAUDE_PID UPTIME_SECONDS`. Summarize it in a few lines:

- Whether this tab has an `alive` instance, and how long it has run. The
  hooks keep it running for 10 minutes after each prompt or finished tool
  call, and for up to 2 hours while a tool call runs.
- Any `dead` instance, meaning its tab has closed. Tell the user
  `claffeinate kill-orphans` stops those. Don't run it yourself.
- No rows means nothing is keeping the Mac awake.

If the command reports that it needs macOS, tell the user claffeinate only
works on macOS and stop.
