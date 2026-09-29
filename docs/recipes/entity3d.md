# entity3d (moving 3D entities)

Tools: `model_upload` (push a runtime model to every client), `entity3d_spawn`, `entity3d_move`,
`entity3d_rotate`, `entity3d_remove`, `entity3d_list` (client authority: the server keeps the registry and every
client draws the entity on a transparent `UI3DScene` layer synced to the iso camera). Background and every verified
engine fact: `docs/ENGINE_NOTES.md`, "Moving 3D entities".

## The rolling Claude star (demo)

```sh
python3 art/3d/make_star.py      # art/3d/zmcp_star_orange.x + .png (Claude orange, radius 0.45); zmcp_star.x is the live-verified spike mesh
```
Then, through the MCP (`model_upload` base64-encodes the local files itself):
```
model_upload   {"id": "star", "mesh_path": "art/3d/zmcp_star.x", "png_path": "art/3d/zmcp_star_orange.png", "scale": 3}
entity3d_spawn {"id": "star", "model": "star", "x": 6081, "y": 5382, "z": 0, "roll": 1.35,
                "path": "6091,5382;6091,5392;6081,5392;6081,5382", "speed": 2, "loop": "loop"}
entity3d_rotate {"id": "star", "spin": "0,90,0", "roll": 0, "h": 1.5}      -> hover and spin instead of rolling
entity3d_move   {"id": "star", "x": 6081, "y": 5382, "duration": 3, "ease": true}
entity3d_remove {"id": "star"}
```
`roll` is the wheel radius in tiles (mesh radius 0.45 × scale 3); `h` defaults to it so the disc touches the ground.
Single player: `dev/e3d_demo.lua` does the same through `dev/bundle_sp.sh` (owner's OK required).

## Raw Lua (what the client does)

```lua
-- client: one full-screen, click-through UI3DScene below the Zomboid MCP overlay
local Layer = ISUIElement:derive("My3DLayer")
function Layer:instantiate()
    self.javaObject = UI3DScene.new(self)
    self.javaObject:setWidth(self.width); self.javaObject:setHeight(self.height)
    self.javaObject:setConsumeMouseEvents(false)
end
local layer = Layer:new(0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
layer:initialise(); layer:instantiate(); layer:addToUIManager(); layer:backMost()
local J = layer.javaObject
J:fromLua1("setView", "UserDefined"); J:fromLua3("setViewRotation", 30, 315, 0); J:fromLua1("setZoom", 7)
J:fromLua1("setDrawGrid", false); J:fromLua1("setDrawGridAxes", false); J:fromLua1("setDrawGridPlane", false)
J:fromLua1("setGizmoVisible", "none")
J:fromLua2("createModel", "star", ZMCPClient.models.name("star"))   -- or a vanilla ModelScript name

-- every frame (prerender): world tile -> scene units, calibrated from the scene's own projection
function Layer:prerender()
    local u0, v0 = J:sceneToUIX(0, 0, 0), J:sceneToUIY(0, 0, 0)
    local ax, by = J:sceneToUIX(1, 0, 0) - u0, J:sceneToUIY(0, 1, 0) - v0
    local zoom = getCore():getZoom(0)
    local k, ky = (32 / zoom) / math.abs(ax), (96 / zoom) / math.abs(by)
    local cx, cy = screenToIsoX(0, u0, v0, 0), screenToIsoY(0, u0, v0, 0)
    local wx, wy, wz, h = 6081, 5382, 0, 1.35                           -- where the star should be
    J:fromLua1("getObjectTranslation", "star"):set((wx - cx) * k, (wz * ky + h * k), (wy - cy) * k)
    J:fromLua1("getObjectRotation", "star"):set(0, heading, -math.deg(distance / 1.35))   -- degrees
    J:fromLua1("getObjectScale", "star"):set(k, k, k)
end
```
`ZMCPClient.e3d` (`client/ZomboidMCP/ClientModels.lua`) is this with sign calibration, motion (path / tween),
spin/roll/face, pending models and hot reload. Notes:
- Model space is Y-up; a mesh centred on the origin needs `h` = its half height to sit on the ground.
- Rotation order is `rotateXYZ`: Z (roll about the model normal) is applied first, then Y (heading), then X.
- The layer draws on top of walls (own depth buffer). Pure client side: MP clients each run the same motion from
  the server's commands; late joiners get every entity on `hello` with its elapsed time.
