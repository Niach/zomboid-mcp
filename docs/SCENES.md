# Scenes and screen apps: SDK reference and writing guide

A **scene** is a Lua chunk Claude writes live and starts with `scene_start {name, code, args?, persistent?}`. It runs
on the server as a coroutine (`Api/Scenes.lua`), so it can `wait()`, walk a zombie puppet somewhere and continue when
it arrives, drift a sprite across the map, ask a player a question and react to the answer. Everything it creates is
tracked and removed by `scene_stop`. A **screen app** is a Lua chunk that runs on a player's client (`app_start`),
draws on the overlay and reads keys and mouse: a flappy bird, a HUD mini-game, a menu.

Examples: `examples/scenes/*.lua`, `examples/apps/flappy.lua` and `examples/apps/flappy_phone.lua` (the same game inside a
phone frame with the world visible around it; shipped inside the mod at `mod/Contents/mods/ZomboidMCP/examples/`, the repo root `examples/` is a symlink to it), served by `scene_template {name}`. Tools:
`scene_start`, `scene_stop`, `scene_list`, `scene_logs`, `scene_signal`, `scene_template`, `app_start`, `app_stop`,
`app_list` (docs/TOOLS.md). Client commands: docs/PROTOCOL.md part 2, "Scenes and apps".

## How a scene runs

- The chunk is compiled with `loadstring` and run in its **own environment** (`setfenv`): the SDK functions below are
  globals of that environment, everything else falls through to the engine and to `ZMCP`. Globals the scene sets
  stay inside the scene (`GHOST = spriteActor{...}` does not leak).
- The main chunk is the **main task**. `every`, `trigger`, `onPlayerNear`, `ambient`, `spawn`, `parallel`, `race`,
  `actor:follow` create **child tasks** (more coroutines of the same scene). The bridge tick (about 10 Hz while players
  are online) resumes every task whose wait is over, with a shared budget of **8 ms per tick for all scenes**. A task
  that does not yield blocks the whole server: never `while true do end` without a `wait`.
- **Lifecycle.** `running` while any task is alive or a listener is registered (`onDeath`, `onClick`, `onKey`,
  `onSignal`, an open `ask`); `done` when the last task returns and nothing listens; `stopped` after `scene_stop`,
  `stop()` or a replacement with the same name; `error` when the main task throws. A child task that throws is logged
  (scene_logs, event `scene_error` with `fatal=false`) and only that task dies.
- **Errors** never reach the bridge tick. A compile error or an error in the first statements comes back from
  `scene_start` (`status = "error"`, `error = ...`); later ones are in `scene_logs {name}` and `events_poll`.
- **Cleanup** on any end: zombie puppets are removed, world sprites and their animations, bubbles, dialogs, lights and
  click/key watchers are removed on every client, event handlers are unregistered, `onStop(fn)` callbacks run. What a
  scene changed in the **world** (items, tiles, weather) stays: that is the point of `snapshotArea` / `restoreArea`.
- **Persistence.** `persistent = true` writes the code to `zmcp_scene_<name>.lua.txt` in the Lua dir and records the
  scene in ModData; `Api/Scenes.lua` restarts it on every load (server start, `reloadlua`, `tools/pz load`).
  `state` is a table saved in ModData that survives restarts and re-starts of the same name; put counters, timestamps
  and "already built" flags there, never code or big data. `scene_stop` forgets the scene but keeps `state`
  (`clear_state = true` wipes it). The restarted scene runs from the top again: write it idempotently
  (`if not state.built then ... end`) and wait for players before touching squares (nothing is loaded on an empty
  server).
- **Time** is real seconds (`now()`), not game time.

## SDK reference

### Time and tasks

