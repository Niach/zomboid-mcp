# model_place / model_remove (static 3D models)

Tools: `model_upload` (push the runtime model to every client), `model_place`, `model_remove`, `visuals_list`
(`placements`). A static custom model is a **carrier world item** (default `Base.TirePiece`) whose world model is
set to the runtime `ModelScript` registered by `model_upload` (`zmcp_<id>_<gen>`). Engine facts:
`docs/ENGINE_NOTES.md`, "Runtime 3D models" and "3D permanence".

```
model_upload {"id": "star", "mesh_path": "art/3d/zmcp_star.x", "png_path": "art/3d/zmcp_star_orange.png", "scale": 3}
model_place  {"id": "star", "x": 6084, "y": 5391, "z": 0, "yrot": 45, "collide": "solid", "pid": "star-1"}
visuals_list {}                                  -> placements: [{pid: "star-1", name: "zmcp_star_1", itemId, collide, ...}]
model_remove {"pid": "star-1"}
```

## Raw Lua (what the tool does)

```lua
-- server
local sq = getCell():getGridSquare(6084, 5391, 0)
if not sq then error("square not loaded") end
local item = sq:AddWorldInventoryItem("Base.TirePiece", 0.5, 0.5, 0)
item:setWorldStaticModel("zmcp_star_1")          -- stored in the item's ModData ("worldStaticModel"): saved with the world
item:setWorldYRotation(45)                        -- saved too (worldXRotation/worldYRotation/worldZRotation)
if isServer() then item:getWorldItem():transmitCompleteItemToClients() end   -- MP: the carrier went out before the name was set
return { id = item:getID(), model = item:getWorldStaticModel() }
```

```lua
-- server or client: find the carrier again on a loaded square and re-apply the model if it lost it
local sq = getCell():getGridSquare(6084, 5391, 0)
local list = sq:getWorldObjects()
for i = 0, list:size() - 1 do
    local wo = list:get(i)
    local item = wo:getItem()
    if item and item:getFullType() == "Base.TirePiece" and item:getWorldStaticModel() ~= "zmcp_star_1" then
        item:setWorldStaticModel("zmcp_star_1")
        sq:invalidateRenderChunkLevel(16)         -- FBORenderChunk.DIRTY_ITEM_MODIFY: redraw the cached chunk level
    end
end
```

Notes:
- **Permanent:** the model name is saved with the world item and re-sent to clients with it. The mod also keeps
  the placement (`visuals_list` → `placements`) and, on every square load (`LoadGridsquare`, server and clients),
  re-applies the model when the carrier lost it (`restored` counter; `missing` when the item is gone, e.g. picked up).
- **Fresh client:** until the model files arrived and the `ModelScript` is registered, the engine draws the carrier's
  flat item sprite (`ItemModelRenderer` → `NoModel`, checked every frame, nothing cached); the 3D model appears on
  the first frame after the registration. Late joiners receive models before placements and entities.
- **Collision:** the model has none; `collide` puts an invisible blocker on the square
  ([collision_place](collision_place.md)), removed again by `model_remove`.
- `clear_visuals {what: "models"}` forgets the uploads on clients but keeps placements; `model_remove {all: true}`
  removes the world items (loaded squares only).
