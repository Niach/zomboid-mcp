# Static 3D models at runtime

Verified live on 42.21 (single player, with the owner watching): a custom mesh + texture written into the client's Lua
dir, registered as a `ModelScript`, and shown on a world item renders as a real 3D object with proper occlusion and no
flicker. That is the Claude star. Moving or rotating it every frame is a different story: `entity3d_spawn` and the 3D layer
(`3d-moving-entities.md`). Placed models are **permanent** (they survive server restarts and rejoins) and can get
**collision** in the same call; both are explained below.

## Tool path

```json
[
  {"tool": "model_upload", "args": {"id": "star", "mesh_path": "/home/me/art/zmcp_star.x", "png_path": "/home/me/art/zmcp_star.png", "scale": 3}},
  {"tool": "events_poll", "args": {"kinds": ["client_model", "client_file"]}},
  {"tool": "model_place", "args": {"id": "star", "x": 6405, "y": 5500, "z": 0, "item": "Base.TirePiece", "ox": 0.5, "oy": 0.5, "oz": 0.6, "yrot": 30, "collide": "solid", "pid": "star-1"}},
  {"tool": "world_query", "args": {"x": 6405, "y": 5500, "z": 0, "radius": 1, "what": "items"}},
  {"tool": "visuals_list", "args": {}},
  {"tool": "model_remove", "args": {"pid": "star-1"}}
]
```

- `model_upload {id, mesh_path | mesh_base64, png_path | png_base64, scale?, player?}`: both files are streamed to every
  client into `~/Zomboid/Lua/media/zmcp_model_<id>_<gen>.x` / `.png` (the path **must contain `media/`** and an
  extension, or the loader fails with "Failed to load asset") and registered as ModelScript `zmcp_<id>_<gen>`.
  `client_model {ok, name}` events confirm it; `ZMCPClient.models.name("star")` returns the name in client code.
  Late joiners get every model on `hello`.
- `model_place {id, x, y, z?, item?, ox?, oy?, oz?, yrot?, collide?, pid?}`: the server spawns a carrier world item
  (default `Base.TirePiece`) on the square with `AddWorldInventoryItem(item, ox, oy, oz)`, sets
  `item:setWorldStaticModel(name)` and records the placement (`pid`, default `p<n>`). `collide` adds an invisible
  blocker on the square (`true` = `solid`, or any `collision_place` kind). Single player verified; in multiplayer the
  carrier syncs and is re-sent after the model name is set (unverified live: test with a second player).
- `model_remove` (`{pid}` or `{all: true}`) removes the carrier item, its blocker and the record everywhere;
  `visuals_list` lists every placement under `placements` (`pid`, model name, square, carrier item id, `collide`,
  `missing`, `restored`).

## Persistence: what survives a restart and a rejoin

Nothing to do; know what happens:
- **The model name is saved with the world item.** `setWorldStaticModel` writes `worldStaticModel` into the item's
  ModData, which `InventoryItem.save` stores with the world item (rotations too) and sends to clients with the item.
- **The mod keeps a registry** (`visuals_list` → `placements`, in ModData) and the uploaded files (`zmcp_model_<id>.*`
  in the Lua dir). Every client `hello` (join, reconnect, after a restart) gets textures, models, client scripts,
  sprites, then the placements, then the moving entities, in that order.
- **Square load re-applies.** On every `LoadGridsquare` (server and clients) the carrier of a placement on that square
  is looked up (item id, then type + model name) and the model set again if it is missing (`restored` counts it,
  `model_place_restored` in `events_poll`). A carrier that is gone (somebody picked the tire piece up) shows as
  `missing`; place it again.
- **A client that has not registered the model yet** (files still streaming after a join) shows the carrier item's
  flat sprite. `ItemModelRenderer` checks `getModelScript` every frame and caches nothing, so the 3D model appears on
  the first frame after the registration; the client also marks the chunk for a redraw. If a model stays flat,
  `events_poll {kinds: ["client_model"]}` shows why the registration failed.
- `clear_visuals {what: "models"}` forgets the uploads on clients but keeps placements and files; `model_remove
  {all: true}` takes the world items away (loaded squares only, the rest on the next visit).

## Collision: models have none

A carrier item is walkable; zombies and players pass straight through the star. Pair every model that should block
with an invisible blocker:
- `model_place {..., collide: "solid"}` puts one on the model's square in the same call (`solid` blocks walking, zombie
  pathing and line of sight; `solidtrans` blocks walking and pathing but not sight; `wall_n` / `wall_w` / `wall_nw`
  are invisible walls on those edges).
