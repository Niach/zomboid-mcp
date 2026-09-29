"""Tool catalogue for the Zomboid MCP server (scripting-first, see the top of docs/PLAN.md).

The primary tools are ``run_lua_server`` and ``run_lua_client`` plus persistent
script modules: Claude writes Lua and runs it live, guided by the "zomboid engine
handbook" skill. A small curated set covers the most common operations. These
descriptions and JSON schemas are the main documentation an MCP client sees, so
each one states where the code runs, **authority** (server-owned and synced to
everyone vs. client-owned and pushed to the client mod), **who sees** the effect,
how return values and errors come back, and the **limits** we know about.

Every tool has ``game``: the name of the tool on the Lua side (``None`` when the
MCP process answers it itself). Tools registered in the running game that are not
listed here are exposed too, as passthrough tools with a free-form argument object.
"""

PROTOCOL_VERSION = "2025-06-18"
SUPPORTED_PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")

HANDBOOK = ("the \"zomboid engine handbook\" skill (skill/SKILL.md in the mod: categorized map of every Lua-reachable "
            "engine function, guides for overlays, textures, 3D models, world/tiles, items, zombies, vehicles, weather, "
            "players and scenes, tested snippets and all known B42 gotchas)")

SERVER_INSTRUCTIONS = """\
Zomboid MCP controls a running Project Zomboid (Build 42) game through the ZomboidMCP mod. It is scripting-first:
you write Lua and run it live.

- `run_lua_server` runs Lua in the server (or single-player host) Lua state; `run_lua_client` runs Lua on every
  connected client or one player's client. `script_install` makes a server script persistent (re-run on every bridge
  load and server start), `script_list` / `script_remove` manage them. Before writing Lua, read the "zomboid engine
  handbook" skill (skill/SKILL.md in the mod) and use `api_search` (engine signatures with Lua call hints) and
  `lua_examples` (how vanilla Lua calls it). The handbook's gotchas are real: Kahlua has no `io`/`bit`, overloads are
  chosen by argument count, `tostring()` without an argument throws, `require` of new files fails at runtime.
- A handful of curated tools cover the most common operations with validated arguments: `status`, `players_list`,
  `texture_upload`, `model_upload`, `spawn_item`, `spawn_vehicle`, `spawn_zombies`, `world_sprite`,
  `object_3d_static`, `object_3d_moving`, `falling_items`, `set_weather`, `set_time`, `server_console`. Everything
  else is a script.
- Authority: the server owns zombies, items, world objects, vehicles, weather, time, XP, traits and god mode; code
  run on the server takes effect for everybody at once. A player's position, body damage, infection, appearance,
  stats and everything drawn on screen (overlays, textures, sprites, 3D models) belong to that player's client, so
  run that code with `run_lua_client`; it reaches players running the ZomboidMCP mod (all players on a server that
  requires it).
- Every tool call is a file in the game's Zomboid/Lua directory executed by the server-side bridge on the next game
  tick (well under a second). The server ticks only while a player is online: a dedicated server with PauseEmpty=true
  is frozen when empty and calls time out with a "server paused" error. Call `status` first (never blocks) and
  `wait_for` to block until somebody joins. `server_console` works even while paused.
- Only the loaded area (roughly 100 tiles around online players) exists on the server; squares outside it are nil.
- `player` arguments accept the account name or the character name and may be omitted when exactly one player is
  online. `events_poll` returns what the game appended since your last call (script errors, joins, deaths, notes).
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
X = _i("World tile x (east). Use players_list for a reference position.")
Y = _i("World tile y (south).")
Z = _i("Floor level, 0 = ground.", default=0, minimum=-32, maximum=32)
TIMEOUT = _n("How long to wait for the result, in seconds.", default=20, minimum=1, maximum=600)

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
getClimateManager(), sendServerCommand(...), ZMCP helpers: ZMCP.player(name), ZMCP.players(), ZMCP.square(x,y,z),
ZMCP.zombiesNear(x,y,z,r), ZMCP.toClients(cmd, args[, player]), ZMCP.event(kind, data), ZMCP.readFile/writeFile).
Authority: server-owned state (zombies, items, world objects, vehicles, weather, time, XP, traits, god mode) changes
for everyone immediately and is saved with the world. Client-owned state (player position, body/infection,
appearance, stats, anything drawn) cannot be changed reliably from here: use run_lua_client.
Return values: use `return`; one value comes back as JSON, several as an array. Tables become JSON objects/arrays,
Java objects are stringified (return fields such as p:getX() instead). nil returns null.
Errors: compile errors and runtime errors come back as a tool error with the Lua message and line; the server keeps
running. print() output goes to the server console, not to you (use server_console or return the text).
Limits: the chunk blocks the whole server while it runs, so keep it under ~100 ms and never loop waiting for
something (use ZMCP.tickHooks.<name> = function(t) ... end for periodic work, and script_install for anything that
must survive a reload). Only the loaded area near players exists. Globals persist between calls in the same Lua
state; `require` of new files does not work at runtime (paste the code instead).
""" % HANDBOOK, _obj({
    "code": _s("Lua source. Example: 'local p = ZMCP.player(\"niach\"); return {x = p:getX(), y = p:getY()}'."),
    "timeout_s": TIMEOUT,
}, ["code"]), game="lua_eval")

