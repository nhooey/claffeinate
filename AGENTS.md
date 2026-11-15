# claffeinate

A macOS command and Claude Code plugin that keeps the Mac awake while
Claude Code works and lets it sleep once the work stops. It tags each
`caffeinate(1)` it starts with the Claude Code session that owns it and
reaps the ones whose session has gone.

- `bin/claffeinate`: the command, a Bash script.
- `hooks/`: the plugin's hook, which starts and stops holds.
- `skills/`: the plugin's skills.
- `.claude-plugin/`: the plugin and marketplace manifests; `plugin.json`
  holds the one version for the plugin and the Nix package.
- `SPECIFICATION.md`: the full contract. `README.md`: the user's guide.

## Build and test

Work inside the dev shell (`nix develop`); entering it also installs the
project's skills into `.agents/skills/`.

```sh
nix flake check                        # shellcheck and the acceptance tests
tests/test.sh [TEST...]                # acceptance tests, or only those named
nix build                              # the package
claude plugin validate --strict .      # the manifests
```

macOS only: the script relies on `caffeinate`, `pmset` and BSD `ps -E`.
