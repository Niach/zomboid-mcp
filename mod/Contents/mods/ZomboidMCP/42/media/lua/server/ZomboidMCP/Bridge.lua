-- Zomboid MCP server bridge.
-- The MCP process (zomboid_mcp.py) talks to the game through files in the Lua cache dir (~/Zomboid/Lua/):
--   zmcp_req_<n>.json   request  {"tool": "...", "args": {...}}          written by MCP
--   zmcp_res_<n>.json   response {"ok": true, "result": ...} / {"ok": false, "error": "..."}
--   zmcp_status.json    heartbeat (every 2 s): version, nextReq, players, time
--   zmcp_events.jsonl   append-only event log
-- Requests are executed in order on the server tick (~10/s while players are online).
-- Everything here is re-runnable (hot reload): handlers are removed and re-added.
require "ZomboidMCP/Json"

if isClient() then return end   -- server (dedicated or SP host) only

ZMCP = ZMCP or {}
local Z = ZMCP
local J = ZMCPJson
Z.version = "0.1.0"
Z.tools = Z.tools or {}          -- name -> { fn = function(args) ... end, desc = "..." }
Z.handlers = Z.handlers or {}

for ev, fn in pairs(Z.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
Z.handlers = {}

---------------------------------------------------------------- utilities
function Z.now() return getTimestampMs() / 1000 end

function Z.event(kind, data)
    local w = getFileWriter("zmcp_events.jsonl", true, true)
    if w then
        w:write(J.encode({ t = math.floor(Z.now()), kind = kind, data = data }) .. "\n")
        w:close()
    end
    print("[ZomboidMCP] " .. kind .. " " .. (type(data) == "table" and J.encode(data) or tostring(data)))
end

function Z.players()
    local out = {}
    local list = getOnlinePlayers and getOnlinePlayers()
    if list and list:size() > 0 then
        for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
    elseif not isServer() then
        local p = getSpecificPlayer(0)          -- single player
        if p then out[1] = p end
    end
    return out
end

function Z.player(name)
    local list = Z.players()
    if not name or name == "" then
        if #list == 1 then return list[1] end
        error("player name required (online: " .. Z.playerNames() .. ")")
    end
    for _, p in ipairs(list) do
        local d = p:getDescriptor()
        local full = d and ((d:getForename() or "") .. " " .. (d:getSurname() or "")) or ""
        if string.lower(p:getUsername() or "") == string.lower(name) or string.lower(full) == string.lower(name) then return p end
    end
    error("player not online: " .. tostring(name) .. " (online: " .. Z.playerNames() .. ")")
end

function Z.playerNames()
    local n = {}
    for _, p in ipairs(Z.players()) do n[#n + 1] = p:getUsername() end
    return table.concat(n, ", ")
end

function Z.charName(p)
    local d = p:getDescriptor()
    return d and ((d:getForename() or "") .. " " .. (d:getSurname() or "")) or ""
end

function Z.square(x, y, z)
    local sq = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0))
    if not sq then error(string.format("square %d,%d,%d is not loaded (only areas near players are loaded)", x, y, z or 0)) end
    return sq
end

