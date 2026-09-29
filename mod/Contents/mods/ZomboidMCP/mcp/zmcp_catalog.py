"""Tool catalogue for the Zomboid MCP server (scripting-first, see the top of docs/PLAN.md).

The primary tools are ``run_lua_server`` and ``run_lua_client`` plus persistent
scripts: Claude writes Lua and runs it live, guided by the "zomboid engine
handbook" skill. The curated tools cover the most common operations with
validated arguments. These descriptions and JSON schemas are the main
documentation an MCP client sees, so each one states where the code runs,
**authority** (server-owned and synced to everyone vs. client-owned and pushed
to the client mod), **who sees** the effect, how return values and errors come
back, and the **limits** we know about.

One namespace: an MCP tool name is the game-side tool name (``game``), except
for the tools the MCP process answers itself (``local``). ``docs/TOOLS.md`` is
generated from this file (``tools/gen_tools_md.py``) and ``tests/mcp/test_catalog.py``
checks it against the Lua. Tools registered in the running game that are not
listed here are exposed too, as passthrough tools with a free-form argument object.
"""

PROTOCOL_VERSION = "2025-06-18"
SUPPORTED_PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")

HANDBOOK = ("the \"zomboid engine handbook\" skill (skill/SKILL.md in the mod: a categorized map of every "
            "Lua-reachable engine function, guides for overlays and screen apps, textures, 3D models, world/tiles, "
            "items, zombies, vehicles, weather, players and scenes, tested snippets and every known B42 gotcha)")

SERVER_INSTRUCTIONS = """\
Zomboid MCP controls a running Project Zomboid (Build 42) game through the ZomboidMCP mod. It is scripting-first:
you write Lua and run it live; nothing needs a restart or a Workshop update.

- `run_lua_server` runs Lua in the server (or single-player host) Lua state; `run_lua_client` runs Lua on every
  connected client or one player's client and returns each client's value. `script_install` makes Lua persistent
  (server: re-run on every bridge load and server start; client: re-sent to every player who joins);
  `script_list` / `script_remove` manage them. Before writing Lua read the "zomboid engine handbook" skill
  (skill/SKILL.md in the mod) and use `api_search` (engine signatures with Lua call hints) and `lua_examples`
  (how vanilla Lua calls it). The handbook's gotchas are real: Kahlua has no `io`/`bit`/`next`, overloads are
  chosen by argument count, `tostring()` without an argument throws, `require` of new files fails at runtime.
- Curated tools cover the common operations with validated arguments: `status`, `players_list`, `player_info`,
  `world_query`, `spawn_item`, `give_item`, `spawn_vehicle`, `vehicle_fix`, `spawn_zombies`, `kill_zombies_area`,
  `place_object`, `remove_object`, `build_structure`, `set_weather`, `set_time`, `teleport`, `texture_upload`,
  `texture_pixel`, `model_upload`, `model_place`, `world_sprite`, `falling_items`, `overlay_draw`,
  `server_message`, `capture_input`, `visuals_list`, `clear_visuals`, `server_console`. Everything else is a script.
- Authority: the server owns zombies, items, world objects, vehicles, weather, time, XP, traits and god mode; code
  run on the server takes effect for everybody at once. A player's position, body damage, infection, appearance,
  stats and everything drawn on screen (overlays, textures, sprites, 3D models) belong to that player's client, so
  run that code with `run_lua_client`; it reaches players running the ZomboidMCP mod (all players on a server that
  requires it).
- Every tool call is a file in the game's Zomboid/Lua directory executed by the server-side bridge on the next game
  tick (well under a second). A dedicated server with PauseEmpty=true is frozen when nobody is online; when the MCP
  has console access it wakes the bridge through the console (`reloadlua`), otherwise calls time out with a
  "server paused" error. Call `status` first (never blocks) and `wait_for` to block until somebody joins.
- Only the loaded area (roughly 100 tiles around online players) exists on the server; squares outside it are nil.
- `player` arguments accept the account name or the character name and may be omitted when exactly one player is
  online. `events_poll` returns what the game appended since your last call (script errors, client results, joins,
  deaths, notes your scripts write with ZMCP.event).
- Everything you do is visible to real players immediately. Anything destructive or affecting a player's character
  (hordes, killing, teleporting, changing traits) should be what they asked for.
"""


def _obj(props, required=None, extra=False):
    out = {"type": "object", "properties": props, "additionalProperties": extra}
    if required:
        out["required"] = list(required)
    return out


def _s(desc, **kw):
    d = {"type": "string", "description": desc}
    d.update(kw)
    return d


def _i(desc, **kw):
    d = {"type": "integer", "description": desc}
    d.update(kw)
    return d


def _n(desc, **kw):
    d = {"type": "number", "description": desc}
    d.update(kw)
    return d


def _b(desc, **kw):
    d = {"type": "boolean", "description": desc}
    d.update(kw)
    return d


def _arr(desc, items, **kw):
    d = {"type": "array", "description": desc, "items": items}
    d.update(kw)
    return d


