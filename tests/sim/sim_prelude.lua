-- Mock of the Project Zomboid Lua globals used by the mod, for offline tests under a standalone Lua 5.1
-- (tests/sim/test_sim.py). Single-player semantics: isClient()/isServer() are false, ZMCP.toClients calls the
-- client directly, sendClientCommand fires OnClientCommand on the same state.
SIM = { fs = {}, out = {}, sent = {}, draws = {}, spawned = {}, now = 1000, moddata = {}, vanilla = {}, clientCmds = {} }

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
local rnd = math.random     -- captured: the test removes math.random afterwards, like the single-player state
function ZombRand(a, b) if b then return math.floor(a + rnd() * (b - a)) end return math.floor(rnd() * a) end
function ZombRandFloat(a, b) return a + rnd() * (b - a) end
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
    if not (name:match("%.txt$") or name:match("%.json$") or name:match("%.log$")) then return nil end   -- .lua, .jsonl, .b64, no extension: refused
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
SIM.carrierTypes = { ["Base.TirePiece"] = true }
-- instanceItem(type): a detached InventoryItem (nil for unknown types); sq:AddWorldInventoryItem(item, ...) puts it down
function instanceItem(t)
    local it = SIM.items[t]
    if not it and not SIM.carrierTypes[t] then return nil end
    local item = SIM.newItem(t)
    item.getTex = function() if it then return texture("Item_" .. it.icon, 32, 32) end return nil end
    return item
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
-- world: persistent mock squares (tile objects + world items), sprites with property flags (IsoSpriteManager,
-- IsoFlagType, IsoObject) the way Api/Objects.lua, Api/Collision.lua and the model placements use them.
-- A square's has(flag) merges its objects' sprite flags like IsoGridSquare.RecalcProperties does.
SIM.squares = {}
SIM.itemSeq = 0
function jlist(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end, items = t,
        indexOf = function(_, v) for i, x in ipairs(t) do if x == v then return i - 1 end end return -1 end }
end
SIM.jlist = jlist
IsoFlagType = setmetatable({}, { __index = function(t, k) local f = { name = k }; rawset(t, k, f); return f end })
local function flagName(f) if type(f) == "table" then return f.name end return tostring(f) end
local function newProps()
    local p = { flags = {} }
    function p:set(f, v) self.flags[flagName(f)] = v == nil and true or v end
    function p:unset(f) self.flags[flagName(f)] = nil end
    function p:has(f) return self.flags[flagName(f)] ~= nil end
    function p:CreateKeySet() end
    return p
end
local function newSprite(name, id)
    local sp = { name = name, id = id or -1, props = newProps() }
    sp.getName = function() return sp.name end
    sp.setName = function(_, n) sp.name = n end
    sp.getID = function() return sp.id end
    sp.getProperties = function() return sp.props end
    return sp
end
SIM.sprites = { named = {}, ints = {} }
IsoSpriteManager = { instance = {} }
local ISM = IsoSpriteManager.instance
-- getSprite(String) creates a blank sprite for unknown names (the engine does too); getSprite(int) does not.
-- The sim treats an unknown name as a vanilla tile it does not list (named, id -1: IsoObject.new(sq, 'graffiti_01_3')
-- in the tests). AddSprite, like the engine's, never sets IsoSprite.name: only the tile definitions (SIM.tile) do.
function ISM:getSprite(key)
    if type(key) == "number" then return SIM.sprites.ints[key] end
    local sp = SIM.sprites.named[key]
    if not sp then sp = newSprite(key, -1); SIM.sprites.named[key] = sp end
    return sp
end
function ISM:AddSprite(name, id)
    local sp = SIM.sprites.named[name]
    if sp then return sp end
    sp = newSprite(nil, id)
    SIM.sprites.named[name] = sp
    if id then SIM.sprites.ints[id] = sp end
    return sp
