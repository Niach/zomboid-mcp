-- Companion: a passive zombie who follows the nearest player, keeps a polite distance, comments on the weather, the
-- time of day and nearby zombies, cheers when the player fights, and mourns when they die.
-- Start: scene_start {name = "companion", code = <this file>, args = {player, outfit, name, distance}}
-- Args (optional): player = account name to follow (default: whoever is nearest when the scene starts, re-picked when
--   they leave); outfit = zombie outfit (default "Police"); name = shown in bubbles (default "Dave");
--   distance = tiles to keep (default 2).
local cfg = args or {}
local who = cfg.name or "Dave"
local keep = cfg.distance or 2

waitUntil(function() return #players() > 0 end)
local function pickPlayer()
    if cfg.player then
        local ok, p = pcall(player, cfg.player)
        if ok then return p end
    end
    return players()[1]
end
local target = pickPlayer()
local sx, sy, sz = math.floor(target:getX()) + 2, math.floor(target:getY()), math.floor(target:getZ())
waitUntil(function() return loaded(sx, sy, sz) end)

local buddy = spawnActor{ kind = "zombie", outfit = cfg.outfit or "Police", x = sx, y = sy, z = sz, name = who, passive = true }
buddy:say("Hey " .. name(target) .. ". Mind if I tag along?")
buddy:follow(target, keep)
state.comments = state.comments or 0

local function comment(text)
    state.comments = state.comments + 1
    buddy:say(text, 5)
end

-- re-pick the player if ours logged off
every(5, function()
    local stillHere = false
    for _, p in ipairs(players()) do if p == target then stillHere = true end end
    if not stillHere and #players() > 0 then
        target = pickPlayer()
        buddy:follow(target, keep)
        comment("Oh, hi " .. name(target) .. ".")
    end
end)

-- small talk every 20 s, only while the player is close enough to read it
every(20, function()
    local bx, by = buddy:pos()
    if distTo(target, bx, by) > 12 then comment("Wait up!") return end
    local hour = getGameTime():getTimeOfDay()
    local zeds = #zombiesNear(bx, by, sz, 8)
    if zeds > 3 then comment("Uh... " .. zeds .. " of my old friends are close.")
    elseif hour >= 21 or hour < 5 then comment("Dark out. I like the dark.")
    elseif getClimateManager():getRainIntensity() > 0.2 then comment("Rain. Good for the skin.")
    else
        local lines = { "Nice day for a walk.", "You smell... alive.", "Ever tried brains? Don't.", "I used to have a job." }
        comment(lines[random(#lines)])
    end
end, { near = { sx, sy, 60 } })

onZombieDead(function(zed)
    local bx, by = buddy:pos()
    if distTo(zed, bx, by) < 10 then comment("Nice hit!") end
end)

onDeath(function(p)
    if p == target then
        buddy:stop()
        comment("No... " .. name(p) .. "...")
        wait(4)
        comment("I will find you again.")
        wait(2)
        stop("player died")
    end
end)

onStop(function() log("companion left after", state.comments, "comments") end)
