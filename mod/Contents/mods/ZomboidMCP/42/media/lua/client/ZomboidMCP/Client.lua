-- Zomboid MCP client: receives "zmcp" server commands (Events.OnServerCommand) and renders visuals.
-- Protocol: docs/CLIENT_PROTOCOL.md. Server side: server/ZomboidMCP/Api/Visuals.lua.
--
-- Commands handled (args are flat tables of strings/numbers/booleans):
--   exec        chunked Lua {id, part, total, code, module?}  -> loadstring, run, reply "execResult"
--   modRemove   {name}                    forget a persistent client module (+ its render/tick hooks)
--   tex         {id, gen, part, total, data}   base64 PNG chunk -> file -> texture (ClientTextures)
--   pixel       {id, def}                 pixel-sprite fallback (palette/rows JSON)
--   sprite      {id, tex, x, y, z, ...}   world sprite (ClientSprites)
--   spriteRemove {id?}
--   fall        {id, item, items, ...}    falling items (ClientFalling)
--   draw        {id?, kind, anchor, ...}  overlay primitive (ClientOverlay)
--   notify      {text, ttl, ...}          on-screen message
--   halo        {text, r, g, b, time}     overhead text on the local player
--   say         {text}                    speech bubble
--   heal / cure / teleport {x, y, z}      client-authoritative body state / position
--   clear       {what = all|sprites|draw|fall|notices|textures, id?}
--   ping        {}                        -> "pong" with the client version
-- Replies go through sendClientCommand(player, "zmcp", cmd, args): hello, execResult, texResult, pong.
--
-- Everything is re-runnable (the server can push this file again through exec): state lives in the
-- global ZMCPClient table, event handlers are removed before they are re-added.
require "ISUI/ISUIElement"
require "ZomboidMCP/Json"
require "ZomboidMCP/ClientBase64"
require "ZomboidMCP/ClientTextures"
require "ZomboidMCP/ClientSprites"
require "ZomboidMCP/ClientFalling"
require "ZomboidMCP/ClientOverlay"

ZMCPClient = ZMCPClient or {}
local C = ZMCPClient
C.version = "0.2.0"
C.MODULE = "zmcp"
C.commands = C.commands or {}        -- command -> function(args)
C.renderHooks = C.renderHooks or {}  -- name -> function(overlay)   (pushed code draws here)
C.tickHooks = C.tickHooks or {}      -- name -> function(now)       (pushed code updates here)
C.modules = C.modules or {}          -- persistent client modules: name -> source
C.pendingExec = C.pendingExec or {}  -- id -> { total, parts }
C.handlers = C.handlers or {}
C.stats = C.stats or { commands = 0, errors = 0 }

