# services.mesh-agents.buzz: goose agents as members of a Buzz team chat.
#
# Each agent is a buzz-acp harness on the relay: it listens for @mentions,
# prompts goose over ACP, and goose answers in the channel. goose runs on
# the local MeshLLM node (services.mesh-agents), so the whole conversation
# stays on your machines.
#
# An agent needs its own Nostr key, registered as a member of the relay:
#   buzz-admin generate-key   → the secret key into `privateKeyFile`
#   buzz-admin add-member --pubkey <public key>
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.mesh-agents;

  # goose's provider for the local node; `mesh` lets the mesh pick the model.
  provider = (pkgs.formats.json { }).generate "mesh.json" {
    name = "mesh";
    display_name = "mesh-llm";
    description = "Distributed LLM inference via mesh-llm";
    engine = "openai";
    base_url = "http://localhost:9337";
    api_key_env = "";
    requires_auth = false;
    supports_streaming = true;
    timeout_seconds = 600;
    models = [
      {
        name = "mesh";
        context_limit = 32768;
      }
    ];
  };

  agentModule = {
    options = {
      relayUrl = lib.mkOption {
        type = lib.types.str;
        example = "wss://buzz.example.com";
        description = "WebSocket URL of the Buzz relay.";
      };

      privateKeyFile = lib.mkOption {
        type = lib.types.externalPath;
        example = "/run/secrets/buzz-agent-key";
        description = "File with the agent's Nostr secret key (`nsec1…` or hex).";
      };

      model = lib.mkOption {
        type = lib.types.str;
        default = "mesh";
        description = "Model for goose: `mesh` lets the mesh pick, or a name from `/v1/models`.";
      };

      owner = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d";
        description = ''
          Your hex public key. The agent answers its owner, and only its owner
          by default: without one it answers nobody.
        '';
      };

      respondTo = lib.mkOption {
        type = lib.types.enum [
          "owner-only"
          "allowlist"
          "anyone"
          "nobody"
        ];
        default = "owner-only";
        description = "Whose messages the agent answers (buzz-acp's author gate).";
      };

      allowlist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Hex public keys the agent answers besides its owner, with `respondTo = \"allowlist\"`.";
      };
    };
  };

  agentService =
    name: agent:
    lib.nameValuePair "mesh-agents-buzz-${name}" {
      description = "Buzz agent ${name} (goose on MeshLLM)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "mesh-llm.service"
      ];
      path = [
        pkgs.goose-cli
        pkgs.buzz-cli
        pkgs.git
      ];
      environment = {
        HOME = "/var/lib/mesh-agents-buzz-${name}";
        BUZZ_RELAY_URL = agent.relayUrl;
        BUZZ_ACP_RESPOND_TO = agent.respondTo;
        GOOSE_PROVIDER = "mesh";
        GOOSE_MODEL = agent.model;
        # No human approves tool calls in a chat; the unit is the sandbox.
        GOOSE_MODE = "auto";
        GOOSE_TELEMETRY_OFF = "1";
      }
      // lib.optionalAttrs (agent.owner != null) {
        BUZZ_ACP_AGENT_OWNER = agent.owner;
      }
      // lib.optionalAttrs (agent.allowlist != [ ]) {
        BUZZ_ACP_RESPOND_TO_ALLOWLIST = lib.concatStringsSep "," agent.allowlist;
      };
      script = ''
        install -D -m 0644 ${provider} "$HOME/.config/goose/custom_providers/mesh.json"
        BUZZ_PRIVATE_KEY=$(< "$CREDENTIALS_DIRECTORY/key")
        export BUZZ_PRIVATE_KEY
        exec ${lib.getExe' pkgs.buzz-acp "buzz-acp"}
      '';
      serviceConfig = {
        LoadCredential = [ "key:${agent.privateKeyFile}" ];
        DynamicUser = true;
        StateDirectory = "mesh-agents-buzz-${name}";
        WorkingDirectory = "/var/lib/mesh-agents-buzz-${name}";
        Restart = "on-failure";
        RestartSec = 10;

        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };
in
{
  options.services.mesh-agents.buzz.agents = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule agentModule);
    default = { };
    example = lib.literalExpression ''
      {
        helper = {
          relayUrl = "wss://buzz.example.com";
          privateKeyFile = "/run/secrets/buzz-helper-key";
        };
      }
    '';
    description = ''
      goose agents as members of a Buzz relay, one buzz-acp harness each, all
      on this node's MeshLLM.
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.buzz.agents != { }) {
    systemd.services = lib.mapAttrs' agentService cfg.buzz.agents;
  };
}