PLAYER = _s("Account name or character name of an online player. Optional when exactly one player is online.")
PLAYER_ONLY = _s("Only this player's client (account or character name); default: every connected client.")
X = _i("World tile x (east). Use players_list for a reference position.")
Y = _i("World tile y (south).")
Z = _i("Floor level, 0 = ground.", default=0, minimum=0, maximum=31)
ID = _s("Id (letters, digits, _ . -). Reusing an id replaces that entry.", pattern="^[A-Za-z0-9_.-]+$")
COLOR_COMPONENT = _n("Colour component, 0..1 (or 0..255).", minimum=0, maximum=255)

TOOLS = []


def tool(name, description, schema, game=None, local=None):
    TOOLS.append({"name": name, "description": description.strip(), "inputSchema": schema,
                  "game": game, "local": local})


# ------------------------------------------------------------------ scripting (primary)
tool("run_lua_server", """
Run a Lua chunk in the server Lua state (the dedicated server, or the host in single-player / co-op) and return what
it returns. THE primary tool: anything the engine can do, you can script here. Consult %s first, then `api_search`
for exact signatures.

Where it runs: on the game thread between two ticks, with full engine access (getOnlinePlayers(), getCell(),
getClimateManager(), sendServerCommand(...)) and the ZMCP helpers: ZMCP.player(name), ZMCP.players(),
ZMCP.square(x,y,z), ZMCP.zombiesNear(x,y,z,r), ZMCP.toClients(cmd, args[, player]), ZMCP.event(kind, data),
ZMCP.readFile/writeFile, ZMCP.tool(name, desc, fn) to register a new tool, ZMCP.tickHooks.<name> = function(t) end.
Authority: server-owned state (zombies, items, world objects, vehicles, weather, time, XP, traits, god mode) changes
for everyone immediately and is saved with the world. Client-owned state (player position, body/infection,
appearance, stats, anything drawn) cannot be changed reliably from here: use run_lua_client.
Return values: use `return`; one value comes back as JSON, several as an array. Tables become JSON objects/arrays,
Java objects are stringified (return fields such as p:getX() instead). nil returns null.
Errors: compile errors and runtime errors come back as a tool error with the Lua message and line; the server keeps
running. print() output goes to the server console, not to you (use server_console or return the text).
Limits: the chunk blocks the whole server while it runs, so keep it under ~100 ms and never loop waiting for
something (use ZMCP.tickHooks for periodic work and script_install for anything that must survive a reload). Only
the loaded area near players exists. Globals persist between calls in the same Lua state; `require` of new files
does not work at runtime (paste the code instead). Sources above 32 kB are passed to the game as a file automatically.
""" % HANDBOOK, _obj({
    "code": _s("Lua source. Example: 'local p = ZMCP.player(\"niach\"); return {x = p:getX(), y = p:getY()}'."),
    "timeout_s": _n("How long to wait for the result, in seconds.", default=20, minimum=1, maximum=600),
}, ["code"]), game="run_lua_server")

tool("run_lua_client", """
Run a Lua chunk on players' clients (every connected client with the ZomboidMCP mod, or one player's client) and
return each client's result. Use it for everything the client owns or draws: overlays and screen apps, runtime
textures and world sprites, 3D models, camera, sounds only one player should hear, and client-authoritative player
state (position, body damage and infection, appearance via getHumanVisual() + sendVisual, stats via getStats()).
See %s for the drawing, input and world-anchoring recipes.

Where it runs: the source is chunked over sendServerCommand (about 3 kB per message) to the target clients, executed
there with loadstring, and each client sends its return value back; the MCP waits up to timeout_s for the replies.
`getPlayer()` is the local player on each client; `isClient()` is true in multiplayer; server-only functions are
unavailable. Client script API: ZMCPClient.on(name, event, fn) with event = render(ui) | tick(now) | keyDown(key) |
keyUp | keyHeld | mouseDown(x,y,button) | mouseUp | mouseMove | mouseWheel(delta); ZMCPClient.off(name);
ZMCPClient.capture(true) makes the overlay swallow the mouse for screen apps; ZMCPClient.tex.get(id) / draw(...),
ZMCPClient.sprites, ZMCPClient.draw, ZMCPClient.models.name(id), ZMCPClient.send(cmd, args) to talk to the server
(Events.OnClientCommand there), ZMCPJson. A hook that throws is removed after the first error and logged.
Authority: effects are client-side. Visuals are seen only by the clients that ran the code (all of them when
`player` is omitted); position/body/appearance changes are then synced by the engine to everyone. Nothing here
changes the saved world; use run_lua_server for that.
Return values: {results: {<player>: {ok, value|error, ms}}, missing: [players that did not answer in time]}.
Tables come back JSON-decoded, other values as strings.
Errors: per-client Lua errors are in results (and in events_poll as client_exec_result); a broken chunk never
crashes a client's game, but an infinite loop freezes that player's game: keep it short and use hooks for
continuous work. Not persistent: late joiners do not get it (use script_install with side 'client').
""" % HANDBOOK, _obj({
    "code": _s("Lua source to run on the client. `getPlayer()` is the local player; use `return` for a value."),
    "player": PLAYER_ONLY,
    "id": _s("Script id for events and client_results; default generated."),
    "timeout_s": _n("How long to wait for client replies, in seconds.", default=10, minimum=1, maximum=120),
}, ["code"]), game="run_lua_client", local="run_lua_client")

