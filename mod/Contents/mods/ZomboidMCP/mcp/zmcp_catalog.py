"""Static tool catalogue for the Zomboid MCP server.

These descriptions and JSON schemas are the main documentation an MCP client
(Claude) sees, so each one states:

* **authority**: whether the effect is applied by the server (authoritative,
  synced to everyone) or has to be pushed to a client (player position, body
  state, visuals), and
* **who sees it** and the **limits** we know about (loaded area only, sizes,
  cooldowns, what needs the client mod).

Every tool has ``game``: the name of the tool on the Lua side (``None`` when
the MCP process answers it itself). Tools registered in the running game that
are not listed here are exposed too, as passthrough tools with a free-form
argument object.
"""

PROTOCOL_VERSION = "2025-06-18"
SUPPORTED_PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")

SERVER_INSTRUCTIONS = """\
Zomboid MCP controls a running Project Zomboid (Build 42) game through the ZomboidMCP mod.

How the game side works:
- Every tool call is written as a file into the game's Zomboid/Lua directory and executed by the server-side Lua
  bridge on the next game tick, so a call normally takes well under a second. The server ticks only while at least
  one player is online: a dedicated server with PauseEmpty=true is frozen when empty, and tool calls then time out
  with a "server paused" error. Call `status` first (it never needs the game to respond) and `wait_for` to block
  until somebody joins.
- Authority: the server owns zombies, items, world objects, vehicles, weather, time, XP, traits and god mode; those
  tools take effect for everybody immediately. A player's position, body damage, infection, appearance and stats are
  owned by that player's client, so `teleport`, `heal`, `cure`, `set_appearance` and every visual tool (`overlay_draw`,
  `texture_upload`, `world_sprite`, `falling_items`, `client_exec`, `lua_eval_client`) are pushed to the client mod
  and only work for players running the ZomboidMCP mod (all players on a server that requires it).
- Only the loaded area (roughly 100 tiles around online players) exists on the server. World queries and spawns
  outside it fail; teleport a player there first.
- Player names: the `player` argument accepts the account name or the character name and may be omitted when exactly
  one player is online.
- Escape hatches: `lua_eval_server` runs arbitrary Lua on the server, `lua_eval_client` on a client, `module_install`
  hot-loads a persistent Lua module without a restart, `server_console` sends raw admin console commands (dedicated
  servers reached over ssh). `api_search` and `lua_examples` look up engine signatures and vanilla Lua usage before
  you write Lua. Prefer the curated tools when one fits: they validate arguments and report what happened.
- `events_poll` returns deaths, joins, tool errors and chat-like notes appended by the game since your last call.
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
X = _i("World tile x (east). Use players_list / player_info for a reference position.")
Y = _i("World tile y (south).")
Z = _i("Floor level, 0 = ground.", default=0, minimum=-32, maximum=32)

TOOLS = []


def tool(name, description, schema, game=None, local=None):
    TOOLS.append({"name": name, "description": description.strip(), "inputSchema": schema,
                  "game": game, "local": local})


# ------------------------------------------------------------------ discover
tool("status", """
Snapshot of the game as seen by the MCP process: bridge liveness (live / paused / stale / not_running with a hint),
heartbeat age, online players with position and health, in-game time, bridge version, registered game tools and
installed modules, and how this MCP is connected. Answered from the heartbeat file the server writes every 2 s, so it
never blocks and works while the server is paused. Call it first in a session and whenever a tool times out.
""", _obj({}), local="status")

tool("wait_for", """
Block until the game bridge is alive and a condition holds: a named player is online, or at least `min_players`
are. Use it after `status` reports the server paused (no players online). Read-only; returns the status once the
condition is met or a timeout error.
""", _obj({
    "player": _s("Wait for this player (account or character name) to be online."),
    "min_players": _i("Minimum number of online players.", default=1, minimum=0),
    "timeout_s": _n("Give up after this many seconds.", default=300, minimum=1, maximum=3600),
}), local="wait_for")

tool("players_list", """
List online players: account name, character name, position (x,y,z), health, dead/alive, and what the server knows
about their state. Server-side, read-only, instant. In single-player the local player is returned.
""", _obj({}), game="players_list")

tool("player_info", """
Detailed server-side view of one player: position, health, infection flag as the server sees it (the client owns the
truth), traits, skill levels, equipped weapon, inventory summary, nearby zombie count. Read-only.
""", _obj({"player": PLAYER}), game="player_info")

tool("world_query", """
Inspect the world around a point: the grid square (room, outside, sprites), objects with their sprite names, items on
the ground, zombies, vehicles and players within `radius` tiles. Server-side, read-only, limited to the loaded area
(near online players) and to a radius of 50 tiles. Use it to find sprite names to reuse with place_object and to check
what spawn/place tools did.
""", _obj({
    "x": X, "y": Y, "z": Z,
    "radius": _i("Radius in tiles (1..50).", default=5, minimum=0, maximum=50),
    "include": _arr("Categories to include; default all.", {
        "type": "string", "enum": ["square", "objects", "items", "zombies", "vehicles", "players"]}),
}, ["x", "y"]), game="world_query")

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

tool("events_poll", """
Events the game appended since your last call: player deaths and joins, tool errors, bridge reloads, chat-like notes
from server modules. Each event is {t: unix seconds, kind, data}. The first call in a session returns the recent tail;
pass the returned `cursor` (a byte offset) to resume explicitly. Read-only and works while the server is paused.
""", _obj({
    "cursor": _i("Byte offset returned by the previous call; omit to continue from where this session left off."),
    "limit": _i("Return at most this many (newest) events.", default=100, minimum=1, maximum=2000),
    "kinds": _arr("Only these event kinds, e.g. ['death','join','tool_error'].", {"type": "string"}),
}), local="events_poll")

# ------------------------------------------------------------------ players
tool("teleport", """
Move a player to a tile or next to another player. Position is client-authoritative: the move is pushed to that
player's client mod and confirmed on the next tick, so the player needs the mod. Everyone sees the player appear at
the target. The target square need not be loaded (the client loads it). Affects a character: only when asked.
""", _obj({
    "player": PLAYER, "x": X, "y": Y, "z": Z,
    "to_player": _s("Instead of x/y/z: teleport next to this online player."),
}), game="teleport")

tool("heal", """
Restore a player to full body health: wounds, bleeding, fractures, pain, and reset moodle-driving stats (hunger,
thirst, fatigue, panic). Body state is client-authoritative, so the fix is pushed to the player's client mod; the
server-side vanilla sync is applied as well. Visible to everyone within a second. Does not remove zombie infection
(use cure).
""", _obj({"player": PLAYER}), game="heal")

tool("cure", """
Remove the zombie infection (Knox virus) and infected wounds from a player. Client-authoritative like heal; without
the client mod the server-side attempt is overwritten by the client within seconds. Reports whether the client
confirmed the cure.
""", _obj({"player": PLAYER}), game="cure")

tool("god_mode", """
Toggle invincibility for a player (the server's godmode flag, same as the admin command). Server-authoritative and
synced to the player's client; other players see nothing but the player takes no damage. Persists until turned off.
""", _obj({"player": PLAYER, "enabled": _b("true to enable, false to disable.", default=True)}, ["enabled"]),
     game="god_mode")

tool("set_traits", """
Add and/or remove character traits by their CharacterTrait constant name (e.g. 'BRAVE', 'HANDY', 'CLUMSY'; use
api_search 'CharacterTrait' for the list). Server-authoritative and persisted with the character; effects apply on
the player's next update. Affects a character: only when asked.
""", _obj({
    "player": PLAYER,
    "add": _arr("Trait constants to add.", {"type": "string"}),
    "remove": _arr("Trait constants to remove.", {"type": "string"}),
}), game="set_traits")

tool("set_skills", """
Set skill (perk) levels 0..10 by perk name (e.g. 'Aiming', 'Woodwork', 'Fitness', 'Strength'; api_search 'Perks' for
names). Server-authoritative via XP grants without multipliers; the client shows the new level within a tick. Lowering
a level is not supported by the engine and is reported as skipped.
""", _obj({
    "player": PLAYER,
    "skills": {"type": "object", "description": "Map of perk name to target level 0..10.",
               "additionalProperties": {"type": "integer", "minimum": 0, "maximum": 10}},
}, ["skills"]), game="set_skills")

tool("set_appearance", """
Change hair style, beard style and hair colour of a player. Appearance is client-authoritative: pushed to the player's
client mod and then broadcast by the engine, so everyone sees it. Style names come from media/hairStyles/*.xml
(lua_examples 'hairStyles'). Unverified in 42.21 for some fields; the result says what was applied.
""", _obj({
    "player": PLAYER,
    "hair": _s("Hair style id, e.g. 'Bald', 'Long', 'Mohawk'."),
    "beard": _s("Beard style id, or '' for none."),
    "hair_color": _arr("RGB 0..1, e.g. [0.9, 0.1, 0.1].", {"type": "number", "minimum": 0, "maximum": 1},
                       minItems=3, maxItems=3),
}), game="set_appearance")

tool("give_item", """
Put items straight into a player's main inventory. Server-authoritative (AddItem + sendAddItemToContainer): the item
appears for the player at once and is real for everyone. Item type is 'Module.Name' like 'Base.Axe', 'Base.Banana';
count is capped at 100 per call. Weight limits are ignored (the player may become overloaded).
""", _obj({
    "player": PLAYER,
    "item": _s("Full item type, e.g. 'Base.Katana'."),
    "count": _i("How many.", default=1, minimum=1, maximum=100),
}, ["item"]), game="give_item")

tool("snapshot", """
Save a named snapshot of a player's character: skills, traits, inventory (item types and conditions), position, health.
Stored server-side in mod data (survives restarts). Use restore to bring it back, e.g. after a death. Read-only for
the player.
""", _obj({"player": PLAYER, "name": _s("Snapshot name; default 'auto'.", default="auto")}), game="snapshot")

tool("restore", """
Restore a player's character from a snapshot: skills and traits (server-authoritative), inventory (re-created
server-side), and optionally position (pushed to the client). Overwrites the current character state. Affects a
character: only when asked.
""", _obj({
    "player": PLAYER,
    "name": _s("Snapshot name; default 'auto'.", default="auto"),
    "position": _b("Also teleport to the saved position.", default=False),
}), game="restore")

# ------------------------------------------------------------------ world
tool("spawn_item", """
Drop items on the ground at a tile (real world items everyone can see and pick up). Server-authoritative
(AddWorldInventoryItem). The square must be loaded (near a player). Up to 100 per call; large counts spread over
`radius` tiles. Use give_item for inventories and falling_items for a visible fall from the sky.
""", _obj({
    "item": _s("Full item type, e.g. 'Base.Banana'."),
    "x": X, "y": Y, "z": Z,
    "count": _i("How many.", default=1, minimum=1, maximum=100),
    "radius": _i("Scatter within this many tiles.", default=0, minimum=0, maximum=20),
}, ["item", "x", "y"]), game="spawn_item")

tool("spawn_vehicle", """
Spawn a vehicle by script name (e.g. 'Base.CarNormal', 'Base.PickUpTruck', 'Base.SportsCar'; api_search 'Vehicles'
or lua_examples 'addVehicleDebug' for names) at a tile, facing a direction. Server-authoritative, appears for everyone
at once, on loaded squares only. The vehicle spawns in random condition; use vehicle_fix to repair and refuel it.
""", _obj({
    "script": _s("Vehicle script name, e.g. 'Base.CarNormal'."),
    "x": X, "y": Y, "z": Z,
    "direction": _s("Facing direction.", enum=["N", "NE", "E", "SE", "S", "SW", "W", "NW"], default="S"),
}, ["script", "x", "y"]), game="spawn_vehicle")

tool("vehicle_fix", """
Repair all parts and/or fill the gas tank of the vehicle a player is in or the nearest vehicle to a tile. Server-
authoritative (vehicle:repair, part mod data transmit); other players see the repaired state. Only loaded vehicles.
""", _obj({
    "player": _s("Use this player's current or nearest vehicle."),
    "x": X, "y": Y, "z": Z,
    "repair": _b("Repair every part to full condition.", default=True),
    "refuel": _b("Fill the gas tank.", default=True),
}), game="vehicle_fix")

tool("spawn_zombies", """
Spawn a group of zombies at a tile (addZombiesInOutfit). Server-authoritative: real zombies for everyone. `count` is
capped at 50 per call; the square must be loaded. Optional outfit name (e.g. 'Police', 'Fireman', 'Nurse';
lua_examples 'Outfit' for names). This is a horde event: dangerous for players, do it only when asked.
""", _obj({
    "x": X, "y": Y, "z": Z,
    "count": _i("Number of zombies (1..50).", default=5, minimum=1, maximum=50),
    "outfit": _s("Outfit name or omit for random."),
    "female_chance": _i("Percent chance each zombie is female (0..100).", default=50, minimum=0, maximum=100),
}, ["x", "y"]), game="spawn_zombies")

tool("kill_zombies_area", """
Kill every zombie within `radius` tiles of a point (or of a player). Server-authoritative; bodies drop for everyone.
Limited to the loaded area and a radius of 80. Returns the number killed.
""", _obj({
    "player": _s("Centre on this player instead of x/y/z."),
    "x": X, "y": Y, "z": Z,
    "radius": _i("Radius in tiles (1..80).", default=10, minimum=1, maximum=80),
}), game="kill_zombies_area")

tool("place_object", """
Place a vanilla tile sprite as a new world object on a square (IsoObject + transmitAddObjectToSquare), e.g. walls
('walls_exterior_house_01_0'), furniture, fences, lamps, decorations. Server-authoritative, persistent in the save,
visible to everyone. The square must be loaded. Sprite names: world_query on an existing object, or lua_examples.
Placed objects have no collision or function unless the sprite's properties provide them.
""", _obj({
    "sprite": _s("Tile sprite name, e.g. 'walls_exterior_house_01_0'."),
    "x": X, "y": Y, "z": Z,
    "name": _s("Optional object name (shown in world_query).", default="ZomboidMCP"),
}, ["sprite", "x", "y"]), game="place_object")

tool("remove_object", """
Remove a world object from a square (transmitRemoveItemFromSquare). Server-authoritative and persistent. Selects by
sprite name and/or object index (from world_query); by default only objects created by place_object are removed, set
`any` to true to delete vanilla map objects (irreversible without a map reset).
""", _obj({
    "x": X, "y": Y, "z": Z,
    "sprite": _s("Only objects with this sprite name."),
    "index": _i("Object index on the square, from world_query."),
    "any": _b("Allow removing objects that were not placed by this mod.", default=False),
}, ["x", "y"]), game="remove_object")

tool("set_weather", """
Change the weather for everyone: start rain of a given intensity, a storm, or clear the sky. Server-authoritative via
the climate manager (transmitServerStartRain / TriggerStorm / StopWeather); clients follow within seconds. The
simulation may drift back to natural weather over time.
""", _obj({
    "mode": _s("Weather to set.", enum=["rain", "storm", "clear"]),
    "intensity": _n("Rain/storm intensity 0..1.", default=0.8, minimum=0, maximum=1),
}, ["mode"]), game="set_weather")

tool("set_time", """
Set the in-game time of day (0..24 hours) for the whole server; day/month/year are left alone. Server-authoritative
and synced to all clients. Sudden jumps affect darkness, zombie behaviour and player fatigue.
""", _obj({"hour": _n("Hour of day, e.g. 6.5 for 06:30.", minimum=0, maximum=24)}, ["hour"]), game="set_time")

tool("sound", """
Play a named game sound at a tile or at a player (playServerSound). Server-authoritative: heard by every player in
range. Sound names are the engine's sound bank names, e.g. 'ZombieThumpGeneric', 'BurglarAlarm', 'ChurchBell'
(lua_examples 'playSound' for examples). Also attracts zombies like any world sound.
""", _obj({
    "name": _s("Sound bank name."),
    "player": _s("Play at this player's position instead of x/y/z."),
    "x": X, "y": Y, "z": Z,
}, ["name"]), game="sound")

tool("lightning", """
Trigger a lightning flash (and optional strike sound / rumble) at a tile. Server-authoritative
(transmitServerTriggerLightning): everyone nearby sees the flash. Purely audiovisual, no damage or fire.
""", _obj({
    "x": X, "y": Y, "z": Z,
    "strike": _b("Play the strike sound.", default=True),
    "light": _b("Flash the light.", default=True),
    "rumble": _b("Distant rumble.", default=True),
}, ["x", "y"]), game="lightning")

tool("server_message", """
Broadcast a text message to all players (server chat / on-screen server message). Server-authoritative. Keep it
short; the chat window wraps at roughly 100 characters.
""", _obj({"text": _s("Message text.", maxLength=500)}, ["text"]), game="server_message")

# ------------------------------------------------------------------ visuals (client push)
tool("client_exec", """
Run a Lua chunk on every connected client (or one player's client) that has the ZomboidMCP mod. Client-side only:
use it for UI, drawing, camera, local effects, or anything client-authoritative (position, body state). The code is
chunked over sendServerCommand (≈3 kB per message, large sources are fine but slower) and executed with loadstring;
errors are reported back through events_poll as 'client_error'. Returns which clients acknowledged. Not persistent:
late joiners do not receive it unless `persist` is true.
""", _obj({
    "code": _s("Lua source to run on the client. `getPlayer()` is the local player."),
    "player": _s("Only this player's client; default all."),
    "persist": _b("Re-send to players who join later (until clear_visuals).", default=False),
}, ["code"]), game="client_exec")

tool("overlay_draw", """
Draw shapes and text on players' screens, anchored to the screen (HUD) or to a world position (follows the camera and
zoom). Client-side visual pushed to every client with the mod (or one player); nothing changes in the world. Each
overlay has an id you can update or clear (clear_visuals). Shapes: rect, line, text, texture (id from texture_upload),
circle. Colours are RGBA 0..1. Overlays are lost on relog unless `persist`.
""", _obj({
    "id": _s("Overlay id; reusing an id replaces it.", default="default"),
    "player": _s("Only this player's screen; default everyone."),
    "anchor": _s("'screen' uses pixel coordinates; 'world' uses tile coordinates x/y/z per shape.",
                 enum=["screen", "world"], default="world"),
    "shapes": _arr("Shapes to draw.", {
        "type": "object",
        "properties": {
            "type": {"type": "string", "enum": ["rect", "line", "text", "texture", "circle"]},
            "x": _n("X (pixels or tiles)."), "y": _n("Y (pixels or tiles)."), "z": _n("Floor for world anchor.", default=0),
            "x2": _n("Line end x."), "y2": _n("Line end y."),
            "w": _n("Width (pixels, or tiles for world anchor)."), "h": _n("Height."),
            "r": _n("Circle radius."),
            "text": _s("Text to draw."), "font": _s("Font name.", enum=["Small", "Medium", "Large", "Title"], default="Medium"),
            "texture": _s("Texture id from texture_upload."),
            "color": _arr("RGBA 0..1.", {"type": "number"}, minItems=3, maxItems=4),
        },
        "required": ["type"], "additionalProperties": True,
    }),
    "ttl_s": _n("Remove automatically after this many seconds (0 = keep).", default=0, minimum=0),
    "persist": _b("Also send to players who join later.", default=False),
}, ["shapes"]), game="overlay_draw")

tool("texture_upload", """
Upload a PNG (base64) to every connected client and register it under a texture id for world_sprite and
overlay_draw. Client-side: the image is chunked over the network, written into each client's Zomboid folder and loaded
as a Texture; nothing is stored on the server. Keep images small (≤ 512×512, a few hundred kB) — upload time is about
1 s per 30 kB. Late joiners receive all uploaded textures. Returns the texture id and which clients loaded it.
""", _obj({
    "id": _s("Texture id to reference later, e.g. 'snail'."),
    "png_base64": _s("PNG file contents, base64-encoded. Large values are passed to the game as a file automatically."),
}, ["id", "png_base64"]), game="texture_upload")

tool("world_sprite", """
Show an uploaded texture (or a vanilla texture name) in the world at a tile position, scaled in tiles, optionally
moving along a path over time. Client-side visual on every client with the mod: everyone sees it in the same place,
scaled with the camera zoom, but it has no collision and is not an object. Reuse an id to move/replace, clear_visuals
to remove.
""", _obj({
    "id": _s("Sprite id; reusing replaces it."),
    "texture": _s("Texture id from texture_upload, or a vanilla texture name such as 'Item_Banana'."),
    "x": _n("Tile x (fractional allowed)."), "y": _n("Tile y."), "z": _n("Floor.", default=0),
    "scale": _n("Width in tiles.", default=1, minimum=0.05, maximum=50),
    "path": _arr("Optional way-points; the sprite moves linearly between them.", {
        "type": "object", "properties": {"x": _n("Tile x."), "y": _n("Tile y."), "z": _n("Floor."),
                                         "t": _n("Seconds from start when this point is reached.")},
        "required": ["x", "y", "t"]}),
    "loop": _b("Repeat the path.", default=False),
    "ttl_s": _n("Remove after this many seconds (0 = keep).", default=0, minimum=0),
    "persist": _b("Also send to late joiners.", default=True),
}, ["id", "texture", "x", "y"]), game="world_sprite")

tool("falling_items", """
Make items visibly fall from the sky around a point and become real ground items when they land. The fall animation
is a client-side visual pushed to everyone with the mod; the landing spawns real server-authoritative items (like
spawn_item) that anyone can pick up. Count ≤ 100, area must be loaded.
""", _obj({
    "item": _s("Full item type, e.g. 'Base.Banana'."),
    "count": _i("How many.", default=10, minimum=1, maximum=100),
    "player": _s("Centre on this player instead of x/y/z."),
    "x": X, "y": Y, "z": Z,
    "radius": _i("Spread in tiles.", default=4, minimum=0, maximum=30),
    "height": _n("Drop height in tiles (visual only).", default=8, minimum=1, maximum=50),
    "duration_s": _n("Seconds over which the items fall.", default=3, minimum=0.2, maximum=60),
}, ["item"]), game="falling_items")

tool("clear_visuals", """
Remove overlays, world sprites and persisted client_exec payloads: everything, one id, or for one player. Client-side.
Uploaded textures stay cached unless `textures` is true.
""", _obj({
    "id": _s("Only this overlay/sprite id."),
    "player": _s("Only this player's client."),
    "textures": _b("Also drop uploaded textures.", default=False),
}), game="clear_visuals")

# ------------------------------------------------------------------ power
tool("lua_eval_server", """
Run arbitrary Lua on the game server (loadstring on the server tick) and return its value(s) JSON-encoded. Full
engine access: getOnlinePlayers(), getCell(), getClimateManager(), sendServerCommand(...), ZMCP helpers
(ZMCP.player(name), ZMCP.square(x,y,z), ZMCP.zombiesNear(...), ZMCP.toClients(cmd,args)). Errors are returned as
tool errors with the Lua message. Server-authoritative effects sync to everyone; client-owned state (position, body)
cannot be changed from here reliably: use lua_eval_client. Long loops block the whole server: keep it under ~100 ms.
Use `return` to get a value back; Java objects are stringified.
""", _obj({
    "code": _s("Lua source, e.g. 'return getGameTime():getTimeOfDay()'."),
    "timeout_s": _n("How long to wait for the result.", default=20, minimum=1, maximum=600),
}, ["code"]), game="lua_eval")

tool("lua_eval_client", """
Run Lua on one player's client (or all) and return the value(s) each client sent back. Client-side: use for
client-authoritative state (position, body, stats, appearance), UI, camera, screenshots of state that only the client
knows. Requires the client mod; the round trip needs two ticks. Blocking the client freezes that player's game.
""", _obj({
    "code": _s("Lua source; `getPlayer()` is the local player. Use `return` for a value."),
    "player": _s("Target player; default all connected clients."),
    "timeout_s": _n("How long to wait for replies.", default=10, minimum=1, maximum=120),
}, ["code"]), game="lua_eval_client")

tool("module_install", """
Install or update a persistent server-side Lua module without restarting: the source is written into the game's Lua
directory as zmcp_mod_<name>.lua, executed now with loadstring, and re-executed on every bridge (re)load. Use it to add
new tools (ZMCP.tool(name, desc, fn)), tick hooks (ZMCP.tickHooks.name = function(t) end) and helpers. Make the code
re-runnable (remove old handlers before adding). Errors are returned; the module is kept only if it ran cleanly.
""", _obj({
    "name": _s("Module name (letters, digits, _ and -).", pattern="^[A-Za-z0-9_-]{1,64}$"),
    "code": _s("Lua source of the module."),
}, ["name", "code"]), game="module_install", local="module_install")

tool("module_list", """
List installed persistent Lua modules with size, install time and whether the last load succeeded. Read-only.
""", _obj({}), game="module_list")

tool("module_remove", """
Delete a persistent module so it no longer loads on bridge reloads. Tools it registered stay until the next reload.
""", _obj({"name": _s("Module name.")}, ["name"]), game="module_remove")

# ------------------------------------------------------------------ auto
tool("guardian_config", """
Configure the Guardian: an opt-in server-side watcher that automatically heals/cures/clears zombies around a player
when their health drops below thresholds. Off by default. Server-authoritative (kills, god mode) plus client push for
body state. Set `enabled` per player or globally; omit values to read the current config.
""", _obj({
    "enabled": _b("Turn the Guardian on or off."),
    "player": _s("Only for this player; default all players."),
    "heal_below": _i("Heal when overall health drops below this percent.", minimum=0, maximum=100),
    "clear_radius": _i("Kill zombies within this radius when rescuing.", minimum=0, maximum=80),
    "cure": _b("Also cure infection when rescuing."),
}), game="guardian_config")

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
