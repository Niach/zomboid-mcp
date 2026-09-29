-- Live single-player demo for ZOM-11: the rolling Claude star (moving 3D entity on the UI3DScene layer).
-- Run ONLY with the owner's OK:  dev/bundle_sp.sh dev/e3d_demo.lua
-- Prerequisites (once):  base64 -w0 art/3d/zmcp_star.x > ~/Zomboid/Lua/zmcp_model_star.x.b64   (live-verified mesh)
--                        base64 -w0 art/3d/zmcp_star_orange.png > ~/Zomboid/Lua/zmcp_model_star.png.b64   (orange, from art/3d/make_star.py)
-- What it does: registers the star model (scale 3, radius 1.35 tiles), spawns entity "star" 3 tiles east of the
-- player and rolls it around a 10x10 tile loop at 2 tiles/s. Then check with dev/zmcp_local.py:
--   tools/zmcp_client.py --local call entity3d_list '{}'         (server view)
--   tools/zmcp_client.py --local call entity3d_rotate '{"id":"star","spin":"0,90,0","roll":0,"h":1.5}'   (spin instead of roll)
--   tools/zmcp_client.py --local call entity3d_remove '{"all":true}'
-- Tuning knobs if the star is off: ZMCPClient.e3d.MODEL_SCALE (size), ZMCPClient.e3d.YAW / PITCH (camera).
local T = ZMCP.tools
local p = getSpecificPlayer(0)
local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
local up = T.model_upload.fn({ id = "star", scale = 3, mesh_base64_file = "zmcp_model_star.x.b64", png_base64_file = "zmcp_model_star.png.b64" })
local x0, y0 = px + 3, py
local sp = T.entity3d_spawn.fn({ id = "star", model = "star", x = x0, y = y0, z = pz, roll = 1.35,
    path = string.format("%d,%d,%d;%d,%d,%d;%d,%d,%d;%d,%d,%d", x0 + 10, y0, pz, x0 + 10, y0 + 10, pz, x0, y0 + 10, pz, x0, y0, pz),
    speed = 2, loop = "loop" })
return string.format("model %s gen %d; entity %s at %d,%d,%d rolling a 10x10 loop; e3d layer=%s", up.name, up.gen, sp.id, x0, y0, pz,
    tostring(ZMCPClient.e3d.layer ~= nil))