- `collision_place {x, y, z, w, h, kind, name}` fills a rectangle of squares (a bridge's rails, the walls of a cavern,
  a chasm), `collision_list` shows what exists (and drops entries whose blocker is gone), `collision_clear` removes
  them, `collision_place {kind: "remove"}` clears a rectangle. `world_query` lists blockers as sprite
  `zmcp_collision_<kind>`, name `ZMCP_collision`; `remove_object` works on them.
- The blockers are ordinary world objects (saved, synced, not thumpable: zombies cannot break them) whose sprite
  carries the vanilla flags (`invisible` + `solid` / `solidtrans` / `WallN` + `collideN` + `cutN`, ...), registered
  on the server and every client by the mod with fixed sprite ids; `docs/ENGINE_NOTES.md` "Collision blockers" has
  the research. Walk the area yourself, with a second player and with a zombie: client-side movement and pathing
  around a fresh blocker are not verified live yet.

```json
[
  {"tool": "collision_place", "args": {"x": 6400, "y": 5498, "w": 8, "h": 1, "kind": "solidtrans", "name": "bridge-north-rail"}},
  {"tool": "collision_place", "args": {"x": 6400, "y": 5502, "w": 8, "h": 1, "kind": "solidtrans", "name": "bridge-south-rail"}},
  {"tool": "collision_list", "args": {"x": 6404, "y": 5500, "z": 0, "radius": 6}},
  {"tool": "collision_place", "args": {"x": 6400, "y": 5498, "w": 8, "h": 5, "kind": "remove"}},
  {"tool": "collision_clear", "args": {"all": true}}
]
```

## Axes, origin, lift

- **Model space is Y-up** for world items. A disc modelled in the XY plane stands upright like a coin; `setWorldYRotation`
  rolls it like a wheel (`setWorldZRotation` did not visibly rotate it).
- The **origin sits at ground level**: a mesh centred on the origin is half buried. Either put the mesh bottom at y = 0
  when generating it, or lift with `oz` (`setOffset`): at scale 3, `oz` 0.45 still left the star about a fifth in the
  ground, so start around 0.6 and adjust live.
- `scale` in the ModelScript multiplies the mesh units; the star mesh has radius 0.45, so scale 3 is about 1.35 tiles.
- `worldItem:setOffset(x, y, z)` may exceed 0..1; `InventoryItem.setWorldX/Y/ZRotation` exist.

## Generating a `.x` mesh with Python (no Blender needed)

Project Zomboid loads DirectX **text** `.x` meshes. The verified star is an extruded 12-ray star with per-face normals,
one material with a `TextureFilename`, and UVs. This stdlib script writes the same geometry plus a flat-colour PNG:

```python
# test: python
# make_star.py: an extruded star (.x text mesh, Y-up, centred on the origin) + a flat colour PNG texture.
import math, struct, zlib

def png_solid(path, w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)

def star_x(rays=12, radius=0.45, inner=0.55, depth=0.06, tex_name="zmcp_star.png"):
    outline = []
    for i in range(rays * 2):
        a = math.pi / 2 + i * math.pi / rays
        r = radius if i % 2 == 0 else radius * inner
        outline.append((r * math.cos(a), r * math.sin(a)))
    verts, norms, uvs, faces = [], [], [], []
    def add(v, n, uv):
        verts.append(v); norms.append(n); uvs.append(uv)
        return len(verts) - 1
    def uv_of(x, y):
        return (0.5 + x / (2 * radius) * 0.9, 0.5 - y / (2 * radius) * 0.9)
    hz = depth / 2
    for sign in (1, -1):                                   # front and back caps (triangle fans)
        c = add((0, 0, sign * hz), (0, 0, sign), (0.5, 0.5))
        ring = [add((x, y, sign * hz), (0, 0, sign), uv_of(x, y)) for x, y in outline]
        n = len(ring)
        for i in range(n):
            a, b = ring[i], ring[(i + 1) % n]
            faces.append((c, a, b) if sign == 1 else (c, b, a))
    n = len(outline)
    for i in range(n):                                     # sides, one flat-shaded quad per edge
        (x1, y1), (x2, y2) = outline[i], outline[(i + 1) % n]
        ex, ey = x2 - x1, y2 - y1
        L = math.hypot(ex, ey) or 1
        nx, ny = ey / L, -ex / L
        q = [add((x1, y1, hz), (nx, ny, 0), (0.2, 0.2)), add((x2, y2, hz), (nx, ny, 0), (0.8, 0.2)),
             add((x2, y2, -hz), (nx, ny, 0), (0.8, 0.8)), add((x1, y1, -hz), (nx, ny, 0), (0.2, 0.8))]
        faces.append((q[0], q[1], q[2])); faces.append((q[0], q[2], q[3]))
    f = lambda v: "%.6f" % v
    sep = lambda i, n: "," if i < n - 1 else ";"
    out = ["xof 0303txt 0032", "", "Material mat0 {", " 1.000000;1.000000;1.000000;1.000000;;", " 10.000000;",
           " 0.000000;0.000000;0.000000;;", " 0.000000;0.000000;0.000000;;", "", " TextureFilename {",
           '  "%s";' % tex_name, " }", "}", "", "Frame ZMCPStar {", "", " FrameTransformMatrix {",
           "  1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000;;",
           " }", "", " Mesh ZMCPStar {", "  %d;" % len(verts)]
    out += ["  %s;%s;%s;%s" % (f(x), f(y), f(z), sep(i, len(verts))) for i, (x, y, z) in enumerate(verts)]
    out += ["  %d;" % len(faces)]
    out += ["  3;%d,%d,%d;%s" % (a, b, c, sep(i, len(faces))) for i, (a, b, c) in enumerate(faces)]
    out += ["", "  MeshNormals {", "   %d;" % len(norms)]
    out += ["   %s;%s;%s;%s" % (f(x), f(y), f(z), sep(i, len(norms))) for i, (x, y, z) in enumerate(norms)]
    out += ["   %d;" % len(faces)]
    out += ["   3;%d,%d,%d;%s" % (a, b, c, sep(i, len(faces))) for i, (a, b, c) in enumerate(faces)]
    out += ["  }", "", "  MeshMaterialList {", "   1;", "   %d;" % len(faces)]
    out += ["   0%s" % sep(i, len(faces)) for i in range(len(faces))]
    out += ["   { mat0 }", "  }", "", "  MeshTextureCoords c1 {", "   %d;" % len(uvs)]
    out += ["   %s;%s;%s" % (f(u), f(v), sep(i, len(uvs))) for i, (u, v) in enumerate(uvs)]
    out += ["  }", " }", "}", ""]
    return "\n".join(out)

open("zmcp_star.x", "w").write(star_x())
png_solid("zmcp_star.png", 64, 64, (0xD9, 0x77, 0x57))     # Claude orange
print("wrote zmcp_star.x and zmcp_star.png")
```

Other shapes: replace `outline` with any closed polygon (a box is 4 points, a coin is 24 points on a circle). Blender
users: export DirectX `.x` as text, Y-up, triangulated, a single material with a texture file name, then rename the
texture to the PNG you upload (the file name inside the mesh is informational; the ModelScript sets the texture).

## By hand (what the client does on `model` and what the server does on `model_place`)

```lua
-- client: register a ModelScript for files already in ~/Zomboid/Lua/media/ (what model_upload does per client)
local sep = getFileSeparator()
local dir = getMyDocumentFolder() .. sep .. "Lua" .. sep .. "media" .. sep
local name = "my_star_1"
local ms = ModelScript.new()
ms:setModule(getScriptManager():getModule("Base"))     -- without this addModelScript throws an NPE
ms:InitLoadPP(name)
ms:Load(name, "{ mesh = " .. dir .. "my_star.x, texture = " .. dir .. "my_star.png, scale = 3, }")
getScriptManager():addModelScript(ms)
return name
```

```lua
-- server: place a registered model on a carrier world item and roll it 45 degrees (what model_place does)
local sq = ZMCP.square(6405, 5500, 0)
local item = sq:AddWorldInventoryItem("Base.TirePiece", 0.5, 0.5, 0.6)   -- (type, ox, oy, oz)
item:setWorldStaticModel("zmcp_star_1")                                 -- name from model_upload / client_model event
item:setWorldYRotation(45)
return { id = item:getID(), x = sq:getX(), y = sq:getY() }
```

```lua
-- server: remove the carrier items again by hand (model_remove {pid} does this and also drops the blocker + record)
local sq = ZMCP.square(6405, 5500, 0)
local wos, removed = sq:getWorldObjects(), 0
for i = wos:size() - 1, 0, -1 do
    local wo = wos:get(i)
    local it = wo:getItem()
    if it and it:getFullType() == "Base.TirePiece" then sq:removeWorldObject(wo); removed = removed + 1 end
end
return { removed = removed }
```

## What does not work

- `ScriptManager.ParseScript` parses item scripts but does not finalize them ("Couldn't find item"); `ScriptBucket` is
  not exposed. New item types cannot be created at runtime: use vanilla carrier items plus a `ModelScript`.
- Changing the carrier's rotation or offset every tick flickers (chunk FBO cache + `WorldItemAtlas` invalidation),
  even from `OnTick`. Static is fine; moving needs the entity layer.
- The mesh path must contain `media/`; a bare `~/Zomboid/Lua/x.x` fails.
