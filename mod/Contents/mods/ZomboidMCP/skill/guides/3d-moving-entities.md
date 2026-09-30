# 3D moving entities (guide)

Custom 3D models that move, roll and spin smoothly in the world, visible to every player with the mod. This is the
dynamic counterpart of static models (`model_place`). Tools: `entity3d_spawn`, `entity3d_move`, `entity3d_rotate`,
`entity3d_remove`, `entity3d_list`; models come from `model_upload`. Raw Lua and the engine facts: `docs/recipes/entity3d.md`
and `docs/ENGINE_NOTES.md` ("Moving 3D entities").

## How it works (know this before you tune anything)
- Every client keeps one transparent, click-through, full-screen `UI3DScene` (the engine's model-editor viewport) below
  the Zomboid MCP overlay. Its camera is the iso projection (`UserDefined`, rotation 30/315/0); each frame the layer
  calibrates its pixel mapping and places every entity where `isoToScreenX/Y` puts its world position.
- Because it is its own layer: **no wall occlusion** (entities draw on top of everything in the world, under the HUD),
  no shadows, no collisions, no lighting from the world. World items (`model_place`) do occlude but cannot move.
- Pure client side: the server stores the registry and streams `e3d` commands; clients simulate the motion locally.
  Late joiners get every entity with its elapsed time, so loops stay in phase (within network latency).
- Units: tiles. Model space is Y-up, 1 model unit = 1 tile at scale 1. `h` lifts the model origin above the ground.

## Recipes
Rolling coin / the Claude star (mesh radius 0.45, scale 3 → radius 1.35 tiles):
```
model_upload   {id: star, mesh_path: art/3d/zmcp_star.x, png_path: art/3d/zmcp_star_orange.png, scale: 3}
entity3d_spawn {id: star, model: star, x: 6081, y: 5382, roll: 1.35, path: "6091,5382;6091,5392;6081,5392;6081,5382", speed: 2}
```
`roll` = wheel radius: the entity faces its travel direction and rotates about its model Z axis by distance / radius;
`h` defaults to the radius so the disc touches the ground. A mesh must have its origin at the centre for this.

Hovering, spinning object: `entity3d_spawn {model: star, x, y, h: 1.5, spin: "0,90,0"}` (degrees per second per axis).

Fly somewhere: `entity3d_move {id, x, y, z, duration: 3, ease: true}`; `entity3d_move {id, path: "...", speed, loop: pingpong}`
for patrols. `entity3d_rotate {id, rx, ry, rz}` for a fixed pose; `roll: 0` / `spin: ""` stop the animations.

Vanilla models work without an upload: `entity3d_spawn {model: RadioBlue_Ground, x, y, spin: "0,45,0"}`. Find names with
`api_search` / `lua_examples` on "ModelScript" or the `media/scripts/*.txt` model definitions.

## Meshes
- Format: Project Zomboid `.x` text (see `art/3d/make_star.py` for a generator; `art/3d/zmcp_star.x` is live-verified).
  A PNG texture; keep both small (≤ 1.2 MB base64 each, a few thousand triangles).
- Rotation order is `rotateXYZ`: `rz` is applied first in model space (that is the rolling axis for a disc in the model
  XY plane), then `ry` (heading), then `rx`.
- Scale = ModelScript scale (`model_upload`) × entity `scale`.

## Etiquette and limits
- Entities are visible to everyone immediately; remove what you no longer need (`entity3d_remove {all: true}`).
- One frame update per entity per client is cheap; dozens are fine, hundreds are not.
- If an entity never appears, `entity3d_list` shows `clients.<user>.err` (usually the model name or a mesh the engine
  could not load). `events_poll` shows `client_entity3d` results.
- Verified offline against the mocked engine; the live picture (model size versus tiles, rotation sense, clipping) is
  tuned with `ZMCPClient.e3d.MODEL_SCALE / YAW / PITCH / ZOOM` through `run_lua_client` if it looks off.

## Background: why not a world item (verified)

A custom model on a world item (`3d-static-models.md`) renders perfectly while it stands still. Changing its offset or
rotation every tick **flickers**: Build 42 renders map chunks into cached FBOs (`PerformanceSettings.fboRenderChunk`)
and world items go through the `WorldItemAtlas`; every transform change invalidates the cache. Updating in `OnTick`
instead of the render pass did not help. So "roll the star down the street" cannot be a world item.

## Carriers that were evaluated (from `javap` of 42.21 and vanilla Lua)

| carrier | verdict | why |
|---|---|---|
| world item with a "dynamic" flag | no | no per-object flag; only the global `fboRenderChunk` |
| `IsoPhysicsObject` / `IsoBall` | no | not exposed to Lua; `IsoBall` draws a sprite, not a model |
| zombie or animal carrying the model | partial | `createZombie(...)` + `setUseless(true)` + `setAttachedItem(location, item)` with `item:setStaticModel(name)` moves smoothly and syncs, but the model cannot be rotated per frame, the body cannot be hidden, and animals use another skeleton. Good for "a zombie carrying a thing" |
| runtime vehicle script | no | `ScriptManager` has no `addVehicleScript`; vehicles need wheels, physics shapes and skins; physics fights manual rotation |
| `UI3DScene` layer | **chosen** | the vehicle / attachment editor viewport is Lua-exposed, transparent (it clears only the depth buffer), can use the exact iso projection and any registered `ModelScript`, and is moved per frame from Lua |

## Raw Lua: the layer by hand

What `ZMCPClient.e3d` does, reduced to one model (use the tools; this is for understanding and for experiments on one
player with `run_lua_client {player}`):

```lua
-- client: a transparent UI3DScene layer with one model (offline-verified maths; live picture tuned with the e3d knobs)
My3D = My3D or {}
local Layer = ISUIElement:derive("My3DLayer")
function Layer:instantiate()
    self.javaObject = UI3DScene.new(self)
    self.javaObject:setWidth(self.width)
    self.javaObject:setHeight(self.height)
    self.javaObject:setConsumeMouseEvents(false)
end
if My3D.layer then My3D.layer:removeFromUIManager() end
local layer = Layer:new(0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
layer:initialise(); layer:instantiate(); layer:addToUIManager(); layer:backMost()
My3D.layer = layer
local J = layer.javaObject
J:fromLua1("setView", "UserDefined")
J:fromLua3("setViewRotation", 30, 315, 0)
J:fromLua1("setZoom", 7)
J:fromLua1("setDrawGrid", false); J:fromLua1("setDrawGridAxes", false); J:fromLua1("setDrawGridPlane", false)
J:fromLua1("setGizmoVisible", "none")
J:fromLua2("createModel", "star", ZMCPClient.models.name("star"))   -- or a vanilla ModelScript name
My3D.pos = { x = getPlayer():getX() + 3, y = getPlayer():getY(), z = 0, h = 1.35, heading = 0, dist = 0 }
function Layer:prerender()
    local P = My3D.pos
    local u0, v0 = J:sceneToUIX(0, 0, 0), J:sceneToUIY(0, 0, 0)
    local ax, by = J:sceneToUIX(1, 0, 0) - u0, J:sceneToUIY(0, 1, 0) - v0
    local zoom = getCore():getZoom(0)
    local k, ky = (32 / zoom) / math.abs(ax), (96 / zoom) / math.abs(by)      -- scene units per tile / per floor
    local cx, cy = screenToIsoX(0, u0, v0, 0), screenToIsoY(0, u0, v0, 0)       -- world point under the scene origin
    J:fromLua1("getObjectTranslation", "star"):set((P.x - cx) * k, P.z * ky + P.h * k, (P.y - cy) * k)
    J:fromLua1("getObjectRotation", "star"):set(0, P.heading, -math.deg(P.dist / P.h))
    J:fromLua1("getObjectScale", "star"):set(k, k, k)
end
return "layer up"
```