tool("run_lua_client", """
Run a Lua chunk on players' clients: every connected client with the ZomboidMCP mod, or one player's client. Use it
for everything the client owns or draws: overlays and screen apps (ISUIElement, drawTextureScaled, isoToScreenX/Y),
runtime textures and world sprites, 3D models on world items, camera, sounds only one player should hear, and
client-authoritative player state (position via setX/setY/setZ, body damage and infection, appearance via
getHumanVisual() + sendHumanVisual, stats via getStats()). See %s for the drawing and world-anchoring recipes.

Where it runs: the code is chunked over sendServerCommand (about 3 kB per message) to the target clients, executed
there with loadstring, and each client sends its return value back; the round trip takes two ticks plus network.
`getPlayer()` is the local player on each client; `isClient()` is true; server-only functions are unavailable.
Authority: effects are client-side. Visuals are seen only by the clients that ran the code (all of them when
`player` is omitted); position/body/appearance changes are then synced by the engine to everyone. Nothing here
changes the saved world; use run_lua_server for that.
Return values: one value per client, as {player: value} (JSON-encoded like run_lua_server). Clients that did not
answer within timeout_s are listed as missing.
Errors: per-client Lua errors come back in the result (and in events_poll as 'client_error'); a broken chunk never
crashes a client's game, but an infinite loop freezes that player's game: keep it short and hook into Events or a
UI element's render/update for continuous work.
Limits: requires the client mod (players without it silently receive nothing). Not persistent: late joiners do not
get it unless `persist` is true, in which case it is re-sent to every player who joins until cleared with
run_lua_client({code: 'ZMCPClient.clear()'}) or a server restart.
""" % HANDBOOK, _obj({
    "code": _s("Lua source to run on the client. `getPlayer()` is the local player."),
    "player": _s("Only this player's client; default all connected clients."),
    "persist": _b("Also send to players who join later.", default=False),
    "timeout_s": _n("How long to wait for client replies.", default=10, minimum=1, maximum=120),
}, ["code"]), game="lua_eval_client")

tool("script_install", """
Install or update a persistent server script module: the Lua source is written to the game's Lua directory as
zmcp_mod_<name>.lua, executed right now in the server Lua state (like run_lua_server), and recorded so it runs again
on every bridge reload and server start, before players join. Use it for anything that must keep working: new tools
(ZMCP.tool(name, desc, fn) makes them appear in tools/list), tick hooks (ZMCP.tickHooks.<name> = function(t) end),
event handlers, and client code that should be pushed to every player on join (ZMCP.toClients from a handler).
Return value: the module's return value plus the file name and whether it was persisted.
Errors: a compile or runtime error is returned and the module is not recorded (the previous version, if any, stays).
Rules from %s: make the code re-runnable (keep state in a global table like `MyMod = MyMod or {}`, store handlers and
Events.X.Remove them before adding again), keep big data in files rather than ModData, and never block the tick.
Server-authoritative like run_lua_server; scripts are stored on the server only (single-player: the host's save).
""" % HANDBOOK, _obj({
    "name": _s("Module name (letters, digits, _ and -). Reusing a name replaces that module.",
               pattern="^[A-Za-z0-9_-]{1,64}$"),
    "code": _s("Lua source of the module."),
}, ["name", "code"]), game="module_install", local="script_install")

tool("script_list", """
List installed persistent server script modules with file name and install time. Read-only, server-side. Use
run_lua_server with ZMCP.readFile('zmcp_mod_<name>.lua') to read a module's source.
""", _obj({}), game="module_list")

