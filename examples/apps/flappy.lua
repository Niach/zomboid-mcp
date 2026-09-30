-- Flappy: a complete flappy-bird screen app drawn from shapes. Space / Up / left click to flap, Esc to quit.
-- Start: app_start {name = "flappy", code = <this file>}   (the chunk sets focus = true itself)
-- The score is reported to the server with app.score(n) when a run ends (app_score event; app_list shows it).
focus = true

local W, H = app.size()
local GROUND = H - 80
local GRAVITY, FLAP, SPEED = 1400, -420, 220
local GAP, PIPE_W, PIPE_EVERY = 170, 70, 1.6
local bird, pipes, score, best, alive, started, sinceLastPipe, reported
local flapAnim = 0

local function reset()
    bird = { x = W * 0.3, y = H * 0.45, vy = 0, r = 16 }
    pipes = {}
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
    local top = 60 + math.random() * (GROUND - GAP - 120)
    pipes[#pipes + 1] = { x = W + PIPE_W, top = top, passed = false }
end

function update(dt)
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
        -- collision: bird circle vs the two pipe rectangles
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

function draw(ui)
    -- sky, ground
    app.rect(ui, 0, 0, W, H, 0.35, 0.65, 0.95, 1)
    app.rect(ui, 0, GROUND, W, H - GROUND, 0.75, 0.6, 0.3, 1)
    app.rect(ui, 0, GROUND, W, 6, 0.4, 0.75, 0.3, 1)
    -- pipes
    for _, p in ipairs(pipes) do
        app.rect(ui, p.x, 0, PIPE_W, p.top, 0.2, 0.7, 0.2, 1)
        app.rect(ui, p.x - 4, p.top - 24, PIPE_W + 8, 24, 0.15, 0.6, 0.15, 1)
        app.rect(ui, p.x, p.top + GAP, PIPE_W, GROUND - p.top - GAP, 0.2, 0.7, 0.2, 1)
        app.rect(ui, p.x - 4, p.top + GAP, PIPE_W + 8, 24, 0.15, 0.6, 0.15, 1)
    end
    -- bird: body, wing, eye, beak
    local r = bird.r
    app.rect(ui, bird.x - r, bird.y - r, 2 * r, 2 * r, 1, 0.85, 0.2, 1)
    app.rect(ui, bird.x - r, bird.y + (flapAnim > 0 and -6 or 2), r, 8, 0.95, 0.65, 0.1, 1)
    app.rect(ui, bird.x + 4, bird.y - 10, 7, 7, 1, 1, 1, 1)
    app.rect(ui, bird.x + 7, bird.y - 8, 3, 3, 0, 0, 0, 1)
    app.rect(ui, bird.x + r, bird.y - 2, 10, 6, 1, 0.45, 0.1, 1)
    -- score and prompts
    app.text(ui, tostring(score), W / 2, 30, 1, 1, 1, 1, "title", true)
    if not started then
        app.text(ui, "Space / click to flap. Esc to quit.", W / 2, H * 0.6, 1, 1, 1, 1, "large", true)
    elseif not alive then
        app.text(ui, "Splat! Score " .. score .. "  (best " .. best .. ")", W / 2, H * 0.4, 1, 0.9, 0.3, 1, "large", true)
        app.text(ui, "Space to try again, Esc to quit", W / 2, H * 0.4 + 40, 1, 1, 1, 1, "medium", true)
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
