# Recipes

Complete, ready-to-run sequences. Each one lists the MCP calls in order (as `{"tool", "args"}` objects with the real
argument names), the raw Lua behind them, how to verify, and how to clean up. Replace positions with the ones
`players_list` gives you.

| recipe | what it makes | main tools |
|---|---|---|
| [bananas-from-the-sky](bananas-from-the-sky.md) | 20 bananas rain down and can be picked up | `falling_items` |
| [giant-snail](giant-snail.md) | a 3-tile snail PNG crawling next to the player | `texture_upload`, `world_sprite` |
| [claude-star](claude-star.md) | a 3D Claude star standing in the street, then rolling down it | `model_upload`, `model_place`, `entity3d_spawn` |
| [tile-house](tile-house.md) | a small wooden hut from vanilla tiles, and its removal | `build_structure`, `remove_object` |
| [horde-event](horde-event.md) | a timed horde with warning, lightning and cleanup | `spawn_zombies`, `set_weather`, `kill_zombies_area` |
| [merchant-actor](merchant-actor.md) | a passive zombie trader that greets and hands out items | `run_lua_server`, `script_install` |
| [supply-drop](supply-drop.md) | a crate falls from the sky with loot inside | `falling_items`, `place_object`, `run_lua_server` |
| [flappy-bird](flappy-bird.md) | a screen app for one player or everyone | `script_install side=client` |
| [custom-hud](custom-hud.md) | a persistent HUD with health, position, nearby zombies | `script_install side=client` |

The raw-Lua equivalents of every curated tool, and scripting-only operations (traits, skills, appearance, searches,
lightning, sound), are in the repo under `docs/recipes/` ([index](../../../../../../docs/recipes/README.md)): the
guides in `../guides/` carry the same snippets with context.
