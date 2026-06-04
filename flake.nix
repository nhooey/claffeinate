{
  description = "claffeinate -- tag caffeinate(1) instances with the Claude Code tab that owns them";

  # Pinned to the current stable channel. Bump deliberately at NixOS release
  # time; the project doesn't need bleeding-edge toolchains.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    devshell.url = "github:numtide/devshell";
    devshell.inputs.nixpkgs.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    # `flake-skills` is the builder library, not a skill — it provides
    # `mkCombination`, used in `outputs` to build the dev-shell skill set.
    flake-skills.url = "github:nhooey/flake-skills";
    flake-skills.inputs.nixpkgs.follows = "nixpkgs";

    # ---------------------------------------------------------------------
    # Dev-shell skill sources (inlined — consumed only by the dev shell)
    # ---------------------------------------------------------------------
    # The project dev shell installs one curated skill set: the full git/GitHub
    # hygiene pack plus the nix-flakes and nix-garnix-ci skills from skills-nix
    # — combined via flake-skills' `mkCombination` in `outputs` (`devshellSkills`).
    # These were previously isolated in a `skills-devshell/` sub-flake, but a
    # same-repo sub-flake can only be addressed by a relative `path:` input
    # (which sandboxed/transitive consumers reject) or a brittle self-URL (which
    # breaks on any repo/owner/host rename), so they are inlined here instead.
    #
    # Each source `follows` only the parent `nixpkgs`, NOT `flake-skills`.
    # Forcing `flake-skills.follows` would make the combination's transitive
    # sources resolve against this root's owner-namespacing flake-skills and
    # trip a strict null-owner check. Following only nixpkgs and letting each
    # source keep its own flake-skills is the proven working pattern.
    skills-git = {
      url = "github:nhooey/skills-git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    skills-nix = {
      url = "github:nhooey/skills-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      flake-parts,
      nixpkgs,
      flake-skills,
      ...
    }@inputs:
    let
      # The project dev-shell skill set, combined from the inlined skill
      # sources: the full git/GitHub hygiene pack plus the nix-flakes and
      # nix-garnix-ci skills from skills-nix. `reconcileScript` is a
      # `system -> string` function the dev shell splices into a startup hook.
      devshellSkills = flake-skills.lib.mkCombination {
        inherit nixpkgs;
        name = "claffeinate-devshell";
        envName = "agent-skills-claffeinate-devshell";
        packagePrefix = "agent-skill-";
        sources = [
          { source = inputs.skills-git; }
          {
            source = inputs.skills-nix;
            skills = [
              "nix-flakes"
              "nix-garnix-ci"
            ];
          }
        ];
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Darwin-only: claffeinate wraps macOS caffeinate(1) and uses BSD ps -E.
      # Hardcoded rather than via nix-systems/default because Linux builds
      # would never produce a working binary.
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      imports = [
        inputs.devshell.flakeModule
        inputs.treefmt-nix.flakeModule
      ];

      perSystem =
        {
          pkgs,
          lib,
          system,
          ...
        }:
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
                  shellcheck ${./bin/claffeinate.sh} ${./tests/test.sh}
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

          devshells.default = {
            name = "claffeinate";
            motd = ''
              {bold}{14}claffeinate dev shell{reset}
              Type {bold}menu{reset} to see available commands.
            '';
            # Reconcile the dev-shell skill set (git/GitHub hygiene pack plus
            # the nix-flakes / nix-garnix-ci skills) at project scope under a
            # single owner. `devshellSkills` (in `outputs`) yields the reconcile
            # one-liner per system; this splices it in.
            devshell.startup.install-skills.text = ''
              ${devshellSkills.reconcileScript system}
            '';
            packages = [
              pkgs.bash
              pkgs.jq
              pkgs.shellcheck
              pkgs.shfmt
            ];
            commands = [
              {
                category = "ci";
                name = "check";
                help = "Run all flake checks (formatter + shellcheck)";
                command = ''nix flake check "$@"'';
              }
              {
                category = "dev";
                name = "fmt";
                help = "Format Nix and shell sources via treefmt";
                command = ''nix fmt "$@"'';
              }
              {
                category = "dev";
                name = "lint";
                help = "Run shellcheck on bin/claffeinate and tests/test.sh";
                command = ''
                  set -eu
                  shellcheck "$PRJ_ROOT/bin/claffeinate" "$PRJ_ROOT/tests/test.sh"
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
