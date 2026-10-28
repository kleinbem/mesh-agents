# The module on a minimal NixOS system: it evaluates, and the system with the
# MeshLLM unit and the agent tools builds.
{ pkgs, module }:

let
  nixos = pkgs.nixos {
    imports = [ module ];
    services.mesh-agents = {
      enable = true;
      models = [ "Qwen3-8B-Q4_K_M" ];
      joinFile = "/run/secrets/mesh-agents-join";
    };
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
    };
    system.stateVersion = "26.05";
  };
  unit = nixos.config.systemd.units."mesh-llm.service".unit;
in
pkgs.runCommand "mesh-agents-module" { } ''
  grep -q -- '--join-file %d/join' ${unit}/mesh-llm.service
  grep -q 'LoadCredential=join:/run/secrets/mesh-agents-join' ${unit}/mesh-llm.service
  test -x ${nixos.config.system.path}/bin/mesh-agents
  test -x ${nixos.config.system.path}/bin/goose
  grep -q GOOSE_TELEMETRY_OFF ${nixos.config.system.build.setEnvironment}
  touch $out
''
