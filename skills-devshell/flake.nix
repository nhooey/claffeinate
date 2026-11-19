{
  description = "claffeinate dev-shell skill set — an isolated sub-flake invoked at RUNTIME by the root devShell, never a root input. The skill sources live only in THIS flake's lock, so the root claffeinate stays a leaf with zero skill inputs and transitive consumers never drag the skill mesh in.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    systems.url = "github:nix-systems/default";

    # `agent-skill-flake` is the builder library, not a skill — it provides
    # `mkDevshellSkillsFlake`. It carries no skill inputs.
    agent-skill-flake = {
      url = "github:nhooey/agent-skill-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The one skill source: skillspkgs' combination for the Claude Code
    # tools family. It follows `nixpkgs` but not `agent-skill-flake`, so
    # its skill sources keep their own compatible builder.
    skillspkgs-combinations = {
      url = "github:nhooey/skillspkgs?dir=sources/combinations";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      agent-skill-flake,
      ...
    }@inputs:
    agent-skill-flake.lib.mkDevshellSkillsFlake {
      inherit nixpkgs;
      systems = import inputs.systems;
      name = "claffeinate-skills";
      sources = [
        { source = inputs.skillspkgs-combinations.combinations.claude-code-tools; }
      ];
    };
}
