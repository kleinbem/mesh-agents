# mesh-agents

Public product repo: private, self-hosted AI agents on a MeshLLM mesh. The
README is the pitch; keep it short and true, and update it with every
user-visible change.

| Path | What lives here |
|---|---|
| `flake.nix` | Packages (the stack, re-exported), `nixosModules.default`, `homeManagerModules.default`, `overlays.default`, checks, treefmt. |
| `pkgs/mesh-agents/` | The `nix run` launcher: starts a private node unless one listens on the API port, then `mesh-llm goose`. |
| `modules/nixos/mesh-agents.nix` | `services.mesh-agents`, on top of nixpkgs' `services.mesh-llm` (NixOS/nixpkgs#571722). |
| `modules/home-manager/mesh-agents.nix` | The same node as a user service: systemd on Linux, launchd on macOS. |
| `tests/` | The NixOS module on a minimal system, the home-manager module in a user's configuration. |

- Packages come from `kleinbem/nix-packages` for now; moving the Block AI ones
  here (and nix-packages consuming this flake) is the next step.
- Never default to `--auto` or `--publish`: the node stays private unless the
  user joins it with their own invite token.
- `nix flake check` and `nix fmt -- --fail-on-change` are the CI `check` job.