end
function ISM:getNamedMap() return { containsKey = function(_, k) return SIM.sprites.named[k] ~= nil end } end
-- a vanilla tile as IsoWorld.LoadTileDefinitions makes it: registered with an id AND named
function SIM.tile(name, id) local sp = ISM:AddSprite(name, id); sp:setName(name); return sp end
-- a couple of vanilla sprites the tests may place
SIM.tile("walls_exterior_wooden_01_2", 1048576 + 2):getProperties():set(IsoFlagType.WallN)
ISM:AddSprite("walls_exterior_wooden_01_2"):getProperties():set(IsoFlagType.collideN)
SIM.tile("floors_exterior_natural_01_0", 1048576 + 100)
IsoObject = { new = function(sq, spriteName, name)
    local o = { __class = "IsoObject", sq = sq, spriteName = spriteName, name = name, modData = {} }
    o.sprite = ISM:getSprite(spriteName)
    o.getSprite = function() return o.sprite end
    o.getSpriteName = function() return o.spriteName end
    o.getName = function() return o.name end
    o.getObjectName = function() return "IsoObject" end
    o.getProperties = function() return o.sprite.props end
    o.getModData = function() return o.modData end
    o.getObjectIndex = function() for i, x in ipairs(sq.objects) do if x == o then return i - 1 end end return -1 end
    o.getSquare = function() return sq end
    return o
end }
-- the chunk save of one object (IsoObject.save -> WorldDictionary.getIdForSpriteName(spriteName)): a registered
-- sprite (id >= 0, not 20000000) without a name throws the NullPointerException that aborts the whole chunk save
-- (ServerChunkLoader$SaveChunkThread); returns what would be written (the id, or the name as a string)
function SIM.saveObject(o)
    local spn = o.getSpriteName and o.getSpriteName() or nil
    if spn == nil then return -1 end
    local sp = SIM.sprites.named[spn]
    if sp and sp.id >= 0 and sp.id ~= 20000000 then
        if sp.name == nil then error("NullPointerException: sprite.name is null (DictionaryData.getIdForSpriteName: " .. spn .. ")") end
        if sp.name == spn then return sp.id end
    end
    return spn
