# Guide: scenes and screen apps (how Claude writes them)

Part of the "zomboid engine handbook" skill. Full SDK reference: `docs/SCENES.md`. Tools: `scene_start`,
`scene_stop`, `scene_list`, `scene_logs`, `scene_signal`, `scene_template`, `app_start`, `app_stop`, `app_list`.
Every snippet below is exercised by `tests/sim/test_scenes.py` or is one of the shipped examples.

## When to write a scene instead of a script

- Anything with **timing** (wait, then do the next thing), **motion you await** (a puppet walks over, a sprite drifts
  in), **reactions to players** (someone enters an area, answers a question, dies), or that must **clean itself up**.
- A plain `run_lua_server` chunk cannot wait; a `script_install` script must wire its own tick handlers and cleanup.
  A scene gives you `wait`, tasks, triggers, tracked actors/sprites/lights and `scene_stop`.
- A **screen app** when the player should see and control something on their screen (a game, a menu, a HUD).

## Workflow

1. `status` / `players_list`: who is online, where. Nothing outside the loaded area around players exists.
2. `scene_template {name}` for the closest example (`merchant`, `supply_drop`, `meteor_shower`, `haunted_house`,
   `companion`, `flappy`). Adapt `args` before code.
3. `scene_start {name, code, args}`. Read the result: `status = "error"` means the first statements failed.
4. `scene_logs {name}` after a few seconds, and `events_poll` for `scene_error`. Fix, `scene_start` again with the
   same name (replaces, keeps `state`).
5. When done or on request: `scene_stop {name}`. Check `scene_list` shows nothing left running.

## The skeleton

```lua
-- one-shot sequence: runs top to bottom and ends
waitUntil(function() return #players() > 0 end)
local p = players()[1]
local x, y, z = math.floor(p:getX()) + 5, math.floor(p:getY()), math.floor(p:getZ())
waitUntil(function() return loaded(x, y, z) end)
message("Something is coming...", "notify")
wait(2)
local guy = spawnActor{ kind = "zombie", outfit = "Bandit", x = x, y = y, z = z, name = "Guy", passive = true }
guy:say("Hey.")
if guy:walkTo(p:getX(), p:getY(), { dist = 1.5, timeout = 20 }) then
    local a = ask(p, "Trade a Banana for an Axe?", { "Deal", "No" }, 30)
    if a == "Deal" then giveItem(p, "Base.Axe", 1) end
end
wait(2)
guy:remove()
```

```lua
-- installation: sets up, registers triggers, main returns; stays alive through tasks and listeners
local x, y, z = args.x, args.y, args.z or 0
state.visits = state.visits or 0
local lamp = light(x, y, z, 1, 0.8, 0.5, 6)                 -- re-created on every start (never saved by the engine)
onPlayerNear(x, y, 6, function(player, n)
    state.visits = state.visits + 1
    say(player, "Welcome back, visit #" .. state.visits)
    wait(1)
    sound("LightSwitch", x, y, z)
end, { cooldown = 30 })
ambient(x, y, 20, 15, function() sound("WoodDoorOpen", x + 1, y, z) end)   -- silent when nobody is within 20 tiles
onStop(function(reason) log("closing:", reason) end)
```

## Patterns that work

- **Wait for the world.** `waitUntil(players)` and `waitUntil(loaded(...))` before spawning or building. Persistent
  scenes start on an empty server; they must not assume anyone is online.
- **Idempotent setup** for persistent scenes: `if not state.built then placeTile(...) state.built = true end`.
  `state` is saved in ModData; keep it tiny (numbers, flags, a snapshot id).
- **Snapshot before you build.** `state.snap = state.snap or snapshotArea(x1, y1, x2, y2, z)` first,
  `restoreArea(state.snap)` in `onStop` when `reason == "scene_stop"`.
- **Triggers re-run, cooldown protects.** `onPlayerNear(..., {cooldown = 90})`, `trigger(label, cond, fn, {once = true})`.
  A trigger waits for its `fn` to finish before checking again, so a cutscene never overlaps itself.
- **Parallel motion.** `parallel(function() a:walkTo(...) end, function() s:moveTo(...) end)` or `spawn(fn)` for
  fire-and-forget (each meteor in `meteor_shower.lua`). `race` for "whichever happens first".
- **Ship your own art**: `texture("ghost_px", { palette = { w = {235, 235, 255, 200} }, rows = { ".ww.", "wwww" } })`
  gives a texture id with no PNG; or upload PNGs once with `texture_upload` and `texture("id")` to assert they exist.
- **Speech**: `actor:say(text)` for puppets, `say(player, text)` for a player's bubble, `s:bubble(text)` for sprites,
  `message(text, "notify"|"chat"|"halo")` for everyone.
- **Steer live**: `onSignal("act2", function(data) ... end)` in the scene, `scene_signal {name, signal = "act2", data}`
  from you.
- **Engine access**: everything not in the SDK is one `try` away: `try(function() actor.zombie:setNoTeeth(true) end)`;
  a block of your own world-changing engine calls goes through `engine(function() ... end)` (it runs on the main
  coroutine; on the dedicated server the events those calls fire otherwise break the next `pcall` in the scene).
  `tool("entity3d_spawn", {...})` when ZOM-11's 3D entities are loaded (`ZMCP.tools.entity3d_spawn ~= nil`).

## Budget, safety, etiquette

- 8 ms per tick for all scenes together. Never loop without `wait`; check `scene_list` `stats.overBudget`.
- Big world edits (clearing / flooring thousands of squares) go in slices: one `engine(fn)` per ~200 squares, then
  `tick()`; only loaded squares exist, so count the missing ones and finish them on the next start (the YSNP arena).
- `try(fn, ...)` for calls that may fail; never a plain `pcall` around `wait` or around SDK world calls
  (`placeTile`, `spawnActor`, `tool(...)`, `sound`, ...): they yield to the main coroutine like `wait` does.
- Players see everything at once. Puppets stay `passive`, sounds are sparse, world changes are announced and undone
  (`onStop`, `restoreArea`). Hordes / killing / teleporting / touching a character only when asked. Stop test scenes.
- Single player first (`dev/bundle_sp.sh`, only with the owner's OK; `dev/ZMCPDev` is shared and a bad hook breaks
  the game every frame), offline before that: `python3 tests/sim/test_scenes.py`.

## Screen apps in one page

```lua
focus = true                                   -- capture input, block movement; Esc exits
local W, H = app.size()
local x, vy = W / 2, 0
function update(dt) vy = vy + 900 * dt end
function draw(ui)
    app.rect(ui, 0, 0, W, H, 0.1, 0.1, 0.15, 0.8)
    app.text(ui, "score " .. math.floor(vy), W / 2, 40, 1, 1, 1, 1, "title", true)
end
function onKey(key, down) if down and key == app.keys.SPACE then vy = -300 end end
function onMouse(mx, my, button, down) if down then x = mx end end
function onExit(reason) app.score(math.floor(vy)) end
```

`app_start {name = "demo", code = <that>}`; the client answers with an `app_result` event (ok or the error), scores
arrive as `app_score`, `app_list` summarizes. Draw with `app.rect/border/line/text/texture` or the `ui` element
directly (`ui:drawTextureScaled`). Keys are LWJGL codes (`app.keys`). The game's own keybinds still fire, so avoid
WASD-heavy controls unless focus is on (movement is blocked, keys still reach the game UI). `examples/apps/flappy.lua`
is a complete game.