tool("script_install", """
Install or replace a persistent script. side 'server' (default): the Lua source is written to the game's Lua
directory as zmcp_script_<name>.lua.txt, executed right now in the server Lua state (like run_lua_server) and
recorded so it runs again on every bridge reload and server start, before players join. side 'client': the source
is stored on the server, pushed to every connected client now (like run_lua_client) and re-sent to every player who
joins; register its hooks with ZMCPClient.on(<name>, event, fn) so script_remove can drop them.
Use it for anything that must keep working: new tools (ZMCP.tool(name, desc, fn) makes them appear in tools/list),
tick hooks (ZMCP.tickHooks.<name>), event handlers, HUDs, screen apps.
Return value: {name, side, file, result} (server: the chunk's return value; client: chunks sent and the recipients).
Errors: a server script with a compile or runtime error is reported and not recorded (the previous version stays).
Rules from %s: make the code re-runnable (keep state in a global table like `MyMod = MyMod or {}`, store handlers
and Events.X.Remove them before adding again), keep big data in files rather than ModData, never block the tick.
""" % HANDBOOK, _obj({
    "name": _s("Script name (letters, digits, _ and -). Reusing a name replaces that script.",
               pattern="^[A-Za-z0-9_-]{1,64}$"),
    "code": _s("Lua source of the script."),
    "side": _s("Where it lives and runs.", enum=["server", "client"], default="server"),
}, ["name", "code"]), game="script_install")

tool("script_list", """
List installed persistent scripts per side: {server: [{name, file, installed}], client: [...]}. Read-only. Use
run_lua_server with ZMCP.readFile(file) to read a script's source.
""", _obj({}), game="script_list")

tool("script_remove", """
Forget a persistent script so it no longer runs on reloads, restarts or joins. Server side: the file stays and
anything the script already registered (tools, tick hooks, event handlers) stays active until its own cleanup runs
or the server restarts; to undo immediately, run the cleanup with run_lua_server. Client side: every client drops the
hooks registered under the script's name at once.
""", _obj({
    "name": _s("Script name."),
    "side": _s("Where it lives.", enum=["server", "client"], default="server"),
}, ["name"]), game="script_remove")

# ------------------------------------------------------------------ discover
tool("status", """
Snapshot of the game as seen by the MCP process: bridge liveness (live / paused / stale / not_running with a hint),
heartbeat age, online players with position and health, in-game time, bridge version, registered game tools and
installed scripts, the API index version, and how this MCP is connected. Answered from the heartbeat file the server
writes every 2 s (refreshed through a console poll when the server is paused and the MCP has console access), so it
never needs the game to tick. Call it first in a session and whenever a tool times out.
""", _obj({}), local="status")

tool("players_list", """
List online players: account name, character name, position (x, y, z), health, dead/alive, access level, online id
and the vehicle they are in. Server-side, read-only, instant. In single-player the local player is returned.
""", _obj({}), game="players_list")

tool("player_info", """
Full server-side picture of one online player: position and facing, profession, health (overall, infection flag and
level, bleeding parts, asleep, god mode, invisible), hours survived, zombie kills, traits [{id, label}], skills
[{id, name, level, xp}], inventory summary (item types by count, weight), equipped and worn items, moodles and stats.
Read-only. Moodles, stats and infection are the server's copy of client-owned state and may lag a few seconds.
""", _obj({
    "player": PLAYER,
    "inventory_limit": _i("Max distinct item types in the inventory summary.", default=60, minimum=1, maximum=500),
}), game="player_info")

tool("world_query", """
Inspect the loaded world around a tile: zombies [{id, x, y, z, outfit, crawling, female, health, target}], players,
objects with their sprite names [{x, y, index, sprite, type, name}], ground items [{x, y, type, name, condition}] and
vehicles [{id, script, x, y, z, speed, engineRunning, engineQuality, driver}] within `radius` tiles, plus how many
squares in the area were not loaded. Server-side, read-only, limited to the loaded area near online players (the
centre square must be loaded) and to 40 tiles for objects/items/vehicles, 80 for zombies. Use it to find sprite
names and object indexes for place_object / remove_object and to check what spawn tools did.
""", _obj({
    "x": X, "y": Y, "z": Z,
    "radius": _i("Radius in tiles.", default=10, minimum=0, maximum=80),
    "what": _s("Category to list; default all.", enum=["all", "zombies", "objects", "items", "vehicles", "players"],
               default="all"),
    "limit": _i("Max entries per category.", default=200, minimum=1, maximum=5000),
    "include_floor": _b("Include floor tiles among the objects.", default=False),
}, ["x", "y"]), game="world_query")

tool("wait_for", """
Block until the game bridge is alive and a condition holds: a named player is online, or at least `min_players`
are. Use it after `status` reports the server paused (no players online). Read-only; returns the status once the
condition is met, or a timeout error.
""", _obj({
    "player": _s("Wait for this player (account or character name) to be online."),
    "min_players": _i("Minimum number of online players.", default=1, minimum=0),
    "timeout_s": _n("Give up after this many seconds.", default=300, minimum=1, maximum=3600),
}), local="wait_for")

