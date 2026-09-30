# Deploying Zomboid MCP (ZOM-9)

Everything here changes the live server or the Workshop item: do it with the owner in chat. Deployment specifics
(ssh target, container, volume, SteamCMD paths, Steam user, Workshop id) live in `~/.config/zomboid-mcp/local.env`
and never in the repo (see `docs/local.env.example`).

## 1. Workshop upload (public)

```sh
make test                              # everything green
tools/upload.sh --dry-run              # shows the generated VDF and the SteamCMD command
tools/upload.sh "0.3.0: scripting-first bridge, client runtime, MCP server"
```

- `tools/upload.sh` renders `tools/workshop.vdf.template` (title "Zomboid MCP", **visibility 0 = public**,
  `contentfolder` = `mod/Contents`, preview = the poster) and runs SteamCMD from the isolated HOME
  `$ZMCP_STEAMCMD_HOME`, then verifies: the public API must report `result=1, visibility=0`, and an anonymous
  `workshop_download_item` must fetch `mods/ZomboidMCP/mod.info` identical to the repo.
- **SteamCMD logs in with the owner's account and kicks their desktop Steam.** Only when they are not playing.
- **Never use visibility 3.** It produced a private item and every join hung at `GettingServerInfo`.
- Re-running the script re-uploads; `tools/upload.sh --verify` checks without uploading.

## 2. Server switch (Coolify service, one restart)

The container (`danixu86/project-zomboid-dedicated-server`) reads its mod lists from the environment and writes
`Server/*.ini`. **Done on 2026-09-30** (steps 1-7 below, kept as the record and for a redo): the compose now has the
Workshop id, `\ZomboidMCP` in `MOD_IDS`, the ZomboidMCP bind mount, and the prototype files are gone.
`PauseEmpty=true`, `DoLuaChecksum=false`.

Changes in the Coolify compose (API token in `~/.config/coolify/config.json`, context "home"; the API wants
`docker_compose_raw` **base64-encoded** in the PATCH body; save, then `POST .../services/<uuid>/restart`):

1. `WORKSHOP_IDS`: append `;3810456179`.
2. `MOD_IDS`: append `;\ZomboidMCP` (**single backslash**; the image escapes it itself).
3. Volumes: replace the `vapps` bind mount with
   `/opt/zomboid-lua/ZomboidMCP:/home/steam/pz-dedicated/media/lua/server/ZomboidMCP:ro`
   (dev hot reload: `tools/deploy_server.sh` syncs the repo's server Lua there; files load at startup like vanilla
   server Lua and `reloadlua ZomboidMCP/<file>.lua` re-runs one live).
4. On the host: `rm -rf /opt/zomboid-lua/vapps` and, in the Lua dir, the `vapps_*` files
   (`vapps_client_halo.lua`, `vapps_cmd.txt`, `vapps_events.log`, `vapps_run.lua`, `vapps_status.json`) plus the dev
   scratch files `zmcp_src_*.lua`, `zmcp_boot.lua`, `zmcp_run.lua`.
5. `tools/deploy_server.sh` once, so the mount holds the merged server Lua (Json.lua is copied alongside; the mod's
   own copy loads too and the mounted one wins after `reloadlua ZomboidMCP/Bridge.lua`).
6. Restart the service (kicks the players: announce it). Then verify:
   - `tools/pz log 200` shows `SERVER STARTED`, `[ZomboidMCP] bridge_loaded`, `[ZomboidMCP] visuals_loaded`, no Lua
     errors, and `workshop_log.txt` has neither "private" nor "Access Denied".
   - A client with the mod can join (not stuck at `GettingServerInfo`) and the client's `console.txt` shows
     `[ZomboidMCP]` and a `client_hello` event arrives (`tools/pz events`).
   - `ZMCP_POLL_FILE=ZomboidMCP/ZMCPPoll.lua` in `local.env` (the old `VappsGuardian.lua` bootstrap is gone), and
     `tools/pz status` answers while the server is paused.
7. Remove the dev-only bootstrap tooling from the repo: `tools/dev_bootstrap.lua`, `pz bootstrap`, `pz legacy` (done).

## 3. Local install

```sh
mod/Contents/mods/ZomboidMCP/mcp/install.sh --env-file ~/.config/zomboid-mcp/local.env
# = claude mcp add zomboid -- python3 <mod>/mcp/zomboid_mcp.py --env-file ~/.config/zomboid-mcp/local.env
#   + the zomboid-engine skill into ~/.claude/skills/
python3 mod/Contents/mods/ZomboidMCP/mcp/zomboid_mcp.py --env-file ~/.config/zomboid-mcp/local.env --check
```

For the Workshop copy use the path under `~/.steam/steam/steamapps/workshop/content/108600/3810456179/mods/ZomboidMCP`.

## 4. Acceptance demos (with the owner, ideally with a friend online)

1. `status`, `players_list`
2. bananas: `falling_items {item: "Base.Banana", count: 20, player: "<owner>"}`; pick one up
3. giant snail: `texture_upload {id: "snail", png_path: "art/snail.png"}` then
   `world_sprite {id: "snail", texture: "snail", x, y, tiles: 3, path: [[x+10, y]], speed: 0.5, loop: "pingpong"}`
4. static 3D Claude star: `model_upload {id: "star", mesh_path: "art/3d/zmcp_star.x", png_path: "art/3d/zmcp_star.png", scale: 3}`
   then `model_place {id: "star", x, y}`; moving via `entity3d_*` if ZOM-11 landed
5. a tile structure: `build_structure` wall ring, `remove_object` to clear it
6. a flappy bird screen app (`app_start` with `examples/apps/flappy.lua`, ZOM-10)
7. a scene with a passive zombie merchant (`scene_start` with `examples/scenes/merchant.lua`, ZOM-10)
8. hot reload without restart: `script_install` a tool, call it, `script_remove`

## 5. Memory

Update `~/.claude/projects/-home-niach/memory/project_zomboid_mcp.md`: install command, Workshop state, the
poll file, where the dev mount is, and the Unlisted pitfall.
