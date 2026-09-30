-- Supply drop: a plane sound, a parachute drifting down over a spot, then a real crate of items on the ground,
-- a flare light that marks it for a while and a message to everyone.
-- Start: scene_start {name = "supply_drop", code = <this file>, args = {x, y, z, items = {...}, duration, texture}}
-- Args (optional): x, y, z = landing tile (default: 6 tiles east of the nearest player); items = list of item types
--   in the crate (default: a survival kit); duration = seconds of descent (default 10); texture = an uploaded
--   texture id for the parachute (default: a built-in pixel-art parachute drawn with texture_pixel).
local cfg = args or {}
local items = cfg.items or { "Base.FirstAidKit", "Base.TinnedBeans", "Base.CannedChili", "Base.Bandage", "Base.Bullets9mm", "Base.Hammer", "Base.Nails" }
local duration = cfg.duration or 10

waitUntil(function() return #players() > 0 end)
local x, y, z = cfg.x, cfg.y, cfg.z or 0
if not x then
    local p = players()[1]
    x, y, z = math.floor(p:getX()) + 6, math.floor(p:getY()), math.floor(p:getZ())
end
waitUntil(function() return loaded(x, y, z) end, 30)

-- the parachute: an uploaded texture, or 12x14 pixel art registered on the fly (works without any PNG)
local tex = cfg.texture or texture("parachute_px", {
    palette = { c = { 230, 60, 60, 255 }, w = { 240, 240, 240, 255 }, s = { 60, 60, 60, 255 }, b = { 120, 80, 40, 255 } },
    rows = {
        "...cwcwcwc...",
        "..cwcwcwcwc..",
        ".cwcwcwcwcwc.",
        "cwcwcwcwcwcwc",
        "cwcwcwcwcwcwc",
        ".s.........s.",
        "..s.......s..",
        "...s.....s...",
        "....s...s....",
        ".....s.s.....",
        "....bbbbb....",
        "....bbbbb....",
        "....bbbbb....",
        ".............",
    },
})

message("Incoming supply drop!", "notify")
sound("Helicopter", x, y, z)

-- the drop starts high "in the sky": far to the north-west on screen (smaller x and y are further up) and drifts in
local chute = spriteActor{ texture = tex, x = x - 14, y = y - 14, z = z, tiles = 2.5, bob = 6, bobHz = 0.4 }
chute:bubble("Supplies", 3)
chute:moveTo(x, y, { duration = duration })

-- touchdown: the real crate (server items everyone can pick up), the chute collapses, a flare marks the spot
for _, item in ipairs(items) do spawnItem(item, x, y, z, 1) end
log("crate landed at", x, y, "with", #items, "items")
sound("ZombieThumpGeneric", x, y, z)
local flare = light(x, y, z, 1, 0.25, 0.1, 7)
message("A crate landed at " .. x .. ", " .. y .. ".", "chat")
chute:fade(0, 1.5)
chute:remove()

-- a pulsing marker above the crate until somebody comes to collect it (or 3 minutes pass)
local marker = spriteActor{ texture = "item:" .. items[1], x = x, y = y, z = z, scale = 1.5, bob = 10, bobHz = 0.8 }
local collected = waitUntil(function() return #playersNear(x, y, 2) > 0 end, 180)
marker:remove()
flare.remove()
log(collected and "collected" or "unclaimed")
