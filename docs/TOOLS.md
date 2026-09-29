# Tools

Every tool is registered in the game with `ZMCP.tool(name, desc, fn)` and takes one JSON object of arguments; it returns a
JSON-friendly table or raises an error (the bridge answers `{"ok": false, "error": "..."}`). Argument specs are also
available live through the `tools_specs` tool (`Api/Common.lua` registry).

**Authority** says who owns the result in multiplayer:
- **server**: done on the server and synced to all clients by the engine. Reliable.
- **client**: the server only sends a command to the player's Zomboid MCP client mod (`docs/PROTOCOL.md`). The tool
  reports `sent = true`; nothing happens for players without the mod. Verify with `player_info`.
- **mixed**: applied on the server copy and also sent to the client.

Coordinates are world tiles (`x`, `y`, level `z`, 0 = ground). Only squares near online players are loaded; tools that
touch a square fail with `square x,y,z is not loaded (only areas near players are loaded)` otherwise. `radius` scans are
capped (40 tiles for objects/items/vehicles, 80 for zombies). Tools needing a player accept `name` = username or
character name; when exactly one player is online `name` may be omitted.

## Game-side tools (ZOM-4)

### Discovery (`Api/World.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `status` | – | `{version, server, t, players[], time{hour,day,month,year,daysSurvived}, weather{raining,rain,snowing,storm,tropical,blizzard,temperature,fog,wind,clouds,daylight}, zombiesLoaded, vehiclesLoaded, tools}` | server |
| `players_list` | – | `[{user, name, x, y, z, dead, health, accessLevel, onlineId, inVehicle}]` | server |
| `player_info` | `name?`, `inventory_limit?` (default 60) | player summary plus `dir, female, profession, health{overall, infected, infectionLevel, bleedingParts, asleep, godMode, invisible}, hoursSurvived, zombieKills, traits[{id,label}], skills[{id,name,level,xp}], inventory{items[{type,name,count}], distinctTypes, count, weight, maxWeight}, equipped{primary, secondary, worn[{location,type,name}]}, moodles{NAME=level}, stats{NAME=value}` | server (moodles/stats are the server's copy of client state and may lag) |
| `world_query` | `x, y, z?, radius?` (10), `what?` = `zombies|objects|items|vehicles|players|all`, `limit?` (200), `include_floor?` | `{zombies[], zombieCount, players[], objects[{x,y,index,sprite,type,name}], objectCount, items[{x,y,type,name,...}], itemCount, vehicles[{id,script,x,y,z,speed,engineRunning,driver}], unloadedSquares, scanRadius}` | server |

### Players (`Api/Players.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `teleport` | `name?, x, y, z?` | `{sent, user, x, y, z, from}` | **client** (`teleport` command) |
| `traits_list` | `query?` | `[{id, label, cost, free}]` | server |
| `set_traits` | `name?, add?[], remove?[]` (constant `BRAVE`, label `Brave`, or id `base:brave`) | `{user, added[], removed[], traits[]}` | server (`CharacterTraits:add/remove` + `sendPlayerExtraInfo`; the client's UI may refresh only after relog) |
| `set_skills` | `name?, skills{PerkId = 0..10}` (ids like `Woodwork`, `Aiming`, `Fitness`) | `{user, changes[{id, before, after, requested, method}]}` | server. Raising: `addXpNoMultiplier` (synced). Lowering: `setPerkLevelDebug` + `setXPToLevel` on the server copy (unverified sync) |
| `hair_styles` | `female?` | `{hair[], beard[]}` | server |
| `set_appearance` | `name?, hair?, beard?, hair_color?, beard_color?, skin_color?` (`#rrggbb` or `r,g,b`) | `{user, applied{}, current{hair, beard}}` | **mixed**: `HumanVisual` set on the server + `sendHumanVisual`, and the `appearance` command to the owning client |
| `give_item` | `name?, type, count?` (1..100) | `{user, type, name, count, items[]}` | server (`AddItem` + `sendAddItemToContainer`) |

### Items (`Api/Items.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `item_types` | `query, limit?` (50), `include_hidden?` | `{query, total, items[{type, name, category, weight}], truncated}` | server |
| `spawn_item` | `x, y, z?, type, count?` (1..200), `scatter?` (tiles, ≤20) | `{type, name, placed, skipped, squares{"x,y"=n}}` | server (`AddWorldInventoryItem`) |

### Zombies (`Api/Zombies.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `outfits` | `query?, female?` | `[outfitName]` | server |
| `spawn_zombies` | `x, y, z?, count?` (1..100), `outfit?`, `female_chance?` | `{spawned, ids[], outfit, x, y, z}` | server (`addZombiesInOutfit`). **Ask the owner before hordes near players.** |
| `kill_zombies_area` | `x, y, z?` or `name`, `radius?` (10, ≤80), `killer?` | `{killed, x, y, z, radius}` | server (`setAttackedBy` + `Kill`) |
| `zombies_count_near` | `name?` or `x, y, z?`, `radius?` (15) | `{count, radius, crawling, targetingPlayer, nearest{...}, nearestDistance}` | server |

### Vehicles (`Api/Vehicles.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `vehicle_types` | `query?, limit?` | `{total, vehicles[{script, name, mechanicType}], truncated}` | server |
| `spawn_vehicle` | `script, x, y, z?, dir?` (`N..NW`, default `S`) | vehicle info `{id, script, x, y, z, dir, ...}` | server (`addVehicleDebug`). Needs free ground; **ask the owner near players.** |
| `vehicle_fix` | `name?` (their vehicle or nearest) or `x, y, z?`, `radius?` (12), `repair?` (true), `refuel?` (true) | `{vehicle, repaired, refueled, fuel{amount,capacity}, before{engineQuality, parts[]}, after{...}}` | server (`repair()`, `GasTank:setContainerContentAmount` + `transmitPartModData`) |
| `vehicle_info` | same lookup args | `{id, script, x, y, z, dir, speed, engineRunning, engineQuality, driver, parts[{id, condition, content?, capacity?}]}` | server |

### Objects (`Api/Objects.lua`, `Api/TileSheets.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `sprite_search` | `query, limit?` (100) | `{source: live\|index, sheets[{sheet, count}], sprites[], total, truncated}` | server. Live = `IsoSpriteManager` named map (mods included); index = vanilla tilesheet list (`tools/gen_tilesheets.sh`). A sheet `X` with count `N` has sprites `X_0 .. X_(N-1)`. |
| `place_object` | `x, y, z?, sprite, name?` | `{x, y, z, sprite, name, index, spriteSource}` | server (`IsoObject.new` + `transmitAddObjectToSquare`). Sprite names are validated without creating blank sprites. |
| `remove_object` | `x, y, z?, sprite?` or `index?`, `all?`, `force?` | `{x, y, z, removed[], objects[]}`; without `sprite`/`index` only lists the square's objects | server (`transmitRemoveItemFromSquare`). Floors need `force`. |
| `build_structure` | `objects[{x, y, z?, sprite, name?}]` (≤500), `stop_on_error?` | `{placed, errors[{i, error, ...}], objects[]}` | server (batched `place_object`) |

### Environment (`Api/Environment.lua`)

| tool | args | result | authority |
| --- | --- | --- | --- |
| `set_weather` | `kind` = `rain|storm|clear`, `intensity?` (0..1, 0.7) | `{kind, intensity, weather{...}}` | server (`transmitServerStartRain` / `transmitServerTriggerStorm` / `transmitServerStopWeather`) |
| `set_time` | `hour?` (0..24), `day?`, `month?`, `year?` (1-based) | `{before{...}, after{...}}` | server (`GameTime:setTimeOfDay/setDay/setMonth/setYear`) |
| `lightning` | `x, y, strike?, light?, rumble?` | `{x, y, strike, light, rumble}` | server (`transmitServerTriggerLightning`) |
| `sound` | `x, y, z?, name` | `{name, x, y, z}` | server (`playServerSound`) |
| `server_message` | `text, name?, mode?` = `halo|chat`, `color?` | `{sent, to, mode, players}` | **client** (`message` command). Vanilla fallback: console `servermsg`. |

### Bridge core (`Bridge.lua`, ZOM-1)
`ping`, `lua_eval {code}`, `tools_list`, `run_file {file}`, plus `tools_specs` (argument specs of everything above).

## Events
Tools that change the world append to `zmcp_events.jsonl` (`kind` = tool name, `data` = what was changed) so the MCP
`events_poll` shows them.

## Testing on the live server
`tools/zmcp_dev.sh load` bundles Json + Bridge + Api into one file and loads it through `tools/pz run` (players must be
online: the dedicated server pauses when empty). `tools/zmcp_dev.sh call <tool> '<json args>'` sends one request.
Rules from `docs/ENGINE_NOTES.md` apply: read-only tests near players are fine; spawning hordes, vehicles or objects near
people and anything touching a character needs the owner's OK, and everything created must be cleaned up.
