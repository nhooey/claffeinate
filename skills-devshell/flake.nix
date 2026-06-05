{
  description = "claffeinate dev-shell skill set — an isolated sub-flake invoked at RUNTIME by the root devShell, never a root input. The skill sources (all skills-git skills plus nix-flakes/nix-garnix-ci from skills-nix) live only in THIS flake's lock, so the root claffeinate stays a leaf with zero skill inputs and transitive consumers never drag the skill mesh in.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    # `agent-skill-flake` is the builder library, not a skill — it provides
    # `mkDevshellSkillsFlake`. Followed by every skill source below so the
    # whole tree shares one evaluation.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Every input below this divider is a skill source.

    # All of skills-git's skills (git hygiene, GitHub policy, PR lifecycle).
    skills-git = {
      url = "github:nhooey/skills-git";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        agent-skill-flake.follows = "agent-skill-flake";
      };
    };

    # skills-nix: only nix-flakes and nix-garnix-ci are cherry-picked below.
    # skills-nix still names its builder input `flake-skills` (agent-skill-flake
    # is that repo renamed), followed onto our node to collapse the builder.
    skills-nix = {
      url = "github:nhooey/skills-nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-skills.follows = "agent-skill-flake";
        skills-git.follows = "skills-git";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      agent-skill-flake,
      skills-git,
      skills-nix,
      ...
    }@inputs:
    agent-skill-flake.lib.mkDevshellSkillsFlake {
      inherit nixpkgs;
      systems = import inputs.systems;
      name = "claffeinate-skills";
      envName = "agent-skills-claffeinate-skills";
      packagePrefix = "agent-skill-";
      sources = [
        { source = skills-git; }
        {
          source = skills-nix;
          skills = [
            "nix-flakes"
            "nix-garnix-ci"
          ];
        }
      ];
    };
}