tool("script_remove", """
Forget a persistent script module so it no longer runs on bridge reloads and restarts. The file stays in the Lua
directory and anything the module already registered (tools, tick hooks, event handlers) stays active until the
module's own cleanup code runs or the server restarts; to undo immediately, run the cleanup with run_lua_server.
""", _obj({"name": _s("Module name.")}, ["name"]), game="module_remove")

# ------------------------------------------------------------------ discover
tool("status", """
Snapshot of the game as seen by the MCP process: bridge liveness (live / paused / stale / not_running with a hint),
heartbeat age, online players with position and health, in-game time, bridge version, registered game tools and
installed script modules, and how this MCP is connected. Answered from the heartbeat file the server writes every 2 s,
so it never blocks and works while the server is paused. Call it first in a session and whenever a tool times out.
""", _obj({}), local="status")

tool("players_list", """
List online players: account name, character name, position (x,y,z), health and dead/alive. Server-side, read-only,
instant. In single-player the local player is returned. For anything more (traits, skills, inventory, infection, what
is around them) write a run_lua_server chunk using ZMCP.player(name).
""", _obj({}), game="players_list")

tool("wait_for", """
Block until the game bridge is alive and a condition holds: a named player is online, or at least `min_players`
are. Use it after `status` reports the server paused (no players online). Read-only; returns the status once the
condition is met or a timeout error.
""", _obj({
    "player": _s("Wait for this player (account or character name) to be online."),
    "min_players": _i("Minimum number of online players.", default=1, minimum=0),
    "timeout_s": _n("Give up after this many seconds.", default=300, minimum=1, maximum=3600),
}), local="wait_for")

