---
name: set
description: Change a claffeinate setting for this Claude Code session only, such as how long a hold may keep the Mac awake.
argument-hint: SETTING VALUE
disable-model-invocation: true
---

The user wants to change a claffeinate setting for this session: `$ARGUMENTS`.

The settings are:

- `awake-max-duration`: the longest one hold keeps the Mac awake, such as
  `8h` or `90m` (default `4h`)
- `awake-min-battery`: the battery percent at which holds end; `0` never
  (default `20`)
- `emoji`: `on` or `off`, for the status output (default `on`)

Run, with the Bash tool:

```sh
claffeinate config set --session "$CLAUDE_CODE_SESSION_ID" SETTING VALUE
```

with the setting and value from `$ARGUMENTS`. With no arguments, or with
`show`, run `claffeinate config` instead, and show its output unchanged.

Then tell the user, in one line, that the change applies to holds started
from now on in this session; a hold already running keeps its settings.
To set it for every session, they can run
`claffeinate config set --global SETTING VALUE`.
