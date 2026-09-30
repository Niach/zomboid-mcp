-- Zomboid MCP client: receives "zmcp" server commands (Events.OnServerCommand) and renders visuals.
-- Protocol: docs/PROTOCOL.md part 2. Server side: server/ZomboidMCP/Api/Visuals.lua.
--
-- Scripting first: "exec" runs chunked Lua on this client (run_lua_client) and reports the result back;
-- scripts register hooks with ZMCPClient.on(name, "render"|"tick"|"keyDown"|..., fn) (ClientInput.lua).
-- Commands handled (args are flat tables of strings/numbers/booleans):
--   exec        chunked Lua {id, part, total, code, module?}  -> loadstring, run, reply "execResult"
--   scriptRemove {name}                   forget a persistent client script (+ every hook of that name)
--   tex         {id, gen, part, total, data}   base64 PNG chunk -> file -> texture (ClientTextures)
--   pixel       {id, def}                 pixel-sprite fallback (palette/rows JSON)
--   file        {id, gen, part, total, data, path}   any file into the Lua dir (ClientModels)
--   model       {id, gen, mesh, texture, scale}      runtime ModelScript registration (ClientModels)
--   sprite      {id, tex, x, y, z, ...}   world sprite (ClientSprites)
--   spriteRemove {id?}
--   fall        {id, item, items, ...}    falling items (ClientFalling)
--   draw        {id?, kind, anchor, ...}  overlay primitive (ClientOverlay)
--   notify      {text, ttl, r, g, b, font}   message box at the top of the screen
--   halo        {text, r, g, b, time}     overhead text on the local player
--   chat        {text, r, g, b}           a line in the chat panel (falls back to notify)
--   say         {text}                    speech bubble
--   capture     {on}                      overlay swallows the mouse / sits on top (screen apps)
--   heal / cure / teleport {x, y, z}      client-authoritative body state / position
--   clear       {what = all|sprites|overlays|falling|notices|textures|models|hooks, id?}
--   ping        {}                        -> "pong" with the client version
-- Replies: sendClientCommand(player, "zmcp", cmd, args): hello, execResult, texResult, fileResult, modelResult, pong.
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
require "ZomboidMCP/ClientInput"
require "ZomboidMCP/ClientModels"

ZMCPClient = ZMCPClient or {}
local C = ZMCPClient
C.version = "0.3.0"          -- keep equal to ZMCP.version in Bridge.lua
C.MODULE = "zmcp"
C.commands = C.commands or {}        -- command -> function(args)
C.renderHooks = C.renderHooks or {}  -- name -> function(overlay)   (pushed code draws here)
C.tickHooks = C.tickHooks or {}      -- name -> function(now)       (pushed code updates here)
C.modules = C.modules or {}          -- persistent client scripts: name -> source
C.pendingExec = C.pendingExec or {}  -- id -> { total, parts }
C.handlers = C.handlers or {}
C.stats = C.stats or { commands = 0, errors = 0, execs = 0 }