| function | what |
|---|---|
| `wait(sec)` | sleep this task for `sec` real seconds (yields). |
| `waitUntil(fn, timeout?)` | wait until `fn()` returns a truthy value; returns `true, value`, or `false, "timeout"` after `timeout` seconds. `fn` runs in the scheduler, it must not `wait`. |
| `tick()` | yield until the next bridge tick. |
| `now()` | unix seconds (float). |
| `spawn(fn, ...)` | run `fn(...)` as a child task now; returns a handle `{stop(), done(), result()}`. |
| `parallel(f1, f2, ...)` | run the functions as child tasks and wait for all; returns a list of their results. |
| `race(f1, f2, ...)` | run them, return `index, result` of the first to finish, stop the rest. |
| `every(sec, fn, opts?)` | call `fn(n)` every `sec` seconds in its own task until `fn` returns `false`, `opts.times` runs are done or the handle is stopped. `opts.near = {x, y, r}` **pauses** the loop while no player is within `r` tiles (idle ambience costs nothing). |
| `ambient(x, y, r, sec, fn)` | shorthand for `every(sec, fn, {near = {x, y, r}})`. |
| `trigger(label, condFn, fn, opts?)` | every `opts.interval` (0.5 s) evaluate `condFn()`; when truthy, run `fn(value, count)` as a task and wait for it. Re-arms when the condition turns false; `opts.cooldown` seconds between runs, `opts.once` ends after the first run, `opts.wait = false` does not wait for `fn`. Returns a handle. |
| `onPlayerNear(x, y, r, fn, opts?)` | `trigger` whose condition is "a player within `r` tiles of x,y" (`opts.z` limits the floor); `fn(player, count)`. |
| `onDeath(fn)` | `fn(player)` when a player dies (server events `OnPlayerDeath` / `OnCharacterDeath`, de-duplicated). |
| `onZombieDead(fn)` | `fn(zombie)` on `OnZombieDead`. |
| `onEvent(name, fn)` | any `Events.<name>`; removed with the scene. Returns `{stop()}`. |
| `onClick(spriteId, fn)` | `fn(player, screenX, screenY)` when a player clicks that world sprite (client-forwarded). |
| `onKey(code, fn)` | `fn(player, code)` when a player presses that LWJGL key (client-forwarded; the game's own binding fires too, prefer unused keys). |
| `ask(player, text, options, timeout?)` | dialog with buttons on that player's screen; returns the chosen option string, or `nil` on timeout. Number keys 1..n work too. |
| `onSignal(name, fn)` / `waitSignal(name, timeout?)` | react to `scene_signal {name, signal, data}` from the MCP (or `signal(otherScene, name, data)` from another scene): `fn(data)` runs as a task; `waitSignal` returns `data`. Screen apps reach a scene as signal `"app:<appName>"` with `{user, score}` or `{user, data}`. |
| `stop(reason?)` | end this scene now (cleanup runs). |
| `onStop(fn)` | `fn(reason)` runs when the scene ends for any reason (`"scene_stop"`, `"replaced"`, `"done"`, `"error"`, your `stop()` reason). |
| `log(...)` | one log line (scene_logs, server console). Tables are JSON-encoded. |
| `event(kind, data)` | writes `scene:<kind>` to the event log (events_poll). |
| `state`, `args`, `scene` | saved state table, the `args` object from `scene_start`, `{name, started, persistent}`. |

### Players and positions

| function | what |
|---|---|
| `players()` | online `IsoPlayer`s (Java objects: `p:getX()`, `p:getUsername()`, `p:getInventory()` ...). |
| `player(name?)` | one player by account or character name (the only one online when omitted). |
| `nearestPlayer(x, y)` | `player, distance`. |
| `playersNear(x, y, r, z?)` | list of players within `r` tiles. |
| `pos(obj)` | `x, y, z` of a player, zombie or actor. `name(p)` the account name. |
| `dist(x1, y1, x2, y2)`, `distTo(obj, x, y)` | distances in tiles. |
| `loaded(x, y, z)` | is that square loaded (somebody near)? Wait for it before spawning or building there. |
| `square(x, y, z)` | the `IsoGridSquare` or an error. |
| `random()`, `random(n)`, `random(a, b)` | float 0..1, integer 1..n, float a..b. |

### World (server-authoritative, everyone sees it)

These forward to the curated tools with validated arguments; errors carry the tool's message.

| function | what |
|---|---|
| `spawnItem(type, x, y, z, count?)` | items on the ground (`spawn_item`). |
| `giveItem(player, type, count?)` | into a player's inventory (`give_item`). |
| `dropItemsFromSky(type, count, x?, y?, opts?)` | falling items that become real items (`falling_items`; `opts.radius/duration/fall/spawn/scale/player`). |
| `placeTile(sprite, x, y, z, name?)` / `removeTile(sprite, x, y, z, all?)` / `build(objects)` | tile objects (`place_object`, `remove_object`, `build_structure`). Tiles are saved with the world. |
| `snapshotArea(x1, y1, x2, y2, z)` | records every tile object of the (loaded, at most 900 squares) area to `zmcp_snap_<scene>_<n>.json`; returns the id. Keep it in `state`. |
| `restoreArea(id)` | removes objects that were not in the snapshot and re-adds missing ones (floors are never removed, ground items ignored); returns `{removed, added, skipped}`. |
| `weather(kind, intensity?)` | `rain`, `storm`, `clear` (`set_weather`). `time(hour, day?, month?, year?)` (`set_time`). |
| `lightning(x, y, opts?)` | `transmitServerTriggerLightning`; `opts.strike/light/rumble` default true. |
| `sound(name, x, y, z?)` | a vanilla sound at a square for everyone in range (`playServerSound`). `sound(name, nil, nil, nil, player?)` plays a UI sound on the clients through the mod. Names: `Thunder`, `ZombieThumpGeneric`, `HouseAlarm`, `LightSwitch`, `WoodDoorOpen`, `WoodDoorClose`, `ZombieSurprisedPlayer`, `UIActivateButton`, `Helicopter` (`media/scripts/**/sounds*.txt` has all). |
| `message(text, mode?, player?, opts?)` | `server_message`: `notify` (box), `halo`, `chat`, `say`. `say(player, text)` is a speech bubble on that player. |
| `zombies(x, y, z, count?, outfit?)` / `killZombies(x, y, z, r?)` / `zombiesNear(x, y, z, r)` | `spawn_zombies`, `kill_zombies_area`, live `IsoZombie` list. |
| `light(x, y, z, r, g, b, radius)` | a light on every client (`IsoCell:addLamppost`). Returns `{id, remove()}`. Lights are render state: **the engine does not save them** (verified in 42.21: `IsoCell.lamppostPositions` is only touched by add/remove/update/dispose, no save/load path), which is why a persistent scene re-creates them on every start and the scene re-sends them to every client that joins. `scene_stop` removes them. |
| `texture(id)` / `texture(id, def)` | returns the id of an uploaded texture (`texture_upload`), erroring early when missing; with `def = {palette, rows}` registers pixel art (`texture_pixel`) so a scene can ship its own sprites without a PNG. `"item:Base.X"` and vanilla texture names pass through. |
| `sprite(args)` / `draw(args)` / `clearDraw(id)` | raw `world_sprite` (owned by the scene) and `overlay_draw`. Prefer `spriteActor`. |
| `tool(name, args)` | call any registered tool (also `entity3d_*` from ZOM-11 when present: check `ZMCP.tools.entity3d_spawn` first). |

### Actors: zombie puppets

`spawnActor{kind = "zombie", x, y, z?, outfit?, name?, passive = true, female?, walk?}` spawns one zombie with
`addZombiesInOutfit` on a loaded square. `passive` (default) calls `setUseless(true)`: it does not attack or chase.
The `IsoZombie` is `actor.zombie` for anything the SDK lacks.

| method | what |
|---|---|
| `actor:walkTo(x, y, opts?)` | `pathToLocation` and wait until within `opts.dist` (1 tile) or `opts.timeout` seconds (default 5 + 2 per tile); re-paths every 3 s. Returns `true`, or `false, "timeout"|"dead"`. Awaitable. |
| `actor:say(text, ttl?)` | the engine speech line (`Say`) plus a client bubble that follows the zombie in multiplayer. |
| `actor:face(x, y)` | `faceLocationF`. |
| `actor:follow(player, keepDistance?)` | keeps pathing after the player in its own task; `actor:stop()` ends it. |
| `actor:onNear(r, fn, opts?)` | trigger with cooldown: `fn(player, count)` when a player is within `r` tiles of the actor. |
| `actor:walk(type)` | `setWalkType` (vanilla walk type names; unverified in 42.21, wrapped in pcall). |
| `actor:passive(on)` | toggle `setUseless`. |
| `actor.pos()` / `actor.alive()` | position, not dead. |
| `actor:remove()` | `removeFromWorld` + `removeFromSquare` (falls back to `Kill`). Done automatically at scene end. |

Puppets are real zombies: players can kill them (`alive()` turns false, `walkTo` returns `false, "dead"`), they are
saved with the world if the server saves while the scene runs (re-start cleans up only what the scene knows, so a
persistent scene should spawn its puppets on demand and remove them when the visit ends, as the examples do).

### Sprite actors

`spriteActor{texture | frames, x, y, z?, scale? | tiles?, fps?, flip?, anchor?, opacity?, bob?, bobHz?, fade?}`
creates a world sprite owned by the scene (bottom-centre at the tile, scaled with zoom, always on top).

| method | what |
|---|---|
| `s:moveTo(x, y, opts?)` | straight line at `opts.speed` tiles/s or over `opts.duration` seconds (default 2 tiles/s); the client tweens it, the server waits and pins the sprite at the target. Awaitable. |
| `s:playAnim(frames, fps?)` / `s:stopAnim()` | cycle texture ids as frames (one uploaded/pixel texture per frame). |
| `s:fade(opacity, dur)` | tween the opacity on the clients and wait. |
| `s:bubble(text, ttl?)` | speech bubble above the sprite (follows it). |
| `s:onClick(fn)` | `fn(player, sx, sy)` when clicked. |
| `s:set{...}` | change any sprite argument (`scale`, `flip`, `x`, `y`, ...) and re-send. |
| `s.pos()`, `s.id`, `s:remove()` | position, the world_sprite id, removal (automatic at scene end). |

Frames are separate textures (upload `walk_1.png`, `walk_2.png` ... once; late joiners receive them). Sub-rect
sprite sheets are not supported yet.

### Tweens

`tween(from, to, dur, fn, easing?)` calls `fn(value, t)` every tick for `dur` seconds (awaitable; `easing` is a name
or a function). `ease.linear|inQuad|outQuad|inOutQuad|inCubic|outCubic|inOutCubic|outBounce|outElastic|sine`,
`lerp(a, b, t)`.

## Writing a scene

1. **Start from a template.** `scene_template {name = "merchant"}` returns a complete, tested scene; change the
   parameters through `args` first, then the script.
2. **Wait for the world.** `waitUntil(function() return #players() > 0 end)` and `waitUntil(function() return
   loaded(x, y, z) end)` before spawning or building. Only the area around online players exists.
3. **Structure.** Set up once at the top (idempotent when persistent: `if not state.built then ... end`), then
   register triggers/ambience and let the main chunk return. The scene stays alive through its tasks and listeners.
   One-shot sequences (a supply drop) just run top to bottom and end.
4. **Budget.** Everything that repeats goes through `every`/`ambient`/`trigger` with sensible periods (0.5 s and up).
   Use `near`/`ambient` so idle installations cost nothing when nobody is there. `scene_list` shows `stats.ms` and
   `overBudget`.
5. **Errors.** `pcall` engine calls you are not sure about (`local ok, r = pcall(spawnActor, {...})`), but never
   `pcall` around `wait` (a yield inside `pcall` is not portable). Check `scene_logs` after starting.
6. **Cleanup and etiquette on a live server.** Players see everything immediately. Announce with `message`, keep
   puppets passive, keep sounds sparse, remove what you add (`onStop`, `restoreArea`), and stop test scenes when
   done (`scene_stop`). Hordes, killing, teleporting, changing a character: only when asked. Test in single player
   first when you can (`dev/bundle_sp.sh`).
7. **Persistent installations** (the endgame scene): `persistent = true`, snapshot the area on first run into
   `state`, build once, re-create lights every start, drive the cutscene with `trigger`/`onPlayerNear` + `cooldown`,
   restore in `onStop` only for `reason == "scene_stop"`. See `examples/scenes/haunted_house.lua`.
8. **Steer it live.** `scene_signal {name, signal, data}` + `onSignal`/`waitSignal` let you advance acts or change
   parameters without restarting; `scene_start` with the same name replaces the scene and keeps `state`.

## Screen apps

`app_start {name, code, player?, focus?}` pushes a chunk to every client (or one). The chunk runs in its own
environment on the client and defines:

```lua
focus = true                          -- optional: capture mouse + keys, block player movement (Esc always exits)
function update(dt) end               -- every game tick (frame), dt in seconds (capped at 0.25)
function draw(ui) end                 -- every frame on the overlay ISUIElement
function onKey(key, down) end         -- LWJGL codes: app.keys.SPACE, .UP, .W ...; down = true on press
function onMouse(x, y, button, down) end   -- 0 left, 1 right (screen pixels)
function onExit(reason) end           -- "esc" | "appStop" | "exit" | "restart" | "error"
```

or returns `{update = ..., draw = ..., focus = true}`. The `app` table: `app.size()` (screen w, h), `app.now()`,
`app.score(n)` (event `app_score` on the server, shown in `app_list`), `app.exit()`, `app.send(data)` (event
`app_message`; a scene receives it as signal `"app:<name>"`), `app.sound(name)` (UI sound), `app.keyDown(code)`,
`app.mouse()` (x, y, left, right), `app.log(msg)`, drawing helpers `app.rect(ui, x, y, w, h, r, g, b, a)`,
`app.border(...)`, `app.line(ui, x1, y1, x2, y2, r, g, b, a)`, `app.text(ui, text, x, y, r, g, b, a, font, centre)`
(`small|medium|large|title`), `app.textWidth(text, font)`, `app.texture(ui, ref, x, y, w, h, alpha?, flip?)` (an
uploaded/pixel texture id, `item:Base.X` or a vanilla name), and `app.state` (a scratch table).

Rules: a callback that throws stops the app and reports it (`app_result` event with the error). Keys the game binds
still reach the game (Esc also opens the pause menu in single player, pick keys the game does not use). Movement is
blocked with `IsoPlayer:setBlockMovement(true)` while a focused app runs and released on exit. Multiplayer: an app runs
for one player or for all; shared state is optional through `app.send` + a scene's `onSignal("app:<name>")` +
`scene_signal`/`server_message` back, or simply through `run_lua_client`. `examples/apps/flappy.lua` is the reference;
`examples/apps/flappy_phone.lua` draws the same game inside a phone frame (bezel, speaker slit) centred on the screen,
clipping the game to the phone's screen by hand, so the world stays visible around it (the showcase capture).

## Offline testing

`tests/sim/test_scenes.py` runs the whole SDK under Lua 5.1 with the mocked engine (`tests/sim/sim_prelude.lua`):
puppets that walk one tile per tick, tiles, lights, climate, sounds, the client modules and the screen apps, and it
starts every example. Use it to check a new scene before touching a live game: paste it into the test or call
`scene_start` through the harness.