tool("events_poll", """
Events the game appended since your last call: script/tool errors, client errors from run_lua_client, bridge reloads,
module installs, player deaths and joins, and notes your own scripts write with ZMCP.event(kind, data). Each event is
{t: unix seconds, kind, data}. The first call in a session returns the recent tail; pass the returned `cursor` (a byte
offset) to resume explicitly. Read-only and works while the server is paused.
""", _obj({
    "cursor": _i("Byte offset returned by the previous call; omit to continue from where this session left off."),
    "limit": _i("Return at most this many (newest) events.", default=100, minimum=1, maximum=2000),
    "kinds": _arr("Only these event kinds, e.g. ['client_error','module_error'].", {"type": "string"}),
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

# ------------------------------------------------------------------ curated: assets
tool("texture_upload", """
Upload a PNG (base64) to every connected client and register it under a texture id for world_sprite, object_3d_*
and your own run_lua_client drawing code (ZMCPClient.texture(id) returns the Texture). Client-side: the image is
chunked over the network (~3 kB per message, about 1 s per 30 kB), written into each client's Zomboid/Lua folder under
a fresh file name (textures are cached by path) and loaded with getTexture. Nothing is stored on the server. Late
joiners receive all uploaded textures. Keep images ≤ 256×256 and ≤ 100 kB where possible. Returns the texture id
and which clients loaded it (with width/height).
""", _obj({
    "id": _s("Texture id to reference later, e.g. 'snail'."),
    "png_base64": _s("PNG file contents, base64-encoded. Large values are passed to the game as a file automatically."),
}, ["id", "png_base64"]), game="texture_upload")

tool("model_upload", """
Upload a 3D model (Wavefront .obj or PZ .fbx/.x, plus an optional texture id from texture_upload) to every connected
client and register it as a runtime ModelScript under a model id, for object_3d_static / object_3d_moving and for
your own run_lua_client code (ZMCPClient.model(id)). Client-side, chunked like texture_upload; keep meshes small
(a few thousand triangles, ≤ 300 kB). Late joiners receive all uploaded models. Returns the model id and which
clients loaded it.
""", _obj({
    "id": _s("Model id, e.g. 'snail_mesh'."),
    "model_base64": _s("Model file contents, base64-encoded. Large values are passed to the game as a file automatically."),
    "format": _s("Model file format.", enum=["obj", "fbx", "x"], default="obj"),
    "texture": _s("Texture id from texture_upload to apply; omit for the model's own material."),
}, ["id", "model_base64"]), game="model_upload")

# ------------------------------------------------------------------ curated: spawning
tool("spawn_item", """
Create real items: on the ground at a tile, or in a player's main inventory. Server-authoritative
(AddWorldInventoryItem / AddItem + sendAddItemToContainer): everyone sees them at once and can pick them up. Item
type is 'Module.Name' like 'Base.Axe', 'Base.Banana'. Ground spawns need a loaded square (near a player); up to 100
per call, spread over `radius` tiles. Inventory spawns ignore weight limits.
""", _obj({
    "item": _s("Full item type, e.g. 'Base.Banana'."),
    "count": _i("How many.", default=1, minimum=1, maximum=100),
    "player": _s("Put the items in this player's inventory instead of on the ground."),
    "x": X, "y": Y, "z": Z,
    "radius": _i("Scatter ground items within this many tiles.", default=0, minimum=0, maximum=20),
}, ["item"]), game="spawn_item")

tool("spawn_vehicle", """
Spawn a vehicle by script name (e.g. 'Base.CarNormal', 'Base.PickUpTruck', 'Base.SportsCar'; api_search 'Vehicles'
or lua_examples 'addVehicleDebug' for names) at a tile, facing a direction. Server-authoritative (addVehicleDebug):
appears for everyone at once, on loaded squares only. `fixed` repairs every part and fills the tank; otherwise the
vehicle spawns in random condition.
""", _obj({
    "script": _s("Vehicle script name, e.g. 'Base.CarNormal'."),
    "x": X, "y": Y, "z": Z,
    "direction": _s("Facing direction.", enum=["N", "NE", "E", "SE", "S", "SW", "W", "NW"], default="S"),
    "fixed": _b("Repair all parts and refuel after spawning.", default=True),
}, ["script", "x", "y"]), game="spawn_vehicle")

tool("spawn_zombies", """
Spawn a group of zombies at a tile (addZombiesInOutfit). Server-authoritative: real zombies for everyone. `count` is
capped at 50 per call; the square must be loaded. Optional outfit name (e.g. 'Police', 'Fireman', 'Nurse';
lua_examples 'Outfit' for names). This is a horde event: dangerous for players, do it only when asked. For passive
puppet actors (zombies that do not attack) see the handbook's zombies guide and use run_lua_server.
""", _obj({
    "x": X, "y": Y, "z": Z,
    "count": _i("Number of zombies (1..50).", default=5, minimum=1, maximum=50),
    "outfit": _s("Outfit name or omit for random."),
    "female_chance": _i("Percent chance each zombie is female (0..100).", default=50, minimum=0, maximum=100),
}, ["x", "y"]), game="spawn_zombies")

# ------------------------------------------------------------------ curated: visuals
tool("world_sprite", """
Show an uploaded texture (or a vanilla texture name) in the world at a tile position, scaled in tiles, optionally
moving along a path over time. Client-side visual on every client with the mod: everyone sees it in the same place,
drawn bottom-centre at the point, scaled with the camera zoom, always on top (no wall occlusion), but it has no
collision and is not a world object. Reuse an id to move or replace it; ttl_s or an empty `texture` removes it.
Sent to late joiners while it exists.
""", _obj({
    "id": _s("Sprite id; reusing replaces it."),
    "texture": _s("Texture id from texture_upload, or a vanilla texture name such as 'Item_Banana'. Empty removes the sprite."),
    "x": _n("Tile x (fractional allowed)."), "y": _n("Tile y."), "z": _n("Floor.", default=0),
    "scale": _n("Width in tiles.", default=1, minimum=0.05, maximum=50),
    "path": _arr("Optional way-points; the sprite moves linearly between them.", {
        "type": "object", "properties": {"x": _n("Tile x."), "y": _n("Tile y."), "z": _n("Floor."),
                                         "t": _n("Seconds from start when this point is reached.")},
        "required": ["x", "y", "t"]}),
    "loop": _b("Repeat the path.", default=False),
    "ttl_s": _n("Remove after this many seconds (0 = keep).", default=0, minimum=0),
}, ["id", "texture", "x", "y"]), game="world_sprite")

tool("object_3d_static", """
Place a static 3D model in the world: a real world item on a square whose ModelScript is replaced at runtime by an
uploaded model (model_upload) or a vanilla model name, with scale and rotation. Verified flicker-free. The item is
server-authoritative and saved (everyone sees it, it survives restarts) while the model swap is pushed to clients and
re-applied for late joiners. Loaded squares only. Reuse an id to update; `remove` deletes the item.
""", _obj({
    "id": _s("Object id; reusing updates it."),
    "model": _s("Model id from model_upload, or a vanilla model script name."),
    "x": _n("Tile x (fractional allowed)."), "y": _n("Tile y."), "z": _n("Floor.", default=0),
    "scale": _n("Uniform scale, 1 = the model's own size.", default=1, minimum=0.01, maximum=100),
    "rotation": _n("Rotation around the vertical axis in degrees.", default=0),
    "remove": _b("Remove the object instead.", default=False),
}, ["id"]), game="object_3d_static")

tool("object_3d_moving", """
Show a moving/animated 3D model: an uploaded or vanilla model attached to a dynamic carrier entity that can follow
a path, turn and be animated without the flicker that animated world items show (chunk FBO caching). Client-side
visual pushed to every client with the mod (late joiners included while it exists); it has no collision and is not
saved. Reuse an id to update the path or model; ttl_s or `remove` deletes it.
""", _obj({
    "id": _s("Object id; reusing updates it."),
    "model": _s("Model id from model_upload, or a vanilla model script name."),
    "x": _n("Start tile x."), "y": _n("Start tile y."), "z": _n("Floor.", default=0),
    "scale": _n("Uniform scale.", default=1, minimum=0.01, maximum=100),
    "path": _arr("Way-points; the object moves and turns along them.", {
        "type": "object", "properties": {"x": _n("Tile x."), "y": _n("Tile y."), "z": _n("Floor."),
                                         "t": _n("Seconds from start when this point is reached.")},
        "required": ["x", "y", "t"]}),
    "loop": _b("Repeat the path.", default=True),
    "speed": _n("Playback speed multiplier for the path and animation.", default=1, minimum=0.01, maximum=100),
    "ttl_s": _n("Remove after this many seconds (0 = keep).", default=0, minimum=0),
    "remove": _b("Remove the object instead.", default=False),
}, ["id"]), game="object_3d_moving")

tool("falling_items", """
Make items visibly fall from the sky around a point (or a player) and become real ground items when they land. The
fall animation is a client-side visual pushed to everyone with the mod; the landing spawns real server-authoritative
items (like spawn_item) that anyone can pick up. Count ≤ 100, the area must be loaded.
""", _obj({
    "item": _s("Full item type, e.g. 'Base.Banana'."),
    "count": _i("How many.", default=10, minimum=1, maximum=100),
    "player": _s("Centre on this player instead of x/y/z."),
    "x": X, "y": Y, "z": Z,
    "radius": _i("Spread in tiles.", default=4, minimum=0, maximum=30),
    "height": _n("Drop height in tiles (visual only).", default=8, minimum=1, maximum=50),
    "duration_s": _n("Seconds over which the items fall.", default=3, minimum=0.2, maximum=60),
}, ["item"]), game="falling_items")

# ------------------------------------------------------------------ curated: environment
tool("set_weather", """
Change the weather for everyone: start rain of a given intensity, a storm, or clear the sky. Server-authoritative via
the climate manager (transmitServerStartRain / TriggerStorm / StopWeather); clients follow within seconds. The
simulation may drift back to natural weather over time. Lightning, fog, wind and temperature: run_lua_server with
getClimateManager() (see the handbook's weather guide).
""", _obj({
    "mode": _s("Weather to set.", enum=["rain", "storm", "clear"]),
    "intensity": _n("Rain/storm intensity 0..1.", default=0.8, minimum=0, maximum=1),
}, ["mode"]), game="set_weather")

tool("set_time", """
Set the in-game time of day (0..24 hours) for the whole server; day/month/year are left alone. Server-authoritative
and synced to all clients. Sudden jumps affect darkness, zombie behaviour and player fatigue.
""", _obj({"hour": _n("Hour of day, e.g. 6.5 for 06:30.", minimum=0, maximum=24)}, ["hour"]), game="set_time")

# ------------------------------------------------------------------ server admin
tool("server_console", """
Send a raw command to the dedicated server's admin console (e.g. 'players', 'save', 'servermsg Hello',
'additem user Base.Axe', 'reloadlua ZomboidMCP/Bridge.lua', 'help') and return the console output it produced.
Server-authoritative admin power, independent of the Lua bridge: works while the server is paused. Available only
when the MCP was started with a console FIFO/container (dedicated servers over ssh); otherwise it explains what is
missing. Commands like 'quit' stop the server for everybody: ask first.
""", _obj({
    "command": _s("Console command line."),
    "wait_s": _n("Seconds to wait for output.", default=2, minimum=0.2, maximum=30),
    "raw": _b("Return unfiltered log lines (default filters engine noise like AnimState/Saving).", default=False),
}, ["command"]), local="server_console")


BY_NAME = {t["name"]: t for t in TOOLS}
GAME_NAMES = {t["game"] for t in TOOLS if t["game"]}


def passthrough_tool(name, desc):
    """Schema for a tool the game registered but the catalogue does not know."""
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
