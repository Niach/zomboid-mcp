---
name: zomboid-engine
description: The Project Zomboid (Build 42) engine handbook for the zomboid MCP. Use it whenever the user wants to hack the simulation, script or change a running Project Zomboid game or server, create things in-game (spawn items, zombies, vehicles, weather, time, build with tiles, teleport or heal players), draw on players' screens (overlays, HUDs, screen apps such as a flappy bird), push runtime textures, world sprites or 3D models, write persistent Lua scripts or scenes, or asks what the PZ Lua API can do. Also for any run_lua_server / run_lua_client / texture_upload / model_upload / world_sprite / falling_items call.
---

# Zomboid engine handbook

You drive a live Project Zomboid 42.21 game through the `zomboid` MCP. It is **scripting-first**: `run_lua_server` and
`run_lua_client` run Lua you write inside the game, `script_install` keeps it, and the curated tools cover the common
operations with validated arguments (`texture_upload`, `world_sprite`, `falling_items`, `model_upload` + `model_place` / `entity3d_spawn`,
`spawn_item`, `give_item`, `spawn_zombies`, `spawn_vehicle`, `set_weather`, `set_time`, `teleport`, `build_structure`...).
Rules and limits in one page: [CONSTRAINTS](CONSTRAINTS.md), summarized below.

## Mental model

**Two Lua states.** The **server** state (dedicated server, or the host in single player / co-op) owns the world and
runs `run_lua_server`, server scripts and every `Api/*.lua` tool. Each **client** (every player with the mod) runs its own
state: `run_lua_client` and client scripts run there, and only there can anything be drawn or the local player's body be
changed. The two talk through `sendServerCommand` / `sendClientCommand` (flat tables, about 3 kB per message; the mod
chunks code and assets for you).

**Authority: who owns what in multiplayer.**

| owned by the server (change it there, synced to everyone, saved) | owned by each client (change it on that client) |
|---|---|
| zombies (`addZombiesInOutfit`, `zed:Kill(p)`), animals | player position (`teleport`, `p:teleportTo`) |
| items in inventories (`AddItem` + `sendAddItemToContainer`) and on the ground (`AddWorldInventoryItem`) | body damage, infection, healing (`heal` / `cure` client commands) |
| tile objects (`IsoObject.new` + `transmitAddObjectToSquare`), vehicles (`addVehicleDebug`, `repair`) | appearance (`getHumanVisual()` + `sendVisual`), stats and moodles |
| weather (`transmitServer*`), time (`setTimeOfDay`), XP, traits, god mode, server sounds | everything on screen: overlays, HUDs, apps, sprites, textures, 3D layers |

**Loaded area.** Only squares near online players exist: `getCell():getGridSquare(x, y, z)` is nil elsewhere and
`ZMCP.square(x, y, z)` errors. Get a reference position from `players_list` first.

**Pause when empty.** A dedicated server with `PauseEmpty=true` and nobody online runs **no Lua event at all**; the MCP
wakes the bridge through the server console (`reloadlua`) when it has console access, otherwise it reports the server as
paused. While paused nothing simulates and nothing is loaded. `status` shows `paused` / `tps`; `wait_for` blocks until a
player is online. Requests older than 60 s are refused as stale.

**Tick budget.** Server `OnTick` runs about 10×/s and a chunk blocks the whole server: keep `run_lua_server` under
~100 ms, never loop waiting, do periodic work in `ZMCP.tickHooks.<name>` and long sequences as coroutines
(`guides/scenes-and-apps.md`). A client chunk that loops forever freezes that player's game.

