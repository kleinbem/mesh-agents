# shellcheck shell=bash
# mesh-agents: a goose agent on a private MeshLLM node.
#
# Uses the node already listening on the API port (a NixOS host with
# services.mesh-agents), or starts one for this session. That node never
# auto-joins or publishes a mesh: it serves its own model, and joins your
# other devices only with your invite token.

usage() {
  cat <<EOF
Usage: mesh-agents [--model MODEL] [--join-file PATH] [--port PORT]

  --model MODEL      model to serve when no node is running
                     (default: \$MESH_AGENTS_MODEL or Qwen3-8B-Q4_K_M;
                     \`mesh-llm models recommended\` lists more)
  --join-file PATH   join your private mesh with the invite token in PATH
  --port PORT        OpenAI-compatible API port (default: 9337)
EOF
}

model=${MESH_AGENTS_MODEL:-Qwen3-8B-Q4_K_M}
join_file=
port=9337

while [ $# -gt 0 ]; do
  case $1 in
    --model) model=$2; shift 2 ;;
    --join-file) join_file=$2; shift 2 ;;
    --port) port=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

api=http://127.0.0.1:$port/v1

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

mesh-llm goose --port "$port"
