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
        name = "claffeinate";
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
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontBuild = true;
            # Source is bin/claffeinate.sh; installs as bin/claffeinate so the
            # `.sh` extension does not leak into the user-facing command name.
            installPhase = ''
              runHook preInstall
              install -Dm755 bin/claffeinate.sh $out/bin/claffeinate
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
          };

          checks = {
            shellcheck =
              pkgs.runCommand "claffeinate-shellcheck"
                {
                  nativeBuildInputs = [ pkgs.shellcheck ];
                }
                ''
                  shellcheck ${./bin/claffeinate.sh} ${./hooks/claffeinate-hook.sh} ${./tests/test.sh}
                  touch $out
                '';

            # Acceptance tests. Run against the source script (not the wrapped
            # binary): test 8 stubs jq via PATH, which the wrapper's hardcoded
            # PATH would defeat. Sandbox/CI does not have a live Claude Code
            # session, so tests 4 (kill-orphans no-op when alive) and 6
            # (claude-pid resolves) skip there.
            tests =
              pkgs.runCommand "claffeinate-tests"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.jq
                    pkgs.python3
                    pkgs.coreutils
                  ];
                }
                ''
                  set -eu
                  cp -r ${./.} ./src
                  chmod -R u+w ./src
                  cd ./src
                  # Macros + caffeinate(1) live in /usr/bin and /bin on macOS;
                  # add them since the Nix sandbox PATH lists only build inputs.
                  export PATH="/usr/bin:/bin:$PATH"
                  # /tmp/claffeinate/ may be owned by another user on shared
                  # /tmp; redirect to a build-private dir.
                  export CLAFFEINATE_RUN_DIR="$PWD/run/"
                  bash tests/test.sh
                  touch $out
                '';
          };

          # The devshellSkills module (imported above) supplies this devShell's
          # name, motd, the install-skills startup, the ci/dev/maintenance
          # command trio (check / fmt / update-flake), and the skills commands
          # (reap-skills / update-skills-devshell). Only claffeinate-specific
          # packages and commands are set here; both are list options, so they
          # merge onto the module's rather than replacing them.
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
                name = "lint";
                help = "Run shellcheck on the script, the plugin hook and the tests";
                command = ''
                  set -eu
                  shellcheck "$PRJ_ROOT/bin/claffeinate.sh" \
                    "$PRJ_ROOT/hooks/claffeinate-hook.sh" "$PRJ_ROOT/tests/test.sh"
                '';
              }
              {
                category = "dev";
                name = "test";
                help = "Run the acceptance test suite";
                command = ''exec "$PRJ_ROOT/tests/test.sh" "$@"'';
              }
            ];
          };
        };
    };
}