for ev, fn in pairs(C.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
C.handlers = {}

---------------------------------------------------------------- helpers
function C.now() return getTimestampMs() / 1000 end
function C.isEmpty(t) for _ in pairs(t) do return false end return true end   -- Kahlua has no next()
function C.log(msg) print("[ZomboidMCP] " .. tostring(msg)) end
function C.player() return getSpecificPlayer(0) end

-- client -> server. In single player this still arrives at Events.OnClientCommand (SinglePlayerServer).
function C.send(command, args)
    local p = C.player()
    if not p then return false end
    local ok, err = pcall(sendClientCommand, p, C.MODULE, command, args or {})
    if not ok then C.log("send " .. command .. " failed: " .. tostring(err)) end
    return ok
end

local function truncate(s, n)
    s = tostring(s)
    if #s > n then return s:sub(1, n) .. "...(" .. #s .. " chars)" end
    return s
end

---------------------------------------------------------------- overlay (full screen, click-through)
local Overlay = ISUIElement:derive("ZMCPOverlay")
function Overlay:new()
    local o = ISUIElement.new(self, 0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
    return o
end
function Overlay:createChildren() self.javaObject:setConsumeMouseEvents(false) end
function Overlay:render() ZMCPClient.render(self) end
function Overlay:onMouseDown() return false end

function C.render(ui)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    if ui:getWidth() ~= sw or ui:getHeight() ~= sh then ui:setWidth(sw); ui:setHeight(sh) end
    local ok, err = pcall(C.sprites.render, ui)
    if not ok then C.log("sprites render: " .. tostring(err)) end
    ok, err = pcall(C.falling.render, ui)
    if not ok then C.log("falling render: " .. tostring(err)) end
    ok, err = pcall(C.draw.render, ui)
    if not ok then C.log("draw render: " .. tostring(err)) end
    for name, fn in pairs(C.renderHooks) do
        local ok2, err2 = pcall(fn, ui)
        if not ok2 then C.renderHooks[name] = nil; C.log("render hook '" .. tostring(name) .. "' removed: " .. tostring(err2)) end
    end
end

function C.ensureOverlay()
    if C.overlay then return C.overlay end
    local o = Overlay:new()
    o:initialise()
    o:instantiate()
    o:addToUIManager()
    o:backMost()          -- behind the vanilla UI, above the world
    C.overlay = o
    return o
end

---------------------------------------------------------------- code push
-- exec {id, part, total, code, module?}: chunks are concatenated in order, then loadstring + pcall.
local function runChunk(id, src, moduleName)
    local fn, err = loadstring(src, "=zmcp:" .. tostring(moduleName or id))
    if not fn then
        C.log("exec " .. tostring(id) .. " compile error: " .. tostring(err))
        C.send("execResult", { id = id, ok = false, res = "compile: " .. tostring(err), module = moduleName })
        return
    end
    local ok, res = pcall(fn)
    if moduleName then C.modules[moduleName] = src end
    C.log("exec " .. tostring(id) .. (ok and " ok" or (" error: " .. tostring(res))))
    C.send("execResult", { id = id, ok = ok, res = truncate(res == nil and "nil" or res, 4000), module = moduleName })
end

C.commands.exec = function(a)
    local id = tostring(a.id or "?")
    local part, total = tonumber(a.part) or 1, tonumber(a.total) or 1
    local m = C.pendingExec[id]
    if not m or m.total ~= total then m = { total = total, parts = {}, got = 0 }; C.pendingExec[id] = m end
    if not m.parts[part] then m.got = m.got + 1 end
    m.parts[part] = a.code or ""
    if m.got < total then return end
    C.pendingExec[id] = nil
    C.ensureOverlay()
    runChunk(id, table.concat(m.parts), a.module and tostring(a.module) or nil)
end

C.commands.modRemove = function(a)
    local name = tostring(a.name or "")
    C.modules[name] = nil
    C.renderHooks[name] = nil
    C.tickHooks[name] = nil
    C.log("module " .. name .. " removed")
end

---------------------------------------------------------------- visuals
C.commands.tex = function(a) C.tex.onChunk(a) end
C.commands.pixel = function(a) C.tex.onPixel(a) end
C.commands.sprite = function(a) C.ensureOverlay(); C.sprites.set(a) end
C.commands.spriteRemove = function(a) C.sprites.remove(a.id) end
C.commands.fall = function(a) C.ensureOverlay(); C.falling.add(a) end
C.commands.draw = function(a) C.ensureOverlay(); C.draw.add(a) end
C.commands.notify = function(a) C.ensureOverlay(); C.draw.notify(a) end

C.commands.clear = function(a)
    local what, id = tostring(a.what or "all"), a.id
    if what == "all" or what == "sprites" then C.sprites.remove(id) end
    if what == "all" or what == "draw" then C.draw.clear(id) end
    if what == "all" or what == "fall" then C.falling.clear(id) end
    if what == "all" or what == "notices" then C.draw.notices = {} end
    if what == "textures" then C.tex.clear(id) end
    if what == "all" and not id then C.renderHooks = {} end
end

C.commands.halo = function(a)
    local p = C.player()
    if not p then return end
    p:setHaloNote(tostring(a.text or ""), math.floor(tonumber(a.r) or 255), math.floor(tonumber(a.g) or 255),
        math.floor(tonumber(a.b) or 255), tonumber(a.time) or 300)
end

C.commands.say = function(a)
    local p = C.player()
    if p then p:Say(tostring(a.text or "")) end
end

---------------------------------------------------------------- client-authoritative player state
C.commands.heal = function()
    local p = C.player()
    if not p then return end
    local bd = p:getBodyDamage()
    local parts = bd:getBodyParts()
    for i = 0, parts:size() - 1 do
        local bp = parts:get(i)
        bp:RestoreToFullHealth()
        pcall(function()
            if bp:getStiffness() > 0 then
                bp:setStiffness(0)
                p:getFitness():removeStiffnessValue(BodyPartType.ToString(bp:getType()))
            end
        end)
    end
    pcall(function() bd:RestoreToFullHealth() end)
    pcall(function() bd:setOverallBodyHealth(100) end)
    pcall(function()
        -- B42 stats registry: stats:set(CharacterStat.X, value)
        local st = p:getStats()
        for name, v in pairs({ PAIN = 0, PANIC = 0, STRESS = 0, FATIGUE = 0, ENDURANCE = 1, HUNGER = 0, THIRST = 0, FOOD_SICKNESS = 0 }) do
            local stat = CharacterStat[name]
            if stat then st:set(stat, v) end
        end
    end)
    pcall(function() sendPlayerStatsChange(p) end)
    C.log("healed")
end

C.commands.cure = function()
    local p = C.player()
    if not p then return end
    local bd = p:getBodyDamage()
    local parts = bd:getBodyParts()
    for i = 0, parts:size() - 1 do
        local bp = parts:get(i)
        pcall(function() bp:SetInfected(false) end)
        pcall(function() bp:SetFakeInfected(false) end)
        pcall(function() bp:setInfectedWound(false) end)
        pcall(function() bp:setWoundInfectionLevel(0) end)
    end
    pcall(function() bd:setInfected(false) end)
    pcall(function() bd:setIsFakeInfected(false) end)
    pcall(function() bd:setInfectionTime(-1) end)
    pcall(function() bd:setInfectionMortalityDuration(-1) end)
    pcall(function() bd:setInfectionLevel(0) end)
    pcall(function() bd:setWetness(0) end)
    C.log("cured")
end

C.commands.teleport = function(a)
    local p = C.player()
    if not p then return end
    local x, y, z = tonumber(a.x), tonumber(a.y), tonumber(a.z) or p:getZ()
    if not x or not y then return end
    p:teleportTo(x, y, z)
end

C.commands.ping = function()
    C.send("pong", { version = C.version, sprites = #C.sprites.info(), textures = #C.tex.list() })
end

---------------------------------------------------------------- dispatch
function C.onCommand(command, args)
    local fn = C.commands[command]
    if not fn then C.log("unknown command '" .. tostring(command) .. "'"); return end
    C.stats.commands = C.stats.commands + 1
    local ok, err = pcall(fn, args or {})
    if not ok then
        C.stats.errors = C.stats.errors + 1
        C.log("command '" .. tostring(command) .. "' failed: " .. tostring(err))
    end
end

function C.hello()
    C.ensureOverlay()
    C.send("hello", { version = C.version })
end

C.handlers.OnServerCommand = function(module, command, args)
    if module ~= C.MODULE then return end
    C.onCommand(command, args)
end
C.handlers.OnGameStart = function() C.hello() end
C.handlers.OnTick = function()
    if C.isEmpty(C.tickHooks) then return end
    local t = C.now()
    for name, fn in pairs(C.tickHooks) do
        local ok, err = pcall(fn, t)
        if not ok then C.tickHooks[name] = nil; C.log("tick hook '" .. tostring(name) .. "' removed: " .. tostring(err)) end
    end
end
for ev, fn in pairs(C.handlers) do if Events[ev] then Events[ev].Add(fn) end end

-- re-run while in game (pushed through exec): keep the overlay, re-announce
if C.player() then C.ensureOverlay() end
