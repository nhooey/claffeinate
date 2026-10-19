---
name: status
description: Show when this Mac will be allowed to sleep, and every claffeinate hold keeping it awake.
disable-model-invocation: true
---

Run `claffeinate status` with the Bash tool. The plugin puts `claffeinate` on
the Bash tool's `PATH`.

Show its output to the user unchanged, in a `text` code block. Don't
rearrange or summarize it: its fixed shape is what lets the user compare
one reading with the next.

Then add one line on what stands out, such as:

- which limit decides when the Mac sleeps, from the `💤 sleep` line's `by=`
- a `🔴 dead` hold: tell the user `claffeinate kill-orphans` stops it. Don't
  run it yourself.
- another app holding the Mac awake, named in `other=`

If the user asks how the forecast works, run `claffeinate status --explain`.
If the command reports that it needs macOS, tell the user claffeinate only
works on macOS and stop.
