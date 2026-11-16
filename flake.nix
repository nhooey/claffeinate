{
  description = "claffeinate -- tag caffeinate(1) instances with the Claude Code tab that owns them";

  # Pinned to the current stable channel. Bump deliberately at NixOS release
  # time; the project doesn't need bleeding-edge toolchains.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    # `agent-skill-flake` is the builder library, not a skill — it provides the
    # `flakeModules.devshellSkills` flake-parts module that wires the dev-shell
    # skill set in below. That module bundles numtide/devshell, so this flake
    # needs no `devshell` input of its own. The skill sources themselves are NOT
    # inputs here: they live only in the `skills-devshell/` sub-flake's lock,
    # which this dev shell invokes at RUNTIME (never as a root input), keeping
    # this flake a leaf with zero skill inputs.
    agent-skill-flake.url = "github:nhooey/agent-skill-flake";
    agent-skill-flake.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      flake-parts,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Darwin-only: claffeinate wraps macOS caffeinate(1) and uses BSD ps -E.
      # Hardcoded rather than via nix-systems/default because Linux builds
      # would never produce a working binary.
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      imports = [
        # Bundles numtide/devshell + the whole dev-shell skills convention
        # (motd, install-skills startup, the ci/dev/maintenance command trio,
        # and the reap-skills/update-skills-devshell pair). Configured via the
        # `agent-skill-flake.devshellSkills` options block below.
        inputs.agent-skill-flake.flakeModules.devshellSkills
        inputs.treefmt-nix.flakeModule
      ];

      # claffeinate keeps its custom motd ("Type menu …"); the module's
      # generated banner is overridden by passing `motd` here.
      agent-skill-flake.devshellSkills = {
        # Not "claffeinate": devshell names its launcher after this, and that
        # launcher would shadow the installed command inside the dev shell.
        name = "claffeinate-dev";
        motd = ''
          {bold}{14}claffeinate dev shell{reset}
          Type {bold}menu{reset} to see available commands.
        '';
      };

      perSystem =
        { pkgs, lib, ... }:
        {
          packages.default = pkgs.stdenv.mkDerivation {
            pname = "claffeinate";
            # The plugin manifest holds the one version for both.
            inherit (lib.importJSON ./.claude-plugin/plugin.json) version;
            src = ./.;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              install -Dm755 bin/claffeinate $out/bin/claffeinate
              # The script finds it as ../share/claffeinate/defaults.conf.
              install -Dm644 share/claffeinate/defaults.conf \
                $out/share/claffeinate/defaults.conf
              wrapProgram $out/bin/claffeinate \
                --prefix PATH : ${lib.makeBinPath [ pkgs.jq ]}
              runHook postInstall
            '';
            meta = {
              description = "Tag caffeinate(1) instances with the Claude Code tab that owns them";
              platforms = lib.platforms.darwin;
              mainProgram = "claffeinate";
            };
          };

          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
            programs.shfmt = {
              enable = true;
              indent_size = 2;
            };
            # shfmt matches by extension, and these scripts have none.
            settings.formatter.shfmt.includes = [
              "bin/claffeinate"
              "scripts/claff-dev"
            ];
          };

          checks = {
            shellcheck =
              pkgs.runCommand "claffeinate-shellcheck"
                {
                  nativeBuildInputs = [ pkgs.shellcheck ];
                }
                ''
                  bash ${./.}/scripts/claff-dev lint
                  touch $out
                '';

            # The dev tool's argument parsing, through --dry-run and --help.
            claff-dev = pkgs.runCommand "claffeinate-claff-dev-tests" { nativeBuildInputs = [ pkgs.bash ]; } ''
              bash ${./.}/tests/claff-dev.sh
              touch $out
            '';

            # Acceptance tests. Run against the source script (not the wrapped
            # binary): json_without_jq_fails stubs jq via PATH, which the
            # wrapper's hardcoded PATH would defeat. Every test runs here: the
            # build denies exec of the setuid /bin/ps, so nixpkgs' ps comes
            # first on PATH, ahead of the macOS tools.
            tests =
              pkgs.runCommand "claffeinate-tests"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.jq
                    pkgs.python3
                    pkgs.coreutils
                    pkgs.ps
                  ];
                }
                ''
                  set -eu
                  cp -r ${./.} ./src
                  chmod -R u+w ./src
                  cd ./src
                  # caffeinate(1), pmset, lsof and the other macOS tools live in
                  # /usr/bin, /usr/sbin and /bin.
                  export PATH="${pkgs.ps}/bin:/usr/bin:/usr/sbin:/bin:$PATH"
                  # Keep the build off the shared /tmp/claffeinate-$UID/: use a
                  # build-private run dir.
                  export CLAFFEINATE_RUN_DIR="$PWD/run/"
                  export CLAFFEINATE_TESTS_REQUIRE_EXEC=1
                  bash scripts/claff-dev test
                  touch $out
                '';
          };

          # The devshellSkills module (imported above) supplies this devShell's
          # name, motd, the install-skills startup, the ci/dev/maintenance
          # command trio (check / fmt / update-flake), and the skills commands
          # (reap-skills / update-skills-devshell). Only claffeinate-specific
          # packages and commands are set here; both are list options, so they
          # merge onto the module's rather than replacing them. Each command
          # is a token of scripts/claff-dev, which holds the bodies.
          devshells.default = {
            packages = [
              pkgs.bash
              pkgs.jq
              pkgs.shellcheck
              pkgs.shfmt
            ];

            commands = [
              {
                category = "dev";
                name = "claff-dev";
                help = "The developer commands as one tool; claff-dev --help lists them";
                command = ''exec "$PRJ_ROOT/scripts/claff-dev" "$@"'';
              }
              {
                category = "dev";
                name = "lint";
                help = "Run shellcheck on the repository's shell files";
                command = ''exec "$PRJ_ROOT/scripts/claff-dev" lint "$@"'';
              }
              {
                category = "dev";
                # Not "test": the shell's test builtin would shadow it.
                name = "run-tests";
                help = "Run the acceptance tests, or only those named";
                command = ''exec "$PRJ_ROOT/scripts/claff-dev" test "$@"'';
              }
              {
                category = "dev";
                name = "try-plugin";
                help = "Run claude -p with the plugin loaded from this checkout";
                command = ''exec "$PRJ_ROOT/scripts/claff-dev" try-plugin "$@"'';
              }
              {
                category = "dev";
                name = "validate-plugin";
                help = "Validate the plugin and marketplace manifests with Claude Code";
                command = ''exec "$PRJ_ROOT/scripts/claff-dev" validate-plugin "$@"'';
              }
            ];
          };
        };
    };
}
