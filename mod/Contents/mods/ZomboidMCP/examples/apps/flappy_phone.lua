-- Flappy phone: the flappy bird from flappy.lua inside a phone frame in the middle of the screen (the showcase
-- capture). The world stays visible around the phone; the game only uses the portrait area inside the bezel.
-- Space / Up / left click to flap, Esc to quit. Score reported with app.score(n) when a run ends.
-- Start: app_start {name = "flappy_phone", code = <this file>}   (the chunk sets focus = true itself)
focus = true

local SW, SH = app.size()
-- the phone: a portrait bezel about 45% of the screen height wide, centred; the screen inside it is the play area
local PH = math.floor(SH * 0.92)
local PW = math.floor(PH * 0.5)
local PX, PY = math.floor((SW - PW) / 2), math.floor((SH - PH) / 2)
local BEZEL, TOP = 12, 44                           -- side bezel and the top bar with the speaker slit
local X0, Y0 = PX + BEZEL, PY + TOP                 -- top-left of the screen inside the phone
local W, H = PW - 2 * BEZEL, PH - TOP - BEZEL
local GROUND = H - 70
local GRAVITY, FLAP, SPEED = 1200, -380, 190
local GAP, PIPE_W, PIPE_EVERY = 150, 60, 1.7
local bird, pipes, clouds, score, best, alive, started, sinceLastPipe, reported
local flapAnim = 0

local function reset()
    bird = { x = W * 0.3, y = H * 0.45, vy = 0, r = 14 }
    pipes, clouds = {}, {}
    for i = 1, 3 do clouds[i] = { x = W * i / 3, y = 40 + ZombRandFloat(0, 1) * (H * 0.4), w = 50 + ZombRandFloat(0, 1) * 40 } end
    score, alive, started, sinceLastPipe, reported = 0, true, false, PIPE_EVERY, false
end
reset()
best = 0

local function flap()
    if not alive then reset() return end
    started = true
    bird.vy = FLAP
    flapAnim = 0.15
end

