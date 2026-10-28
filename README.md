# mesh-agents

Private, self-hosted AI agents that share compute across your devices.

```bash
nix run github:kleinbem/mesh-agents
```

That starts a [MeshLLM](https://github.com/Mesh-LLM/mesh-llm) node on your
machine with an open model, and a [goose](https://github.com/aaif-goose/goose)
agent on top of it. No API keys, no cloud, nothing leaves your machine:
goose's usage reporting is off by default, and MeshLLM's is built without it.

Add your other machines and they become one mesh: a model too big for your
laptop runs split across the desktop and the GPU box, and every agent on every
device can use it.

> Status: early. The pieces work in a real home fleet every day; the
> one-command path is new. Unofficial: not affiliated with Block or the MeshLLM
> project.

## How it fits together

```
 laptop                    desktop                   GPU box
 ┌──────────────┐          ┌──────────────┐          ┌──────────────┐
 │ goose agent  │          │ goose agent  │          │              │
 │      │       │          │      │       │          │              │
 │ localhost:   │          │ localhost:   │          │              │
 │ 9337/v1      │          │ 9337/v1      │          │              │
 │ MeshLLM node ├──────────┤ MeshLLM node ├──────────┤ MeshLLM node │
 │ small model  │  private │ 14B model    │   mesh   │ 32B model    │
 └──────────────┘   QUIC   └──────────────┘          └──────────────┘
```

Every node has the same OpenAI-compatible API on `localhost:9337`, which
routes each request to whichever node holds the model. Agents don't need to
know where anything runs.

## Try it

```bash
nix run github:kleinbem/mesh-agents                      # Qwen3-8B, ~5 GB download
nix run github:kleinbem/mesh-agents -- --model Qwen3-4B-Q4_K_M
```

`nix run nixpkgs#mesh-llm -- models recommended` lists the models. The node
only lives as long as the session and never joins or publishes a public mesh.

## Run it on your machines (NixOS)

```nix
{
  inputs.mesh-agents.url = "github:kleinbem/mesh-agents";

  outputs = { nixpkgs, mesh-agents, ... }: {
    nixosConfigurations.desktop = nixpkgs.lib.nixosSystem {
      modules = [
        mesh-agents.nixosModules.default
        {
          services.mesh-agents = {
            enable = true;
            models = [ "Qwen3-14B-Q4_K_M" ];
            # package = pkgs.mesh-llm-cuda;  # NVIDIA
          };
        }
      ];
    };
  };
}
```

The first machine creates the mesh and prints an invite token at its first
start (`journalctl -u mesh-llm`). Put the token in a file on each other machine
(sops-nix, agenix, or by hand) and point `services.mesh-agents.joinFile` at it.

## Any Linux or macOS (home-manager)

The same node as a user service (systemd on Linux, launchd on macOS), no
NixOS needed:

```nix
{
  imports = [ mesh-agents.homeManagerModules.default ];

  services.mesh-agents = {
    enable = true;
    models = [ "Qwen3-8B-Q4_K_M" ];
    # joinFile = "/path/to/invite-token";  # every node but the first
  };
}
```

The first node prints its invite token to its log: `journalctl --user -u
mesh-llm` on Linux, `~/Library/Logs/mesh-agents.log` on macOS. Set
`autoStart = false` on a laptop to start the node only when you need it.

## What's inside

| Package | What it is |
|---|---|
| `mesh-agents` | The launcher behind `nix run` |
| `mesh-llm`, `skippy` | Distributed LLM inference over a peer-to-peer mesh |
| `goose-cli` | The agent ([goose](https://github.com/aaif-goose/goose)) |
| `buzz-app`, `buzz-cli`, `buzz-relay`, `buzz-acp` | Self-hosted team chat where agents are members ([Buzz](https://github.com/block/buzz)) |
| `berd`, `braindump` | More agent tools from the same ecosystem |

The packages are built the way nixpkgs builds them; several are on their way
into nixpkgs ([mesh-llm](https://github.com/NixOS/nixpkgs/pull/571722)).
Until they land, this flake is the place to get them, and it keeps tracking
upstream after that.

## Roadmap

- Public binary cache, so nothing compiles on your machine
- nix-darwin module
- Agents in Buzz: your agents as members of your own team chat
- A daily `unstable` channel built from each project's main branch

## License

MIT
