# The Claude star (3D)

A 3D orange star standing in the street (static, verified live), and the same star rolling down the road like a coin on
the moving-entity layer (`guides/3d-moving-entities.md`).

## Make the mesh

The verified mesh ships in the repo as `art/3d/zmcp_star.x` + `zmcp_star.png`. Without the repo, generate it: run the
Python script in `guides/3d-static-models.md` (stdlib only), which writes `zmcp_star.x` (an extruded 12-ray star,
radius 0.45, centred on the origin in the XY plane, Y-up) and a 64×64 orange PNG.

## Calls

```json
[
  {"tool": "players_list", "args": {}},
  {"tool": "model_upload", "args": {"id": "star", "mesh_path": "/home/me/zmcp_star.x", "png_path": "/home/me/zmcp_star.png", "scale": 3}},
  {"tool": "events_poll", "args": {"kinds": ["client_model"]}},
  {"tool": "model_place", "args": {"id": "star", "x": 6405, "y": 5500, "z": 0, "item": "Base.TirePiece", "ox": 0.5, "oy": 0.5, "oz": 0.6, "yrot": 30}},
  {"tool": "world_query", "args": {"x": 6405, "y": 5500, "z": 0, "radius": 1, "what": "items"}}
]
```

1. `model_upload`: both files go to every client under `Lua/media/` and are registered as ModelScript `zmcp_star_1`
   (`client_model {ok, name}` per client; the name is also in the tool result).
2. `model_place`: a carrier world item (`Base.TirePiece`) on the square with the model as its world model. `oz`
   lifts it (the origin is at ground level; at scale 3, 0.45 was still a fifth in the ground), `yrot` rolls it like a
   wheel (Y is up in model space; a disc in the XY plane stands upright).
3. It renders in 3D with occlusion and no flicker. Multiplayer: the carrier syncs; whether other clients apply the model
   assignment is unverified, so check with a second player.

## Raw Lua

```lua
-- server: place and later remove the carrier (what model_place does; removal = remove the TirePiece world item)
local sq = ZMCP.square(6405, 5500, 0)
local item = sq:AddWorldInventoryItem("Base.TirePiece", 0.5, 0.5, 0.6)
item:setWorldStaticModel("zmcp_star_1")
item:setWorldYRotation(30)
return { placed = item:getID() }
```

```lua
-- server: remove every TirePiece on the square
local sq = ZMCP.square(6405, 5500, 0)
local wos = sq:getWorldObjects()
for i = wos:size() - 1, 0, -1 do
    local it = wos:get(i):getItem()
    if it and it:getFullType() == "Base.TirePiece" then sq:removeWorldObject(wos:get(i)) end
end
return "removed"
```

## Rolling down the street

The same upload, drawn on the transparent 3D layer every client keeps (smooth, no chunk-cache flicker, no wall
occlusion). `roll` is the wheel radius in tiles (mesh radius 0.45 × scale 3 = 1.35); `h` defaults to it so the star
touches the ground; the `path` is walked at `speed` tiles per second and loops.

```json
[
  {"tool": "entity3d_spawn", "args": {"id": "star", "model": "star", "x": 6405, "y": 5500, "z": 0, "roll": 1.35, "path": "6415,5500;6415,5510;6405,5510;6405,5500", "speed": 2, "loop": "loop"}},
  {"tool": "events_poll", "args": {"kinds": ["client_entity3d"]}},
  {"tool": "entity3d_list", "args": {}},
  {"tool": "entity3d_rotate", "args": {"id": "star", "spin": "0,90,0", "roll": 0, "h": 1.5}},
  {"tool": "entity3d_move", "args": {"id": "star", "x": 6405, "y": 5500, "z": 0, "duration": 3, "ease": true}},
  {"tool": "entity3d_remove", "args": {"id": "star"}}
]
```

`entity3d_rotate` switches to hovering and spinning (degrees per second about X, Y, Z; `roll = 0` stops rolling),
`entity3d_move` tweens it somewhere with a soft start and stop, `entity3d_remove` takes it away everywhere (late joiners
included). Never animate the static carrier item instead: it flickers.