tool("events_poll", """
Events the game appended since your last call: script errors, client results and client texture/model loads, tool
actions (spawns, placements, teleports), bridge reloads, and notes your own scripts write with ZMCP.event(kind,
data). Each event is {t: unix seconds, kind, data}. The first call in a session returns the recent tail; pass the
returned `cursor` (a byte offset) to resume explicitly. Read-only and works while the server is paused.
""", _obj({
    "cursor": _i("Byte offset returned by the previous call; omit to continue from where this session left off."),
    "limit": _i("Return at most this many (newest) events.", default=100, minimum=1, maximum=2000),
    "kinds": _arr("Only these event kinds, e.g. ['client_exec_result', 'script_error'].", {"type": "string"}),
}), local="events_poll")

tool("api_search", """
Search the Project Zomboid engine API index: every Java class the Lua VM can reach (fields, constructors, methods
with parameter names, inheritance) plus the global Lua functions. Case-insensitive name match ranked exact, prefix,
substring (a regex is accepted too). `Class.member` or `Class:member` searches one class and its superclasses. Each hit
has a Java `signature` (e.g. `IsoLightSource IsoCell:addLamppost(int x, int y, ...)`) and a `lua` call hint
(`obj:addLamppost(x, y, z, r, g, b, rad)`, `IsoObject.new(square, tile, name)`, `getTexture(filename)`); a `warning`
marks members whose class is not exposed to Lua. Local and instant, works without the game. The index is built by
tools/build_api_index.py for the installed game version; when it is missing the tool says so instead of guessing.
""", _obj({
    "query": _s("Name, substring or regex, e.g. 'addLamppost', 'IsoGridSquare:transmit', 'getTexture'."),
    "kind": _s("Restrict to a record type.", enum=["any", "class", "method", "field", "ctor", "global"], default="any"),
    "limit": _i("Maximum results.", default=40, minimum=1, maximum=500),
}, ["query"]), local="api_search")

tool("lua_examples", """
Show how vanilla Lua uses an engine symbol: real call sites from the game's media/lua (`calls`, best first, with
file:line), Lua function definitions matching the name (`defs`; a table name lists its methods), and hand-verified
snippets for things vanilla never calls (`curated`, e.g. addLamppost, transmitAddObjectToSquare). `Class.new` and
`Events.OnTick` are valid symbols. When nothing matches, `related` lists similar symbols to retry with; when a local
game install is present it is grepped as a fallback. Local and instant. Use it before writing Lua to copy the exact
call shape the engine expects.
""", _obj({
    "query": _s("Engine symbol, e.g. 'setHairModel', 'IsoObject.new', 'Events.OnTick', 'sendServerCommand'."),
    "limit": _i("Maximum call sites / definitions.", default=8, minimum=1, maximum=100),
    "context": _i("Context lines for the grep fallback only.", default=0, minimum=0, maximum=20),
}, ["query"]), local="lua_examples")

# ------------------------------------------------------------------ players
tool("teleport", """
Move a player to a tile. Position is client-authoritative: the move is sent to that player's client mod, which
teleports the local player and then reports the new position to the server through the normal update path, so the
player needs the mod. Everyone sees the player appear at the target; the target chunks load around them (a short
black screen for far jumps). Returns {sent, user, x, y, z, from}; verify with player_info a second later. Affects a
character: only when asked.
""", _obj({
    "player": PLAYER,
    "x": _n("Target tile x (fractional allowed)."), "y": _n("Target tile y."), "z": Z,
}, ["x", "y"]), game="teleport")

tool("give_item", """
Put items straight into a player's main inventory. Server-authoritative (AddItem + sendAddItemToContainer): the item
appears for the player at once and is real for everyone. Item type is 'Module.Name' like 'Base.Axe', 'Base.Banana'
(search with run_lua_server over getScriptManager():getAllItems(), see docs/recipes/item_types.md). Count is capped
at 100 per call. Weight limits are ignored (the player may become overloaded). Returns the items created.
""", _obj({
    "player": PLAYER,
    "item": _s("Full item type, e.g. 'Base.Katana'."),
    "count": _i("How many.", default=1, minimum=1, maximum=100),
}, ["item"]), game="give_item")

# ------------------------------------------------------------------ world
tool("spawn_item", """
Drop items on the ground at a tile (real world items everyone can see and pick up). Server-authoritative
(AddWorldInventoryItem). The square must be loaded (near a player). Up to 200 per call; `scatter` spreads them over
neighbouring tiles. Use give_item for inventories and falling_items for a visible fall from the sky. Returns
{type, name, placed, skipped, squares}.
""", _obj({
    "item": _s("Full item type, e.g. 'Base.Banana'."),
    "x": X, "y": Y, "z": Z,
    "count": _i("How many.", default=1, minimum=1, maximum=200),
    "scatter": _i("Spread over this many tiles around x,y.", default=0, minimum=0, maximum=20),
}, ["item", "x", "y"]), game="spawn_item")