-- iterate zombies in a square area around x,y (loaded area only)
function Z.zombiesNear(x, y, z, radius)
    local out, cell = {}, getCell()
    local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z or 0)
    radius = math.min(radius or 10, 80)
    for dx = -radius, radius do
        for dy = -radius, radius do
            local sq = cell:getGridSquare(fx + dx, fy + dy, fz)
            if sq then
                local objs = sq:getMovingObjects()
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    if instanceof(o, "IsoZombie") and not o:isDead() then out[#out + 1] = o end
                end
            end
        end
    end
    return out
end

-- send a command to the Zomboid MCP client mod of every player, or one player
function Z.toClients(command, args, player)
    if isServer() then
        if player then sendServerCommand(player, "zmcp", command, args or {})
        else sendServerCommand("zmcp", command, args or {}) end
    elseif ZMCPClient and ZMCPClient.onCommand then
        ZMCPClient.onCommand(command, args or {})       -- single player: same Lua state
    end
end

-- register a tool: Z.tool("name", "description", function(args) return result end)
function Z.tool(name, desc, fn)
    Z.tools[name] = { fn = fn, desc = desc }
end

---------------------------------------------------------------- request loop
local store = function() return ModData.getOrCreate("ZomboidMCP") end
Z.nextReq = Z.nextReq or store().nextReq or 1

local function readFile(name)
    local ok, r = pcall(getFileReader, name, false)
    if not ok or not r then return nil end
    local t, l = {}, r:readLine()
    while l do t[#t + 1] = l; l = r:readLine() end
    r:close()
    return table.concat(t, "\n")
end
Z.readFile = readFile

local function writeFile(name, text)
    local w = getFileWriter(name, true, false)
    if w then w:write(text); w:close() end
end
Z.writeFile = writeFile

local function run(req)
    local tool = Z.tools[req.tool or ""]
    if not tool then error("unknown tool '" .. tostring(req.tool) .. "'") end
    return tool.fn(req.args or {})
end

local function processOne(n)
    local text = readFile("zmcp_req_" .. n .. ".json")
    if not text or text == "" then return false end
    local req, err = J.decode(text)
    local res
    if not req then
        res = { ok = false, error = "bad json: " .. tostring(err) }
    else
        local ok, result = pcall(run, req)
        if ok then res = { ok = true, result = result }
        else res = { ok = false, error = tostring(result) } end
    end
    writeFile("zmcp_res_" .. n .. ".json", J.encode(res))
    writeFile("zmcp_req_" .. n .. ".json", "")    -- mark consumed (MCP deletes both files)
    return true
end

local lastStatus = 0
local function writeStatus()
    local players = {}
    for _, p in ipairs(Z.players()) do
        players[#players + 1] = {
            user = p:getUsername(), name = Z.charName(p),
            x = math.floor(p:getX()), y = math.floor(p:getY()), z = math.floor(p:getZ()),
            dead = p:isDead(), health = math.floor(p:getBodyDamage():getOverallBodyHealth()),
        }
    end
    local gt = getGameTime()
    writeFile("zmcp_status.json", J.encode({
        version = Z.version, t = math.floor(Z.now()), nextReq = Z.nextReq,
        server = isServer(), players = players,
        time = { hour = gt:getTimeOfDay(), day = gt:getDay() + 1, month = gt:getMonth() + 1, year = gt:getYear() },
        tools = (function() local n = 0 for _ in pairs(Z.tools) do n = n + 1 end return n end)(),
    }))
end

function Z.tick()
    -- process all pending requests in order; tolerate small gaps (crashed MCP writes)
    local budget = 20
    while budget > 0 do
        if processOne(Z.nextReq) then
            Z.nextReq = Z.nextReq + 1; store().nextReq = Z.nextReq; budget = budget - 1
        else
            local jumped = false
            for k = 1, 5 do
                local t = readFile("zmcp_req_" .. (Z.nextReq + k) .. ".json")
                if t and t ~= "" then Z.nextReq = Z.nextReq + k; jumped = true; break end
            end
            if not jumped then break end
        end
    end
    local t = Z.now()
    if t - lastStatus >= 2 then
        lastStatus = t
        pcall(writeStatus)
    end
    for _, fn in pairs(Z.tickHooks or {}) do pcall(fn, t) end
end
Z.tickHooks = Z.tickHooks or {}   -- other modules add periodic work here: Z.tickHooks.name = function(t) end

Z.handlers.OnTick = function() local ok, err = pcall(Z.tick); if not ok then print("[ZomboidMCP] tick error: " .. tostring(err)) end end
Z.handlers.OnTickEvenPaused = function()
    -- keep answering while the dedicated server is paused (no players online) at a low rate
    if Z.pausedAt and Z.now() - Z.pausedAt < 0.5 then return end
    Z.pausedAt = Z.now()
    if Z.lastTick and Z.now() - Z.lastTick < 1 then return end
    pcall(Z.tick)
end
local tickWrap = Z.handlers.OnTick
Z.handlers.OnTick = function() Z.lastTick = Z.now(); tickWrap() end

for ev, fn in pairs(Z.handlers) do if Events[ev] then Events[ev].Add(fn) end end

---------------------------------------------------------------- core tools
Z.tool("ping", "Health check.", function() return { pong = true, version = Z.version, players = Z.playerNames() } end)

Z.tool("lua_eval", "Run Lua on the server (loadstring). Return value is JSON-encoded.", function(a)
    local fn, err = loadstring(a.code or "")
    if not fn then error("compile: " .. tostring(err)) end
    local res = { pcall(fn) }
    if not res[1] then error(tostring(res[2])) end
    if #res <= 2 then return res[2] end
    table.remove(res, 1)
    return res
end)

Z.tool("tools_list", "List tools registered in the game.", function()
    local out = {}
    for name, t in pairs(Z.tools) do out[#out + 1] = { name = name, desc = t.desc } end
    return out
end)

-- load (or reload) a Lua file from the Lua cache dir: used by module_install
Z.tool("run_file", "Execute a Lua file from ~/Zomboid/Lua/ on the server.", function(a)
    local text = readFile(a.file)
    if not text then error("file not found in Lua dir: " .. tostring(a.file)) end
    local fn, err = loadstring(text)
    if not fn then error("compile: " .. tostring(err)) end
    return fn()
end)

Z.event("bridge_loaded", { version = Z.version, nextReq = Z.nextReq })
