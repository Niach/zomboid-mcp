-- Meteor shower: glowing rocks streak in from the sky around the players, flash and rumble on impact, and leave a
-- hot stone (a real item) behind. Some carry loot.
-- Start: scene_start {name = "meteors", code = <this file>, args = {count, spread, loot, chance, pause}}
-- Args (optional): count = meteors (default 10); spread = tiles around each player (default 10); loot = item type
--   found in some craters (default "Base.Sledgehammer"); chance = loot probability 0..1 (default 0.3);
--   pause = seconds between meteors (default 0.6 to 1.8, random).
local cfg = args or {}
local count = cfg.count or 10
local spread = cfg.spread or 10
local loot, chance = cfg.loot or "Base.Sledgehammer", cfg.chance or 0.3

waitUntil(function() return #players() > 0 end)

local rock = texture("meteor_px", {
    palette = { o = { 255, 140, 30, 255 }, y = { 255, 230, 90, 255 }, d = { 90, 40, 20, 255 } },
    rows = { "..oo..", ".oyyo.", "oyddyo", "oyddyo", ".oyyo.", "..oo.." },
})

message("Look up. Something is falling.", "notify")
weather("storm", 0.3)

local impacts = 0
local function meteor(i)
    local p = players()[random(#players())]
    local tx, ty, tz = math.floor(p:getX() + random(-spread, spread)), math.floor(p:getY() + random(-spread, spread)), math.floor(p:getZ())
    if not loaded(tx, ty, tz) then return end
    -- the streak: from high up (north-west on screen) down to the impact tile in 1.2 s
    local m = spriteActor{ texture = rock, x = tx - 12, y = ty - 12, z = tz, scale = 5 }
    m:moveTo(tx, ty, { duration = 1.2 })
    lightning(tx, ty, { strike = false, light = true, rumble = true })
    sound("ZombieThumpGeneric", tx, ty, tz)
    m:fade(0, 0.3)
    m:remove()
    impacts = impacts + 1
    spawnItem("Base.Stone2", tx, ty, tz, 1)
    if random() < chance then
        spawnItem(loot, tx, ty, tz, 1)
        log("loot at", tx, ty)
    end
    -- a short glow in the crater
    local glow = light(tx, ty, tz, 1, 0.5, 0.1, 4)
    wait(6)
    glow.remove()
end

for i = 1, count do
    spawn(meteor, i)                      -- each meteor is its own task, so several can be in the air
    wait(cfg.pause or random(0.6, 1.8))
end
wait(8)
weather("clear")
message("The sky is quiet again. " .. impacts .. " impacts.", "notify")
log("done, impacts:", impacts)