tool("spawn_vehicle", """
Spawn a vehicle by script name (e.g. 'Base.CarNormal', 'Base.PickUpTruck', 'Base.SportsCar'; list them with
run_lua_server over getScriptManager():getAllVehicleScripts(), see docs/recipes/vehicle_types.md) at a tile, facing a
direction. Server-authoritative (addVehicleDebug): appears for everyone at once, on a loaded square with free flat
ground only. The vehicle spawns in random condition; use vehicle_fix to repair and refuel it. Ask the owner before
spawning next to players. Returns the vehicle's id, script, position and engine state.
""", _obj({
    "script": _s("Vehicle script name, e.g. 'Base.CarNormal' (short names are matched too)."),
    "x": X, "y": Y, "z": Z,
    "dir": _s("Facing direction.", enum=["N", "NE", "E", "SE", "S", "SW", "W", "NW"], default="S"),
}, ["script", "x", "y"]), game="spawn_vehicle")

tool("vehicle_fix", """
Repair every part and/or fill the gas tank of a vehicle: the one a player is in, the nearest to that player, or the
nearest to a tile within `radius`. Server-authoritative (vehicle:repair, GasTank content + transmitPartModData);
other players see the repaired state. Loaded vehicles only. Returns the vehicle, what was done and the parts before
and after.
""", _obj({
    "player": _s("Use this player's current vehicle, or the nearest one to them."),
    "x": X, "y": Y, "z": Z,
    "radius": _i("Search radius in tiles when looking for the nearest vehicle.", default=12, minimum=0, maximum=40),
    "repair": _b("Repair every part to full condition.", default=True),
    "refuel": _b("Fill the gas tank.", default=True),
}), game="vehicle_fix")

tool("spawn_zombies", """
Spawn a group of zombies at a tile (addZombiesInOutfit). Server-authoritative: real zombies for everyone. `count` is
capped at 100 per call; the square must be loaded. Optional outfit name (e.g. 'Police', 'Fireman', 'Nurse'; list
them with run_lua_server over getAllOutfits(), see docs/recipes/outfits.md). This is a horde event and dangerous for
players: do it only when asked. Returns the zombie ids.
""", _obj({
    "x": X, "y": Y, "z": Z,
    "count": _i("Number of zombies.", default=1, minimum=1, maximum=100),
    "outfit": _s("Outfit name, or omit for random."),
    "female_chance": _i("Percent chance each zombie is female.", default=50, minimum=0, maximum=100),
}, ["x", "y"]), game="spawn_zombies")

tool("kill_zombies_area", """
Kill every zombie within `radius` tiles of a tile or of a player. Server-authoritative (setAttackedBy + Kill);
bodies drop for everyone. Limited to the loaded area and a radius of 80. Returns the number killed.
""", _obj({
    "player": _s("Centre on this player instead of x/y/z (and credit the kills to them)."),
    "x": X, "y": Y, "z": Z,
    "radius": _i("Radius in tiles.", default=10, minimum=0, maximum=80),
    "killer": _s("Credit the kills to this player."),
}), game="kill_zombies_area")

tool("place_object", """
Place a vanilla tile sprite as a new world object on a square (IsoObject + transmitAddObjectToSquare): walls
('walls_exterior_wooden_01_2'), furniture, fences, lamps, decorations. Server-authoritative, persistent in the save,
visible to everyone. The square must be loaded. Sprite names are validated against the live sprite map (search
with run_lua_server, see docs/recipes/sprite_search.md, or copy one from world_query). Placed objects have no
collision or function unless the sprite's properties provide them. Ask the owner before building next to players.
Returns the object's index on the square (for remove_object).
""", _obj({
    "sprite": _s("Tile sprite name, e.g. 'walls_exterior_wooden_01_2'."),
    "x": X, "y": Y, "z": Z,
    "name": _s("Optional object name (shown in world_query), e.g. 'Campfire'."),
}, ["sprite", "x", "y"]), game="place_object")

tool("remove_object", """
Remove a world object from a square (transmitRemoveItemFromSquare). Server-authoritative and persistent. Select by
sprite name (first match, or every match with `all`) or by object index from world_query. Without sprite or index
it only lists the square's objects. Floors are refused unless `force`. Removing vanilla map objects is irreversible
without a map reset. Returns what was removed and the remaining objects.
""", _obj({
    "x": X, "y": Y, "z": Z,
    "sprite": _s("Remove objects with this sprite name."),
    "index": _i("Object index on the square, from world_query or a previous listing.", minimum=0),
    "all": _b("Remove every object matching the sprite, not just the first.", default=False),
    "force": _b("Allow removing the floor tile.", default=False),
}, ["x", "y"]), game="remove_object")

tool("build_structure", """
Place many tile sprites in one call (batched place_object): a wall ring, a hut, a decorated square. Up to 500
objects; each entry is {x, y, z?, sprite, name?}. Per-entry errors (unloaded square, unknown sprite) are collected
and the rest is still placed unless `stop_on_error`. Server-authoritative and persistent. Ask the owner before
building next to players. Returns {placed, errors, objects}.
""", _obj({
    "objects": _arr("Objects to place.", {
        "type": "object",
        "properties": {"x": X, "y": Y, "z": Z, "sprite": _s("Tile sprite name."), "name": _s("Optional object name.")},
        "required": ["x", "y", "sprite"], "additionalProperties": False}, minItems=1, maxItems=500),
    "stop_on_error": _b("Abort at the first failing entry.", default=False),
}, ["objects"]), game="build_structure")

