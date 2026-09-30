-- Zomboid MCP: invisible collision sprites, registered on the SERVER and on EVERY CLIENT (shared Lua).
-- Custom 3D models (model_place / entity3d_*) have no collision of their own, so Api/Collision.lua places plain
-- IsoObjects whose sprite carries the vanilla movement / sight flags (docs/ENGINE_NOTES.md "Collision blockers"):
--   solid       {invisible, solid}                     blocks walking, pathing and line of sight (a full square)
--   solidtrans  {invisible, solidtrans}                blocks walking and pathing, see-through (rails, chasm edges)
--   wall_n      {invisible, WallN, collideN, cutN}     an invisible wall on the square's north edge
--   wall_w      {invisible, WallW, collideW, cutW}     ... on the west edge
--   wall_nw     {invisible, WallNW, collideN, cutN, collideW, cutW}   both edges (a corner)
-- The flag sets copy what IsoWorld.LoadTileDefinitions derives for vanilla tiles ("WallN" => collideN + cutN, ...);
-- IsoGridSquare.RecalcProperties / CalculateCollide / CalculateVisionBlocked and the zombie path map
-- (PolygonalMap2.squareChanged, called from AddTileObject) read exactly these flags, and IsoObject.render skips
-- sprites with the `invisible` flag.
--
-- Persistence: IsoObject.save writes the sprite id that WorldDictionary finds for the object's sprite name (and the
-- load maps it back to IsoSprite.name), so every sprite gets a NAME (setName) and a FIXED id far above the
-- vanilla range (IsoWorld.getSpriteID: tileset 460 ends near 121 million; ours start at "tileset 8000") and is
-- re-registered whenever the sprite manager is (re)built: at file load, OnLoadedTileDefinitions (every world
-- init, before chunks load), OnGameStart (clients / SP host) and OnServerStarted (dedicated server). Registration
-- is idempotent (an existing named sprite is reused and only gets its flags set again).
-- Hot-reload safe: handlers are kept in ZMCPCollision.handlers and removed before they are re-added.
ZMCPCollision = ZMCPCollision or {}
local CS = ZMCPCollision
CS.version = "0.1.0"
CS.PREFIX = "zmcp_collision_"
CS.OBJECT_NAME = "ZMCP_collision"          -- IsoObject name: world_query / remove_object find blockers by it
CS.ID_BASE = 2097676288                     -- 1048576 + (8000 - 2) * 262144: sprite id of tileset 8000, row 1, column 0
CS.KINDS = {
    solid      = { index = 0, flags = { "invisible", "solid" }, blocks = "movement, pathing, sight" },
    solidtrans = { index = 1, flags = { "invisible", "solidtrans" }, blocks = "movement, pathing (see-through)" },
    wall_n     = { index = 2, flags = { "invisible", "WallN", "collideN", "cutN" }, blocks = "north edge: movement, pathing, sight" },
    wall_w     = { index = 3, flags = { "invisible", "WallW", "collideW", "cutW" }, blocks = "west edge: movement, pathing, sight" },
    wall_nw    = { index = 4, flags = { "invisible", "WallNW", "collideN", "cutN", "collideW", "cutW" }, blocks = "north + west edges" },
}
CS.ORDER = { "solid", "solidtrans", "wall_n", "wall_w", "wall_nw" }
CS.registered = CS.registered or {}         -- kind -> sprite id once registered in this Lua state
CS.handlers = CS.handlers or {}
CS.lastError = nil

for ev, fn in pairs(CS.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
CS.handlers = {}

function CS.spriteName(kind) return CS.PREFIX .. kind end
function CS.spriteId(kind) return CS.ID_BASE + CS.KINDS[kind].index end

-- "zmcp_collision_wall_n" -> "wall_n"; nil for any other sprite name
function CS.kindOf(spriteName)
    if type(spriteName) ~= "string" then return nil end
    local kind = string.match(spriteName, "^zmcp_collision_(%a[%w_]*)$")
    if kind and CS.KINDS[kind] then return kind end
    return nil
end

function CS.isBlocker(spriteName) return CS.kindOf(spriteName) ~= nil end

-- register one kind; returns the sprite or nil, err
local function registerKind(kind)
    local def = CS.KINDS[kind]
    local name, id = CS.spriteName(kind), CS.spriteId(kind)
    local sm = IsoSpriteManager.instance
    -- AddSprite(name, id) on a known name replaces the sprite object (keeping the old id), so reuse an existing one;
    -- getSprite(name) is only safe once the name exists (for unknown names it creates a blank sprite with id -1)
    local sprite
    if sm:getNamedMap():containsKey(name) then sprite = sm:getSprite(name) else sprite = sm:AddSprite(name, id) end
    if not sprite then error("AddSprite returned nil for " .. name) end
    -- AddSprite never sets IsoSprite.name (vanilla tiles get it from LoadTileDefinitions). A registered sprite
    -- (id >= 0) without a name makes every chunk save throw (DictionaryData.getIdForSpriteName: sprite.name.equals
    -- -> NullPointerException in ServerChunkLoader$SaveChunkThread), so the chunk is never written and everything
    -- placed on it vanishes at reload; loading resolves the saved id back through sprite.name as well.
    if sprite:getName() ~= name then sprite:setName(name) end
    local props = sprite:getProperties()
    for _, flag in ipairs(def.flags) do
        local f = IsoFlagType[flag]
        if f then props:set(f) end
    end
    pcall(function() props:CreateKeySet() end)
    return sprite
end

-- Register every kind (idempotent). Returns the number of kinds registered, or nil + reason when the sprite
-- manager is not available yet (too early in the boot, or a Lua state without the engine).
function CS.register()
    if not (IsoSpriteManager and IsoSpriteManager.instance and IsoFlagType) then
        return nil, "IsoSpriteManager not available yet"
    end
    local n = 0
    for _, kind in ipairs(CS.ORDER) do
        local ok, err = pcall(registerKind, kind)
        if ok then CS.registered[kind] = CS.spriteId(kind); n = n + 1
        else CS.lastError = tostring(err); print("[ZomboidMCP] collision sprite " .. kind .. ": " .. tostring(err)) end
    end
    return n
end

-- make sure the sprites exist before an object is created from them (lazy path for tools)
function CS.ensure()
    for _, kind in ipairs(CS.ORDER) do
        if not CS.registered[kind] then return CS.register() end
    end
    return #CS.ORDER
end

function CS.info()
    local out = {}
    for _, kind in ipairs(CS.ORDER) do
        out[#out + 1] = { kind = kind, sprite = CS.spriteName(kind), id = CS.spriteId(kind), flags = CS.KINDS[kind].flags,
            blocks = CS.KINDS[kind].blocks, registered = CS.registered[kind] ~= nil }
    end
    return out
end

CS.handlers.OnLoadedTileDefinitions = function() CS.registered = {}; CS.register() end
CS.handlers.OnGameStart = function() CS.register() end
CS.handlers.OnServerStarted = function() CS.register() end
for ev, fn in pairs(CS.handlers) do if Events[ev] then Events[ev].Add(fn) end end

CS.register()      -- at file load, when the sprite manager already exists (hot reload, dev bundles)
