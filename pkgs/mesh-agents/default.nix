{
  lib,
  writeShellApplication,
  curl,
  goose-cli,
  jq,
  mesh-llm,
  # With Berd, the launcher opens the desktop app instead of goose in the terminal.
  berd ? null,
}:

writeShellApplication {
  name = if berd == null then "mesh-agents" else "mesh-agents-berd";
  runtimeInputs = [
    curl
    goose-cli
    jq
    mesh-llm
  ]
  ++ lib.optional (berd != null) berd;
  runtimeEnv = lib.optionalAttrs (berd != null) { MESH_AGENTS_APP = "berd"; };
  text = builtins.readFile ./mesh-agents.sh;
  meta = {
    description =
      if berd == null then
        "Start a private MeshLLM node and a goose agent on it"
      else
        "Start a private MeshLLM node and open Berd on it";
    homepage = "https://github.com/kleinbem/mesh-agents";
    license = lib.licenses.mit;
    mainProgram = if berd == null then "mesh-agents" else "mesh-agents-berd";
    platforms = if berd == null then mesh-llm.meta.platforms else berd.meta.platforms;
  };
}
