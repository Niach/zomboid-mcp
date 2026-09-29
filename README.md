# Zomboid MCP — Claude hacks the simulation

A Project Zomboid (Build 42) mod plus a bundled MCP server that gives Claude (or any MCP client) live control over a running game: query the world, spawn things, build with tiles, change weather and time, manage players, and push brand-new visuals (textures, sprites, overlays) to every connected player. Nothing needs a restart or a Workshop update.

The project is in progress. See [docs/PLAN.md](docs/PLAN.md) for the architecture and [docs/ENGINE_NOTES.md](docs/ENGINE_NOTES.md) for the verified engine facts.

## Layout
- `mod/Contents/mods/ZomboidMCP/`: the Workshop item (`42/media/lua/{shared,server,client}/ZomboidMCP`). The MCP server ships inside the mod under `mcp/` and the skill under `skill/`.
- `tools/`: the dev CLI (`pz`), Workshop upload and server deploy.
- `spikes/`: experiments. `art/`: sample art.

## Install (target)
1. Subscribe to the Workshop item and enable **Zomboid MCP** (server: add it to `WorkshopItems` / `Mods`).
2. `claude mcp add zomboid -- python3 "<workshop>/3810456179/mods/ZomboidMCP/mcp/zomboid_mcp.py"`. Add `--ssh root@host --lua-dir /path/to/Zomboid/Lua` for a remote dedicated server.
