# Tools

Direction (see the top of `docs/PLAN.md`): **scripting-first**. Claude mostly writes Lua and runs it through the
`run_lua_*` tools; only the curated "best of" operations below stay as MCP tools. Every tool has a recipe in
`docs/recipes/<tool>.md` with the equivalent raw Lua, and operations that are *not* tools (traits, skills, appearance,
searches, lightning, sound, messages) are recipes only.

Every tool is registered in the game with `ZMCP.tool(name, desc, fn)` (through `ZMCP.util.def`, which also records
the argument spec: `tools_specs` returns `name -> {desc, authority, args[{name, type, required, desc}]}`). A tool takes
one JSON object of arguments and returns a JSON-friendly table, or raises an error (the bridge answers
`{"ok": false, "error": "..."}`).

**Authority** says who owns the result in multiplayer:
- **server**: done on the server and synced to all clients by the engine. Reliable.
- **client**: the server only sends a command to the player's Zomboid MCP client mod (`docs/PROTOCOL.md`). The tool
  reports `sent = true`; nothing happens for players without the mod. Verify with `player_info`.

Coordinates are world tiles (`x`, `y`, level `z`, 0 = ground; fractional x/y are floored except for `teleport`). Only
squares near online players are loaded; tools that touch a square fail with
`square x,y,z is not loaded (only areas near players are loaded)` otherwise. Tools needing a player accept
`player` = username or character name; when exactly one player is online `player` may be omitted.

## Curated game-side tools (ZOM-4)