end
function SIM.saveSquare(sq) local n = 0; for _, o in ipairs(sq.objects) do SIM.saveObject(o); n = n + 1 end return n end
-- an object loaded from a save: the engine resolves the sprite by its numeric id and then by the sprite's NAME
-- (DictionaryData.getSpriteNameFromID returns IsoSprite.name, null for a nameless sprite: the object loses it)
function SIM.loadObject(sq, spriteId, name)
    local sp = ISM:getSprite(spriteId)
    if not sp or sp.name == nil then return nil end
    local o = IsoObject.new(sq, sp.name, name)
    sq.objects[#sq.objects + 1] = o
    return o
end
-- a detached item (instanceItem); SIM.addWorldItem puts it on a square
function SIM.newItem(itemType, id)
    SIM.itemSeq = SIM.itemSeq + 1
    local rec = { item = itemType, id = id or SIM.itemSeq, modData = {}, modelSets = 0, transmits = 0 }
    local item = { rec = rec, __class = "InventoryItem" }
    item.getID = function() return rec.id end
    item.getFullType = function() return rec.item end
    item.getType = function() return (rec.item:match("%.(.*)$") or rec.item) end
    item.getName = function() return item.getType() end
    item.getDisplayName = function() return item.getType() end
    item.getWorldStaticModel = function() return rec.model end
    item.setWorldStaticModel = function(_, n) rec.model = n; rec.modelSets = rec.modelSets + 1 end
    item.setWorldYRotation = function(_, r) rec.yrot = r end
    item.getWorldYRotation = function() return rec.yrot or 0 end
    item.setWorldZRotation = function(_, r) rec.yaw = r; rec.yawSets = (rec.yawSets or 0) + 1 end
    item.getWorldZRotation = function() return rec.yaw or -1 end
    item.getModData = function() return rec.modData end
    return item
end
-- AddWorldInventoryItem(type or item, ox, oy, oz): the engine sends the new world item to the clients once
-- (IsoWorldInventoryObject.transmitCompleteItemToClients = an AddItemToMap packet); rec.sentModel is the model name
-- that send carried. A second transmitCompleteItemToClients adds ANOTHER copy on every client (rec.transmits counts
-- those duplicates, verified live 2026-09-30). The IsoWorldInventoryObject constructor zeroes X/Y rotation and
-- randomizes a negative Z rotation (the yaw); rec.sentYaw is the yaw that send carried.
-- Offsets: setOffX/Y/Z only set the field (rec.ox/oy/oz); setOffset(x, y, z) would also sync (rec.offsetSyncs);
-- invalidateRenderChunkLevel on the world object counts redraw requests (rec.redraws).
function SIM.addWorldItem(sq, itemOrType, ox, oy, oz, id)
    local item = type(itemOrType) == "table" and itemOrType or SIM.newItem(itemOrType, id)
    local rec = item.rec
    rec.x, rec.y, rec.z, rec.ox, rec.oy, rec.oz = sq.x, sq.y, sq.z, ox, oy, oz
    rec.yrot = nil
    if rec.yaw == nil or rec.yaw < 0 then rec.yaw = 123 end
    rec.sentModel = rec.model
    rec.sentYaw = rec.yaw
    rec.redraws = 0
    SIM.spawned[#SIM.spawned + 1] = rec
    local wo = { __class = "IsoWorldInventoryObject", item = item, rec = rec }
    wo.getItem = function() return item end
    wo.getSquare = function() return sq end
    wo.transmitCompleteItemToClients = function() rec.transmits = rec.transmits + 1 end
    wo.getOffX = function() return rec.ox end
    wo.getOffY = function() return rec.oy end
    wo.getOffZ = function() return rec.oz end
    wo.setOffX = function(_, v) rec.ox = v end
    wo.setOffY = function(_, v) rec.oy = v end
    wo.setOffZ = function(_, v) rec.oz = v end
    wo.setOffset = function(_, x, y, z) rec.ox, rec.oy, rec.oz = x, y, z; rec.offsetSyncs = (rec.offsetSyncs or 0) + 1 end
    wo.invalidateRenderChunkLevel = function(_, flags) rec.redraws = rec.redraws + 1; rec.lastDirty = flags end
    item.getWorldItem = function() return wo end
    rec.wo = wo
    sq.worldObjects[#sq.worldObjects + 1] = wo
    return item
end
function SIM.square(x, y, z)
    x, y, z = math.floor(x), math.floor(y), math.floor(z or 0)
    local k = x .. "," .. y .. "," .. z
    local sq = SIM.squares[k]
    if sq then return sq end
    sq = { x = x, y = y, z = z, objects = {}, worldObjects = {}, floor = nil, recalcs = 0, invalidated = 0 }
    sq.getX = function() return sq.x end
    sq.getY = function() return sq.y end
    sq.getZ = function() return sq.z end
    sq.getObjects = function() return jlist(sq.objects) end
    sq.getWorldObjects = function() return jlist(sq.worldObjects) end
    sq.getFloor = function() return sq.floor end
    sq.getMovingObjects = function() return jlist({}) end
    sq.getVehicleContainer = function() return nil end
    -- transmitAddObjectToSquare(obj, index): -1 appends; 0 puts the object first (a floor sprite there becomes the floor)
    sq.transmitAddObjectToSquare = function(_, o, index)
        if index == 0 then table.insert(sq.objects, 1, o); if o.spriteName and o.spriteName:find("^floors_") then sq.floor = o end
        else sq.objects[#sq.objects + 1] = o end
        sq.recalcs = sq.recalcs + 1
    end
    sq.transmitRemoveItemFromSquare = function(_, o)
        if o == sq.floor then sq.floor = nil end
        for i, x in ipairs(sq.objects) do if x == o then table.remove(sq.objects, i); sq.recalcs = sq.recalcs + 1; return 1 end end
        for i, x in ipairs(sq.worldObjects) do if x == o then table.remove(sq.worldObjects, i); return 1 end end
        return 0
    end
    sq.RecalcAllWithNeighbours = function() sq.recalcs = sq.recalcs + 1 end
    sq.invalidateRenderChunkLevel = function(_, flags) sq.invalidated = sq.invalidated + 1; sq.lastDirty = flags end
    sq.AddWorldInventoryItem = function(_, itemOrType, ox, oy, oz) return SIM.addWorldItem(sq, itemOrType, ox, oy, oz) end
    -- addFloor(sprite): the vanilla floor builder (ISWoodenFloor): replaces the floor object, returns it, and sends
    -- it to the clients itself; an extra transmitCompleteItemToClients would add a DUPLICATE floor on every client
    -- (sq.floorDuplicates counts those, verified live 2026-09-30)
    sq.addFloor = function(_, spriteName)
        local o = IsoObject.new(sq, spriteName)
        o.transmitCompleteItemToClients = function() sq.floorDuplicates = (sq.floorDuplicates or 0) + 1 end
        if sq.floor then for i, x in ipairs(sq.objects) do if x == sq.floor then table.remove(sq.objects, i); break end end end
        table.insert(sq.objects, 1, o)
        sq.floor = o
        sq.recalcs = sq.recalcs + 1
        return o
    end
    sq.getChunk = function() return { invalidateRenderChunkLevels = function() end } end
    sq.has = function(_, f) for _, o in ipairs(sq.objects) do if o.sprite.props:has(f) then return true end end return false end
    sq.isSolid = function() return sq:has(IsoFlagType.solid) end
    sq.isSolidTrans = function() return sq:has(IsoFlagType.solidtrans) end
    SIM.squares[k] = sq
    return sq
end
function SIM.loadSquare(x, y, z) local sq = SIM.square(x, y, z); SIM.fire("LoadGridsquare", sq); return sq end
function getCell()
    return { getGridSquare = function(_, x, y, z)
            if math.abs(x - SIM.player.x) > 50 or math.abs(y - SIM.player.y) > 50 then return nil end
            if z and z > 0 and not SIM.squares[math.floor(x) .. "," .. math.floor(y) .. "," .. math.floor(z)] then return nil end   -- upper levels exist only once created
            return SIM.square(x, y, z)
        end,
        -- createNewGridSquare(x, y, z, connect): what vanilla building does for upper-floor squares that do not exist yet
        createNewGridSquare = function(_, x, y, z) SIM.created = (SIM.created or 0) + 1; return SIM.square(x, y, z) end,
        getZombieList = function() return jlist({}) end, getVehicles = function() return jlist({}) end }
end
function getGameTime() return { getTimeOfDay = function() return 12 end, getDay = function() return 1 end, getMonth = function() return 6 end, getYear = function() return 1993 end } end
function getCore() return { getZoom = function() return SIM.zoom or 1 end, getScreenWidth = function() return 1920 end, getScreenHeight = function() return 1080 end } end
-- IsoUtils.XToScreen is (x - y) * 32 * Core.tileScale (2 with the 2x textures of a 4K client), YToScreen likewise
function isoToScreenX(pn, x, y, z) return (x - y) * 32 * (SIM.tileScale or 1) / (SIM.zoom or 1) + 960 end
function isoToScreenY(pn, x, y, z) return ((x + y) * 16 - z * 96) * (SIM.tileScale or 1) / (SIM.zoom or 1) + 540 end
UIFont = { Small = "Small", Medium = "Medium", Large = "Large", Title = "Title" }
function getTextManager() return { MeasureStringX = function(_, f, s) return #s * 7 end, getFontHeight = function() return 16 end } end

-- UI
ISUIElement = {}
ISUIElement.__index = ISUIElement
function ISUIElement:derive(name) local c = { Type = name }; c.__index = c; setmetatable(c, { __index = ISUIElement }); return c end
function ISUIElement:new(x, y, w, h) local o = setmetatable({ x = x, y = y, w = w, h = h, javaObject = { setConsumeMouseEvents = function(_, v) SIM.consume = v end } }, self); return o end
function ISUIElement:initialise() end
function ISUIElement:instantiate() if self.createChildren then self:createChildren() end end
function ISUIElement:addToUIManager() SIM.uiAdded = (SIM.uiAdded or 0) + 1; SIM.uiList[self.javaObject] = true end
function ISUIElement:removeFromUIManager() SIM.uiList[self.javaObject] = nil end
function ISUIElement:isRemoved() return not SIM.uiList[self.javaObject] end
SIM.uiList = SIM.uiList or {}
UIManager = { getUI = function() return { contains = function(_, jo) return SIM.uiList[jo] == true end } end }
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
    local zoom = (SIM.zoom or 1) / (SIM.tileScale or 1)
    local A, B = (u - 960) * zoom / 32, (v - 540) * zoom / 16 + z * 6
    return (A + B) / 2
end
function screenToIsoY(pn, u, v, z)
    local zoom = (SIM.zoom or 1) / (SIM.tileScale or 1)
    local A, B = (u - 960) * zoom / 32, (v - 540) * zoom / 16 + z * 6
    return (B - A) / 2
end
function ISUIElement:getAbsoluteX() return self.x end
function ISUIElement:getAbsoluteY() return self.y end
-- ---------------------------------------------------------------- scenes (ZOM-10): puppets, tiles, lights, climate
-- fake zombies from addZombiesInOutfit walk one tile per tick towards their path target
SIM.zombies = {}
SIM.zombieSpeed = 1
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

local oldGetCell = getCell
function getCell()
    local cell = oldGetCell()
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
