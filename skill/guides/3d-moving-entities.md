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
