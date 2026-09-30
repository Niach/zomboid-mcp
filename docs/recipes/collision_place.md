# collision_place / collision_list / collision_clear

Tools: `collision_place`, `collision_list`, `collision_clear` (server). Invisible blocking objects for custom 3D
models (which have no collision of their own): a plain `IsoObject` named `ZMCP_collision` whose sprite carries the
vanilla movement / sight flags. Engine facts: `docs/ENGINE_NOTES.md`, "Collision blockers".

| kind | sprite flags | effect |
| --- | --- | --- |
| `solid` | `invisible, solid` | the square blocks walking, zombie pathing and line of sight |
| `solidtrans` | `invisible, solidtrans` | blocks walking and pathing, see-through (rails, chasm edges) |
| `wall_n` | `invisible, WallN, collideN, cutN` | an invisible wall on the north edge (like a vanilla wall) |
| `wall_w` | `invisible, WallW, collideW, cutW` | ... on the west edge |
| `wall_nw` | `invisible, WallNW, collideN, cutN, collideW, cutW` | both edges (a corner) |

```
collision_place {"x": 6080, "y": 5390, "w": 8, "h": 1, "kind": "solidtrans", "name": "bridge-north-rail"}
collision_place {"x": 6080, "y": 5392, "w": 8, "h": 1, "kind": "solidtrans", "name": "bridge-south-rail"}
collision_list  {"x": 6084, "y": 5391, "radius": 6}
collision_place {"x": 6080, "y": 5390, "w": 8, "h": 3, "kind": "remove"}
collision_clear {"all": true}
model_place     {"id": "star", "x": 6084, "y": 5391, "collide": "solid"}     -> model + blocker in one call
```

## Raw Lua (what the tool does)

The sprites are registered on the server **and on every client** by `shared/ZomboidMCP/CollisionSprites.lua`
(the mod is required on clients), with fixed numeric ids because `IsoObject.save` stores only the sprite id:

```lua
-- shared (both sides), idempotent; the mod runs this at load, OnLoadedTileDefinitions, OnGameStart, OnServerStarted
local sm = IsoSpriteManager.instance
local id = 2097676288                                   -- IsoWorld.getSpriteID(8000, 1, 0): far above vanilla ids
local sprite = sm:getSprite(id) or sm:AddSprite("zmcp_collision_solid", id)
local props = sprite:getProperties()
props:set(IsoFlagType.invisible)                        -- never drawn (IsoObject.isSpriteInvisible)
props:set(IsoFlagType.solid)                            -- blocks movement, pathing and sight
```

```lua
-- server: place / remove one blocker (the tool does a rectangle and keeps a registry in ModData)
local sq = getCell():getGridSquare(6084, 5391, 0)
if not sq then error("square not loaded") end
local obj = IsoObject.new(sq, "zmcp_collision_solid", "ZMCP_collision")
sq:transmitAddObjectToSquare(obj, -1)                   -- saved in the chunk, sent to clients, RecalcAllWithNeighbours
                                                        -- + PolygonalMap2.squareChanged (zombies re-path at once)
-- later: find it by sprite name and take it away (remove_object does the same)
local objs = sq:getObjects()
for i = 0, objs:size() - 1 do
    local o = objs:get(i)
    if o:getSprite() and o:getSprite():getName() == "zmcp_collision_solid" then sq:transmitRemoveItemFromSquare(o) end
end
return { solid = sq:isSolid(), solidTrans = sq:isSolidTrans() }
```

Notes:
- One blocker per kind per square; `wall_n` and `solidtrans` can share a square. `world_query` lists them
  (sprite `zmcp_collision_<kind>`, name `ZMCP_collision`); `collision_list` reconciles its registry with the world.
- Only loaded squares (near online players) can be changed; the tools report `unloaded` counts.
- A `solid` square is impassable for players and zombies and blocks vision. For a bridge over a chasm, make the
  chasm squares `solid` (or `solidtrans` to keep the view) and leave the bridge squares free.
- The objects are not `IsoThumpable`, so zombies cannot break them.
- Not verified live yet: client-side player collision (movement is client-authoritative), zombie pathing around a
  fresh blocker, that a client resolves the sprite id on chunk load. Check with a player and a zombie.