local function addPipe()
    local top = 50 + ZombRandFloat(0, 1) * (GROUND - GAP - 100)
    pipes[#pipes + 1] = { x = W + PIPE_W, top = top, passed = false }
end

function update(dt)
    for _, c in ipairs(clouds) do
        c.x = c.x - 12 * dt
        if c.x + c.w < 0 then c.x = W + 10; c.y = 40 + ZombRandFloat(0, 1) * (H * 0.4) end
    end
    if not started or not alive then return end
    bird.vy = bird.vy + GRAVITY * dt
    bird.y = bird.y + bird.vy * dt
    flapAnim = math.max(0, flapAnim - dt)
    sinceLastPipe = sinceLastPipe + dt
    if sinceLastPipe >= PIPE_EVERY then sinceLastPipe = 0 addPipe() end
    local keep = {}
    for _, p in ipairs(pipes) do
        p.x = p.x - SPEED * dt
        if p.x + PIPE_W > 0 then keep[#keep + 1] = p end
        if not p.passed and p.x + PIPE_W < bird.x then p.passed = true score = score + 1 app.sound("UIActivateButton") end
        local inX = bird.x + bird.r > p.x and bird.x - bird.r < p.x + PIPE_W
        if inX and (bird.y - bird.r < p.top or bird.y + bird.r > p.top + GAP) then alive = false end
    end
    pipes = keep
    if bird.y + bird.r > GROUND or bird.y - bird.r < 0 then alive = false end
    if not alive and not reported then
        reported = true
        best = math.max(best, score)
        app.score(score)
        app.sound("ZombieThumpGeneric")
    end
end

-- everything inside the phone screen is drawn with these (clipped by hand to the screen area)
local function rect(ui, x, y, w, h, r, g, b, a)
    if x < 0 then w = w + x; x = 0 end
    if y < 0 then h = h + y; y = 0 end
    if x + w > W then w = W - x end
    if y + h > H then h = H - y end
    if w <= 0 or h <= 0 then return end
    app.rect(ui, X0 + x, Y0 + y, w, h, r, g, b, a)
end
local function text(ui, s, x, y, r, g, b, a, font, centre) app.text(ui, s, X0 + x, Y0 + y, r, g, b, a, font, centre) end

function draw(ui)
    -- the phone: body, screen bezel, speaker slit, home bar
    app.rect(ui, PX - 3, PY - 3, PW + 6, PH + 6, 0.05, 0.05, 0.07, 1)
    app.rect(ui, PX, PY, PW, PH, 0.16, 0.17, 0.2, 1)
    app.rect(ui, PX + PW * 0.3, PY + 14, PW * 0.4, 16, 0.1, 0.1, 0.12, 1)
    app.rect(ui, PX + PW * 0.42, PY + 20, PW * 0.16, 4, 0.35, 0.35, 0.4, 1)
    -- sky, clouds, ground
    rect(ui, 0, 0, W, H, 0.35, 0.65, 0.95, 1)
    for _, c in ipairs(clouds) do
        rect(ui, c.x, c.y, c.w, 18, 1, 1, 1, 1)
        rect(ui, c.x + c.w * 0.25, c.y - 10, c.w * 0.5, 12, 1, 1, 1, 1)
    end
    rect(ui, 0, GROUND, W, H - GROUND, 0.75, 0.6, 0.3, 1)
    rect(ui, 0, GROUND, W, 6, 0.4, 0.75, 0.3, 1)
    -- pipes
    for _, p in ipairs(pipes) do
        rect(ui, p.x, 0, PIPE_W, p.top, 0.2, 0.7, 0.2, 1)
        rect(ui, p.x - 4, p.top - 20, PIPE_W + 8, 20, 0.15, 0.6, 0.15, 1)
        rect(ui, p.x, p.top + GAP, PIPE_W, GROUND - p.top - GAP, 0.2, 0.7, 0.2, 1)
        rect(ui, p.x - 4, p.top + GAP, PIPE_W + 8, 20, 0.15, 0.6, 0.15, 1)
    end
    -- bird: body, wing, eye, beak
    local r = bird.r
    rect(ui, bird.x - r, bird.y - r, 2 * r, 2 * r, 0.95, 0.55, 0.35, 1)
    rect(ui, bird.x - r, bird.y + (flapAnim > 0 and -6 or 2), r, 7, 0.85, 0.4, 0.25, 1)
    rect(ui, bird.x + 3, bird.y - 9, 7, 7, 1, 1, 1, 1)
    rect(ui, bird.x + 6, bird.y - 7, 3, 3, 0, 0, 0, 1)
    rect(ui, bird.x + r, bird.y - 2, 9, 5, 1, 0.8, 0.1, 1)
    -- score and prompts
    text(ui, tostring(score), W / 2, 24, 1, 1, 1, 1, "title", true)
    text(ui, "best " .. best, W / 2, 62, 1, 1, 1, 0.9, "medium", true)
    if not started then
        text(ui, "Space / click to flap", W / 2, H * 0.6, 1, 1, 1, 1, "medium", true)
        text(ui, "Esc to put the phone away", W / 2, H * 0.6 + 26, 1, 1, 1, 0.8, "small", true)
    elseif not alive then
        text(ui, "Splat! Score " .. score, W / 2, H * 0.4, 1, 0.9, 0.3, 1, "large", true)
        text(ui, "Space to try again", W / 2, H * 0.4 + 36, 1, 1, 1, 1, "medium", true)
    end
end

function onKey(key, down)
    if down and (key == app.keys.SPACE or key == app.keys.UP or key == app.keys.W) then flap() end
end

function onMouse(x, y, button, down)
    if down and button == 0 then flap() end
end

function onExit(reason)
    if started and not reported then app.score(score) end
end