for ev, fn in pairs(C.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
C.handlers = {}

---------------------------------------------------------------- helpers
function C.now() return getTimestampMs() / 1000 end
function C.isEmpty(t) for _ in pairs(t) do return false end return true end   -- Kahlua has no next()
function C.log(msg) print("[ZomboidMCP] " .. tostring(msg)) end
function C.player() return getSpecificPlayer(0) end
function C.screen() return getCore():getScreenWidth(), getCore():getScreenHeight() end
function C.zoom() local z = getCore():getZoom(0); if not z or z <= 0 then return 1 end; return z end

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
-- mouse callbacks reach the overlay only while ZMCPClient.capture(true) made it consume events
function Overlay:onMouseDown(x, y) return ZMCPClient.input.overlayMouseDown(x, y) end
function Overlay:onMouseUp(x, y) return ZMCPClient.input.overlayMouseUp(x, y) end
function Overlay:onRightMouseDown(x, y) return ZMCPClient.input.overlayRightDown(x, y) end
function Overlay:onRightMouseUp(x, y) return ZMCPClient.input.overlayRightUp(x, y) end
function Overlay:onMouseMove(dx, dy) return ZMCPClient.input.overlayMouseMove(dx, dy) end
function Overlay:onMouseWheel(del) return ZMCPClient.input.overlayMouseWheel(del) end

function C.render(ui)
    local sw, sh = C.screen()
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

-- true when the element is in the UI manager's list; nil when that cannot be checked in this Lua state
function C.inUI(el)
    local ok, v = pcall(function() return UIManager.getUI():contains(el.javaObject) end)
    if ok then return v == true end
    return nil
end

-- (re)attach a full-screen element: elements can be dropped from the UI manager behind our back (verified
-- 2026-09-30 after a hot reload in single player, isRemoved() stays true afterwards), so check the UI list itself
function C.attach(el)
    if C.inUI(el) == false then pcall(function() el:addToUIManager(); el:backMost() end) end
    return el
end

function C.ensureOverlay()
    if C.overlay then return C.attach(C.overlay) end
    local o = Overlay:new()
    o:initialise()
    o:instantiate()
    o:addToUIManager()
    o:backMost()          -- behind the vanilla UI, above the world
    C.overlay = o
    return o
end

---------------------------------------------------------------- code push (run_lua_client)
-- exec {id, part, total, code, module?}: chunks are concatenated in order, then loadstring + pcall.
-- The chunk's return value (or the error) goes back as execResult {id, ok, res, ms, module?}.
local function runChunk(id, src, moduleName)
    local fn, err = loadstring(src, "=zmcp:" .. tostring(moduleName or id))
    if not fn then
        C.log("exec " .. tostring(id) .. " compile error: " .. tostring(err))
        C.send("execResult", { id = id, ok = false, res = "compile: " .. tostring(err), module = moduleName })
        return
    end
    local t0 = C.now()
    local ok, res = pcall(fn)
    local ms = math.floor((C.now() - t0) * 1000 + 0.5)
    C.stats.execs = C.stats.execs + 1
    if moduleName then C.modules[moduleName] = src end
    if type(res) == "table" then
        local okj, json = pcall(ZMCPJson.encode, res)
        res = okj and json or tostring(res)
    end
    C.log("exec " .. tostring(id) .. (ok and " ok" or (" error: " .. tostring(res))) .. " (" .. ms .. " ms)")
    C.send("execResult", { id = id, ok = ok, res = truncate(res == nil and "nil" or res, 4000), ms = ms, module = moduleName })
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

C.commands.scriptRemove = function(a)
    local name = tostring(a.name or "")
    C.modules[name] = nil
    C.off(name)
    C.log("script " .. name .. " removed")
end

---------------------------------------------------------------- visuals
C.commands.tex = function(a) C.tex.onChunk(a) end
C.commands.pixel = function(a) C.tex.onPixel(a) end
C.commands.file = function(a) C.files.onChunk(a) end
C.commands.model = function(a) C.models.onModel(a) end
C.commands.sprite = function(a) C.ensureOverlay(); C.sprites.set(a) end
C.commands.spriteRemove = function(a) C.sprites.remove(a.id) end
C.commands.fall = function(a) C.ensureOverlay(); C.falling.add(a) end
C.commands.draw = function(a) C.ensureOverlay(); C.draw.add(a) end
C.commands.notify = function(a) C.ensureOverlay(); C.draw.notify(a) end
C.commands.capture = function(a) C.ensureOverlay(); C.capture(a.on == true or a.on == 1 or a.on == "1" or a.on == "true") end

C.commands.clear = function(a)
    local what, id = tostring(a.what or "all"), a.id
    if what == "all" or what == "sprites" then C.sprites.remove(id) end
    if what == "all" or what == "overlays" then C.draw.clear(id) end
    if what == "all" or what == "falling" then C.falling.clear(id) end
    if what == "all" or what == "notices" then C.draw.notices = {} end
    if what == "textures" then C.tex.clear(id) end
    if what == "models" then C.models.clear(id) end
    if what == "hooks" then if id then C.off(id) else C.offAll() end end
    if what == "all" and not id then C.offAll() end
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

-- a line in the chat panel; the ISChat message shape varies between builds, so fall back to a notice
C.commands.chat = function(a)
    local text = tostring(a.text or "")
    local ok = pcall(function()
        local line = "[Zomboid MCP] " .. text
        local msg = {
            getText = function() return text end, getTextWithPrefix = function() return line end,
            getTextWithReplacedParentheses = function() return text end, getAuthor = function() return "" end,
            isServerAlert = function() return true end, isShowAuthor = function() return false end,
            isOverHeadSpeech = function() return false end, setOverHeadSpeech = function() end,
            setShouldAttractZombies = function() end, isFromDiscord = function() return false end,
            getChatID = function() return -1 end, getDatetimeStr = function() return "" end,
        }
        ISChat.addLineInChat(msg, -1)
    end)
    if not ok then C.draw.notify({ text = text, r = a.r, g = a.g, b = a.b }) end
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
    C.send("pong", { version = C.version, sprites = #C.sprites.info(), textures = #C.tex.list(), models = #C.models.info(),
        execs = C.stats.execs, captured = C.input.captured })
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
for ev, fn in pairs(C.input.globalHandlers) do C.handlers[ev] = fn end
for ev, fn in pairs(C.handlers) do if Events[ev] then Events[ev].Add(fn) end end

-- re-run while in game (pushed through exec): keep the overlay, re-announce
if C.player() then C.ensureOverlay() end
