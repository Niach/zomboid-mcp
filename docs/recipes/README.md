# Recipes: the raw Lua behind each tool

Every curated MCP tool has a recipe here with the equivalent raw Lua, so the same thing can be scripted through
`run_lua_server` / `run_lua_client` (the skill teaches from these). Recipes for operations that are **not** tools
(traits, skills, appearance, searches, lightning, sound, messages) live here too.

Conventions:
- **Server** snippets run in the server Lua state (`run_lua_server`; in single player the host is the server).
  They return a plain table which comes back JSON-encoded.
- **Client** snippets run on a player's client (`run_lua_client`, one player or all). `getPlayer()` is the local player.
- Only squares near online players are loaded: `getCell():getGridSquare(x, y, z)` returns `nil` elsewhere.
- Kahlua (Lua 5.1 subset): no `io`, no `bit`, `tostring()` needs an argument, Java overloads resolve by argument
  count. Java lists use `:size()` / `:get(i)` (0-based). See `docs/ENGINE_NOTES.md` for every verified gotcha.
- Authority: **server** = done on the server and synced by the engine; **client** = only the owning client can do it.

| recipe | tool | authority |
| --- | --- | --- |
| [status](status.md) | `status` | server |
| [players_list](players_list.md) | `players_list` | server |
| [player_info](player_info.md) | `player_info` | server |
| [world_query](world_query.md) | `world_query` | server |
| [spawn_item](spawn_item.md) | `spawn_item` | server |
| [give_item](give_item.md) | `give_item` | server |
| [spawn_vehicle](spawn_vehicle.md) | `spawn_vehicle` | server |
| [vehicle_fix](vehicle_fix.md) | `vehicle_fix` | server |
| [spawn_zombies](spawn_zombies.md) | `spawn_zombies` | server |
| [kill_zombies_area](kill_zombies_area.md) | `kill_zombies_area` | server |
| [place_object](place_object.md) | `place_object` | server |
| [remove_object](remove_object.md) | `remove_object` | server |
| [build_structure](build_structure.md) | `build_structure` | server |
| [set_weather](set_weather.md) | `set_weather` | server |
| [set_time](set_time.md) | `set_time` | server |
| [teleport](teleport.md) | `teleport` | client |
| [item_types](item_types.md) | – (scripting) | server |
| [vehicle_types](vehicle_types.md) | – | server |
| [vehicle_info](vehicle_info.md) | – | server |
| [sprite_search](sprite_search.md) | – | server |
| [outfits](outfits.md) | – | server |
| [zombies_count_near](zombies_count_near.md) | – | server |
| [set_traits](set_traits.md) | – | server |
| [set_skills](set_skills.md) | – | server |
| [set_appearance](set_appearance.md) | – | client |
| [lightning](lightning.md) | – | server |
| [sound](sound.md) | – | server |
| [server_message](server_message.md) | – | client / console |
