# MCP tools

Generated from `mod/Contents/mods/ZomboidMCP/mcp/zmcp_catalog.py` by `tools/gen_tools_md.py` (`make docs`); do not edit by hand. The catalogue is the schema every tool is validated against, and `tests/mcp/test_catalog.py` checks it against the Lua tools (`ZMCP.tool(...)` in `Api/*.lua` and `Bridge.lua`). Direction: **scripting-first** (top of `docs/PLAN.md`): `run_lua_server` / `run_lua_client` do everything, the curated tools below cover the common operations with validated arguments. The raw Lua behind each one is in `docs/recipes/`.

Arguments marked * are required. `player` arguments accept the account name or the character name and may be omitted when exactly one player is online. Coordinates are world tiles (`x` east, `y` south, `z` floor). Tools that the MCP process answers itself are marked *local*; the others run in the game through the bridge (`docs/PROTOCOL.md`).

| tool | what |
|---|---|
| [`run_lua_server`](#run_lua_server) | Run a Lua chunk in the server Lua state (the dedicated server, or the host in single-player / co-op) and return what
it returns |
| [`run_lua_client`](#run_lua_client) | Run a Lua chunk on players' clients (every connected client with the ZomboidMCP mod, or one player's client) and
return each client's result |
| [`script_install`](#script_install) | Install or replace a persistent script |
| [`script_list`](#script_list) | List installed persistent scripts per side: {server: [{name, file, installed}], client: [...]} |
| [`script_remove`](#script_remove) | Forget a persistent script so it no longer runs on reloads, restarts or joins |
| [`status`](#status) | Snapshot of the game as seen by the MCP process: bridge liveness (live / paused / stale / not_running with a hint),
heartbeat age, online players with position and health, in-game time, bridge version, registered game tools and
installed scripts, the API index version, and how this MCP is connected |
| [`players_list`](#players_list) | List online players: account name, character name, position (x, y, z), health, dead/alive, access level, online id
and the vehicle they are in |
| [`player_info`](#player_info) | Full server-side picture of one online player: position and facing, profession, health (overall, infection flag and
level, bleeding parts, asleep, god mode, invisible), hours survived, zombie kills, traits [{id, label}], skills
[{id, name, level, xp}], inventory summary (item types by count, weight), equipped and worn items, moodles and stats.
Read-only |
| [`world_query`](#world_query) | Inspect the loaded world around a tile: zombies [{id, x, y, z, outfit, crawling, female, health, target}], players,
objects with their sprite names [{x, y, index, sprite, type, name}], ground items [{x, y, type, name, condition}] and
vehicles [{id, script, x, y, z, speed, engineRunning, engineQuality, driver}] within `radius` tiles, plus how many
squares in the area were not loaded |
| [`wait_for`](#wait_for) | Block until the game bridge is alive and a condition holds: a named player is online, or at least `min_players`
are |
| [`events_poll`](#events_poll) | Events the game appended since your last call: script errors, client results and client texture/model loads, tool
actions (spawns, placements, teleports), bridge reloads, and notes your own scripts write with ZMCP.event(kind,
data) |
| [`api_search`](#api_search) | Search the Project Zomboid engine API index: every Java class the Lua VM can reach (fields, constructors, methods
with parameter names, inheritance) plus the global Lua functions |
| [`lua_examples`](#lua_examples) | Show how vanilla Lua uses an engine symbol: real call sites from the game's media/lua (`calls`, best first, with
file:line), Lua function definitions matching the name (`defs`; a table name lists its methods), and hand-verified
snippets for things vanilla never calls (`curated`, e.g |
| [`teleport`](#teleport) | Move a player to a tile |
| [`give_item`](#give_item) | Put items straight into a player's main inventory |
| [`spawn_item`](#spawn_item) | Drop items on the ground at a tile (real world items everyone can see and pick up) |
| [`spawn_vehicle`](#spawn_vehicle) | Spawn a vehicle by script name (e.g |
| [`vehicle_fix`](#vehicle_fix) | Repair every part and/or fill the gas tank of a vehicle: the one a player is in, the nearest to that player, or the
nearest to a tile within `radius` |
| [`spawn_zombies`](#spawn_zombies) | Spawn a group of zombies at a tile (addZombiesInOutfit) |
| [`kill_zombies_area`](#kill_zombies_area) | Kill every zombie within `radius` tiles of a tile or of a player |
| [`place_object`](#place_object) | Place a vanilla tile sprite as a new world object on a square (IsoObject + transmitAddObjectToSquare): walls
('walls_exterior_wooden_01_2'), furniture, fences, lamps, decorations |
| [`remove_object`](#remove_object) | Remove a world object from a square (transmitRemoveItemFromSquare) |
| [`build_structure`](#build_structure) | Place many tile sprites in one call (batched place_object): a wall ring, a hut, a decorated square |
| [`collision_place`](#collision_place) | Give custom 3D models (model_place, entity3d_*) real collision: place invisible blocking objects on a rectangle of
squares (x..x+w-1, y..y+h-1 at level z), or remove them (kind = remove) |
| [`collision_list`](#collision_list) | List the invisible collision blockers placed by collision_place / model_place {collide}: all of them, or those
within `radius` tiles of x,y,z: [{x, y, z, kind, name, sprite, loaded, present}] plus the blocker sprite table
(kind, sprite name, numeric id, flags, registered) |
| [`collision_clear`](#collision_clear) | Remove collision blockers: every registered one (all = true) or those within `radius` of x,y,z |
| [`set_weather`](#set_weather) | Change the weather for everyone: start rain of a given intensity, a thunderstorm, or clear the sky |
| [`set_time`](#set_time) | Set the in-game clock for the whole server: hour of day (0..24, fractional) and optionally day, month and year
(1-based) |
| [`texture_upload`](#texture_upload) | Upload a PNG to every connected client (or one player) and register it under a texture id for world_sprite,
overlay_draw (kind 'texture'), falling_items and your own run_lua_client drawing code (ZMCPClient.tex.get(id)).
Give the image as base64 or as a file path on this machine |
| [`texture_pixel`](#texture_pixel) | Register art without a PNG: a pixel sprite drawn with rectangles, usable wherever a texture id is (world_sprite,
overlay_draw) |
| [`model_upload`](#model_upload) | Register a runtime 3D model on every connected client: a Project Zomboid .x text mesh plus a PNG texture, given as
base64 or as file paths on this machine |
| [`model_place`](#model_place) | Place an uploaded 3D model in the world as a STATIC object: the server spawns a carrier world item on the square
(default Base.TirePiece) and sets its world model to the registered ModelScript, so it renders in 3D with proper
occlusion and no flicker |
| [`model_remove`](#model_remove) | Remove a static model placed with model_place: the carrier world item, the collision blocker placed with it (if
`collide` was set) and the placement record, on the server and on every client |
| [`world_sprite`](#world_sprite) | Show a texture in the world for everyone (or one player), anchored bottom-centre at a tile position, scaled with the
camera zoom and always drawn on top of the world (no wall occlusion; it is not an object and has no collision).
Texture: an uploaded id, 'item:Base.Banana' (an inventory icon) or any vanilla texture path getTexture accepts.
Motion: `path` waypoints from x,y walked at `speed` tiles/s with loop = loop | pingpong | once; `bob` hops;
`flip` auto mirrors it when travelling left |
| [`falling_items`](#falling_items) | Make items visibly fall from the sky around a point and become real ground items when they land |
| [`overlay_draw`](#overlay_draw) | Draw a primitive on players' screens (everyone or one player): a line, a filled or outlined rectangle, text or a
texture, anchored to the screen (pixels; negative x/y count from the right/bottom edge) or to a world tile (follows
the camera and zoom; sizes are pixels at zoom 1, drawn above the tile) |
| [`server_message`](#server_message) | Show a message to every player (or one) through the client mod: mode 'notify' is a box at the top of the screen
that fades after ttl seconds, 'halo' is text floating over the player's head, 'chat' a line in the chat panel and
'say' a speech bubble from the player |
| [`capture_input`](#capture_input) | Screen apps: make every client's (or one player's) overlay swallow mouse events and sit above the vanilla UI
(on = true), or release it again (on = false) |
| [`visuals_list`](#visuals_list) | Everything the visual subsystem knows: uploaded textures [{id, gen, chars|pixel}], registered 3D models [{id, name,
gen, scale}], static model placements [{pid, model, name, x, y, z, item, itemId, collide, missing, restored}]
(model_place; `missing` = the carrier item is gone from its square, `restored` = how often the model had to be
re-applied), persistent world sprites, client scripts [{name, file}], connected clients with their mod version and
what they loaded, the outgoing queue length and pending item landings |
| [`clear_visuals`](#clear_visuals) | Remove client visuals on every client (or one player): 'all' clears world sprites, overlays, falling items, notices,
every script hook and the moving 3D entities (textures, models and client scripts stay); or one category: sprites, overlays, falling,
notices, textures, models, hooks |
| [`entity3d_spawn`](#entity3d_spawn) | Show a MOVING 3D entity on every connected client: an uploaded model (model_upload id) or a vanilla ModelScript
name (e.g |
| [`entity3d_move`](#entity3d_move) | Move a 3D entity smoothly on every client: tween to x,y,z over `duration` seconds (or at `speed` tiles per second,
`ease` for a soft start and stop), or follow a `path` of waypoints from its current position at `speed` with a
`loop` mode |
| [`entity3d_rotate`](#entity3d_rotate) | Change how a 3D entity is oriented and animated on every client: base rotation in degrees (rx, ry, rz), a
constant spin, the rolling radius (0 = stop rolling), facing the travel direction, its height above the ground
or its scale |
| [`entity3d_remove`](#entity3d_remove) | Remove one moving 3D entity (id) or every entity (all = true) from every client and from the server registry, so
late joiners do not get it either |
| [`entity3d_list`](#entity3d_list) | The moving 3D entities the server knows, with their current position computed from the stored motion:
[{id, model, x, y, z, h, scale, rotation [rx, ry, rz], spin, roll, face, motion (static|path|to), moving, loop,
clients {user: {ok, model, err}}}] |
| [`server_console`](#server_console) | Send a raw command to the dedicated server's admin console (e.g |

## Scripting (primary)

### `run_lua_server`

*game*. Run a Lua chunk in the server Lua state (the dedicated server, or the host in single-player / co-op) and return what it returns. THE primary tool: anything the engine can do, you can script here. Consult the "zomboid engine handbook" skill (skill/SKILL.md in the mod: a categorized map of every Lua-reachable engine function, guides for overlays and screen apps, textures, 3D models, world/tiles, items, zombies, vehicles, weather, players and scenes, tested snippets and every known B42 gotcha) first, then `api_search` for exact signatures.  Where it runs: on the game thread between two ticks, with full engine access (getOnlinePlayers(), getCell(), getClimateManager(), sendServerCommand(...)) and the ZMCP helpers: ZMCP.player(name), ZMCP.players(), ZMCP.square(x,y,z), ZMCP.zombiesNear(x,y,z,r), ZMCP.toClients(cmd, args[, player]), ZMCP.event(kind, data), ZMCP.readFile/writeFile, ZMCP.tool(name, desc, fn) to register a new tool, ZMCP.tickHooks.<name> = function(t) end. Authority: server-owned state (zombies, items, world objects, vehicles, weather, time, XP, traits, god mode) changes for everyone immediately and is saved with the world. Client-owned state (player position, body/infection, appearance, stats, anything drawn) cannot be changed reliably from here: use run_lua_client. Return values: use `return`; one value comes back as JSON, several as an array. Tables become JSON objects/arrays, Java objects are stringified (return fields such as p:getX() instead). nil returns null. Errors: compile errors and runtime errors come back as a tool error with the Lua message and line; the server keeps running. print() output goes to the server console, not to you (use server_console or return the text). Limits: the chunk blocks the whole server while it runs, so keep it under ~100 ms and never loop waiting for something (use ZMCP.tickHooks for periodic work and script_install for anything that must survive a reload). Only the loaded area near players exists. Globals persist between calls in the same Lua state; `require` of new files does not work at runtime (paste the code instead). Sources above 32 kB are passed to the game as a file automatically.

| argument | type | description |
|---|---|---|
| `code` * | string | Lua source. Example: 'local p = ZMCP.player("niach"); return {x = p:getX(), y = p:getY()}'. |
| `timeout_s` | number | How long to wait for the result, in seconds. (default `20`, 1..600) |

### `run_lua_client`

*game + local*. Run a Lua chunk on players' clients (every connected client with the ZomboidMCP mod, or one player's client) and return each client's result. Use it for everything the client owns or draws: overlays and screen apps, runtime textures and world sprites, 3D models, camera, sounds only one player should hear, and client-authoritative player state (position, body damage and infection, appearance via getHumanVisual() + sendVisual, stats via getStats()). See the "zomboid engine handbook" skill (skill/SKILL.md in the mod: a categorized map of every Lua-reachable engine function, guides for overlays and screen apps, textures, 3D models, world/tiles, items, zombies, vehicles, weather, players and scenes, tested snippets and every known B42 gotcha) for the drawing, input and world-anchoring recipes.  Where it runs: the source is chunked over sendServerCommand (about 3 kB per message) to the target clients, executed there with loadstring, and each client sends its return value back; the MCP waits up to timeout_s for the replies. `getPlayer()` is the local player on each client; `isClient()` is true in multiplayer; server-only functions are unavailable. Client script API: ZMCPClient.on(name, event, fn) with event = render(ui) | tick(now) | keyDown(key) | keyUp | keyHeld | mouseDown(x,y,button) | mouseUp | mouseMove | mouseWheel(delta); ZMCPClient.off(name); ZMCPClient.capture(true) makes the overlay swallow the mouse for screen apps; ZMCPClient.tex.get(id) / draw(...), ZMCPClient.sprites, ZMCPClient.draw, ZMCPClient.models.name(id), ZMCPClient.send(cmd, args) to talk to the server (Events.OnClientCommand there), ZMCPJson. A hook that throws is removed after the first error and logged. Authority: effects are client-side. Visuals are seen only by the clients that ran the code (all of them when `player` is omitted); position/body/appearance changes are then synced by the engine to everyone. Nothing here changes the saved world; use run_lua_server for that. Return values: {results: {<player>: {ok, value|error, ms}}, missing: [players that did not answer in time]}. Tables come back JSON-decoded, other values as strings. Errors: per-client Lua errors are in results (and in events_poll as client_exec_result); a broken chunk never crashes a client's game, but an infinite loop freezes that player's game: keep it short and use hooks for continuous work. Not persistent: late joiners do not get it (use script_install with side 'client').

| argument | type | description |
|---|---|---|
| `code` * | string | Lua source to run on the client. `getPlayer()` is the local player; use `return` for a value. |
| `player` | string | Only this player's client (account or character name); default: every connected client. |
| `id` | string | Script id for events and client_results; default generated. |
| `timeout_s` | number | How long to wait for client replies, in seconds. (default `10`, 1..120) |

### `script_install`

*game*. Install or replace a persistent script. side 'server' (default): the Lua source is written to the game's Lua directory as zmcp_script_<name>.lua.txt, executed right now in the server Lua state (like run_lua_server) and recorded so it runs again on every bridge reload and server start, before players join. side 'client': the source is stored on the server, pushed to every connected client now (like run_lua_client) and re-sent to every player who joins; register its hooks with ZMCPClient.on(<name>, event, fn) so script_remove can drop them. Use it for anything that must keep working: new tools (ZMCP.tool(name, desc, fn) makes them appear in tools/list), tick hooks (ZMCP.tickHooks.<name>), event handlers, HUDs, screen apps. Return value: {name, side, file, result} (server: the chunk's return value; client: chunks sent and the recipients). Errors: a server script with a compile or runtime error is reported and not recorded (the previous version stays). Rules from the "zomboid engine handbook" skill (skill/SKILL.md in the mod: a categorized map of every Lua-reachable engine function, guides for overlays and screen apps, textures, 3D models, world/tiles, items, zombies, vehicles, weather, players and scenes, tested snippets and every known B42 gotcha): make the code re-runnable (keep state in a global table like `MyMod = MyMod or {}`, store handlers and Events.X.Remove them before adding again), keep big data in files rather than ModData, never block the tick.

| argument | type | description |
|---|---|---|
| `name` * | string | Script name (letters, digits, _ and -). Reusing a name replaces that script. |
| `code` * | string | Lua source of the script. |
| `side` | `server` \| `client` | Where it lives and runs. (default `server`) |

### `script_list`

*game*. List installed persistent scripts per side: {server: [{name, file, installed}], client: [...]}. Read-only. Use run_lua_server with ZMCP.readFile(file) to read a script's source.

No arguments.

### `script_remove`

*game*. Forget a persistent script so it no longer runs on reloads, restarts or joins. Server side: the file stays and anything the script already registered (tools, tick hooks, event handlers) stays active until its own cleanup runs or the server restarts; to undo immediately, run the cleanup with run_lua_server. Client side: every client drops the hooks registered under the script's name at once.

| argument | type | description |
|---|---|---|
| `name` * | string | Script name. |
| `side` | `server` \| `client` | Where it lives. (default `server`) |

## Discover

### `status`

*local*. Snapshot of the game as seen by the MCP process: bridge liveness (live / paused / stale / not_running with a hint), heartbeat age, online players with position and health, in-game time, bridge version, registered game tools and installed scripts, the API index version, and how this MCP is connected. Answered from the heartbeat file the server writes every 2 s (refreshed through a console poll when the server is paused and the MCP has console access), so it never needs the game to tick. Call it first in a session and whenever a tool times out.

No arguments.

### `players_list`

*game*. List online players: account name, character name, position (x, y, z), health, dead/alive, access level, online id and the vehicle they are in. Server-side, read-only, instant. In single-player the local player is returned.

No arguments.

### `player_info`

*game*. Full server-side picture of one online player: position and facing, profession, health (overall, infection flag and level, bleeding parts, asleep, god mode, invisible), hours survived, zombie kills, traits [{id, label}], skills [{id, name, level, xp}], inventory summary (item types by count, weight), equipped and worn items, moodles and stats. Read-only. Moodles, stats and infection are the server's copy of client-owned state and may lag a few seconds.

| argument | type | description |
|---|---|---|
| `player` | string | Account name or character name of an online player. Optional when exactly one player is online. |
| `inventory_limit` | integer | Max distinct item types in the inventory summary. (default `60`, 1..500) |

### `world_query`

*game*. Inspect the loaded world around a tile: zombies [{id, x, y, z, outfit, crawling, female, health, target}], players, objects with their sprite names [{x, y, index, sprite, type, name}], ground items [{x, y, type, name, condition}] and vehicles [{id, script, x, y, z, speed, engineRunning, engineQuality, driver}] within `radius` tiles, plus how many squares in the area were not loaded. Server-side, read-only, limited to the loaded area near online players (the centre square must be loaded) and to 40 tiles for objects/items/vehicles, 80 for zombies. Use it to find sprite names and object indexes for place_object / remove_object and to check what spawn tools did.

| argument | type | description |
|---|---|---|
| `x` * | integer | World tile x (east). Use players_list for a reference position. |
| `y` * | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `radius` | integer | Radius in tiles. (default `10`, 0..80) |
| `what` | `all` \| `zombies` \| `objects` \| `items` \| `vehicles` \| `players` | Category to list; default all. (default `all`) |
| `limit` | integer | Max entries per category. (default `200`, 1..5000) |
| `include_floor` | boolean | Include floor tiles among the objects. (default `False`) |

### `wait_for`

*local*. Block until the game bridge is alive and a condition holds: a named player is online, or at least `min_players` are. Use it after `status` reports the server paused (no players online). Read-only; returns the status once the condition is met, or a timeout error.

| argument | type | description |
|---|---|---|
| `player` | string | Wait for this player (account or character name) to be online. |
| `min_players` | integer | Minimum number of online players. (default `1`, 0..) |
| `timeout_s` | number | Give up after this many seconds. (default `300`, 1..3600) |

### `events_poll`

*local*. Events the game appended since your last call: script errors, client results and client texture/model loads, tool actions (spawns, placements, teleports), bridge reloads, and notes your own scripts write with ZMCP.event(kind, data). Each event is {t: unix seconds, kind, data}. The first call in a session returns the recent tail; pass the returned `cursor` (a byte offset) to resume explicitly. Read-only and works while the server is paused.

| argument | type | description |
|---|---|---|
| `cursor` | integer | Byte offset returned by the previous call; omit to continue from where this session left off. |
| `limit` | integer | Return at most this many (newest) events. (default `100`, 1..2000) |
| `kinds` | array of string | Only these event kinds, e.g. ['client_exec_result', 'script_error']. |

### `api_search`

*local*. Search the Project Zomboid engine API index: every Java class the Lua VM can reach (fields, constructors, methods with parameter names, inheritance) plus the global Lua functions. Case-insensitive name match ranked exact, prefix, substring (a regex is accepted too). `Class.member` or `Class:member` searches one class and its superclasses. Each hit has a Java `signature` (e.g. `IsoLightSource IsoCell:addLamppost(int x, int y, ...)`) and a `lua` call hint (`obj:addLamppost(x, y, z, r, g, b, rad)`, `IsoObject.new(square, tile, name)`, `getTexture(filename)`); a `warning` marks members whose class is not exposed to Lua. Local and instant, works without the game. The index is built by tools/build_api_index.py for the installed game version; when it is missing the tool says so instead of guessing.

| argument | type | description |
|---|---|---|
| `query` * | string | Name, substring or regex, e.g. 'addLamppost', 'IsoGridSquare:transmit', 'getTexture'. |
| `kind` | `any` \| `class` \| `method` \| `field` \| `ctor` \| `global` | Restrict to a record type. (default `any`) |
| `limit` | integer | Maximum results. (default `40`, 1..500) |

### `lua_examples`

*local*. Show how vanilla Lua uses an engine symbol: real call sites from the game's media/lua (`calls`, best first, with file:line), Lua function definitions matching the name (`defs`; a table name lists its methods), and hand-verified snippets for things vanilla never calls (`curated`, e.g. addLamppost, transmitAddObjectToSquare). `Class.new` and `Events.OnTick` are valid symbols. When nothing matches, `related` lists similar symbols to retry with; when a local game install is present it is grepped as a fallback. Local and instant. Use it before writing Lua to copy the exact call shape the engine expects.

| argument | type | description |
|---|---|---|
| `query` * | string | Engine symbol, e.g. 'setHairModel', 'IsoObject.new', 'Events.OnTick', 'sendServerCommand'. |
| `limit` | integer | Maximum call sites / definitions. (default `8`, 1..100) |
| `context` | integer | Context lines for the grep fallback only. (default `0`, 0..20) |

## Players

### `teleport`

*game*. Move a player to a tile. Position is client-authoritative: the move is sent to that player's client mod, which teleports the local player and then reports the new position to the server through the normal update path, so the player needs the mod. Everyone sees the player appear at the target; the target chunks load around them (a short black screen for far jumps). Returns {sent, user, x, y, z, from}; verify with player_info a second later. Affects a character: only when asked.

| argument | type | description |
|---|---|---|
| `player` | string | Account name or character name of an online player. Optional when exactly one player is online. |
| `x` * | number | Target tile x (fractional allowed). |
| `y` * | number | Target tile y. |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |

### `give_item`

*game*. Put items straight into a player's main inventory. Server-authoritative (AddItem + sendAddItemToContainer): the item appears for the player at once and is real for everyone. Item type is 'Module.Name' like 'Base.Axe', 'Base.Banana' (search with run_lua_server over getScriptManager():getAllItems(), see docs/recipes/item_types.md). Count is capped at 100 per call. Weight limits are ignored (the player may become overloaded). Returns the items created.

| argument | type | description |
|---|---|---|
| `player` | string | Account name or character name of an online player. Optional when exactly one player is online. |
| `item` * | string | Full item type, e.g. 'Base.Katana'. |
| `count` | integer | How many. (default `1`, 1..100) |

## World

### `spawn_item`

*game*. Drop items on the ground at a tile (real world items everyone can see and pick up). Server-authoritative (AddWorldInventoryItem). The square must be loaded (near a player). Up to 200 per call; `scatter` spreads them over neighbouring tiles. Use give_item for inventories and falling_items for a visible fall from the sky. Returns {type, name, placed, skipped, squares}.

| argument | type | description |
|---|---|---|
| `item` * | string | Full item type, e.g. 'Base.Banana'. |
| `x` * | integer | World tile x (east). Use players_list for a reference position. |
| `y` * | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `count` | integer | How many. (default `1`, 1..200) |
| `scatter` | integer | Spread over this many tiles around x,y. (default `0`, 0..20) |

### `spawn_vehicle`

*game*. Spawn a vehicle by script name (e.g. 'Base.CarNormal', 'Base.PickUpTruck', 'Base.SportsCar'; list them with run_lua_server over getScriptManager():getAllVehicleScripts(), see docs/recipes/vehicle_types.md) at a tile, facing a direction. Server-authoritative (addVehicleDebug): appears for everyone at once, on a loaded square with free flat ground only. The vehicle spawns in random condition; use vehicle_fix to repair and refuel it. Ask the owner before spawning next to players. Returns the vehicle's id, script, position and engine state.

| argument | type | description |
|---|---|---|
| `script` * | string | Vehicle script name, e.g. 'Base.CarNormal' (short names are matched too). |
| `x` * | integer | World tile x (east). Use players_list for a reference position. |
| `y` * | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `dir` | `N` \| `NE` \| `E` \| `SE` \| `S` \| `SW` \| `W` \| `NW` | Facing direction. (default `S`) |

### `vehicle_fix`

*game*. Repair every part and/or fill the gas tank of a vehicle: the one a player is in, the nearest to that player, or the nearest to a tile within `radius`. Server-authoritative (vehicle:repair, GasTank content + transmitPartModData); other players see the repaired state. Loaded vehicles only. Returns the vehicle, what was done and the parts before and after.

| argument | type | description |
|---|---|---|
| `player` | string | Use this player's current vehicle, or the nearest one to them. |
| `x` | integer | World tile x (east). Use players_list for a reference position. |
| `y` | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `radius` | integer | Search radius in tiles when looking for the nearest vehicle. (default `12`, 0..40) |
| `repair` | boolean | Repair every part to full condition. (default `True`) |
| `refuel` | boolean | Fill the gas tank. (default `True`) |

### `spawn_zombies`

*game*. Spawn a group of zombies at a tile (addZombiesInOutfit). Server-authoritative: real zombies for everyone. `count` is capped at 100 per call; the square must be loaded. Optional outfit name (e.g. 'Police', 'Fireman', 'Nurse'; list them with run_lua_server over getAllOutfits(), see docs/recipes/outfits.md). This is a horde event and dangerous for players: do it only when asked. Returns the zombie ids.

| argument | type | description |
|---|---|---|
| `x` * | integer | World tile x (east). Use players_list for a reference position. |
| `y` * | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `count` | integer | Number of zombies. (default `1`, 1..100) |
| `outfit` | string | Outfit name, or omit for random. |
| `female_chance` | integer | Percent chance each zombie is female. (default `50`, 0..100) |

### `kill_zombies_area`

*game*. Kill every zombie within `radius` tiles of a tile or of a player. Server-authoritative (setAttackedBy + Kill); bodies drop for everyone. Limited to the loaded area and a radius of 80. Returns the number killed.

| argument | type | description |
|---|---|---|
| `player` | string | Centre on this player instead of x/y/z (and credit the kills to them). |
| `x` | integer | World tile x (east). Use players_list for a reference position. |
| `y` | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `radius` | integer | Radius in tiles. (default `10`, 0..80) |
| `killer` | string | Credit the kills to this player. |

### `place_object`

*game*. Place a vanilla tile sprite as a new world object on a square (IsoObject + transmitAddObjectToSquare): walls ('walls_exterior_wooden_01_2'), furniture, fences, lamps, decorations. Server-authoritative, persistent in the save, visible to everyone. The square must be loaded. Sprite names are validated against the live sprite map (search with run_lua_server, see docs/recipes/sprite_search.md, or copy one from world_query). Placed objects have no collision or function unless the sprite's properties provide them. Ask the owner before building next to players. Returns the object's index on the square (for remove_object).

| argument | type | description |
|---|---|---|
| `sprite` * | string | Tile sprite name, e.g. 'walls_exterior_wooden_01_2'. |
| `x` * | integer | World tile x (east). Use players_list for a reference position. |
| `y` * | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `name` | string | Optional object name (shown in world_query), e.g. 'Campfire'. |

### `remove_object`

*game*. Remove a world object from a square (transmitRemoveItemFromSquare). Server-authoritative and persistent. Select by sprite name (first match, or every match with `all`) or by object index from world_query. Without sprite or index it only lists the square's objects. Floors are refused unless `force`. Removing vanilla map objects is irreversible without a map reset. Returns what was removed and the remaining objects.

| argument | type | description |
|---|---|---|
| `x` * | integer | World tile x (east). Use players_list for a reference position. |
| `y` * | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `sprite` | string | Remove objects with this sprite name. |
| `index` | integer | Object index on the square, from world_query or a previous listing. (0..) |
| `all` | boolean | Remove every object matching the sprite, not just the first. (default `False`) |
| `force` | boolean | Allow removing the floor tile. (default `False`) |

### `build_structure`

*game*. Place many tile sprites in one call (batched place_object): a wall ring, a hut, a decorated square. Up to 500 objects; each entry is {x, y, z?, sprite, name?}. Per-entry errors (unloaded square, unknown sprite) are collected and the rest is still placed unless `stop_on_error`. Server-authoritative and persistent. Ask the owner before building next to players. Returns {placed, errors, objects}.

| argument | type | description |
|---|---|---|
| `objects` * | array of object | Objects to place. |
| `stop_on_error` | boolean | Abort at the first failing entry. (default `False`) |

### `collision_place`

*game*. Give custom 3D models (model_place, entity3d_*) real collision: place invisible blocking objects on a rectangle of squares (x..x+w-1, y..y+h-1 at level z), or remove them (kind = remove). Each blocker is a plain world object (IsoObject named 'ZMCP_collision', sprite 'zmcp_collision_<kind>') whose sprite carries the vanilla movement and sight flags (solid / solidtrans / WallN+collideN+cutN / WallW+collideW+cutW), so players cannot walk through, zombies path around it (the path map is updated at once) and line of sight respects it; nothing is drawn. It is server-authoritative, saved in the chunk like any placed tile and synced to every client (the mod registers the sprites on both sides). One blocker per kind per square; placing again is a no-op. Squares that are not loaded are skipped and listed. world_query shows blockers by sprite/name, collision_list lists the registry, remove_object works on them too. Returns {placed, existing, removed, unloaded, squares, sprite}.

| argument | type | description |
|---|---|---|
| `x` * | integer | World tile x (east). Use players_list for a reference position. |
| `y` * | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `w` | integer | Rectangle width in tiles (east). (default `1`, 1..50) |
| `h` | integer | Rectangle height in tiles (south). (default `1`, 1..50) |
| `kind` * | `solid` \| `solidtrans` \| `wall_n` \| `wall_w` \| `wall_nw` \| `remove` | What the blocker does: 'solid' = the whole square blocks walking, zombie pathing and line of sight; 'solidtrans' = blocks walking and pathing but not sight (rails, edges); 'wall_n' / 'wall_w' = an invisible wall on the square's north / west edge (blocks crossing that edge and sight through it, like a vanilla wall); 'wall_nw' = both edges (a corner); 'remove' = take every blocker off the rectangle. |
| `name` | string | Label kept in the registry (collision_list), e.g. 'bridge-north-rail'. |

### `collision_list`

*game*. List the invisible collision blockers placed by collision_place / model_place {collide}: all of them, or those within `radius` tiles of x,y,z: [{x, y, z, kind, name, sprite, loaded, present}] plus the blocker sprite table (kind, sprite name, numeric id, flags, registered). Read-only and self-healing: an entry whose square is loaded but has no blocker any more (removed with remove_object, or the chunk was reset) is dropped and counted in `stale`.

| argument | type | description |
|---|---|---|
| `x` | integer | World tile x (east). Use players_list for a reference position. |
| `y` | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `radius` | integer | Radius in tiles around x,y (omit x,y for everything). (default `10`, 0..200) |

### `collision_clear`

*game*. Remove collision blockers: every registered one (all = true) or those within `radius` of x,y,z. Only loaded squares can be cleared; blockers on unloaded squares stay in the world and in the registry (`unloaded` counts them, run it again when someone is near). Server-authoritative and synced. Returns {removed, unloaded, remaining}.

| argument | type | description |
|---|---|---|
| `all` | boolean | Clear every blocker. (default `False`) |
| `x` | integer | World tile x (east). Use players_list for a reference position. |
| `y` | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `radius` | integer | Radius in tiles around x,y. (default `10`, 0..200) |

### `set_weather`

*game*. Change the weather for everyone: start rain of a given intensity, a thunderstorm, or clear the sky. Server- authoritative through the climate manager (transmitServerStartRain / TriggerStorm / StopWeather); clients follow within seconds. The simulation may drift back to natural weather over time. Returns the weather after the change.

| argument | type | description |
|---|---|---|
| `kind` * | `rain` \| `storm` \| `clear` | Weather to set. |
| `intensity` | number | Rain/storm intensity 0..1. (default `0.7`, 0..1) |

### `set_time`

*game*. Set the in-game clock for the whole server: hour of day (0..24, fractional) and optionally day, month and year (1-based). Server-authoritative and synced to all clients. Sudden jumps affect darkness, zombie behaviour and player fatigue. Returns the time before and after.

| argument | type | description |
|---|---|---|
| `hour` | number | Hour of day, e.g. 6.5 for 06:30. (0..24) |
| `day` | integer | Day of month. (1..31) |
| `month` | integer | Month. (1..12) |
| `year` | integer | Year, e.g. 1993. (1..9999) |

## Visuals (client push)

### `texture_upload`

*game + local*. Upload a PNG to every connected client (or one player) and register it under a texture id for world_sprite, overlay_draw (kind 'texture'), falling_items and your own run_lua_client drawing code (ZMCPClient.tex.get(id)). Give the image as base64 or as a file path on this machine. Client-side: the image is chunked over the network (~3 kB per message, about 1 s per 30 kB), written into each client's Zomboid/Lua folder under a fresh file name (textures are cached by path, so re-uploading an id makes a new generation) and loaded with getTexture. The base64 is kept in a file on the server for late joiners, never in memory. Keep images at most 256x256 and about 100 kB; the hard limit is 1.2 MB of base64. Returns {id, gen, chars, chunks}; each client reports the load as a client_texture event (ok, w, h) in events_poll.

| argument | type | description |
|---|---|---|
| `id` * | string | Id (letters, digits, _ . -). Reusing an id replaces that entry. |
| `png_base64` | string | PNG file contents, base64-encoded (large values are passed to the game as a file automatically). |
| `png_path` | string | Instead of png_base64: path of a PNG file on this machine, read by the MCP process. |
| `player` | string | Only this player's client (account or character name); default: every connected client. |

### `texture_pixel`

*game*. Register art without a PNG: a pixel sprite drawn with rectangles, usable wherever a texture id is (world_sprite, overlay_draw). def = {palette: {"a": [r, g, b, a], ...}, rows: ["aab.", "..a."]} where each character of a row is a palette key, '.' (or any key missing from the palette) is transparent and colours are 0..1 or 0..255. Keep it small (a 32x32 sprite is 1024 rectangles per frame). Client-side, sent to every client and to late joiners.

| argument | type | description |
|---|---|---|
| `id` * | string | Id (letters, digits, _ . -). Reusing an id replaces that entry. |
| `def` * | object | Pixel definition: {w?, h?, palette, rows}. |

### `model_upload`

*game + local*. Register a runtime 3D model on every connected client: a Project Zomboid .x text mesh plus a PNG texture, given as base64 or as file paths on this machine. Clients write both files under Zomboid/Lua/media/ and register a ModelScript named 'zmcp_<id>_<gen>' (ZMCPClient.models.name(id) in run_lua_client code). Then model_place puts it in the world as a static object. Model space is Y-up with the origin at ground level; keep meshes small (a few thousand triangles, at most 1.2 MB of base64 per file). Files are kept on the server for late joiners. Returns {id, gen, name, chunks}; each client reports the registration as a client_model event in events_poll. See docs/ENGINE_NOTES.md 'Runtime 3D models' and art/3d/ for a verified example mesh.

| argument | type | description |
|---|---|---|
| `id` * | string | Id (letters, digits, _ . -). Reusing an id replaces that entry. |
| `mesh_base64` | string | The .x mesh text, base64-encoded. |
| `mesh_path` | string | Instead of mesh_base64: path of the .x file on this machine. |
| `png_base64` | string | Texture PNG, base64-encoded. |
| `png_path` | string | Instead of png_base64: path of the PNG on this machine. |
| `scale` | number | Model scale factor. (default `1`, 0.01..100) |
| `player` | string | Only this player's client (account or character name); default: every connected client. |

### `model_place`

*game*. Place an uploaded 3D model in the world as a STATIC object: the server spawns a carrier world item on the square (default Base.TirePiece) and sets its world model to the registered ModelScript, so it renders in 3D with proper occlusion and no flicker. Server-authoritative and PERMANENT: the model name lives in the carrier item's ModData, which is saved with the world and sent to clients with the item; the placement is also recorded (visuals_list 'placements') and re-sent to every joining client, and whenever the square loads the model is re-applied if the item lost it. A client that has not registered the ModelScript yet (files still streaming after a join) shows the carrier item's flat sprite until the registration lands, then the 3D model. The model itself has NO collision: `collide` puts an invisible blocker on the same square in one call (true = solid; or a collision_place kind such as solidtrans). Offsets are fractions of the tile, oz lifts the model. Returns {pid, placed, x, y, z, item, itemId, collide}; model_remove {pid} takes it away. Moving 3D objects are entity3d_spawn / entity3d_move (a transparent 3D layer, smooth but no occlusion).

| argument | type | description |
|---|---|---|
| `id` * | string | Model id from model_upload. |
| `x` * | integer | World tile x (east). Use players_list for a reference position. |
| `y` * | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `item` | string | Carrier world item type. (default `Base.TirePiece`) |
| `ox` | number | Offset within the tile, x. (default `0.5`, -5..5) |
| `oy` | number | Offset within the tile, y. (default `0.5`, -5..5) |
| `oz` | number | Height offset. (default `0`, -5..10) |
| `yrot` | number | Rotation around the vertical axis in degrees. (-360..360) |
| `collide` | `false` \| `true` \| `solid` \| `solidtrans` \| `wall_n` \| `wall_w` \| `wall_nw` | Collision under the model: 'true' / 'solid' (blocks walking, zombies and sight), 'solidtrans' (blocks walking, see-through), 'wall_n' / 'wall_w' / 'wall_nw' (invisible wall on those edges), 'false' (default: none). (default `false`) |
| `pid` | string | Placement id (letters, digits, _ . -); default generated (p1, p2, ...). |

### `model_remove`

*game*. Remove a static model placed with model_place: the carrier world item, the collision blocker placed with it (if `collide` was set) and the placement record, on the server and on every client. Server-authoritative. One placement (`pid` from model_place / visuals_list) or every placement (`all`). Squares that are not loaded cannot be touched: their world item stays until someone visits, the record is dropped anyway (`unloaded` counts them). Returns {removed, unloaded, missing, blockers, pids}.

| argument | type | description |
|---|---|---|
| `pid` | string | Placement id from model_place. |
| `all` | boolean | Remove every placement. (default `False`) |

### `world_sprite`

*game*. Show a texture in the world for everyone (or one player), anchored bottom-centre at a tile position, scaled with the camera zoom and always drawn on top of the world (no wall occlusion; it is not an object and has no collision). Texture: an uploaded id, 'item:Base.Banana' (an inventory icon) or any vanilla texture path getTexture accepts. Motion: `path` waypoints from x,y walked at `speed` tiles/s with loop = loop | pingpong | once; `bob` hops; `flip` auto mirrors it when travelling left. Size: `scale` multiplies the texture pixels at zoom 1, or `tiles` sets the width in world tiles. Persists for late joiners unless `ttl` or `player` is set. Reuse an id to replace or move it; clear_visuals removes it. Returns {id, persistent}.

| argument | type | description |
|---|---|---|
| `id` | string | Sprite id; reusing it replaces the sprite. Default generated. |
| `texture` * | string | Texture id from texture_upload / texture_pixel, 'item:<type>', or a vanilla texture path. |
| `x` * | number | Tile x (fractional allowed). |
| `y` * | number | Tile y. |
| `z` | number | Floor. (default `0`) |
| `scale` | number | Pixel multiplier at zoom 1. (default `1`, 0.01..100) |
| `tiles` | number | Width in world tiles instead of scale. (0.05..50) |
| `path` | array of array of number | Waypoints after x,y: [[x, y, z?], ...]; the sprite walks them at `speed`. |
| `speed` | number | Tiles per second along the path. (default `0`, 0..100) |
| `loop` | `loop` \| `pingpong` \| `once` | Path behaviour. (default `loop`) |
| `bob` | number | Hop height in pixels at zoom 1. (default `0`, 0..) |
| `bobHz` | number | Hops per second. (default `1`, 0..) |
| `flip` | `auto` \| `0` \| `1` | Mirror horizontally: 'auto' when moving left, '1' always, '0' never. (default `auto`) |
| `opacity` | number | Opacity 0..1. (default `1`, 0..1) |
| `ttl` | number | Remove after this many seconds (not persisted for late joiners). (0..) |
| `fade` | number | Fade-in/out seconds. (default `0`, 0..) |
| `anchor` | `bottom` \| `center` | Anchor point at the position. (default `bottom`) |
| `player` | string | Only this player's client (account or character name); default: every connected client. |

### `falling_items`

*game*. Make items visibly fall from the sky around a point and become real ground items when they land. The fall (the item's inventory icon with a growing shadow and a bounce) is a client-side visual pushed to everyone with the mod; each landing spawns a real server-authoritative item on that square that anyone can pick up. Centre on a player or a tile; the area must be loaded. Up to 200 items. Returns {id, item, count, spawning, done_in}.

| argument | type | description |
|---|---|---|
| `item` * | string | Full item type, e.g. 'Base.Banana'. |
| `count` | integer | How many. (default `10`, 1..200) |
| `player` | string | Centre on this player instead of x/y/z. |
| `x` | integer | World tile x (east). Use players_list for a reference position. |
| `y` | integer | World tile y (south). |
| `z` | integer | Floor level, 0 = ground. (default `0`, 0..31) |
| `radius` | number | Spread in tiles. (default `3`, 0..30) |
| `duration` | number | Seconds over which the drops start. (default `3`, 0..60) |
| `fall` | number | Seconds each drop takes to fall. (default `1.2`, 0.3..30) |
| `spawn` | boolean | Spawn the real items on landing. (default `True`) |
| `scale` | number | Icon size multiplier. (default `1`, 0.1..10) |

### `overlay_draw`

*game*. Draw a primitive on players' screens (everyone or one player): a line, a filled or outlined rectangle, text or a texture, anchored to the screen (pixels; negative x/y count from the right/bottom edge) or to a world tile (follows the camera and zoom; sizes are pixels at zoom 1, drawn above the tile). Client-side, nothing changes in the world. ttl removes it after n seconds, otherwise it stays until clear_visuals {what: 'overlays', id}. Reusing an id replaces it. Colours r,g,b,a are 0..1 (or 0..255). For animated HUDs or many shapes write a render hook with run_lua_client instead. Returns {id}.

| argument | type | description |
|---|---|---|
| `kind` * | `line` \| `rect` \| `text` \| `texture` | Primitive. |
| `anchor` | `screen` \| `world` | Coordinate space. (default `screen`) |
| `x` * | number | X (pixels, or tile x). |
| `y` * | number | Y (pixels, or tile y). |
| `z` | number | Floor for the world anchor. (default `0`) |
| `x2` | number | Line end x. |
| `y2` | number | Line end y. |
| `z2` | number | Line end floor. |
| `w` | number | Width in pixels at zoom 1. (default `32`) |
| `h` | number | Height in pixels at zoom 1. (default `32`) |
| `r` | number | Colour component, 0..1 (or 0..255). (0..255) |
| `g` | number | Colour component, 0..1 (or 0..255). (0..255) |
| `b` | number | Colour component, 0..1 (or 0..255). (0..255) |
| `a` | number | Alpha 0..1. (default `1`, 0..1) |
| `ttl` | number | Seconds until it disappears; omit to keep. (0..) |
| `id` | string | Overlay id; reusing it replaces the overlay. Default generated. |
| `text` | string | Text to draw (kind 'text'). |
| `font` | `small` \| `medium` \| `large` \| `title` | Font for text. (default `medium`) |
| `centre` | boolean | Centre text on x. (default `False`) |
| `fill` | boolean | Filled rectangle (false = border only). (default `True`) |
| `thick` | number | Line thickness in pixels. (default `1`, 1..20) |
| `tex` | string | Texture id (kind 'texture'). |
| `flip` | boolean | Mirror the texture horizontally. (default `False`) |
| `player` | string | Only this player's client (account or character name); default: every connected client. |

### `server_message`

*game*. Show a message to every player (or one) through the client mod: mode 'notify' is a box at the top of the screen that fades after ttl seconds, 'halo' is text floating over the player's head, 'chat' a line in the chat panel and 'say' a speech bubble from the player. Client-side; players without the mod see nothing (the vanilla fallback is server_console 'servermsg <text>'). Keep it short. Returns {sent, mode, to}.

| argument | type | description |
|---|---|---|
| `text` * | string | Message text. |
| `mode` | `notify` \| `halo` \| `chat` \| `say` | How to show it. (default `notify`) |
| `player` | string | Only this player's client (account or character name); default: every connected client. |
| `ttl` | number | Seconds a notify box stays. (default `5`, 0.5..120) |
| `r` | number | Colour component, 0..1 (or 0..255). (0..255) |
| `g` | number | Colour component, 0..1 (or 0..255). (0..255) |
| `b` | number | Colour component, 0..1 (or 0..255). (0..255) |
| `font` | `small` \| `medium` \| `large` \| `title` | Font for notify. (default `large`) |
| `time` | number | Halo display time in frames. (default `300`, 1..) |

### `capture_input`

*game*. Screen apps: make every client's (or one player's) overlay swallow mouse events and sit above the vanilla UI (on = true), or release it again (on = false). While captured, ZMCPClient.on hooks for mouseDown/mouseUp/mouseMove/ mouseWheel receive the clicks and the game world does not. Key hooks always receive keys. Scripts can also call ZMCPClient.capture(true) themselves; clear_visuals {what: 'hooks'} releases it. Client-side.

| argument | type | description |
|---|---|---|
| `on` | boolean | Capture (true) or release (false). (default `True`) |
| `player` | string | Only this player's client (account or character name); default: every connected client. |

### `visuals_list`

*game*. Everything the visual subsystem knows: uploaded textures [{id, gen, chars|pixel}], registered 3D models [{id, name, gen, scale}], static model placements [{pid, model, name, x, y, z, item, itemId, collide, missing, restored}] (model_place; `missing` = the carrier item is gone from its square, `restored` = how often the model had to be re-applied), persistent world sprites, client scripts [{name, file}], connected clients with their mod version and what they loaded, the outgoing queue length and pending item landings. All of it persists across server restarts (ModData + files) and is re-streamed to every joining client. Read-only, server-side; also pings the clients so their entries refresh for the next call.

No arguments.

### `clear_visuals`

*game*. Remove client visuals on every client (or one player): 'all' clears world sprites, overlays, falling items, notices, every script hook and the moving 3D entities (textures, models and client scripts stay); or one category: sprites, overlays, falling, notices, textures, models, hooks. With `id` only that sprite / overlay / texture / model / hook name. Server-side registries are updated too (unless only one player is targeted), so late joiners do not receive removed sprites.

| argument | type | description |
|---|---|---|
| `what` | `all` \| `sprites` \| `overlays` \| `falling` \| `notices` \| `textures` \| `models` \| `hooks` | What to clear. (default `all`) |
| `id` | string | Only this id / hook name. |
| `player` | string | Only this player's client (account or character name); default: every connected client. |

## Moving 3D entities (client push)

### `entity3d_spawn`

*game*. Show a MOVING 3D entity on every connected client: an uploaded model (model_upload id) or a vanilla ModelScript name (e.g. 'RadioBlue_Ground'), drawn on a transparent full-screen 3D layer (UI3DScene) synced to the iso camera, so it moves and rotates smoothly every frame without the chunk-cache flicker of world items. Always drawn on top of the world (no wall occlusion) and below the HUD; pure client side, every player with the mod sees the same motion (late joiners too). Give it a start position, optional height h (tiles above the ground; defaults to roll), extra scale, a base rotation in degrees, and either a constant spin, a wheel radius (roll: faces the direction of travel and rolls like a coin), a path with speed and loop mode, or a tween target (tox/toy/toz + duration or speed). Returns {id, model, x, y, z, h, motion}; each client reports client_entity3d events (ok or the createModel error) in events_poll. Units are tiles (1 model unit = 1 tile at scale 1). See docs/recipes/entity3d.md.

| argument | type | description |
|---|---|---|
| `model` * | string | model_upload id, or a vanilla ModelScript name. |
| `x` * | number | World x in tiles (fractions allowed; east). |
| `y` * | number | World y in tiles (fractions allowed; south). |
| `z` | number | Floor level, 0 = ground. (default `0`, 0..31) |
| `id` | string | Entity id (letters, digits, _ . -). |
| `h` | number | Height of the model origin above the ground in tiles. (-5..50) |
| `scale` | number | Extra scale on top of the ModelScript scale. (default `1`, 0.001..100) |
| `rx` | number | Base rotation about X in degrees. |
| `ry` | number | Base rotation about Y (vertical) in degrees. |
| `rz` | number | Base rotation about Z in degrees (applied first, in model space). |
| `spin` | string | Constant rotation 'dx,dy,dz' in degrees per second about the model X, Y and Z axes; '' stops it. |
| `roll` | number | Wheel radius in tiles: the entity turns into its travel direction and rolls about its model Z axis by distance / radius (the Claude star: mesh radius 0.45 x scale 3 = 1.35). 0 turns rolling off. (0..) |
| `face` | boolean | Turn into the travel direction (rotation about Y) without rolling. |
| `path` | string | Waypoints after the start position, 'x,y,z;x,y,z;...' (z optional), walked at `speed` tiles per second. |
| `speed` | number | Tiles per second along the path, or for a tween the speed that sets its duration. (default `1`, 0..) |
| `loop` | `loop` \| `pingpong` \| `once` | How the path repeats. (default `loop`) |
| `tox` | number | Tween target x (tiles). |
| `toy` | number | Tween target y. |
| `toz` | number | Tween target level. |
| `duration` | number | Tween duration in seconds (alternative: speed). (0..) |
| `ease` | boolean | Tween with a smooth start and stop (smoothstep) instead of constant speed. (default `False`) |

### `entity3d_move`

*game*. Move a 3D entity smoothly on every client: tween to x,y,z over `duration` seconds (or at `speed` tiles per second, `ease` for a soft start and stop), or follow a `path` of waypoints from its current position at `speed` with a `loop` mode. With x,y,z and no duration/speed it jumps. A new motion starts from wherever the entity is right now; a rolling entity keeps rolling. Returns {id, x, y, z, motion, duration}.

| argument | type | description |
|---|---|---|
| `id` * | string | Entity id (letters, digits, _ . -). |
| `x` | number | World x in tiles (fractions allowed; east). |
| `y` | number | World y in tiles (fractions allowed; south). |
| `z` | number | Floor level, 0 = ground. (default `0`, 0..31) |
| `duration` | number | Tween duration in seconds. (0..) |
| `speed` | number | Tiles per second along the path, or for a tween the speed that sets its duration. (default `1`, 0..) |
| `ease` | boolean | Tween with a smooth start and stop (smoothstep) instead of constant speed. (default `False`) |
| `path` | string | Waypoints after the start position, 'x,y,z;x,y,z;...' (z optional), walked at `speed` tiles per second. |
| `loop` | `loop` \| `pingpong` \| `once` | How the path repeats. (default `loop`) |

### `entity3d_rotate`

*game*. Change how a 3D entity is oriented and animated on every client: base rotation in degrees (rx, ry, rz), a constant spin, the rolling radius (0 = stop rolling), facing the travel direction, its height above the ground or its scale. Only the arguments given change. Returns the new rotation state.

| argument | type | description |
|---|---|---|
| `id` * | string | Entity id (letters, digits, _ . -). |
| `rx` | number | Rotation about X in degrees. |
| `ry` | number | Rotation about Y (vertical) in degrees. |
| `rz` | number | Rotation about Z in degrees. |
| `spin` | string | Constant rotation 'dx,dy,dz' in degrees per second about the model X, Y and Z axes; '' stops it. |
| `roll` | number | Wheel radius in tiles: the entity turns into its travel direction and rolls about its model Z axis by distance / radius (the Claude star: mesh radius 0.45 x scale 3 = 1.35). 0 turns rolling off. (0..) |
| `face` | boolean | Turn into the travel direction (rotation about Y) without rolling. |
| `h` | number | Height above the ground in tiles. (-5..50) |
| `scale` | number | Extra scale. (0.001..100) |

### `entity3d_remove`

*game*. Remove one moving 3D entity (id) or every entity (all = true) from every client and from the server registry, so late joiners do not get it either. Uploaded models stay registered (clear_visuals {what: 'models'} forgets them).

| argument | type | description |
|---|---|---|
| `id` | string | Entity id (letters, digits, _ . -). |
| `all` | boolean | Remove every entity. (default `False`) |

### `entity3d_list`

*game*. The moving 3D entities the server knows, with their current position computed from the stored motion: [{id, model, x, y, z, h, scale, rotation [rx, ry, rz], spin, roll, face, motion (static|path|to), moving, loop, clients {user: {ok, model, err}}}]. `clients` shows which player's client created the scene object (or the createModel error), so you can tell whether the entity is actually visible.

No arguments.

## Server admin

### `server_console`

*local*. Send a raw command to the dedicated server's admin console (e.g. 'players', 'save', 'servermsg Hello', 'additem user Base.Axe', 'reloadlua ZomboidMCP/Bridge.lua', 'help') and return the console output it produced. Server-authoritative admin power, independent of the Lua bridge: works while the server is paused. Available only when the MCP was started with --console-container or --console-fifo (dedicated servers, usually over ssh); otherwise it explains what is missing. Commands like 'quit' stop the server for everybody: ask first.

| argument | type | description |
|---|---|---|
| `command` * | string | Console command line. |
| `wait_s` | number | Seconds to wait for output. (default `2`, 0.2..30) |
| `raw` | boolean | Return unfiltered log lines (default filters engine noise like AnimState/Saving). (default `False`) |
