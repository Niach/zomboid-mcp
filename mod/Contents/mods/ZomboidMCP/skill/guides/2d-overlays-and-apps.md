# 2D overlays, HUDs and screen apps

Everything on screen is client-side: it runs on each player's client (`run_lua_client`, or `script_install
side=client` to persist), and only players with the mod see it. The mod owns one full-screen, click-through overlay
(`ZMCPOverlay`, an `ISUIElement` with `setConsumeMouseEvents(false)`, sent `backMost()` so it draws above the world and
below the vanilla UI). Your code draws on it through **render hooks** and reacts through **input hooks**.

## Quick shapes without code: `overlay_draw`

```json
[
  {"tool": "overlay_draw", "args": {"id": "banner", "kind": "text", "anchor": "screen", "x": 20, "y": 20, "text": "Bananas incoming", "font": "large", "r": 1, "g": 0.9, "b": 0.2, "ttl": 5}},
  {"tool": "overlay_draw", "args": {"id": "box", "kind": "rect", "anchor": "screen", "x": -220, "y": 20, "w": 200, "h": 60, "r": 0, "g": 0, "b": 0, "a": 0.6}},
  {"tool": "overlay_draw", "args": {"id": "marker", "kind": "rect", "anchor": "world", "x": 6403, "y": 5498, "z": 0, "w": 24, "h": 24, "r": 1, "g": 0, "b": 0, "fill": false, "thick": 2}},
  {"tool": "clear_visuals", "args": {"what": "overlays"}}
]
```

`anchor = screen` is pixels (negative from the right/bottom edge); `anchor = world` follows a tile through camera and
zoom (sizes are px at zoom 1). `ttl` removes it; reusing `id` replaces it. For anything animated or with many shapes,
write a render hook.

## The hook API (`ZMCPClient.on`)

```lua
-- client: the whole hook surface (register under one name so it can be removed as a unit)
ZMCPClient.on("demo", "render", function(ui) end)                  -- every frame; draw on ui
ZMCPClient.on("demo", "tick", function(now) end)                   -- every game tick, now = seconds (float)
ZMCPClient.on("demo", "keyDown", function(key) end)                -- OnKeyStartPressed; "keyUp" = release, "keyHeld" = held
ZMCPClient.on("demo", "mouseDown", function(x, y, button) end)     -- "mouseUp"(x, y, button), "mouseMove"(x, y, dx, dy), "mouseWheel"(delta)
ZMCPClient.capture(true)                                           -- overlay swallows the mouse and sits above the UI (screen apps)
ZMCPClient.capture(false)                                          -- click-through again, behind the UI
ZMCPClient.off("demo")                                             -- remove every hook named "demo"
local down = ZMCPClient.input.keyDown(57)                          -- polling: isKeyDown(code)
local mx, my, left, right = ZMCPClient.input.mouse()               -- getMouseX/Y, buttons
local sw, sh = ZMCPClient.screen()                                 -- screen size; ZMCPClient.zoom(), ZMCPClient.now(), ZMCPClient.player()
```

- A hook that throws is **removed after the first error** and logged once (`client_exec_result` shows script errors,
  the client log the hook error). Keep per-frame work small.
- Keyboard hooks fire whether or not the overlay captures the mouse; the game's own keybinds fire too, so prefer keys
  the game does not use, or capture and accept that WASD still moves the player. Key codes are LWJGL: Space 57, Escape 1,
  Enter 28, Up 200, Down 208, Left 203, Right 205, W 17, A 30, S 31, D 32, F1 59 (`Keyboard.KEY_*` on the client).
- Mouse hooks reach you through the overlay only while captured (`capture_input` tool or `ZMCPClient.capture(true)`);
  uncaptured, the global `OnMouseDown` events are forwarded (the game gets the click too).
- `clear_visuals {what = "hooks"}` removes every hook and releases capture; `script_remove side=client` drops the hooks
  registered under the script name.

## Drawing primitives (on the `ui` passed to render)

```lua
-- sim: client
-- client: every drawing call you need, in one HUD
ZMCPClient.off("hud")
ZMCPClient.on("hud", "render", function(ui)
    local sw, sh = ZMCPClient.screen()
    local p = getPlayer()
    ui:drawRect(20, sh - 80, 260, 60, 0.6, 0, 0, 0)                          -- (x, y, w, h, alpha, r, g, b)
    ui:drawRectBorder(20, sh - 80, 260, 60, 0.9, 1, 1, 1)                    -- outline
    local hp = p:getBodyDamage():getOverallBodyHealth() / 100
    ui:drawRect(30, sh - 40, 240 * hp, 12, 1, 1 - hp, hp, 0.2)               -- health bar
    ui:drawLine2(30, sh - 24, 270, sh - 24, 1, 1, 1, 1)                       -- (x1, y1, x2, y2, alpha, r, g, b)
    ui:drawText("HP " .. math.floor(hp * 100), 30, sh - 72, 1, 1, 1, 1, UIFont.Medium)   -- (text, x, y, r, g, b, alpha, font)
    ui:drawTextCentre(string.format("%.0f, %.0f", p:getX(), p:getY()), sw / 2, 10, 1, 1, 0.5, 1, UIFont.Small)
    local icon = ZMCPClient.tex.get("item:Base.Banana")
    if icon then ui:drawTextureScaled(icon.tex, 230, sh - 76, 32, 32, 1, 1, 1, 1) end   -- (tex, x, y, w, h, alpha, r, g, b)
end)
return "hud on"
```

Fonts: `UIFont.Small`, `Medium`, `Large`, `Title` (and more via `api_search "UIFont"`). Measure text with
`getTextManager():MeasureStringX(font, text)` and `getFontHeight(font)`. Colours are 0..1. A negative width in
`drawTextureScaled` mirrors the texture. World → screen: `isoToScreenX/Y(0, x, y, z)` (see `world-sprites.md`).

## Screen apps

A screen app is a client script that captures input, draws every frame and updates in `tick`. Pattern:

1. `ZMCPClient.off(NAME)` first (re-runnable), state in one local table with a `reset()`.
2. `ZMCPClient.capture(true)`; Escape always quits: `off(NAME)` + `capture(false)`.
3. `tick(now)`: compute `dt = now - last`, clamp it (`math.min(dt, 0.05)`), advance the simulation.
4. `render(ui)`: draw from state only.
5. Report scores to the server with `sendClientCommand(getPlayer(), "myapp", "score", {score = n})` (see
   `networking-and-sync.md`), install with `script_install {name, side = "client", code}` for one player (`run_lua_client
   {player}`) or everyone.

The scene SDK issue adds an `app_start` / `app_stop` wrapper with movement blocking and `examples/apps/flappy.lua`
(`scenes-and-apps.md`). Until then the raw hooks below are the whole API, and they keep working afterwards.

### Flappy Bird, complete

```lua
-- sim: client
-- Flappy Bird as a client script: Space or click flaps, Escape quits, Space restarts after a crash.
local NAME = "flappy"
local KEY_SPACE, KEY_ESC = 57, 1
local G = { gravity = 1400, flap = -420, speed = 220, gap = 170, pipeW = 70, pipeEvery = 1.6, bird = 14 }
local W, H = ZMCPClient.screen()
local S
local function reset()
    S = { y = H / 2, vy = 0, pipes = {}, t = 0, nextPipe = 1, score = 0, dead = false, last = ZMCPClient.now() }