**Kahlua (the game's Lua 5.1).** No `io`, no `bit`, **no `next()`** (test emptiness with `for _ in pairs(t) do return false end`),
`tostring()` needs an argument, `os.date` works, `loadstring` works, `require` of new files does not (paste the code).
Java overloads are chosen by argument count; Java lists are `:size()` / `:get(i)` with i from 0. Return plain tables,
strings, numbers, booleans from a chunk; userdata comes back as `tostring`.

## Decision tree

1. **Is there a curated tool?** Use it: validated arguments, correct authority, events, late-join persistence. See the
   tool list (`status`, `players_list`, `player_info`, `world_query`, `wait_for`, `events_poll`, `api_search`,
   `lua_examples`, `teleport`, `give_item`, `spawn_item`, `spawn_vehicle`, `vehicle_fix`, `spawn_zombies`,
   `kill_zombies_area`, `place_object`, `remove_object`, `build_structure`, `collision_place`, `collision_list`,
   `collision_clear`, `set_weather`, `set_time`, `texture_upload`, `texture_pixel`, `model_upload`, `model_place`,
   `model_remove` (`{pid}` from `model_place` / `visuals_list`: takes the carrier item, its blocker and the record away),
   `model_move` (glides a placed model to another pose; it stays a world object) and `model_swap` (another model on the
   same carrier: figures that must stand IN the world are placements, not `entity3d_*`),
   `world_sprite`, `falling_items`, `overlay_draw`, `server_message`,
   `capture_input`, `visuals_list`, `clear_visuals`, `entity3d_spawn`, `entity3d_move`, `entity3d_rotate`,
   `entity3d_remove`, `entity3d_list`, `server_console`, `script_install`, `script_list`, `script_remove`).
2. **World state, zombies, items, vehicles, weather, time, XP, traits, server events?** `run_lua_server`. Helpers:
   `ZMCP.player(name)`, `ZMCP.players()`, `ZMCP.square(x, y, z)`, `ZMCP.zombiesNear(x, y, z, r)`,
   `ZMCP.toClients(cmd, args[, player])`, `ZMCP.event(kind, data)`, `ZMCP.readFile` / `writeFile`.
3. **Drawing, input, textures, sprites, 3D, camera, client-side player state?** `run_lua_client` (one player or all).
   Helpers: `ZMCPClient.on(name, event, fn)`, `off(name)`, `capture(on)`, `tex.get(id)`, `tex.draw(...)`, `sprites`,
   `draw`, `models.name(id)`, `send(cmd, args)`, `screen()`, `zoom()`, `player()`, `now()`; `getPlayer()` is the local player.
4. **Must it survive a reload, a restart or a player joining?** `script_install` with `side` `server` or `client`
   (`guides/scripts-and-persistence.md`). Write re-runnable code: state in one global table, handlers removed before
   re-adding, a `stop()` for cleanup.
5. **A sequence over time with actors, waits and triggers?** A scene (`guides/scenes-and-apps.md`, written by the
   scene SDK issue) or a server script with a coroutine ticked from `ZMCP.tickHooks`.
6. **Unknown API?** `api_search "IsoGridSquare:transmit"` for signatures, `lua_examples "setHairModel"` for vanilla
   call sites, then the category files under `reference/`.

## Working loop

`status` → `players_list` (positions, who is online) → act (tool or script) → verify (`world_query`, `player_info`,
`events_poll` for `client_texture` / `client_model` / `client_exec_result` / `script_error`) → clean up
(`clear_visuals`, `script_remove`, remove what you spawned). Ask before hordes, teleports, killing, trait changes,
building next to players or restarts: real people are playing. Never touch the owner's single-player game uninvited.

## Guides (each with tested snippets)

- [2d-overlays-and-apps](guides/2d-overlays-and-apps.md): full-screen overlay, `drawRect` / `drawLine2` / `drawText` /
  `drawTextureScaled`, `ZMCPClient.on` hooks, input capture, a complete Flappy Bird.
- [textures-runtime](guides/textures-runtime.md): the verified PNG pipeline (`texture_upload`, generations, limits, pixel art).
- [world-sprites](guides/world-sprites.md): world-anchored billboards, zoom scaling, paths, the giant snail.
- [3d-static-models](guides/3d-static-models.md): `model_upload` + `model_place`, `.x` meshes from Python, Y-up axes, lift.
- [3d-moving-entities](guides/3d-moving-entities.md): smooth moving/rolling/spinning models on the 3D layer (`entity3d_*`), and why world items flicker.
- [world-and-tiles](guides/world-and-tiles.md): squares, tile objects, sprite names, building and removing, lights, doors.
- [items](guides/items.md): item types, inventories, ground items, falling items, containers.
- [zombies-and-actors](guides/zombies-and-actors.md): spawning, outfits, killing, passive puppet zombies as actors.
- [vehicles](guides/vehicles.md): scripts, spawning, parts, fuel, repair, removal.
- [weather-time](guides/weather-time.md): rain, storms, lightning, clock, seasons.
- [players](guides/players.md): client-authoritative body and infection, teleport, XP, traits, appearance, god mode.
- [networking-and-sync](guides/networking-and-sync.md): server ⇄ client commands, chunking, late joiners, events.
- [performance-and-safety](guides/performance-and-safety.md): heap, files, budgets, `pcall` every hook, cleanup, etiquette.
- [scripts-and-persistence](guides/scripts-and-persistence.md): `script_install`, re-runnable code, hot reload, ModData, new tools.
- [scenes-and-apps](guides/scenes-and-apps.md): coroutine scenes, actors, timelines, screen apps (scene SDK issue).

## Recipes (complete, ready to run)

[bananas from the sky](recipes/bananas-from-the-sky.md), [giant snail](recipes/giant-snail.md),
[Claude star](recipes/claude-star.md) (static and rolling), [tile house](recipes/tile-house.md),
[horde event](recipes/horde-event.md), [merchant actor](recipes/merchant-actor.md), [supply drop](recipes/supply-drop.md),
[flappy bird](recipes/flappy-bird.md), [custom HUD](recipes/custom-hud.md). Index: [recipes/README](recipes/README.md).

## Reference

[reference/README](reference/README.md): the categorized engine API map generated from the index (world, characters,
items, vehicles, climate/time, UI/rendering, networking, scripting/events, globals, Java helpers). Skim it for names,
then `api_search` for exact signatures and `lua_examples` for how vanilla calls them.