tool("set_weather", """
Change the weather for everyone: start rain of a given intensity, a thunderstorm, or clear the sky. Server-
authoritative through the climate manager (transmitServerStartRain / TriggerStorm / StopWeather); clients follow
within seconds. The simulation may drift back to natural weather over time. Returns the weather after the change.
""", _obj({
    "kind": _s("Weather to set.", enum=["rain", "storm", "clear"]),
    "intensity": _n("Rain/storm intensity 0..1.", default=0.7, minimum=0, maximum=1),
}, ["kind"]), game="set_weather")

tool("set_time", """
Set the in-game clock for the whole server: hour of day (0..24, fractional) and optionally day, month and year
(1-based). Server-authoritative and synced to all clients. Sudden jumps affect darkness, zombie behaviour and
player fatigue. Returns the time before and after.
""", _obj({
    "hour": _n("Hour of day, e.g. 6.5 for 06:30.", minimum=0, maximum=24),
    "day": _i("Day of month.", minimum=1, maximum=31),
    "month": _i("Month.", minimum=1, maximum=12),
    "year": _i("Year, e.g. 1993.", minimum=1, maximum=9999),
}), game="set_time")

# ------------------------------------------------------------------ visuals (client push)
tool("texture_upload", """
Upload a PNG to every connected client (or one player) and register it under a texture id for world_sprite,
overlay_draw (kind 'texture'), falling_items and your own run_lua_client drawing code (ZMCPClient.tex.get(id)).
Give the image as base64 or as a file path on this machine. Client-side: the image is chunked over the network
(~3 kB per message, about 1 s per 30 kB), written into each client's Zomboid/Lua folder under a fresh file name
(textures are cached by path, so re-uploading an id makes a new generation) and loaded with getTexture. The base64
is kept in a file on the server for late joiners, never in memory. Keep images at most 256x256 and about 100 kB;
the hard limit is 1.2 MB of base64. Returns {id, gen, chars, chunks}; each client reports the load as a
client_texture event (ok, w, h) in events_poll.
""", _obj({
    "id": ID,
    "png_base64": _s("PNG file contents, base64-encoded (large values are passed to the game as a file automatically)."),
    "png_path": _s("Instead of png_base64: path of a PNG file on this machine, read by the MCP process."),
    "player": PLAYER_ONLY,
}, ["id"]), game="texture_upload", local="texture_upload")

tool("texture_pixel", """
Register art without a PNG: a pixel sprite drawn with rectangles, usable wherever a texture id is (world_sprite,
overlay_draw). def = {palette: {"a": [r, g, b, a], ...}, rows: ["aab.", "..a."]} where each character of a row is a
palette key, '.' (or any key missing from the palette) is transparent and colours are 0..1 or 0..255. Keep it small
(a 32x32 sprite is 1024 rectangles per frame). Client-side, sent to every client and to late joiners.
""", _obj({
    "id": ID,
    "def": {"type": "object", "description": "Pixel definition: {w?, h?, palette, rows}.",
            "properties": {
                "w": _i("Width in pixels; default: length of the first row."),
                "h": _i("Height in pixels; default: number of rows."),
                "palette": {"type": "object", "description": "Character -> [r, g, b, a].",
                            "additionalProperties": _arr("RGBA.", {"type": "number"}, minItems=3, maxItems=4)},
                "rows": _arr("One string per pixel row.", {"type": "string"}, minItems=1),
            }, "required": ["palette", "rows"], "additionalProperties": False},
}, ["id", "def"]), game="texture_pixel")

tool("model_upload", """
Register a runtime 3D model on every connected client: a Project Zomboid .x text mesh plus a PNG texture, given as
base64 or as file paths on this machine. Clients write both files under Zomboid/Lua/media/ and register a
ModelScript named 'zmcp_<id>_<gen>' (ZMCPClient.models.name(id) in run_lua_client code). Then model_place puts it
in the world as a static object. Model space is Y-up with the origin at ground level; keep meshes small (a few
thousand triangles, at most 1.2 MB of base64 per file). Files are kept on the server for late joiners. Returns
{id, gen, name, chunks}; each client reports the registration as a client_model event in events_poll. See
docs/ENGINE_NOTES.md 'Runtime 3D models' and art/3d/ for a verified example mesh.
""", _obj({
    "id": ID,
    "mesh_base64": _s("The .x mesh text, base64-encoded."),
    "mesh_path": _s("Instead of mesh_base64: path of the .x file on this machine."),
    "png_base64": _s("Texture PNG, base64-encoded."),
    "png_path": _s("Instead of png_base64: path of the PNG on this machine."),
    "scale": _n("Model scale factor.", default=1, minimum=0.01, maximum=100),
    "player": PLAYER_ONLY,
}, ["id"]), game="model_upload", local="model_upload")

tool("model_place", """
Place an uploaded 3D model in the world as a STATIC object: the server spawns a carrier world item on the square
(default Base.TirePiece) and sets its world model to the registered ModelScript, so it renders in 3D with proper
occlusion and no flicker. Server-authoritative in single-player (verified); in multiplayer the carrier item syncs
but the model assignment is unverified. Offsets are fractions of the tile, oz lifts the model. Remove it like any
ground item (world_query then run_lua_server). Moving 3D objects are a separate feature (entity3d_* tools when
available). Returns {placed, x, y, z, item}.
""", _obj({
    "id": _s("Model id from model_upload."),
    "x": X, "y": Y, "z": Z,
    "item": _s("Carrier world item type.", default="Base.TirePiece"),
    "ox": _n("Offset within the tile, x.", default=0.5, minimum=-5, maximum=5),
    "oy": _n("Offset within the tile, y.", default=0.5, minimum=-5, maximum=5),
    "oz": _n("Height offset.", default=0, minimum=-5, maximum=10),
    "yrot": _n("Rotation around the vertical axis in degrees.", minimum=-360, maximum=360),
}, ["id", "x", "y"]), game="model_place")

