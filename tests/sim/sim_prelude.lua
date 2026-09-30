-- Mock of the Project Zomboid Lua globals used by the mod, for offline tests under a standalone Lua 5.1
-- (tests/sim/test_sim.py). Single-player semantics: isClient()/isServer() are false, ZMCP.toClients calls the
-- client directly, sendClientCommand fires OnClientCommand on the same state.
SIM = { fs = {}, out = {}, sent = {}, draws = {}, spawned = {}, now = 1000, moddata = {}, vanilla = {} }

function print(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
    SIM.out[#SIM.out + 1] = table.concat(t, "\t")
end
function require() end
function isClient() return false end
function isServer() return false end
function getTimestampMs() return SIM.now * 1000 end
function getMyDocumentFolder() return "/home/sim/Zomboid" end
function getFileSeparator() return "/" end
function ZombRand(a, b) if b then return math.floor(a + math.random() * (b - a)) end return math.floor(math.random() * a) end
function ZombRandFloat(a, b) return a + math.random() * (b - a) end
function instanceof(o, cls) return o and o.__class == cls end

-- events
Events = setmetatable({}, { __index = function(t, k)
    local e = { fns = {} }
    e.Add = function(f) e.fns[#e.fns + 1] = f end
    e.Remove = function(f) for i, g in ipairs(e.fns) do if g == f then table.remove(e.fns, i); return end end end
    rawset(t, k, e)
    return e
end })
function SIM.fire(ev, ...) for _, f in ipairs(Events[ev].fns) do f(...) end end

-- text files in the Lua dir
function getFileWriter(name, create, append)
    -- verified on 42.21: names ending in .lua or .jsonl and names without an extension are refused
    if name:match("%.lua$") or name:match("%.jsonl$") or not name:match("%.[%w]+$") then return nil end
    local w = { buf = {} }
    function w:write(s) self.buf[#self.buf + 1] = s end
    function w:close()
        local s = table.concat(self.buf)
        if append then SIM.fs[name] = (SIM.fs[name] or "") .. s else SIM.fs[name] = s end
    end
    return w
end
function getFileReader(name, create)
    local s = SIM.fs[name]
    if not s then if create then SIM.fs[name] = ""; s = "" else return nil end end
    local lines, i = {}, 0
    for l in (s .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
    if s:sub(-1) == "\n" then lines[#lines] = nil end
    local r = {}
    function r:readLine() i = i + 1; return lines[i] end
    function r:close() end
    return r
end
-- binary files
local binOut
function getFileOutput(name)
    binOut = { name = name, bytes = {} }
    function binOut:writeByte(b) self.bytes[#self.bytes + 1] = string.char(b) end
    return binOut
end
function endFileOutput()
    if binOut then SIM.fs[binOut.name] = table.concat(binOut.bytes); binOut = nil end
end

-- textures
local function pngSize(s)
    if s:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
    local function u32(o) local a, b, c, d = s:byte(o, o + 3); return ((a * 256 + b) * 256 + c) * 256 + d end
    return u32(17), u32(21)
end
local function texture(name, w, h) return { getWidth = function() return w end, getHeight = function() return h end, getName = function() return name end, __tex = true } end
function getTexture(path)
    local prefix = "/home/sim/Zomboid/Lua/"
    if path:sub(1, #prefix) == prefix then
        local s = SIM.fs[path:sub(#prefix + 1)]
        if not s then return nil end
        local w, h = pngSize(s)
        if not w then return nil end
        return texture(path, w, h)
    end
    local v = SIM.vanilla[path]
    if v then return texture(path, v[1], v[2]) end
    return nil
end
Texture = { getSharedTexture = function() return nil end }
function getItemTex() return nil end
SIM.items = { ["Base.Banana"] = { icon = "Banana" }, ["Base.Apple"] = { icon = "Apple" } }
function getScriptManager()
    return { getItem = function(_, t) local it = SIM.items[t]; if it then return { getIcon = function() return it.icon end } end return nil end }
end
function instanceItem(t)
    local it = SIM.items[t]
    if not it then return nil end
    return { getTex = function() return texture("Item_" .. it.icon, 32, 32) end }
end

-- world
ModData = { getOrCreate = function(k) SIM.moddata[k] = SIM.moddata[k] or {}; return SIM.moddata[k] end }
function getOnlinePlayers() return nil end
local function newPlayer(user, x, y, z)
    local parts = {}
    for i = 1, 3 do
        parts[i] = { RestoreToFullHealth = function() end, getStiffness = function() return 0 end, SetInfected = function() end,
            SetFakeInfected = function() end, setInfectedWound = function() end, setWoundInfectionLevel = function() end, getType = function() return i end }
    end
    local p = { user = user, x = x, y = y, z = z, halo = nil, said = nil, healed = 0, cured = 0 }
    p.getUsername = function() return p.user end
    p.getX = function() return p.x end
    p.getY = function() return p.y end
    p.getZ = function() return p.z end
    p.isDead = function() return false end
    p.getDescriptor = function() return { getForename = function() return "Cool" end, getSurname = function() return "Jesus" end } end
    p.getBodyDamage = function()
        return { getOverallBodyHealth = function() return 100 end, getBodyParts = function() return { size = function() return #parts end, get = function(_, i) return parts[i + 1] end } end,
            RestoreToFullHealth = function() p.healed = p.healed + 1 end, setOverallBodyHealth = function() end,
            setInfected = function(_, v) p.cured = p.cured + 1 end, setIsFakeInfected = function() end, setInfectionTime = function() end,
            setInfectionMortalityDuration = function() end }
    end
    p.getStats = function() return { set = function() return true end } end
    p.getFitness = function() return { removeStiffnessValue = function() end } end
    p.setHaloNote = function(_, text) p.halo = text end
    p.Say = function(_, text) p.said = text end
    p.teleportTo = function(_, x, y, z) p.x, p.y, p.z = x, y, z end
    return p
end
SIM.newPlayer = newPlayer
SIM.player = newPlayer("niach", 6078, 5382, 0)
function getSpecificPlayer(i) if i == 0 then return SIM.player end end
function getPlayer() return SIM.player end
function sendClientCommand(p, module, cmd, args)
    SIM.sent[#SIM.sent + 1] = { module = module, cmd = cmd, args = args }
    SIM.fire("OnClientCommand", module, cmd, p, args)
end
function sendServerCommand() error("sendServerCommand must not be called in single player") end
function sendPlayerStatsChange() end
BodyPartType = { ToString = function() return "Hand_L" end }
CharacterStat = { PAIN = 1, PANIC = 2, STRESS = 3, FATIGUE = 4, ENDURANCE = 5, HUNGER = 6, THIRST = 7, FOOD_SICKNESS = 8 }
function getCell()
    return { getGridSquare = function(_, x, y, z)
        if math.abs(x - SIM.player.x) > 50 or math.abs(y - SIM.player.y) > 50 then return nil end
        return { AddWorldInventoryItem = function(_, item, ox, oy, oz)
                local rec = { item = item, x = x, y = y, z = z, ox = ox, oy = oy }
                SIM.spawned[#SIM.spawned + 1] = rec
                return { setWorldStaticModel = function(_, n) rec.model = n end, setWorldYRotation = function(_, r) rec.yrot = r end }
            end,
            getMovingObjects = function() return { size = function() return 0 end } end }
    end }
end
function getGameTime() return { getTimeOfDay = function() return 12 end, getDay = function() return 1 end, getMonth = function() return 6 end, getYear = function() return 1993 end } end
function getCore() return { getZoom = function() return SIM.zoom or 1 end, getScreenWidth = function() return 1920 end, getScreenHeight = function() return 1080 end } end
function isoToScreenX(pn, x, y, z) return (x - y) * 32 / (SIM.zoom or 1) + 960 end
function isoToScreenY(pn, x, y, z) return ((x + y) * 16 - z * 96) / (SIM.zoom or 1) + 540 end
UIFont = { Small = "Small", Medium = "Medium", Large = "Large", Title = "Title" }
function getTextManager() return { MeasureStringX = function(_, f, s) return #s * 7 end, getFontHeight = function() return 16 end } end

-- UI
ISUIElement = {}
ISUIElement.__index = ISUIElement
function ISUIElement:derive(name) local c = { Type = name }; c.__index = c; setmetatable(c, { __index = ISUIElement }); return c end
function ISUIElement:new(x, y, w, h) local o = setmetatable({ x = x, y = y, w = w, h = h, javaObject = { setConsumeMouseEvents = function(_, v) SIM.consume = v end } }, self); return o end
function ISUIElement:initialise() end
function ISUIElement:instantiate() if self.createChildren then self:createChildren() end end
function ISUIElement:addToUIManager() SIM.uiAdded = (SIM.uiAdded or 0) + 1 end
function ISUIElement:backMost() end
function ISUIElement:getWidth() return self.w end
function ISUIElement:getHeight() return self.h end
function ISUIElement:setWidth(w) self.w = w end
function ISUIElement:setHeight(h) self.h = h end
local function rec(kind) return function(self, ...) SIM.draws[#SIM.draws + 1] = { kind = kind, ... } end end
ISUIElement.drawTextureScaled = rec("tex")
ISUIElement.drawRect = rec("rect")
ISUIElement.drawRectBorder = rec("border")
ISUIElement.drawLine2 = rec("line")
ISUIElement.drawText = rec("text")
ISUIElement.drawTextCentre = rec("textc")

-- helpers for tests
function SIM.tick(n, dt)
    for _ = 1, (n or 1) do SIM.now = SIM.now + (dt or 0.1); SIM.fire("OnTick") end
end
function SIM.render() SIM.draws = {}; ZMCPClient.overlay:render(); return SIM.draws end
function SIM.find(list, kind, field, value)
    local out = {}
    for _, m in ipairs(list) do if m[field or "cmd"] == value and (not kind or m.kind == kind) then out[#out + 1] = m end end
    return out
end

-- input + 3D models
function isKeyDown(k) return SIM.keys and SIM.keys[k] or false end
function isMouseButtonDown(b) return false end
function getMouseX() return SIM.mx or 0 end
function getMouseY() return SIM.my or 0 end
function ISUIElement:bringToTop() SIM.onTop = true end
local backMost = ISUIElement.backMost
function ISUIElement:backMost() SIM.onTop = false end
SIM.models = {}
ModelScript = { new = function()
    local ms = {}
    function ms:setModule(m) ms.module = m end
    function ms:InitLoadPP(name) ms.name = name end
    function ms:Load(name, def)
        if not ms.module then error("NPE: no module") end
        local mesh = def:match("mesh = ([^,]+),")
        if not mesh or not mesh:find("media/") then error("Failed to load asset " .. tostring(mesh)) end
        local rel = mesh:gsub("^/home/sim/Zomboid/Lua/", "")
        if not SIM.fs[rel] then error("mesh file missing: " .. rel) end
        ms.def = def
    end
    return ms
end }
local sm = getScriptManager
function getScriptManager()
    local m = sm()
    m.getModule = function(_, name) return { name = name } end
    m.addModelScript = function(_, ms) SIM.models[ms.name] = ms end
    return m
end

-- 3D scene layer (zombie.vehicles.UI3DScene): orthographic iso view, 1 scene unit = 45.2548 px at zoom 1,
-- i.e. one world tile along x when the entity code calibrates k = 1 at zoom 1 (32 px = 45.2548 * cos 45)
SIM.scene = nil
local function vec3(x, y, z)
    local v = { x = x or 0, y = y or 0, z = z or 0 }
    function v:set(a, b, c) if b == nil then b, c = a, a end self.x, self.y, self.z = a, b, c; return self end
    return v
end
UI3DScene = { new = function(tbl)
    local J = { objects = {}, calls = {}, zoom = 1, view = nil, rot = nil, S = 45.2548 }
    SIM.scene = J
    for _, m in ipairs({ "setX", "setY", "setWidth", "setHeight", "setAnchorLeft", "setAnchorRight", "setAnchorTop", "setAnchorBottom" }) do J[m] = function() end end
    function J:setConsumeMouseEvents(v) SIM.consume3d = v end
    function J:getAbsoluteX() return 0 end
    function J:getAbsoluteY() return 0 end
    function J:sceneToUIX(x, y, z) return 960 + (x - z) * 0.70711 * self.S end
    function J:sceneToUIY(x, y, z) return 540 + (x + z) * 0.35355 * self.S - y * 0.86603 * self.S end
    local function obj(name) local o = J.objects[name]; if not o then error("no scene object " .. tostring(name)) end return o end
    function J:fromLua0(c) self.calls[#self.calls + 1] = c; if c == "getView" then return self.view end end
    function J:fromLua1(c, a)
        self.calls[#self.calls + 1] = c
        if c == "setView" then self.view = a
        elseif c == "setZoom" then self.zoom = a
        elseif c == "removeObject" then self.objects[a] = nil
        elseif c == "getObjectExists" then return self.objects[a] ~= nil
        elseif c == "getObjectTranslation" then return obj(a).t
        elseif c == "getObjectRotation" then return obj(a).r
        elseif c == "getObjectScale" then return obj(a).s
        elseif c == "setGizmoVisible" then self.gizmo = a
        elseif c == "setDrawGrid" then self.grid = a end
    end
    function J:fromLua2(c, a, b)
        self.calls[#self.calls + 1] = c
        if c == "createModel" then
            if not SIM.models[b] and not SIM.vanillaModels[b] then error("Failed to load asset " .. tostring(b)) end
            self.objects[a] = { model = b, t = vec3(), r = vec3(), s = vec3(1, 1, 1), visible = true }
        elseif c == "setObjectVisible" then obj(a).visible = b end
    end
    function J:fromLua3(c, a, b, d) self.calls[#self.calls + 1] = c; if c == "setViewRotation" then self.rot = { a, b, d } end end
    function J:fromLua4(c) self.calls[#self.calls + 1] = c end
    return J
end }
SIM.vanillaModels = { RadioBlue_Ground = true }
-- inverse of the isoToScreen mocks above (camera centred on world 0,0 at screen 960,540)
function screenToIsoX(pn, u, v, z)
    local zoom = SIM.zoom or 1
    local A, B = (u - 960) * zoom / 32, (v - 540) * zoom / 16 + z * 6
    return (A + B) / 2
end
function screenToIsoY(pn, u, v, z)
    local zoom = SIM.zoom or 1
    local A, B = (u - 960) * zoom / 32, (v - 540) * zoom / 16 + z * 6
    return (B - A) / 2
end
function ISUIElement:getAbsoluteX() return self.x end
function ISUIElement:getAbsoluteY() return self.y end
-- ---------------------------------------------------------------- scenes (ZOM-10): puppets, tiles, lights, climate
-- fake zombies from addZombiesInOutfit walk one tile per tick towards their path target
SIM.zombies = {}
SIM.zombieSpeed = 1
SIM.tiles = {}        -- "x,y,z" -> list of tile objects
SIM.lights = {}
SIM.sounds = {}
SIM.weather = {}
local function javaList(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end
SIM.javaList = javaList
SIM.player.__class = "IsoPlayer"
SIM.player.setBlockMovement = function(_, v) SIM.player.blocked = v end
local oldNewPlayer = SIM.newPlayer
SIM.newPlayer = function(...)
    local p = oldNewPlayer(...)
    p.__class = "IsoPlayer"
    p.setBlockMovement = function(_, v) p.blocked = v end
    return p
end
local zid = 0
function addZombiesInOutfit(x, y, z, n, outfit, femaleChance)
    local out = {}
    for _ = 1, n do
        zid = zid + 1
        local zed = { __class = "IsoZombie", x = x + 0.5, y = y + 0.5, z = z, outfit = outfit, id = zid, useless = false, dead = false, removed = false, said = {}, paths = 0 }
        zed.getX = function() return zed.x end
        zed.getY = function() return zed.y end
        zed.getZ = function() return zed.z end
        zed.getID = function() return zed.id end
        zed.getOnlineID = function() return -1 end
        zed.isDead = function() return zed.dead end
        zed.setUseless = function(_, v) zed.useless = v end
        zed.isUseless = function() return zed.useless end
        zed.setWalkType = function(_, w) zed.walk = w end
        zed.getOutfitName = function() return zed.outfit end
        zed.pathToLocation = function(_, tx, ty, tz) zed.target = { tx + 0.5, ty + 0.5 }; zed.paths = zed.paths + 1 end
        zed.pathToLocationF = function(_, tx, ty, tz) zed.target = { tx, ty }; zed.paths = zed.paths + 1 end
        zed.faceLocationF = function(_, fx, fy) zed.facing = { fx, fy }; return true end
        zed.Say = function(_, text) zed.said[#zed.said + 1] = text end
        zed.removeFromWorld = function() zed.removed = true end
        zed.removeFromSquare = function() end
        zed.setAttackedBy = function() end
        zed.Kill = function() zed.dead = true end
        SIM.zombies[#SIM.zombies + 1] = zed
        out[#out + 1] = zed
    end
    return javaList(out)
end
function SIM.stepZombies()
    for _, zed in ipairs(SIM.zombies) do
        if zed.target and not zed.dead and not zed.removed then
            local dx, dy = zed.target[1] - zed.x, zed.target[2] - zed.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d <= SIM.zombieSpeed then zed.x, zed.y = zed.target[1], zed.target[2]; zed.target = nil
            else zed.x, zed.y = zed.x + dx / d * SIM.zombieSpeed, zed.y + dy / d * SIM.zombieSpeed end
        end
    end
end
local oldTick = SIM.tick
function SIM.tick(n, dt)
    for _ = 1, (n or 1) do oldTick(1, dt); SIM.stepZombies() end
end

-- tile objects on squares
IsoObject = { new = function(sq, sprite, name)
    local o = { __class = "IsoObject", sprite = sprite, name = name }
    o.getSprite = function() return { getName = function() return o.sprite end } end
    o.getSpriteName = function() return o.sprite end
    o.getName = function() return o.name end
    o.getObjectName = function() return "IsoObject" end
    o.getObjectIndex = function() return 0 end
    return o
end }
local oldGetCell = getCell
function getCell()
    local cell = oldGetCell()
    local oldGS = cell.getGridSquare
    cell.getGridSquare = function(_, x, y, z)
        local sq = oldGS(_, x, y, z)
        if not sq then return nil end
        local key = x .. "," .. y .. "," .. z
        SIM.tiles[key] = SIM.tiles[key] or {}
        sq.getX = function() return x end
        sq.getY = function() return y end
        sq.getZ = function() return z end
        sq.getObjects = function() return javaList(SIM.tiles[key]) end
        sq.getFloor = function() for _, o in ipairs(SIM.tiles[key]) do if o.floor then return o end end return nil end
        sq.transmitAddObjectToSquare = function(_, o) table.insert(SIM.tiles[key], o) end
        sq.transmitRemoveItemFromSquare = function(_, o)
            for i, v in ipairs(SIM.tiles[key]) do if v == o then table.remove(SIM.tiles[key], i); return end end
        end
        return sq
    end
    cell.addLamppost = function(_, x, y, z, r, g, b, rad)
        local l = { x = x, y = y, z = z, r = r, g = g, b = b, radius = rad }
        SIM.lights[#SIM.lights + 1] = l
        return l
    end
    cell.removeLamppost = function(_, l, y, z)
        for i, v in ipairs(SIM.lights) do
            if v == l or (type(l) == "number" and v.x == l and v.y == y and v.z == z) then table.remove(SIM.lights, i); return end
        end
    end
    cell.getZombieList = function() return javaList(SIM.zombies) end
    return cell
end
function playServerSound(name, sq) SIM.sounds[#SIM.sounds + 1] = { name = name, x = sq and sq:getX(), server = true } end
function getSoundManager()
    return { playUISound = function(_, name) SIM.sounds[#SIM.sounds + 1] = { name = name, ui = true } end,
        PlaySound = function(_, name) SIM.sounds[#SIM.sounds + 1] = { name = name } end }
end
function getClimateManager()
    return {
        transmitServerTriggerLightning = function(_, x, y, s, l, r) SIM.weather[#SIM.weather + 1] = { lightning = { x, y } } end,
        transmitServerStartRain = function(_, f) SIM.weather[#SIM.weather + 1] = { rain = f } end,
        transmitServerTriggerStorm = function(_, f) SIM.weather[#SIM.weather + 1] = { storm = f } end,
        transmitServerStopWeather = function() SIM.weather[#SIM.weather + 1] = { clear = true } end,
        transmitServerStopRain = function() end,
        getRainIntensity = function() return 0 end,
    }
end
