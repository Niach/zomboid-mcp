-- Zomboid MCP server bridge: file-based request/response loop between the MCP process and the game.
-- Full protocol: docs/PROTOCOL.md. Short version (all files live in the Lua cache dir, ~/Zomboid/Lua/):
--   zmcp_req_<n>.json    request  {"n": n, "t": unixSeconds, "tool": "...", "args": {...}}   written by the MCP
--   zmcp_res_<n>.json    response {"n": n, "ok": true, "result": ...} | {"n": n, "ok": false, "error": "..."}
--   zmcp_status.json     heartbeat (every 2 s and after every request): nextReq, paused, players, time, tools
--   zmcp_events.log      append-only event log, one JSON object per line {"t", "kind", "data"}
-- Requests execute in order (n = nextReq, nextReq + 1, ...) on the server tick, at most once each: nextReq
-- is advanced (and persisted in ModData "ZomboidMCP") before a request runs. The MCP never needs write
-- access to files the server wrote and vice versa. getFileWriter only accepts .txt/.json/.log style names
-- (verified: .lua, .jsonl and extension-less names are refused), hence the file names below.
--
-- Public API for other modules (keep stable, other files build on it):
--   ZMCP.tool(name, desc, fn)            register a tool; fn(args) returns a JSON-encodable value or errors
--   ZMCP.toClients(cmd, args, player)    sendServerCommand("zmcp", cmd, args) to one player or everyone
--   ZMCP.event(kind, data)               append to zmcp_events.log and log to the console
--   ZMCP.player(name) / ZMCP.players()   online IsoPlayer by user or character name / all online players
--   ZMCP.square(x, y, z)                 loaded IsoGridSquare or error
--   ZMCP.zombiesNear(x, y, z, radius)    live IsoZombie list in the loaded area
--   ZMCP.tickHooks.<name> = function(t)  periodic work, called every processed tick with the unix time
--   ZMCP.readFile(name) / ZMCP.writeFile(name, text)   text files in the Lua cache dir
--   ZMCP.argText(args, key)              a string argument, or the file the MCP moved it to (args.<key>_file)
--   ZMCP.statusDoc()                     the heartbeat document (Api/World.lua extends the status tool with it)
--   ZMCP.scriptSides.<side>              {install(name, code), remove(name), list()} for script_* with side ~= "server"
--   ZMCP.playerNames(), ZMCP.charName(p), ZMCP.now(), ZMCP.version, ZMCP.tools, ZMCP.scripts()
--
-- Hot reload: this file is fully re-runnable. It removes its own event handlers before re-adding them and
-- keeps ZMCP.tools / ZMCP.tickHooks / ZMCP.scriptSides / ZMCP.nextReq across reloads. Load paths: reloadlua Bridge.lua,
-- tools/pz load (loadstring of the concatenated files), or the run_file tool.

if isClient() then return end   -- server (dedicated or SP host) only

if not ZMCPJson then pcall(require, "ZomboidMCP/Json") end   -- no-op when loaded via loadstring bundle
if not ZMCPJson then error("ZomboidMCP/Json.lua must be loaded before Bridge.lua") end

ZMCP = ZMCP or {}
local Z = ZMCP
local J = ZMCPJson
Z.version = "0.3.0"
Z.tools = Z.tools or {}            -- name -> { fn = function(args) ... end, desc = "..." }
Z.tickHooks = Z.tickHooks or {}    -- name -> function(t)
Z.scriptSides = Z.scriptSides or {} -- side -> { install = fn(name, code), remove = fn(name), list = fn() }
Z.handlers = Z.handlers or {}