tool("world_sprite", """
Show a texture in the world for everyone (or one player), anchored bottom-centre at a tile position, scaled with the
camera zoom and always drawn on top of the world (no wall occlusion; it is not an object and has no collision).
Texture: an uploaded id, 'item:Base.Banana' (an inventory icon) or any vanilla texture path getTexture accepts.
Motion: `path` waypoints from x,y walked at `speed` tiles/s with loop = loop | pingpong | once; `bob` hops;
`flip` auto mirrors it when travelling left. Size: `scale` multiplies the texture pixels at zoom 1, or `tiles` sets
the width in world tiles. Persists for late joiners unless `ttl` or `player` is set. Reuse an id to replace or move
it; clear_visuals removes it. Returns {id, persistent}.
""", _obj({
    "id": _s("Sprite id; reusing it replaces the sprite. Default generated."),
    "texture": _s("Texture id from texture_upload / texture_pixel, 'item:<type>', or a vanilla texture path."),
    "x": _n("Tile x (fractional allowed)."), "y": _n("Tile y."), "z": _n("Floor.", default=0),
    "scale": _n("Pixel multiplier at zoom 1.", default=1, minimum=0.01, maximum=100),
    "tiles": _n("Width in world tiles instead of scale.", minimum=0.05, maximum=50),
    "path": _arr("Waypoints after x,y: [[x, y, z?], ...]; the sprite walks them at `speed`.",
                 _arr("Point.", {"type": "number"}, minItems=2, maxItems=3)),
    "speed": _n("Tiles per second along the path.", default=0, minimum=0, maximum=100),
    "loop": _s("Path behaviour.", enum=["loop", "pingpong", "once"], default="loop"),
    "bob": _n("Hop height in pixels at zoom 1.", default=0, minimum=0),
    "bobHz": _n("Hops per second.", default=1, minimum=0),
    "flip": _s("Mirror horizontally: 'auto' when moving left, '1' always, '0' never.", enum=["auto", "0", "1"],
               default="auto"),
    "opacity": _n("Opacity 0..1.", default=1, minimum=0, maximum=1),
    "ttl": _n("Remove after this many seconds (not persisted for late joiners).", minimum=0),
    "fade": _n("Fade-in/out seconds.", default=0, minimum=0),
    "anchor": _s("Anchor point at the position.", enum=["bottom", "center"], default="bottom"),
    "player": PLAYER_ONLY,
}, ["texture", "x", "y"]), game="world_sprite")

tool("falling_items", """
Make items visibly fall from the sky around a point and become real ground items when they land. The fall (the
item's inventory icon with a growing shadow and a bounce) is a client-side visual pushed to everyone with the mod;
each landing spawns a real server-authoritative item on that square that anyone can pick up. Centre on a player or
a tile; the area must be loaded. Up to 200 items. Returns {id, item, count, spawning, done_in}.
""", _obj({
    "item": _s("Full item type, e.g. 'Base.Banana'."),
    "count": _i("How many.", default=10, minimum=1, maximum=200),
    "player": _s("Centre on this player instead of x/y/z."),
    "x": X, "y": Y, "z": Z,
    "radius": _n("Spread in tiles.", default=3, minimum=0, maximum=30),
    "duration": _n("Seconds over which the drops start.", default=3, minimum=0, maximum=60),
    "fall": _n("Seconds each drop takes to fall.", default=1.2, minimum=0.3, maximum=30),
    "spawn": _b("Spawn the real items on landing.", default=True),
    "scale": _n("Icon size multiplier.", default=1, minimum=0.1, maximum=10),
}, ["item"]), game="falling_items")

tool("overlay_draw", """
Draw a primitive on players' screens (everyone or one player): a line, a filled or outlined rectangle, text or a
texture, anchored to the screen (pixels; negative x/y count from the right/bottom edge) or to a world tile (follows
the camera and zoom; sizes are pixels at zoom 1, drawn above the tile). Client-side, nothing changes in the world.
ttl removes it after n seconds, otherwise it stays until clear_visuals {what: 'overlays', id}. Reusing an id
replaces it. Colours r,g,b,a are 0..1 (or 0..255). For animated HUDs or many shapes write a render hook with
run_lua_client instead. Returns {id}.
""", _obj({
    "kind": _s("Primitive.", enum=["line", "rect", "text", "texture"]),
    "anchor": _s("Coordinate space.", enum=["screen", "world"], default="screen"),
    "x": _n("X (pixels, or tile x)."), "y": _n("Y (pixels, or tile y)."), "z": _n("Floor for the world anchor.", default=0),
    "x2": _n("Line end x."), "y2": _n("Line end y."), "z2": _n("Line end floor."),
    "w": _n("Width in pixels at zoom 1.", default=32), "h": _n("Height in pixels at zoom 1.", default=32),
    "r": COLOR_COMPONENT, "g": COLOR_COMPONENT, "b": COLOR_COMPONENT, "a": _n("Alpha 0..1.", default=1, minimum=0, maximum=1),
    "ttl": _n("Seconds until it disappears; omit to keep.", minimum=0),
    "id": _s("Overlay id; reusing it replaces the overlay. Default generated."),
    "text": _s("Text to draw (kind 'text')."),
    "font": _s("Font for text.", enum=["small", "medium", "large", "title"], default="medium"),
    "centre": _b("Centre text on x.", default=False),
    "fill": _b("Filled rectangle (false = border only).", default=True),
    "thick": _n("Line thickness in pixels.", default=1, minimum=1, maximum=20),
    "tex": _s("Texture id (kind 'texture')."),
    "flip": _b("Mirror the texture horizontally.", default=False),
    "player": PLAYER_ONLY,
}, ["kind", "x", "y"]), game="overlay_draw")

