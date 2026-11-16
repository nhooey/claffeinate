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
check                   # nix flake check: shellcheck and all the tests
run-tests [TEST...]     # acceptance tests, or only those named
lint                    # shellcheck
validate-plugin         # the manifests
try-plugin "…"          # claude -p with the plugin from this checkout
claff-dev build         # the package
```

Each is a token of `scripts/claff-dev` (`claff-dev --help`); add a new
developer command there, with a test in `tests/claff-dev.sh` and a menu
entry in `flake.nix`.

macOS only: the script relies on `caffeinate`, `pmset` and BSD `ps -E`.