### Discovery (`Api/World.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `status` | – | the bridge heartbeat (`version, bootId, paused, players[], time, tools[], stats, uptime`) plus `weather{raining, rain, snowing, snow, storm, tropical, blizzard, temperature, fog, wind, clouds, daylight}`, `zombiesLoaded`, `vehiclesLoaded` | server |
| `players_list` | – | `[{user, name, x, y, z, dead, health, accessLevel, onlineId, inVehicle}]` | server |
| `player_info` | `player?`, `inventory_limit?` (60) | player summary plus `dir, female, profession, health{overall, infected, infectionLevel, bleedingParts, asleep, godMode, invisible}, hoursSurvived, zombieKills, traits[{id, label}], skills[{id, name, level, xp}], inventory{items[{type, name, count}], distinctTypes, count, weight, maxWeight, truncated}, equipped{primary, secondary, worn[{location, type, name}]}, moodles{NAME=level}, stats{NAME=value}` | server (moodles/stats are the server's copy of client state and may lag) |
| `world_query` | `x, y, z?, radius?` (10; ≤40 for objects/items/vehicles, ≤80 for zombies), `what?` = `zombies\|objects\|items\|vehicles\|players\|all`, `limit?` (200), `include_floor?` | `{zombies[{id, x, y, z, outfit, crawling, female, health, target}], zombieCount, players[], objects[{x, y, index, sprite, type, name}], objectCount, items[{x, y, type, name, condition, weight}], itemCount, vehicles[{id, script, x, y, z, speed, engineRunning, engineQuality, driver}], unloadedSquares, scanRadius}` | server |

### Players (`Api/Players.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `teleport` | `player?, x, y, z?` | `{sent, user, x, y, z, from}` | **client** (`teleport` command, `docs/PROTOCOL.md`) |
| `give_item` | `player?, type, count?` (1..100) | `{user, type, name, count, items[]}` | server (`AddItem` + `sendAddItemToContainer`) |

### Items (`Api/Items.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `spawn_item` | `x, y, z?, type, count?` (1..200), `scatter?` (tiles, ≤20) | `{type, name, placed, skipped, squares{"x,y"=n}}` | server (`AddWorldInventoryItem`) |

### Zombies (`Api/Zombies.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `spawn_zombies` | `x, y, z?, count?` (1..100), `outfit?`, `female_chance?` | `{spawned, ids[], outfit, x, y, z}` | server (`addZombiesInOutfit`). **Ask the owner before hordes near players.** |
| `kill_zombies_area` | `x, y, z?` or `player`, `radius?` (10, ≤80), `killer?` | `{killed, x, y, z, radius}` | server (`setAttackedBy` + `Kill`) |

### Vehicles (`Api/Vehicles.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `spawn_vehicle` | `script, x, y, z?, dir?` (`N..NW`, default `S`) | `{id, script, x, y, z, dir, speed, engineRunning, engineQuality, driver}` | server (`addVehicleDebug`). Needs free flat ground; **ask the owner near players.** |
| `vehicle_fix` | `player?` (their vehicle, else nearest) or `x, y, z?`, `radius?` (12), `repair?` (true), `refuel?` (true) | `{vehicle, repaired, refueled, fuel{amount, capacity}, before{engineQuality, parts[]}, after{...}}` | server (`repair()`, `GasTank:setContainerContentAmount` + `transmitPartModData`) |

### Objects (`Api/Objects.lua`, `Api/TileSheets.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `place_object` | `x, y, z?, sprite, name?` | `{x, y, z, sprite, name, index, spriteSource}` | server (`IsoObject.new` + `transmitAddObjectToSquare`). Sprite names are validated against the live sprite map (or the vanilla tilesheet index) without `getSprite()`, which would create blank sprites. |
| `remove_object` | `x, y, z?, sprite?` or `index?`, `all?`, `force?` | `{x, y, z, removed[], objects[]}`; without `sprite`/`index` it only lists the square's objects | server (`transmitRemoveItemFromSquare`). Floors need `force`. |
| `build_structure` | `objects[{x, y, z?, sprite, name?}]` (≤500), `stop_on_error?` | `{placed, errors[{i, error, ...}], objects[]}` | server (batched `place_object`) |

### Environment (`Api/Environment.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `set_weather` | `kind` = `rain\|storm\|clear`, `intensity?` (0..1, 0.7) | `{kind, intensity, weather{...}}` | server (`transmitServerStartRain` / `transmitServerTriggerStorm` / `transmitServerStopWeather`) |
| `set_time` | `hour?` (0..24), `day?`, `month?`, `year?` (1-based) | `{before{...}, after{...}}` | server (`GameTime:setTimeOfDay/setDay/setMonth/setYear`) |

### Bridge core (`Bridge.lua`, ZOM-1)
`ping`, `lua_eval {code}`, `tools_list`, `run_file {file}`, `module_install/list/remove`, `status` (extended by
`Api/World.lua`), plus `tools_specs` (argument specs of everything above).

## Scripting-only operations (recipes)
`docs/recipes/`: item_types, vehicle_types, vehicle_info, sprite_search, outfits, zombies_count_near, set_traits,
set_skills, set_appearance, lightning, sound, server_message.

## Events
Tools that change the world append to the bridge event log (`kind` = tool name, `data` = what was changed) so the MCP
`events_poll` shows them.

## Live verification (42.21 dedicated server, 2026-09-30)
- Loaded through the ZOM-1 bridge 0.2.0 (`run_file` of the Api files) while the server was paused: all 16 tools
  registered, `status` merges the bridge heartbeat with weather, `players_list` empty, validation errors
  (`unknown item type`, `kind must be one of`, `square ... is not loaded`, `no player online`) come back as clear
  messages.
- Engine lookups behind the tools and recipes verified with `lua_eval`: item scripts (`Base.Banana`), 395 vehicle
  scripts, the 61k-entry sprite map with `containsKey`, 239 outfits, 97 trait definitions (`CharacterTrait.BRAVE`
  → id `brave`), 42 hair / 10 beard styles, the 35 skill perks, `MoodleType.X`, `CharacterStat.X`, `IsoDirections.S`.
- World-touching tools (spawn/place/kill/vehicle/weather/time) need loaded squares, i.e. a player online; run them
  next to the owner with their OK and clean up afterwards.