end
reset()
ZMCPClient.off(NAME)
ZMCPClient.capture(true)
local function flap() if S.dead then reset() else S.vy = G.flap end end
ZMCPClient.on(NAME, "keyDown", function(key)
    if key == KEY_ESC then ZMCPClient.off(NAME); ZMCPClient.capture(false); return end
    if key == KEY_SPACE then flap() end
end)
ZMCPClient.on(NAME, "mouseDown", function() flap() end)
ZMCPClient.on(NAME, "tick", function(now)
    local dt = math.min(now - S.last, 0.05)
    S.last = now
    if S.dead then return end
    S.t = S.t + dt
    S.vy = S.vy + G.gravity * dt
    S.y = S.y + S.vy * dt
    if S.t >= S.nextPipe then
        S.nextPipe = S.t + G.pipeEvery
        S.pipes[#S.pipes + 1] = { x = W, gapY = 120 + math.random() * (H - 240), passed = false }
    end
    local bx, keep = W * 0.3, {}
    for _, p in ipairs(S.pipes) do
        p.x = p.x - G.speed * dt
        if p.x + G.pipeW > 0 then keep[#keep + 1] = p end
        if not p.passed and p.x + G.pipeW < bx then p.passed = true; S.score = S.score + 1 end
        local overlapX = bx + G.bird > p.x and bx - G.bird < p.x + G.pipeW
        local outsideGap = S.y - G.bird < p.gapY - G.gap / 2 or S.y + G.bird > p.gapY + G.gap / 2
        if overlapX and outsideGap then S.dead = true end
    end
    S.pipes = keep
    if S.y > H or S.y < 0 then S.dead = true end
end)
ZMCPClient.on(NAME, "render", function(ui)
    ui:drawRect(0, 0, W, H, 0.35, 0.3, 0.6, 0.9)
    for _, p in ipairs(S.pipes) do
        ui:drawRect(p.x, 0, G.pipeW, p.gapY - G.gap / 2, 1, 0.2, 0.7, 0.2)
        ui:drawRect(p.x, p.gapY + G.gap / 2, G.pipeW, H, 1, 0.2, 0.7, 0.2)
    end
    ui:drawRect(W * 0.3 - G.bird, S.y - G.bird, G.bird * 2, G.bird * 2, 1, 1, 0.85, 0.1)
    ui:drawTextCentre("Score " .. S.score, W / 2, 30, 1, 1, 1, 1, UIFont.Large)
    if S.dead then
        ui:drawTextCentre("Game over: Space to restart, Esc to quit", W / 2, H / 2, 1, 0.3, 0.3, 1, UIFont.Large)
    end
end)
return "flappy running"
```

Walkthrough: `status` → `players_list` → `script_install {name = "flappy", side = "client", code = <above>}` (or
`run_lua_client {player = "name", code = <above>}` for one player) → `events_poll {kinds = ["client_exec_result"]}`
shows `ok` per client → the player presses Escape, or you `script_remove {name = "flappy", side = "client"}` /
`clear_visuals {what = "hooks"}`. Swap the rectangles for uploaded textures with `ZMCPClient.tex.draw`.

## Windowed panels and vanilla UI

You can also build regular `ISPanel` / `ISButton` windows from client code (they persist until removed and get vanilla
mouse handling for free):

```lua
-- client: a small vanilla-style window with a button (client state, remove with MyWin.panel:removeFromUIManager())
MyWin = MyWin or {}
if MyWin.panel then MyWin.panel:removeFromUIManager() end
local panel = ISPanel:new(100, 100, 220, 90)
panel:initialise()
panel.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
local btn = ISButton:new(10, 50, 200, 25, "Close", panel, function() panel:removeFromUIManager() end)
btn:initialise()
panel:addChild(btn)
panel:addToUIManager()
MyWin.panel = panel
return "window shown"
```

`lua_examples "ISPanel:new"` and `lua_examples "ISButton:new"` show the vanilla shapes. Text input: `ISTextEntryBox`;
lists: `ISScrollingListBox`; modal dialogs: `ISModalDialog`.
