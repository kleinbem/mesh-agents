# services.mesh-agents: this machine as a node of your private agent mesh.
#
# A MeshLLM node (services.mesh-llm) serves models into the mesh, and every
# node's local API (http://127.0.0.1:9337/v1, OpenAI-compatible) routes to
# whichever node holds the model. goose, and `mesh-agents` for a session,
# talk to that local API.
#
# The first node creates the mesh and prints an invite token at its first
# start (journalctl -u mesh-llm). Every other node joins with that token in
# `joinFile`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.mesh-agents;
in
{
  options.services.mesh-agents = {
    enable = lib.mkEnableOption "this machine as a node of your private agent mesh";

    package = lib.mkPackageOption pkgs "mesh-llm" {
      example = "mesh-llm-cuda";
      extraDescription = "Pick the variant with the native runtimes your GPU needs.";
    };

    models = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "Qwen3-8B-Q4_K_M" ];
      description = ''
        Models this node serves into the mesh: names from MeshLLM's catalog
        (`mesh-llm models recommended`, downloaded at the first start) or paths
        to GGUF files. Empty serves none: the node only routes to the others.
      '';
    };

    joinFile = lib.mkOption {
      type = lib.types.nullOr lib.types.externalPath;
      default = null;
      example = "/run/secrets/mesh-agents-join";
      description = ''
        File with the mesh's invite token. `null` creates a mesh of its own:
        the first node.
      '';
    };

    meshPort = lib.mkOption {
      type = lib.types.port;
      default = 7842;
      description = "UDP port for the mesh's traffic between nodes.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to open the mesh port for the other nodes.";
    };

    goose.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to install goose and `mesh-agents`, set up for the local node.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.mesh-llm = {
      enable = true;
      inherit (cfg) package meshPort openFirewall;
      settings = lib.mkIf (cfg.models != [ ]) {
        version = 1;
        models = map (model: { inherit model; }) cfg.models;
      };
      # The service's user can't read a file only root can, so systemd reads
      # it as a credential.
      extraArgs = lib.optionals (cfg.joinFile != null) [
        "--join-file"
        "%d/join"
      ];
    };

    systemd.services.mesh-llm.serviceConfig.LoadCredential = lib.mkIf (cfg.joinFile != null) [
      "join:${cfg.joinFile}"
    ];

    environment = lib.mkIf cfg.goose.enable {
      systemPackages = [
        pkgs.goose-cli
        pkgs.mesh-agents
      ];
      # goose otherwise asks to share usage data, with yes preselected.
      sessionVariables.GOOSE_TELEMETRY_OFF = lib.mkDefault "1";
    };
  };
}
