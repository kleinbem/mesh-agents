{
  lib,
  writeShellApplication,
  curl,
  goose-cli,
  jq,
  mesh-llm,
}:

writeShellApplication {
  name = "mesh-agents";
  runtimeInputs = [
    curl
    goose-cli
    jq
    mesh-llm
  ];
  text = builtins.readFile ./mesh-agents.sh;
  meta = {
    description = "Start a private MeshLLM node and a goose agent on it";
    homepage = "https://github.com/kleinbem/mesh-agents";
    license = lib.licenses.mit;
    mainProgram = "mesh-agents";
    inherit (mesh-llm.meta) platforms;
  };
}