for ev, fn in pairs(Z.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
Z.handlers = {}

local MOD_DATA = "ZomboidMCP"
local STATUS_FILE = "zmcp_status.json"
local EVENTS_FILE = "zmcp_events.log"
local REQ_PREFIX, RES_PREFIX = "zmcp_req_", "zmcp_res_"
local MAX_PER_TICK = 20          -- requests processed per tick
local PROBE_AHEAD = 10           -- how far past nextReq we look for a request when nextReq is missing (gap)
local PROBE_INTERVAL = 0.25      -- seconds between gap probes
local STALE_SECONDS = 60         -- requests older than this are refused (server restarted / MCP gave up)
local STATUS_INTERVAL = 2        -- heartbeat period in seconds
local PAUSED_POLL = 0.2          -- polling period while the game loop is paused

---------------------------------------------------------------- utilities
function Z.now() return getTimestampMs() / 1000 end

-- math.random is nil in the single-player Lua state (verified 42.21); ZombRand exists everywhere
local function randomInt(n) if ZombRand then return ZombRand(n) end return math.floor(getTimestampMs() % n) end
Z.bootId = Z.bootId or string.format("%d-%d", math.floor(Z.now()), randomInt(1000000))   -- changes only on restart
Z.bootAt = Z.bootAt or Z.now()

local function store() return ModData.getOrCreate(MOD_DATA) end

-- absolute path of the Lua cache dir (fileExists needs it; verified: relative names return false)
local SEP = getFileSeparator and getFileSeparator() or "/"
local LUA_DIR = (getMyDocumentFolder and getMyDocumentFolder() or "") .. SEP .. "Lua" .. SEP

-- true/false when fileExists is available, nil when unknown
local function exists(name)
    if fileExists then
        local ok, v = pcall(fileExists, LUA_DIR .. name)
        if ok then return v == true end
    end
    return nil
end
Z.fileExists = exists

local function readFile(name)
    if exists(name) == false then return nil end        -- cheap probe, no exception for missing files
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
    if not w then error("cannot open " .. name .. " for writing (names must end in .txt/.json/.log; .lua is refused)") end
    w:write(text)
    w:close()
end
Z.writeFile = writeFile

-- A string argument that the MCP may have moved into a file when it was large (docs/PROTOCOL.md "Large
-- arguments"): args.<key> inline, or args.<key>_file naming a file in the Lua dir. Errors when required and absent.
function Z.argText(a, key, required)
    local v = a[key]
    if type(v) == "string" and v ~= "" then return v end
    local file = a[key .. "_file"]
    if type(file) == "string" and file ~= "" then
        local text = readFile(file)
        if not text then error("args." .. key .. "_file not found in Lua dir: " .. file) end
        return text
    end
    if required ~= false then error("args." .. key .. " (string) required") end
    return nil
end

function Z.event(kind, data)
    local ok, w = pcall(getFileWriter, EVENTS_FILE, true, true)
    if ok and w then
        w:write(J.encode({ t = Z.now(), kind = kind, data = data }) .. "\n")
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
        local p = getSpecificPlayer(0)          -- single player host
        if p then out[1] = p end
    end
    return out
end

function Z.charName(p)
    local d = p:getDescriptor()
    return d and ((d:getForename() or "") .. " " .. (d:getSurname() or "")) or ""
end

function Z.playerNames()
    local n = {}
    for _, p in ipairs(Z.players()) do n[#n + 1] = p:getUsername() end
    return table.concat(n, ", ")
end

function Z.player(name)
    local list = Z.players()
    if name == nil or name == "" then
        if #list == 1 then return list[1] end
        if #list == 0 then error("no player online") end
        error("player name required (online: " .. Z.playerNames() .. ")")
    end
    name = string.lower(tostring(name))
    for _, p in ipairs(list) do
        if string.lower(p:getUsername() or "") == name or string.lower(Z.charName(p)) == name then return p end
    end
    error("player not online: " .. tostring(name) .. " (online: " .. Z.playerNames() .. ")")
end

function Z.square(x, y, z)
    local sq = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0))
    if not sq then error(string.format("square %d,%d,%d is not loaded (only areas near players are loaded)", x, y, z or 0)) end
    return sq
end

-- live zombies in a square area around x,y (loaded area only)
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

-- register a tool: Z.tool(name, description, function(args) return result end)
function Z.tool(name, desc, fn)
    if type(fn) ~= "function" then error("ZMCP.tool: fn must be a function") end
    Z.tools[name] = { fn = fn, desc = desc or "" }
end

function Z.toolNames()
    local names = {}
    for name in pairs(Z.tools) do names[#names + 1] = name end
    table.sort(names)
    return names
end

---------------------------------------------------------------- request loop
Z.nextReq = Z.nextReq or tonumber(store().nextReq) or 1
Z.lastReq = Z.lastReq or nil
Z.stats = Z.stats or { requests = 0, errors = 0 }
Z.paused = false
local lastProbe, lastStatus, ticksThisSecond, tpsAt, tps = 0, 0, 0, 0, 0

local function run(req)
    local name = req.tool
    if type(name) ~= "string" then error("request has no 'tool' string") end
    local tool = Z.tools[name]
    if not tool then error("unknown tool '" .. name .. "' (see tools_list)") end
    local args = req.args
    if args == nil then args = {} end
    if type(args) ~= "table" then error("'args' must be an object") end
    return tool.fn(args)
end

local function respond(n, res)
    res.n = n
    res.t = Z.now()
    local ok, text = pcall(J.encode, res)
    if not ok then text = J.encode({ n = n, ok = false, error = "encode: " .. tostring(text) }) end
    writeFile(RES_PREFIX .. n .. ".json", text .. "\n")
end

-- execute request n if its file exists. Returns true when n was consumed.
-- nextReq moves past n BEFORE the request runs: a request that kills the Lua state is never retried.
local function processOne(n)
    local text = readFile(REQ_PREFIX .. n .. ".json")
    if not text or text == "" then return false end
    Z.nextReq = n + 1
    store().nextReq = Z.nextReq
    local started = Z.now()
    local req, err = J.decode(text)
    local res
    if type(req) ~= "table" then
        res = { ok = false, error = "bad request json: " .. tostring(err) }
    elseif type(req.t) == "number" and started - req.t > STALE_SECONDS then
        res = { ok = false, error = string.format("stale request (%.0f s old): not executed", started - req.t) }
    else
        Z.stats.requests = Z.stats.requests + 1
        local ok, result = pcall(run, req)
        if ok then res = { ok = true, result = result }
        else
            Z.stats.errors = Z.stats.errors + 1
            res = { ok = false, error = tostring(result) }
        end
    end
    res.ms = math.floor((Z.now() - started) * 1000 + 0.5)
    respond(n, res)
    Z.lastReq = { n = n, tool = type(req) == "table" and req.tool or nil, ok = res.ok, ms = res.ms, t = Z.now() }
    return true
end

function Z.statusDoc()
    local players = {}
    for _, p in ipairs(Z.players()) do
        local ok, entry = pcall(function()
            return {
                user = p:getUsername(), name = Z.charName(p),
                x = math.floor(p:getX()), y = math.floor(p:getY()), z = math.floor(p:getZ()),
                dead = p:isDead(), health = math.floor(p:getBodyDamage():getOverallBodyHealth()),
            }
        end)
        if ok then players[#players + 1] = entry end
    end
    local time
    pcall(function()
        local gt = getGameTime()
        time = { hour = gt:getTimeOfDay(), day = gt:getDay() + 1, month = gt:getMonth() + 1, year = gt:getYear() }
    end)
    return {
        version = Z.version, bootId = Z.bootId, t = Z.now(), uptime = math.floor(Z.now() - Z.bootAt),
        nextReq = Z.nextReq, lastReq = Z.lastReq,
        paused = Z.paused, tps = tps, server = isServer(),
        players = J.array(players), time = time,
        tools = J.array(Z.toolNames()), scripts = J.array(Z.scriptNames()),
        stats = Z.stats,
    }
end

local function writeStatus()
    writeFile(STATUS_FILE, J.encode(Z.statusDoc()) .. "\n")
end

-- process pending requests in order; returns the number processed
local function pump(t)
    local done = 0
    while done < MAX_PER_TICK do
        if processOne(Z.nextReq) then
            done = done + 1
        else
            -- gap: the MCP skipped a number (crashed mid-write, resynced) or an old file was removed.
            if t - lastProbe < PROBE_INTERVAL then break end
            lastProbe = t
            local jumped = false
            for k = 1, PROBE_AHEAD do
                local text = readFile(REQ_PREFIX .. (Z.nextReq + k) .. ".json")
                if text and text ~= "" then
                    Z.event("gap", { from = Z.nextReq, to = Z.nextReq + k })
                    Z.nextReq = Z.nextReq + k
                    jumped = true
                    break
                end
            end
            if not jumped then break end
        end
    end
    return done
end

function Z.tick()
    local t = Z.now()
    local done = pump(t)
    if done > 0 or t - lastStatus >= STATUS_INTERVAL then
        lastStatus = t
        local ok, err = pcall(writeStatus)
        if not ok then print("[ZomboidMCP] status error: " .. tostring(err)) end
    end
    for name, fn in pairs(Z.tickHooks) do
        local ok, err = pcall(fn, t)
        if not ok then print("[ZomboidMCP] tickHook '" .. tostring(name) .. "' error: " .. tostring(err)) end
    end
    return done
end

local function safeTick()
    local ok, err = pcall(Z.tick)
    if not ok then print("[ZomboidMCP] tick error: " .. tostring(err)) end
end

-- OnTick: ~10 Hz while the game loop runs (players online). With PauseEmpty=true and nobody online the
-- dedicated server pauses its loop and NO Lua event fires (verified on 42.21: not OnTick, not
-- EveryOneMinute, not OnTickEvenPaused). Console commands still run, so the MCP triggers
-- `reloadlua ZomboidMCP/ZMCPPoll.lua` (a file that just calls ZMCP.poll) when the heartbeat goes stale.
-- OnTickEvenPaused stays registered for hosts where it does fire; it yields to OnTick.
Z.handlers.OnTick = function()
    local t = Z.now()
    Z.lastTick = t
    Z.paused = false
    ticksThisSecond = ticksThisSecond + 1
    if t - tpsAt >= 1 then tps = ticksThisSecond; ticksThisSecond = 0; tpsAt = t end
    safeTick()
end

-- one request-loop pass outside the tick events (paused server): used by ZMCPPoll.lua / the dev bootstrap
function Z.poll()
    local t = Z.now()
    if t - (Z.lastTick or 0) < 1 then return 0 end     -- the game loop is alive, OnTick does the work
    Z.paused = true
    tps = 0
    Z.lastPoll = t
    lastStatus = 0                                      -- force a heartbeat so the client sees paused=true
    return Z.tick()
end

Z.handlers.OnTickEvenPaused = function()
    local t = Z.now()
    Z.lastTickEvenPaused = t
    if t - (Z.lastPausedPoll or 0) < PAUSED_POLL then return end
    Z.lastPausedPoll = t
    Z.poll()
end
for ev, fn in pairs(Z.handlers) do
    if Events[ev] then Events[ev].Add(fn) else print("[ZomboidMCP] no such event: " .. ev) end
end

---------------------------------------------------------------- scripts (persistent hot-loaded Lua)
-- A server script is a Lua file in the Lua cache dir, remembered in ModData so it is re-run on every bridge load.
-- Other sides (the client, in Api/Visuals.lua) plug into Z.scriptSides.<side>.
local function runLuaFile(file)
    local text = readFile(file)
    if not text then error("file not found in Lua dir: " .. tostring(file)) end
    local fn, err = loadstring(text, "=" .. file)
    if not fn then error("compile " .. file .. ": " .. tostring(err)) end
    return fn()
end

local function scripts()
    local s = store()
    if type(s.scripts) ~= "table" then s.scripts = {} end
    return s.scripts
end
Z.scripts = scripts

function Z.scriptNames()
    local names = {}
    for name in pairs(scripts()) do names[#names + 1] = name end
    table.sort(names)
    return names
end

function Z.checkName(name, what)
    if type(name) ~= "string" or not name:match("^[%w_%-]+$") then
        error((what or "name") .. " must be a string matching [A-Za-z0-9_-]+")
    end
    return name
end

local function scriptFile(name)
    return "zmcp_script_" .. Z.checkName(name, "script name") .. ".lua.txt"    -- getFileWriter refuses .lua
end

function Z.loadScripts()
    local loaded, failed = {}, {}
    for _, name in ipairs(Z.scriptNames()) do
        local ok, err = pcall(runLuaFile, scripts()[name].file)
        if ok then loaded[#loaded + 1] = name
        else failed[#failed + 1] = name; Z.event("script_error", { name = name, side = "server", error = tostring(err) }) end
    end
    return loaded, failed
end

Z.scriptSides.server = {
    install = function(name, code)
        local file = scriptFile(name)
        writeFile(file, code)
        local result = runLuaFile(file)
        scripts()[name] = { file = file, installed = Z.now() }
        return { file = file, result = result }
    end,
    remove = function(name)
        if not scripts()[name] then error("no such server script: " .. tostring(name)) end
        scripts()[name] = nil
    end,
    list = function()
        local out = {}
        for _, name in ipairs(Z.scriptNames()) do
            local m = scripts()[name]
            out[#out + 1] = { name = name, file = m.file, installed = m.installed }
        end
        return J.array(out)
    end,
}

local function side(a)
    local name = a.side
    if name == nil or name == "" then name = "server" end
    local s = Z.scriptSides[name]
    if not s then
        local known = {}
        for k in pairs(Z.scriptSides) do known[#known + 1] = k end
        table.sort(known)
        error("unknown side '" .. tostring(name) .. "' (known: " .. table.concat(known, ", ") .. ")")
    end
    return name, s
end

---------------------------------------------------------------- core tools
Z.tool("ping", "Health check: {pong, version, bootId, paused, players}.", function()
    return { pong = true, version = Z.version, bootId = Z.bootId, paused = Z.paused, players = Z.playerNames() }
end)

Z.tool("run_lua_server", "Run Lua in the server Lua state via loadstring. args: {code}. Returns the chunk's return value(s), JSON-encoded.", function(a)
    local code = Z.argText(a, "code")
    local fn, err = loadstring(code, "=run_lua_server")
    if not fn then error("compile: " .. tostring(err)) end
    local res = { pcall(fn) }
    if not res[1] then error(tostring(res[2])) end
    if #res <= 2 then return res[2] end
    table.remove(res, 1)
    return res
end)

Z.tool("tools_list", "List the tools registered in the game: [{name, desc}].", function()
    local out = {}
    for _, name in ipairs(Z.toolNames()) do out[#out + 1] = { name = name, desc = Z.tools[name].desc } end
    return J.array(out)
end)

Z.tool("run_file", "Execute a Lua file from the Lua cache dir (~/Zomboid/Lua/) on the server. args: {file}. Not remembered across restarts (see script_install).", function(a)
    return runLuaFile(a.file)
end)

Z.tool("script_install", "Install or replace a persistent script: args {name, code, side? = server|client}. It runs now and again on every bridge load / server start (server) or for every player who joins (client).", function(a)
    local name = Z.checkName(a.name, "script name")
    local code = Z.argText(a, "code")
    local sideName, s = side(a)
    local res = s.install(name, code)
    Z.event("script_install", { name = name, side = sideName })
    res = res or {}
    res.name, res.side = name, sideName
    return res
end)

Z.tool("script_list", "Installed persistent scripts per side: {server = [{name, file, installed}], client = [...]}.", function()
    local out = {}
    for name, s in pairs(Z.scriptSides) do out[name] = s.list() end
    return out
end)

Z.tool("script_remove", "Forget a persistent script: args {name, side? = server|client}. Handlers it registered stay until its own cleanup runs or the next restart.", function(a)
    local name = Z.checkName(a.name, "script name")
    local sideName, s = side(a)
    s.remove(name)
    Z.event("script_remove", { name = name, side = sideName })
    return { removed = name, side = sideName }
end)

Z.tool("status", "The bridge heartbeat (zmcp_status.json), written fresh: version, bootId, paused, players, time, tools, scripts, stats.", function()
    writeStatus()
    return Z.statusDoc()
end)

---------------------------------------------------------------- go
do
    local loaded, failed = Z.loadScripts()
    Z.event("bridge_loaded", { version = Z.version, bootId = Z.bootId, nextReq = Z.nextReq, scripts = J.array(loaded), failed = J.array(failed) })
end
lastStatus = 0
safeTick()      -- answer anything already pending (a reload is also how the paused server gets polled)