tool("server_message", """
Show a message to every player (or one) through the client mod: mode 'notify' is a box at the top of the screen
that fades after ttl seconds, 'halo' is text floating over the player's head, 'chat' a line in the chat panel and
'say' a speech bubble from the player. Client-side; players without the mod see nothing (the vanilla fallback is
server_console 'servermsg <text>'). Keep it short. Returns {sent, mode, to}.
""", _obj({
    "text": _s("Message text.", maxLength=500),
    "mode": _s("How to show it.", enum=["notify", "halo", "chat", "say"], default="notify"),
    "player": PLAYER_ONLY,
    "ttl": _n("Seconds a notify box stays.", default=5, minimum=0.5, maximum=120),
    "r": COLOR_COMPONENT, "g": COLOR_COMPONENT, "b": COLOR_COMPONENT,
    "font": _s("Font for notify.", enum=["small", "medium", "large", "title"], default="large"),
    "time": _n("Halo display time in frames.", default=300, minimum=1),
}, ["text"]), game="server_message")

tool("capture_input", """
Screen apps: make every client's (or one player's) overlay swallow mouse events and sit above the vanilla UI
(on = true), or release it again (on = false). While captured, ZMCPClient.on hooks for mouseDown/mouseUp/mouseMove/
mouseWheel receive the clicks and the game world does not. Key hooks always receive keys. Scripts can also call
ZMCPClient.capture(true) themselves; clear_visuals {what: 'hooks'} releases it. Client-side.
""", _obj({
    "on": _b("Capture (true) or release (false).", default=True),
    "player": PLAYER_ONLY,
}), game="capture_input")

tool("visuals_list", """
Everything the visual subsystem knows: uploaded textures [{id, gen, chars|pixel}], registered 3D models [{id, name,
gen, scale}], persistent world sprites, client scripts [{name, file}], connected clients with their mod version and
what they loaded, the outgoing queue length and pending item landings. Read-only, server-side; also pings the
clients so their entries refresh for the next call.
""", _obj({}), game="visuals_list")

tool("clear_visuals", """
Remove client visuals on every client (or one player): 'all' clears world sprites, overlays, falling items, notices
and every script hook (textures, models and client scripts stay); or one category: sprites, overlays, falling,
notices, textures, models, hooks. With `id` only that sprite / overlay / texture / model / hook name. Server-side
registries are updated too (unless only one player is targeted), so late joiners do not receive removed sprites.
""", _obj({
    "what": _s("What to clear.", enum=["all", "sprites", "overlays", "falling", "notices", "textures", "models", "hooks"],
               default="all"),
    "id": _s("Only this id / hook name."),
    "player": PLAYER_ONLY,
}), game="clear_visuals")

# ------------------------------------------------------------------ server admin
tool("server_console", """
Send a raw command to the dedicated server's admin console (e.g. 'players', 'save', 'servermsg Hello',
'additem user Base.Axe', 'reloadlua ZomboidMCP/Bridge.lua', 'help') and return the console output it produced.
Server-authoritative admin power, independent of the Lua bridge: works while the server is paused. Available only
when the MCP was started with --console-container or --console-fifo (dedicated servers, usually over ssh);
otherwise it explains what is missing. Commands like 'quit' stop the server for everybody: ask first.
""", _obj({
    "command": _s("Console command line."),
    "wait_s": _n("Seconds to wait for output.", default=2, minimum=0.2, maximum=30),
    "raw": _b("Return unfiltered log lines (default filters engine noise like AnimState/Saving).", default=False),
}, ["command"]), local="server_console")


BY_NAME = {t["name"]: t for t in TOOLS}
GAME_NAMES = {t["game"] for t in TOOLS if t["game"]}


def passthrough_tool(name, desc):
    """Schema for a tool the game registered but the catalogue does not know (e.g. added by a script)."""
    return {
        "name": name,
        "description": (desc or "Tool registered by the running game (not in the static catalogue).") +
                       " Passed straight to the game with the given arguments; check its result for effects.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": True},
        "game": name, "local": None,
    }


def public(tooldef):
    """The MCP-visible part of a tool definition."""
    return {"name": tooldef["name"], "description": tooldef["description"], "inputSchema": tooldef["inputSchema"]}
