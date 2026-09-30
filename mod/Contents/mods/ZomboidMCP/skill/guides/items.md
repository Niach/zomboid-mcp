# Items and inventories

Legend: ✔ verified live on 42.21, ○ from the API index / vanilla Lua.

Item types are `Module.Name` strings (`Base.Banana`, `Base.Axe`, `Base.Katana`). Item **scripts** describe a type;
`InventoryItem` objects are instances. Everything here is server-side and synced unless marked.

## Find a type

```lua
-- server (or client): search item scripts by type or display name
local q, limit, out = "banana", 50, {}
q = string.lower(q)
local list = getScriptManager():getAllItems()
for i = 0, list:size() - 1 do
    local s = list:get(i)
    local full, disp = s:getFullName(), s:getDisplayName() or ""
    if string.find(string.lower(full), q, 1, true) or string.find(string.lower(disp), q, 1, true) then
        if not s:isHidden() and not s:getObsolete() and #out < limit then
            out[#out + 1] = { type = full, name = disp, category = s:getDisplayCategory(), weight = s:getActualWeight() }
        end
    end
end
return out
```

✔ `getScriptManager():FindItem("Base.Banana")` checks one type (nil when unknown). Categories: `s:getDisplayCategory()`;
food details `s:getHungerChange()` ○; weapons `s:getMaxDamage()` ○ (`api_search "Item:get"` lists them all).

## Give, take, inspect (inventories)

```lua
-- server: give two axes, then list the player's inventory by type
local p = ZMCP.player()
local script = getScriptManager():FindItem("Base.Axe")
if not script then error("unknown item") end
local inv = p:getInventory()
for _ = 1, 2 do
    local item = inv:AddItem(script:getFullName())
    sendAddItemToContainer(inv, item)                 -- ✔ required in MP, harmless in SP
end
local byType = {}
local items = inv:getItems()
for i = 0, items:size() - 1 do
    local t = items:get(i):getFullType()
    byType[t] = (byType[t] or 0) + 1
end
return { weight = inv:getContentsWeight(), items = byType }
```

- Tool: `give_item {player, item, count}` (≤ 100, weight limits ignored).
- Remove: `inv:Remove(item)` + `sendRemoveItemFromContainer(inv, item)` ○; find by type with
  `inv:getFirstTypeRecurse("Base.Axe")` ○ or loop `getItems()`.
- Equipping is client-side (`run_lua_client {player}`): `getPlayer():setPrimaryHandItem(item)` ○ or the vanilla
  `ISInventoryPaneContextMenu.equipWeapon(item, true, false, 0)`.
- Worn items: `p:getWornItems():getItems()` → `w:getLocation():getId()`, `w:getItem()`; `p:getPrimaryHandItem()`.
- Item state: `item:getCondition()` / `setCondition(n)`, `item:getModData()` (+ `item:transmitModData()` ○),
  `Food`: `getHungerChange()`, `setAge`, `DrainableComboItem`: `getUsedDelta()` / `setUsedDelta(0..1)`.
- Money, keys, maps, radios are ordinary items with their own subclasses (`api_search "InventoryItem" kind=class`).

## Items on the ground

```lua
-- server: drop 20 bananas around a tile and count what landed
local x, y, z, itemType, count, scatter = 6400, 5498, 0, "Base.Banana", 20, 3
local script = getScriptManager():FindItem(itemType)
if not script then error("unknown item " .. itemType) end
local cell, placed = getCell(), 0
for _ = 1, count do
    local sq = cell:getGridSquare(x + ZombRand(-scatter, scatter + 1), y + ZombRand(-scatter, scatter + 1), z)
    if sq then
        local item = sq:AddWorldInventoryItem(script:getFullName(), ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0)
        if item then placed = placed + 1 end
    end
end
return { placed = placed }
```

- ✔ `sq:AddWorldInventoryItem(fullType, ox, oy, oz)` (4 arguments returns the `InventoryItem`); `ZombRand(a, b)` is an
  integer in `[a, b)`, `ZombRandFloat(a, b)` a float. Tool: `spawn_item {item, x, y, z, count, scatter}`.
- Listing: `sq:getWorldObjects()` → `wo:getItem()`; the world object is what you remove:
  `sq:removeWorldObject(wo)` (synced) or `sq:removeAllWorldObjects()` ○.
- Falling from the sky: `falling_items {item, count, player | x,y,z, radius, duration, fall, spawn, scale}`: the clients
  animate the item's icon dropping (700 px at zoom 1, shadow, bounce) and the server spawns the real item on each
  landing square (`falling_spawn_error` events if a square unloaded meanwhile). Visual only with `spawn = false`.

```lua
-- server: clear every ground item within 4 tiles of the player
local p = ZMCP.player()
local cx, cy, cz, removed = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ()), 0
for dx = -4, 4 do
    for dy = -4, 4 do
        local sq = getCell():getGridSquare(cx + dx, cy + dy, cz)
        if sq then
            local wos = sq:getWorldObjects()
            for i = wos:size() - 1, 0, -1 do sq:removeWorldObject(wos:get(i)); removed = removed + 1 end
        end
    end
end
return { removed = removed }
```

## Containers in the world

```lua
-- server: put a bag of bananas into the first container on a square (crate, fridge, counter...)
local sq = ZMCP.square(6403, 5498, 0)
local objs = sq:getObjects()
for i = 0, objs:size() - 1 do
    local o = objs:get(i)
    local c = o:getContainer()                       -- nil for non-containers
    if c then
        for _ = 1, 5 do
            local item = c:AddItem("Base.Banana")
            sendAddItemToContainer(c, item)
        end
        return { container = c:getType(), count = c:getItems():size() }
    end
end
return "no container on that square"
```

`o:getContainer():getType()` is the container kind (`crate`, `fridge`, `counter`...). Vehicles have part containers
(`v:getPartById("TruckBed"):getItemContainer()` ○).

## Icons and textures for items

Client side, `ZMCPClient.tex.get("item:Base.Banana")` gives the inventory icon (`instanceItem(type):getTex()`),
usable in `world_sprite`, `overlay_draw {kind = "texture", tex = "item:Base.Banana"}` and render hooks.
