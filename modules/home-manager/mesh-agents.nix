# services.mesh-agents for home-manager: a node of your private agent mesh as
# a user service, on any Linux (systemd) or macOS (launchd), NixOS or not.
# Same model as the NixOS module: the first node creates the mesh and prints
# an invite token to its log; every other node joins with it in `joinFile`.
{ packages }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.mesh-agents;
  stack = packages.${pkgs.stdenv.hostPlatform.system};

  configFile = (pkgs.formats.toml { }).generate "mesh-llm-config.toml" {
    version = 1;
    models = map (model: { inherit model; }) cfg.models;
  };

  node = pkgs.writeShellScript "mesh-agents-node" ''
    ${lib.optionalString (cfg.models != [ ]) ''
      ${pkgs.coreutils}/bin/install -D -m 0600 ${configFile} "$HOME/.mesh-llm/config.toml"
    ''}
    exec ${
      lib.escapeShellArgs (
        [
          (lib.getExe cfg.package)
          "serve"
          "--log-format"
          "json"
          "--bind-port"
          (toString cfg.meshPort)
        ]
        ++ lib.optionals (cfg.joinFile != null) [
          "--join-file"
          cfg.joinFile
        ]
      )
    }
  '';
in
{
  options.services.mesh-agents = {
    enable = lib.mkEnableOption "this machine as a node of your private agent mesh";

    package = lib.mkOption {
      type = lib.types.package;
      default = stack.mesh-llm;
      defaultText = lib.literalExpression "mesh-agents.packages.\${system}.mesh-llm";
      description = "The MeshLLM package, with the native runtimes your GPU needs.";
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
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/user/1000/secrets/mesh-agents-join";
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

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Start the node at login. Off, start it by hand (`systemctl --user
        start mesh-llm` or `launchctl start dev.kleinbem.mesh-agents`): a big
        model holds its memory as long as the node runs.
      '';
    };

    goose.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to install goose and `mesh-agents`, set up for the local node.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf cfg.goose.enable {
        home.packages = [
          stack.goose-cli
          stack.mesh-agents
        ];
        # goose otherwise asks to share usage data, with yes preselected.
        home.sessionVariables.GOOSE_TELEMETRY_OFF = lib.mkDefault "1";
      })

      (lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
        systemd.user.services.mesh-llm = {
          Unit = {
            Description = "MeshLLM node";
            After = [ "network-online.target" ];
          };
          Service = {
            ExecStart = "${node}";
            Restart = "on-failure";
            RestartSec = 5;
          };
          Install.WantedBy = lib.optional cfg.autoStart "default.target";
        };
      })

      (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
        launchd.agents.mesh-agents = {
          enable = true;
          config = {
            Label = "dev.kleinbem.mesh-agents";
            ProgramArguments = [ "${node}" ];
            RunAtLoad = cfg.autoStart;
            KeepAlive.SuccessfulExit = false;
            StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mesh-agents.log";
            StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mesh-agents.log";
          };
        };
      })
    ]
  );
}
