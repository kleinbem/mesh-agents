# shellcheck shell=bash
# mesh-agents: a goose agent, in the terminal or in Berd, on a private MeshLLM
# node.
#
# Uses the node already listening on the API port (a NixOS host with
# services.mesh-agents), or starts one for this session. That node never
# auto-joins or publishes a mesh: it serves its own model, and joins your
# other devices only with your invite token.

usage() {
  cat <<EOF
Usage: mesh-agents [--app goose|berd] [--model MODEL] [--join-file PATH] [--port PORT]

  --app APP          goose in the terminal, or berd, the desktop app on goose
                     (default: \$MESH_AGENTS_APP or goose)

  --model MODEL      model to serve when no node is running
                     (default: \$MESH_AGENTS_MODEL or Qwen3-8B-Q4_K_M;
                     \`mesh-llm models recommended\` lists more)
  --join-file PATH   join your private mesh with the invite token in PATH
  --port PORT        OpenAI-compatible API port (default: 9337)
EOF
}

app=${MESH_AGENTS_APP:-goose}
model=${MESH_AGENTS_MODEL:-Qwen3-8B-Q4_K_M}
join_file=
port=9337

while [ $# -gt 0 ]; do
  case $1 in
    --app) app=$2; shift 2 ;;
    --model) model=$2; shift 2 ;;
    --join-file) join_file=$2; shift 2 ;;
    --port) port=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case $app in
  goose) ;;
  berd)
    if ! command -v berd >/dev/null; then
      echo "Berd isn't installed; use the mesh-agents-berd package." >&2
      exit 1
    fi
    ;;
  *) usage >&2; exit 2 ;;
esac

api=http://127.0.0.1:$port/v1

# goose asks to share usage data at its first start, with yes preselected.
# Nothing here leaves your machine unless you say so: set
# GOOSE_TELEMETRY_OFF=0 to be asked.
export GOOSE_TELEMETRY_OFF=${GOOSE_TELEMETRY_OFF:-1}

served_models() {
  curl -fsS --max-time 2 "$api/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null
}

if ! curl -fsS --max-time 2 "$api/models" >/dev/null 2>&1; then
  state=${XDG_STATE_HOME:-$HOME/.local/state}/mesh-agents
  mkdir -p "$state"
  args=(serve --model "$model" --port "$port")
  if [ -n "$join_file" ]; then
    args+=(--join-file "$join_file")
  fi
  echo "Starting a private MeshLLM node with $model (log: $state/mesh-llm.log)"
  mesh-llm "${args[@]}" >"$state/mesh-llm.log" 2>&1 &
  node=$!
  trap 'kill "$node" 2>/dev/null; wait "$node" 2>/dev/null' EXIT

  echo "Waiting for the model; the first start downloads it."
  until [ -n "$(served_models)" ]; do
    if ! kill -0 "$node" 2>/dev/null; then
      echo "MeshLLM stopped, see $state/mesh-llm.log" >&2
      exit 1
    fi
    sleep 2
  done
fi

if [ "$app" = goose ]; then
  mesh-llm goose --port "$port"
  exit
fi

# Berd starts its own goose. Give that goose the provider `mesh-llm goose`
# writes (~/.config/goose/custom_providers/mesh.json) and pick a served model.
inventory=$(curl -fsS --max-time 5 "$api/models")
if ! jq -e --arg m "$model" '.data[] | select(.id == $m)' <<<"$inventory" >/dev/null; then
  model=$(jq -r '.data[0].id' <<<"$inventory")
fi
providers=${XDG_CONFIG_HOME:-$HOME/.config}/goose/custom_providers
mkdir -p "$providers"
jq --arg base "http://localhost:$port" '{
  name: "mesh",
  engine: "openai",
  display_name: "mesh-llm",
  description: "Distributed LLM inference via mesh-llm",
  api_key_env: "",
  base_url: $base,
  # Served models without context metadata: the same 8k fallback as MeshLLM.
  models: [.data[] | {name: .id, context_limit: (.metadata.context_length // 8192)}],
  timeout_seconds: 600,
  supports_streaming: true,
  requires_auth: false,
  nonce_header: "x-capsule-client-nonce"
}' <<<"$inventory" >"$providers/mesh.json"

echo "Opening Berd with $model"
GOOSE_PROVIDER=mesh GOOSE_MODEL=$model berd
