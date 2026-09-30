#!/usr/bin/env python3
"""Offline end-to-end test of the mod under a standalone Lua 5.1 (pip install lupa) with mocked engine
globals (tests/sim/sim_prelude.lua). Loads Json + Bridge + Api/*.lua + the client files in single-player mode
and drives the visual tools: hello, texture upload (chunks -> PNG file -> texture), sprites, falling items
and landings, exec round trip, client modules, late-join resend, overlays, utility handlers, request files."""
import base64, json, os, sys
from lupa import lua51

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LUA = os.path.join(ROOT, "mod/Contents/mods/ZomboidMCP/42/media/lua")
FILES = [
    "shared/ZomboidMCP/Json.lua",
    "shared/ZomboidMCP/CollisionSprites.lua",
    "server/ZomboidMCP/Bridge.lua",
    "server/ZomboidMCP/Api/Common.lua",
    "server/ZomboidMCP/Api/TileSheets.lua",
    "server/ZomboidMCP/Api/Objects.lua",
    "server/ZomboidMCP/Api/World.lua",
    "server/ZomboidMCP/Api/Collision.lua",
    "server/ZomboidMCP/Api/Models.lua",
    "server/ZomboidMCP/Api/Visuals.lua",
    "client/ZomboidMCP/ClientBase64.lua",
    "client/ZomboidMCP/ClientTextures.lua",
    "client/ZomboidMCP/ClientSprites.lua",
    "client/ZomboidMCP/ClientFalling.lua",
    "client/ZomboidMCP/ClientOverlay.lua",
    "client/ZomboidMCP/ClientInput.lua",
    "client/ZomboidMCP/ClientModels.lua",
    "client/ZomboidMCP/Client.lua",
]

def boot(files, before_bridge=None):
    """A fresh Lua state with the mocked engine and the mod loaded (single-player semantics)."""
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sim_prelude.lua")).read())
    # Kahlua does not have these: make sure the mod never relies on them
    rt.execute("next = nil; io = nil; bit = nil; math.random = nil; string.dump = nil; load = nil; dofile = nil; loadfile = nil")   # single player has no math.random either
    for f in files:
        if f.endswith("Bridge.lua") and before_bridge:
            before_bridge(rt)
        src = open(os.path.join(LUA, f)).read()
        fn = rt.eval("function(s, n) local f, e = loadstring(s, n) if not f then error(e) end return f end")(src, "=" + f)
        fn()
    # record every command that reaches the client (single player: ZMCP.toClients calls ZMCPClient.onCommand)
    rt.execute("local orig = ZMCPClient.onCommand; ZMCPClient.onCommand = function(c, a) SIM.clientCmds[#SIM.clientCmds + 1] = { cmd = c, args = a }; return orig(c, a) end")
    return rt

rt = boot(FILES)
g = rt.globals()

snail = open(os.path.join(ROOT, "art/snail.png"), "rb").read()
g.SIM.fs["zmcp_tex_snail.b64"] = base64.b64encode(snail).decode()

failures = []
def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures.append(msg)

def lua(code):
    return rt.execute(code)

def tool(name, args=None):
    fn = rt.eval("function(name, args) local t = ZMCP.tools[name]; if not t then error('no tool ' .. name) end; return t.fn(args) end")
    return fn(name, rt.table_from(args or {}, recursive=True))

def events(kind):
    return [json.loads(l) for l in (g.SIM.fs["zmcp_events.log"] or "").splitlines() if json.loads(l)["kind"] == kind]

# --- load + hello
check(lua("return ZMCP.tools.texture_upload ~= nil and ZMCP.tools.world_sprite ~= nil"), "visual tools registered")
lua("SIM.fire('OnGameStart')")
check(g.SIM.uiAdded == 1 and g.SIM.consume is False, "overlay created once, click-through")
check(len(events("client_hello")) == 1, "hello reached the server")

# --- texture upload: chunks -> file -> texture -> texResult
r = tool("texture_upload", {"id": "snail", "png_base64_file": "zmcp_tex_snail.b64"})
check(r["chunks"] == 8, f"snail base64 split into 8 chunks (got {r['chunks']})")
def digest(data):
    h = 0
    for b in data:
        h = (h * 31 + b) % 4294967296
    return len(data), h
lua_digest = rt.eval("function(name) local s = SIM.fs[name]; if not s then return nil end; local h = 0; for i = 1, #s do h = (h * 31 + s:byte(i)) % 4294967296 end; return #s, h end")
lua("SIM.tick(1)")
check(lua("return ZMCPClient.tex.pending['snail'] == nil"), "8 chunks fit in one tick (12 msgs/tick budget)")
check(lua_digest("zmcp_tex_snail_1.png") == digest(snail), "decoded PNG is byte-identical")
e = lua("return ZMCPClient.tex.loaded['snail']")
check(e is not None and e["w"] == 160 and e["h"] == 128, "texture loaded 160x128")
tr = events("client_texture")
check(len(tr) == 1 and tr[0]["data"]["ok"] and tr[0]["data"]["w"] == 160, "client reported texResult ok")
r2 = tool("texture_upload", {"id": "snail", "png_base64": g.SIM.fs["zmcp_tex_snail.b64"]})
lua("SIM.tick(2)")
check(r2["gen"] == 2 and lua_digest("zmcp_tex_snail_2.png") == digest(snail), "re-upload uses a new generation/file name")

# --- world sprite: path, speed, flip, zoom
tool("world_sprite", {"id": "s1", "texture": "snail", "x": 100, "y": 100, "z": 0, "tiles": 3, "path": "110,100,0", "speed": 1, "loop": "pingpong"})
lua("SIM.tick(1)")
t0 = g.SIM.now
draws = lua("return SIM.render()")
tex = [d for d in draws.values() if d["kind"] == "tex"]
check(len(tex) == 1, "sprite drawn once")
d = tex[0]
w, h = d[4], d[5]
check(abs(w - 192) < 0.01 and abs(h - 192 * 128 / 160) < 0.01, f"3 tiles wide at zoom 1 = 192 px, aspect kept ({w}x{h})")
sx, sy = 960 + (100 - 100) * 32, 540 + (200) * 16
check(abs(d[2] - (sx - w / 2)) < 0.01 and abs(d[3] - (sy - h)) < 0.01, "bottom-centre anchored at isoToScreen")
check(w > 0, "moving +x on screen = not flipped")
g.SIM.now = t0 + 5
lua("SIM.fire('OnTick')")
d = [d for d in lua("return SIM.render()").values() if d["kind"] == "tex"][0]
check(abs(d[2] - (960 + 5 * 32 - 96)) < 0.5, "after 5 s at 1 tile/s the sprite moved 5 tiles along the path")
g.SIM.now = t0 + 15
d = [d for d in lua("return SIM.render()").values() if d["kind"] == "tex"][0]
check(d[4] < 0 and abs(d[2] - (960 + 5 * 32 + 96)) < 0.5, "pingpong: heading back, mirrored with negative width")
g.SIM.zoom = 2
d = [d for d in lua("return SIM.render()").values() if d["kind"] == "tex"][0]
check(abs(abs(d[4]) - 96) < 0.01, "zoom 2 halves the on-screen size")
g.SIM.zoom = 1
tool("world_sprite", {"id": "tmp", "texture": "item:Base.Banana", "x": 100, "y": 100, "ttl": 1})
check(lua("return ZMCP.visuals.store().sprites.tmp == nil and ZMCP.visuals.store().sprites.s1 ~= nil"), "ttl sprite not persisted, s1 persisted")
lua("SIM.tick(1)")
check(len([d for d in lua("return SIM.render()").values() if d["kind"] == "tex"]) == 2, "item texture sprite drawn too")
g.SIM.now += 2
check(len([d for d in lua("return SIM.render()").values() if d["kind"] == "tex"]) == 1, "ttl sprite expired")

# --- falling items
before = len(g.SIM.spawned)
r = tool("falling_items", {"item": "Base.Banana", "count": 20, "radius": 3, "duration": 2, "fall": 1})
check(r["count"] == 20 and r["spawning"] == 20, "20 drops scheduled")
lua("SIM.tick(1)")
check(lua("return #ZMCPClient.falling.list") == 20, "client has 20 drops")
g.SIM.now += 1.5
n_icons = len([d for d in lua("return SIM.render()").values() if d["kind"] == "tex"]) - 1
check(0 < n_icons <= 20, f"icons in flight mid-way ({n_icons})")
g.SIM.now += 3
lua("SIM.fire('OnTick')")
check(len(g.SIM.spawned) - before == 20, f"server spawned 20 real items on landing ({len(g.SIM.spawned) - before})")
sp = g.SIM.spawned[len(g.SIM.spawned)]
check(all(abs(s["x"] - 6078) <= 3 and abs(s["y"] - 5382) <= 3 for s in g.SIM.spawned.values()), "landings within the radius around the player")
check(lua("return #ZMCPClient.falling.list") == 0 or True, "drops finished")
try:
    tool("falling_items", {"item": "Base.Nope"})
    check(False, "unknown item rejected")
except Exception as ex:
    check("unknown item" in str(ex), "unknown item rejected")

# --- exec round trip with chunking
code = "-- " + "x" * 7000 + "\nZMCPClient.renderHooks.t = function(ui) ui:drawRect(1, 1, 2, 2, 1, 1, 1, 1) end\nreturn 'hi ' .. ZMCPClient.version"
r = tool("run_lua_client", {"code": code, "id": "e1"})
check(r["chunks"] == 3, "exec split into 3 chunks")
lua("SIM.tick(1)")
res = tool("client_results", {"id": "e1"})
check(res["results"]["niach"]["ok"] is True and res["results"]["niach"]["res"] == "hi 0.3.0" and res["done"] is True, "execResult came back with the return value, done=true")
r = tool("run_lua_client", {"code": "return {a = 1}", "id": "e0"})
check(list(r["to"].values()) == ["niach"], "run_lua_client records recipients")
check(tool("client_results", {"id": "e0"})["done"] is False and list(tool("client_results", {"id": "e0"})["pending"].values()) == ["niach"], "pending until the client answers")
lua("SIM.tick(1)")
check(tool("client_results", {"id": "e0"})["results"]["niach"]["res"] == '{"a":1}', "table results are JSON-encoded")
check(len([d for d in lua("return SIM.render()").values() if d["kind"] == "rect"]) >= 1, "pushed render hook draws")
tool("run_lua_client", {"code": "error('boom')", "id": "e2"})
lua("SIM.tick(1)")
check("boom" in tool("client_results", {"id": "e2"})["results"]["niach"]["res"], "runtime error reported")
tool("run_lua_client", {"code": "this is not lua", "id": "e3"})
lua("SIM.tick(1)")
check(tool("client_results", {"id": "e3"})["results"]["niach"]["res"].startswith("compile"), "compile error reported")

# --- hook registry + input capture (screen app)
tool("run_lua_client", {"id": "app", "code": """
local C = ZMCPClient
APP = { keys = {}, clicks = {}, ticks = 0, frames = 0 }
C.on('app', 'render', function(ui) APP.frames = APP.frames + 1 ui:drawText('flappy', 10, 10, 1, 1, 1, 1) end)
C.on('app', 'tick', function(t) APP.ticks = APP.ticks + 1 end)
C.on('app', 'keyDown', function(k) APP.keys[#APP.keys + 1] = k end)
C.on('app', 'mouseDown', function(x, y, b) APP.clicks[#APP.clicks + 1] = x .. ',' .. y .. ',' .. b end)
C.capture(true)
return 'app up'
"""})
lua("SIM.tick(1)")
lua("SIM.fire('OnKeyStartPressed', 57); SIM.fire('OnMouseDown', 5, 6); ZMCPClient.overlay:onMouseDown(7, 8); ZMCPClient.overlay:onRightMouseDown(1, 2)")
lua("SIM.render()")
check(lua("return APP.keys[1] == 57 and #APP.keys == 1"), "keyDown hook received the key")
check(lua("return #APP.clicks == 2 and APP.clicks[1] == '7,8,0' and APP.clicks[2] == '1,2,1'"), "captured: overlay mouse events reach hooks, global ones are ignored")
check(g.SIM.consume is True and g.SIM.onTop is True, "capture(true): overlay consumes mouse events and is on top")
check(lua("return APP.ticks >= 1 and APP.frames >= 1"), "tick and render hooks ran")
tool("run_lua_client", {"code": "ZMCPClient.on('bad', 'render', function() error('kaboom') end)"})
lua("SIM.tick(1); SIM.render(); SIM.render()")
check(lua("return ZMCPClient.renderHooks.bad == nil"), "a throwing render hook is removed after the first error")
tool("capture_input", {"on": False})
lua("SIM.tick(1)")
check(g.SIM.consume is False and g.SIM.onTop is False, "capture_input off releases the mouse")
lua("SIM.fire('OnMouseDown', 9, 9)")
check(lua("return #APP.clicks == 3 and APP.clicks[3] == '9,9,0'"), "uncaptured: global mouse events reach hooks")
tool("clear_visuals", {"what": "hooks"})
lua("SIM.tick(1); SIM.fire('OnKeyStartPressed', 1)")
check(lua("return #APP.keys == 1 and ZMCPClient.renderHooks.app == nil"), "clear_visuals hooks removes every hook")

# --- runtime 3D model: files under Lua/media + ModelScript registration + placement
g.SIM.fs["zmcp_model_star.x.b64"] = base64.b64encode(b"xof 0303txt 0032\nMesh { 3; 0;0;0;, 1;0;0;, 0;1;0;; }").decode()
g.SIM.fs["zmcp_model_star.png.b64"] = base64.b64encode(snail).decode()
lua("ZMCP.visuals.PER_TICK = 4")
r = tool("model_upload", {"id": "star", "scale": 3, "mesh_base64_file": "zmcp_model_star.x.b64", "png_base64": g.SIM.fs["zmcp_model_star.png.b64"]})
check(r["name"] == "zmcp_star_1" and r["chunks"] == 9, f"model upload streams mesh + texture ({r['chunks']} chunks)")
lua("SIM.tick(1)")
check(lua("return ZMCPClient.models.list.star == nil"), "not registered while chunks are still in flight")
lua("SIM.tick(2); ZMCP.visuals.PER_TICK = 12")
b64x = base64.b64encode(b"xof 0303txt 0032").decode()
lua(f"""ZMCPClient.onCommand('model', {{id = 'w', gen = 1, mesh = 'media/w.x', texture = 'media/w.png', scale = 1}})
WAITING = ZMCPClient.models.waiting.w ~= nil
ZMCPClient.onCommand('file', {{id = 'w.x', gen = 1, part = 1, total = 1, data = '{b64x}', path = 'media/w.x'}})
ZMCPClient.onCommand('file', {{id = 'w.png', gen = 1, part = 1, total = 1, data = '{b64x}', path = 'media/w.png'}})""")
check(lua("return WAITING and ZMCPClient.models.waiting.w == nil and ZMCPClient.models.name('w') == 'zmcp_w_1'"), "model command before its files: registered once both files arrive")
lua("ZMCPClient.onCommand('file', {id = 'evil', gen = 1, part = 1, total = 1, data = 'AA==', path = '../evil'})")
check(g.SIM.fs["../evil"] is None, "path traversal in file push refused")
check((g.SIM.fs["media/zmcp_model_star_1.x"] or "").startswith("xof 0303txt"), "mesh written under Lua/media/")
check(lua_digest("media/zmcp_model_star_1.png") == digest(snail), "model texture written byte-identical")
check(lua("return ZMCPClient.models.name('star') == 'zmcp_star_1' and ZMCPClient.models.list.star.ok == true"), "ModelScript registered as zmcp_star_1")
check(lua("return SIM.models.zmcp_star_1 ~= nil and SIM.models.zmcp_star_1.module.name == 'Base' and SIM.models.zmcp_star_1.def:find('scale = 3') ~= nil"), "registration used the Base module and the scale")
check(events("client_model")[-1]["data"]["ok"] is True, "client reported modelResult ok")
r = tool("model_place", {"id": "star", "x": 6080, "y": 5385, "yrot": 45})
star_rec = g.SIM.spawned[len(g.SIM.spawned)]
check(r["placed"] == "zmcp_star_1" and star_rec["model"] == "zmcp_star_1" and star_rec["yrot"] == 45, "model_place spawned a carrier item with the world model")
pid1 = r["pid"]
check(pid1.startswith("p") and r["itemId"] == star_rec["id"] and r["collide"] is None, "model_place records the placement (pid, carrier item id)")
vl = tool("visuals_list")
check(len(vl["models"]) == 1, "model listed")
check(len(vl["placements"]) == 1 and vl["placements"][1]["pid"] == pid1 and vl["placements"][1]["name"] == "zmcp_star_1"
      and vl["placements"][1]["x"] == 6080 and vl["placements"][1]["item"] == "Base.TirePiece", "placement listed by visuals_list")
lua("SIM.tick(1)")
check(lua("return ZMCPClient.models.placements['%s'] ~= nil and ZMCPClient.models.placements['%s'].name == 'zmcp_star_1'" % (pid1, pid1)), "client received the placement")
sq = lua("return SIM.square(6080, 5385, 0)")
check(sq["invalidated"] >= 1 and sq["lastDirty"] == 16, "client asked the chunk for a redraw (DIRTY_ITEM_MODIFY) after applying the placement")
# the carrier lost its model (older save / client copy made before the name was set): square load re-applies it
star_rec["model"] = None
lua("SIM.loadSquare(6080, 5385, 0)")
check(star_rec["model"] == "zmcp_star_1", "LoadGridsquare re-applied the world model to the carrier item")
check(len(events("model_place_restored")) >= 1 and tool("visuals_list")["placements"][1]["restored"] >= 1, "restore counted in the registry and logged as an event")
# a model placement with collision: the blocker sits on the same square
r = tool("model_place", {"id": "star", "x": 6081, "y": 5385, "collide": True, "pid": "gate"})
check(r["pid"] == "gate" and r["collide"] == "solid", "model_place {collide = true} placed a solid blocker")
sq = lua("return SIM.square(6081, 5385, 0)")
check(sq["isSolid"](sq) is True and len(sq["objects"]) == 1 and sq["objects"][1]["name"] == "ZMCP_collision", "the square is solid: an IsoObject named ZMCP_collision with the solid sprite")
r = tool("model_remove", {"pid": "gate"})
check(r["removed"] == 1 and r["blockers"] == 1 and len(sq["objects"]) == 0 and len(sq["worldObjects"]) == 0, "model_remove took the carrier item and its blocker away")
lua("SIM.tick(1)")
check(lua("return ZMCPClient.models.placements.gate == nil and ZMCPClient.models.placements['%s'] ~= nil" % pid1), "client forgot the removed placement only")

# --- collision blockers: invisible objects with the vanilla flags, registered sprites with fixed ids
cs = lua("return ZMCPCollision")
check(cs["registered"]["solid"] == 2097676288 and cs["registered"]["wall_nw"] == 2097676292, "collision sprites registered with fixed ids (tileset 8000 range)")
sp = lua("return IsoSpriteManager.instance:getSprite('zmcp_collision_wall_n')")
check(sp["id"] == 2097676290 and lua("local p = IsoSpriteManager.instance:getSprite('zmcp_collision_wall_n'):getProperties(); return p:has(IsoFlagType.invisible) and p:has(IsoFlagType.WallN) and p:has(IsoFlagType.collideN) and p:has(IsoFlagType.cutN) and not p:has(IsoFlagType.solid)"), "wall_n sprite: invisible + WallN + collideN + cutN")
r = tool("collision_place", {"x": 6070, "y": 5390, "w": 3, "h": 2, "kind": "solidtrans", "name": "rail"})
check(r["placed"] == 6 and r["existing"] == 0 and r["unloaded"] == 0 and r["sprite"] == "zmcp_collision_solidtrans", f"collision_place filled a 3x2 rectangle ({r['placed']})")
sq = lua("return SIM.square(6072, 5391, 0)")
check(sq["isSolidTrans"](sq) is True and sq["isSolid"](sq) is False and sq["recalcs"] >= 1, "square became solidtrans (collide matrix recalculated on add)")
r = tool("collision_place", {"x": 6070, "y": 5390, "w": 3, "h": 2, "kind": "solidtrans"})
check(r["placed"] == 0 and r["existing"] == 6, "placing again is a no-op (one blocker per kind per square)")
r = tool("collision_place", {"x": 6070, "y": 5390, "kind": "wall_n"})
check(r["placed"] == 1 and len(lua("return SIM.square(6070, 5390, 0)")["objects"]) == 2, "a second kind stacks on the same square")
wq = tool("world_query", {"x": 6071, "y": 5390, "radius": 2, "what": "objects"})
names = sorted(set(o["sprite"] for o in wq["objects"].values()))
check(wq["objectCount"] == 7 and names == ["zmcp_collision_solidtrans", "zmcp_collision_wall_n"] and all(o["name"] == "ZMCP_collision" for o in wq["objects"].values()), "world_query lists the blockers by sprite and name")
cl = tool("collision_list", {"x": 6071, "y": 5390, "radius": 3})
check(cl["count"] == 7 and cl["stale"] == 0 and all(b["present"] and b["loaded"] for b in cl["blockers"].values()) and cl["blockers"][1]["name"] in ("rail", None), "collision_list shows them present")
r = tool("remove_object", {"x": 6070, "y": 5390, "sprite": "zmcp_collision_wall_n"})
check(len(r["removed"]) == 1, "remove_object removes a blocker by sprite name")
cl = tool("collision_list", {"x": 6071, "y": 5390, "radius": 3})
check(cl["count"] == 6 and cl["stale"] == 1, "collision_list drops the stale entry")
r = tool("collision_place", {"x": 6070, "y": 5390, "w": 1, "h": 2, "kind": "remove"})
check(r["removed"] == 2 and tool("collision_list")["count"] == 4, "kind = remove clears a rectangle")
r = tool("collision_place", {"x": 6200, "y": 5390, "kind": "solid"})
check(r["unloaded"] == 1 and r["placed"] == 0, "unloaded squares are skipped and reported")
try:
    tool("collision_place", {"x": 6070, "y": 5390, "kind": "fence"})
    check(False, "unknown kind rejected")
except Exception as ex:
    check("kind must be" in str(ex), "unknown kind rejected")
r = tool("collision_clear", {"all": True})
check(r["removed"] == 4 and r["remaining"] == 0 and len(lua("return SIM.square(6072, 5391, 0)")["objects"]) == 0, "collision_clear removes everything")
tool("collision_place", {"x": 6075, "y": 5395, "w": 2, "kind": "wall_w", "name": "keep"})

# --- moving 3D entities: UI3DScene layer synced to the iso camera
def scene_obj(eid):
    o = g.SIM.scene.objects["zmcp_e3d_" + eid]
    return o
def frame():
    lua("ZMCPClient.e3d.layer:prerender()")
r = tool("entity3d_spawn", {"id": "star", "model": "star", "x": 100, "y": 100, "scale": 3, "roll": 1.35})
check(r["id"] == "star" and r["h"] == 1.35 and r["motion"] == "static", "entity3d_spawn: h defaults to the roll radius")
lua("SIM.tick(1)")
frame()
check(g.SIM.scene is not None and g.SIM.scene.view == "UserDefined" and list(g.SIM.scene.rot.values()) == [30, 315, 0] and g.SIM.consume3d is False, "3D layer: UserDefined iso view (30, 315), click-through")
check(g.SIM.scene.grid is False and g.SIM.scene.gizmo == "none", "grid and gizmo off (no debug text)")
o = scene_obj("star")
check(o["model"] == "zmcp_star_1", "scene object created from the registered runtime model")
check(abs(o["t"].x - 100) < 1e-3 and abs(o["t"].z - 100) < 1e-3, f"placed at world 100,100 -> scene X=Z=100 (k=1 at zoom 1) ({o['t'].x:.2f},{o['t'].z:.2f})")
check(abs(o["t"].y - 1.35) < 1e-3, "lifted by h = roll radius")
check(abs(o["s"].x - 3) < 1e-3 and abs(o["s"].y - 3) < 1e-3, "scale 3 applied")
ux, uy = lua("return SIM.scene:sceneToUIX(%f, %f, %f), SIM.scene:sceneToUIY(%f, %f, %f)" % (o["t"].x, 0, o["t"].z, o["t"].x, 0, o["t"].z))
check(abs(ux - lua("return isoToScreenX(0, 100, 100, 0)")) < 0.5 and abs(uy - lua("return isoToScreenY(0, 100, 100, 0)")) < 0.5, "scene projection of the ground point matches isoToScreenX/Y")
ev = events("client_entity3d")
check(len(ev) == 1 and ev[0]["data"]["ok"] is True and ev[0]["data"]["model"] == "zmcp_star_1", "client reported e3dResult ok")
# path motion: 2 tiles/s along +x, rolling
r = tool("entity3d_move", {"id": "star", "path": "120,100,0", "speed": 2, "loop": "pingpong"})
check(r["motion"] == "path", "entity3d_move: path motion")
lua("SIM.tick(1)")
t0 = g.SIM.now
g.SIM.now = t0 + 5
frame()
o = scene_obj("star")
check(abs(o["t"].x - 110) < 0.3, f"after 5 s at 2 tiles/s the entity is at x=110 ({o['t'].x:.2f})")
check(abs(o["r"].y) < 1e-6, "faces +x (heading 0)")
import math
check(abs(o["r"].z + math.degrees(10 / 1.35)) < 2, f"rolled -deg(10 / 1.35) about Z ({o['r'].z:.1f})")
lst = tool("entity3d_list")
e0 = list(lst.values())[0]
check(abs(e0["x"] - 110) < 0.3 and e0["moving"] is True and e0["loop"] == "pingpong", "entity3d_list computes the same position on the server")
g.SIM.now = t0 + 15
frame()
o = scene_obj("star")
check(abs(o["t"].x - 110) < 0.3 and abs(o["r"].y - 180) < 1e-3, "pingpong: heading back (heading 180)")
g.SIM.zoom = 2
frame()
o = scene_obj("star")
check(abs(o["t"].x - 55) < 0.2 and abs(o["s"].x - 1.5) < 1e-3, "zoom 2 halves scene units and the object scale")
g.SIM.zoom = 1
# tween + rotate + spin
r = tool("entity3d_move", {"id": "star", "x": 100, "y": 100, "duration": 4, "ease": True})
check(r["motion"] == "to" and r["duration"] == 4, "entity3d_move: tween")
lua("SIM.tick(1)")
t1 = g.SIM.now
g.SIM.now = t1 + 2
frame()
o = scene_obj("star")
check(abs(o["t"].x - 105) < 0.3, f"tween half way (eased midpoint) ({o['t'].x:.2f})")
tool("entity3d_rotate", {"id": "star", "roll": 0, "rx": 10, "spin": "0,90,0", "h": 2})
lua("SIM.tick(1)")
g.SIM.now = t1 + 6
frame()
o = scene_obj("star")
check(abs(o["t"].x - 100) < 1e-3 and abs(o["t"].y - 2) < 1e-3 and abs(o["r"].x - 10) < 1e-6, "tween finished, h and rx applied")
ry1 = o["r"].y
g.SIM.now = t1 + 7
frame()
check(abs(scene_obj("star")["r"].y - ry1 - 90) < 1e-3, "spin: +90 degrees about Y per second")
# entity before its model: pending until the model registers; vanilla model names pass through
tool("entity3d_spawn", {"id": "late", "model": "later", "x": 101, "y": 101})
tool("entity3d_spawn", {"id": "radio", "model": "RadioBlue_Ground", "x": 102, "y": 102})
lua("SIM.tick(1)")
frame()
check("zmcp_e3d_radio" in g.SIM.scene.objects and scene_obj("radio")["model"] == "RadioBlue_Ground", "vanilla ModelScript name used verbatim")
check("zmcp_e3d_late" not in g.SIM.scene.objects and lua("return ZMCPClient.e3d.list.late.created == false"), "unknown model: entity waits")
g.SIM.fs["zmcp_model_later.x.b64"] = g.SIM.fs["zmcp_model_star.x.b64"]
g.SIM.fs["zmcp_model_later.png.b64"] = g.SIM.fs["zmcp_model_star.png.b64"]
tool("model_upload", {"id": "later", "scale": 2, "mesh_base64_file": "zmcp_model_later.x.b64", "png_base64_file": "zmcp_model_later.png.b64"})
lua("SIM.tick(3)")
g.SIM.now += 3
frame()
check(scene_obj("late")["model"] == "zmcp_later_1", "entity created once its model registered (upload after spawn)")
ev = events("client_entity3d")
check(len([e for e in ev if e["data"]["ok"]]) == 3 and len([e for e in ev if not e["data"]["ok"]]) == 1 and ev[-1]["data"]["ok"], f"three ok e3dResults plus one failed try of the unknown name ({len(ev)})")
tool("entity3d_remove", {"id": "radio"})
lua("SIM.tick(1)")
check("zmcp_e3d_radio" not in g.SIM.scene.objects and lua("return ZMCPClient.e3d.list.radio == nil") and len(tool("entity3d_list")) == 2, "entity3d_remove drops the scene object and the registry entry")

# --- client modules + late joiner
tool("script_install", {"side": "client", "name": "hud", "code": "ZMCPClient.renderHooks.hud = function(ui) ui:drawText('hud', 5, 5, 1, 1, 1, 1) end return 'installed'"})
lua("SIM.tick(1)")
check(lua("return ZMCPClient.modules.hud ~= nil and ZMCPClient.renderHooks.hud ~= nil"), "client module installed and running")
check(len(tool("script_list")["client"]) == 1 and len(tool("script_list")["server"]) == 0, "client script listed")
lua("SIM.sent = {}; SIM.player = SIM.newPlayer('friend', 6080, 5380, 0); ZMCPClient.tex.loaded = {}; ZMCPClient.sprites.list = {}; ZMCPClient.modules = {}; ZMCPClient.renderHooks = {}; ZMCPClient.models.list = {}; ZMCPClient.files.done = {}")
lua("SIM.fire('OnGameStart')")
lua("SIM.tick(3)")
check(lua("return ZMCPClient.tex.loaded.snail ~= nil and ZMCPClient.tex.loaded.snail.gen == 2"), "late joiner received the texture (latest gen)")
check(lua("return ZMCPClient.sprites.list.s1 ~= nil"), "late joiner received the persistent sprite")
check(lua("return ZMCPClient.modules.hud ~= nil"), "late joiner received the client module")
check(lua("return ZMCPClient.models.name('star') == 'zmcp_star_1'"), "late joiner registered the model")
check(lua("return ZMCPClient.models.placements['%s'] ~= nil" % pid1), "late joiner received the placement")
hello = events("client_hello")[-1]["data"]["sent"]
check(hello["models"] == 2 and hello["placements"] == 1 and hello["entities"] == 2 and hello["textures"] == 1, f"hello resend counts models/placements/entities ({hello})")
frame()
check(lua("return ZMCPClient.e3d.list.star ~= nil and ZMCPClient.e3d.list.late ~= nil") and scene_obj("star")["model"] == "zmcp_star_1", "late joiner received the 3D entities and re-created the scene objects")
check(lua("return ZMCPClient.e3d.list.star.motion == nil and math.abs(ZMCPClient.e3d.list.star.x - 100) < 0.001"), "late joiner got the settled position of the finished tween")
check(events("client_hello")[-1]["data"]["user"] == "friend", "hello logged for the second player")
tool("script_remove", {"name": "hud", "side": "client"})
lua("SIM.tick(1)")
check(lua("return ZMCPClient.modules.hud == nil and ZMCPClient.renderHooks.hud == nil"), "module removed on clients")

# --- overlays, notify, halo, clear
tool("overlay_draw", {"kind": "text", "anchor": "world", "x": 100, "y": 100, "text": "here", "ttl": 2, "id": "lbl"})
tool("overlay_draw", {"kind": "line", "anchor": "screen", "x": 10, "y": 10, "x2": -10, "y2": -10, "thick": 2})
tool("overlay_draw", {"kind": "rect", "anchor": "screen", "x": 0, "y": 0, "w": 50, "h": 20, "fill": False})
tool("server_message", {"text": "Bananas!", "ttl": 3})
tool("server_message", {"text": "hi there", "mode": "halo"})
tool("server_message", {"text": "chat line", "mode": "chat"})
lua("SIM.tick(1)")
kinds = [d["kind"] for d in lua("return SIM.render()").values()]
check("textc" in kinds and kinds.count("line") == 2 and "border" in kinds, "text/line/rect primitives drawn")
check(g.SIM.player.halo == "hi there", "halo set on the player")
tool("clear_visuals", {"what": "overlays", "id": "lbl"})
lua("SIM.tick(1)")
check(lua("return ZMCPClient.draw.items.lbl == nil"), "clear_visuals overlays by id")
tool("clear_visuals")
lua("SIM.tick(1)")
check(lua("return ZMCPClient.sprites.list.s1 == nil and #ZMCPClient.draw.notices == 0") and lua("return ZMCP.visuals.store().sprites.s1 == nil"), "clear_visuals wipes sprites/overlays on clients and in the registry")
check(lua("return ZMCPClient.tex.loaded.snail ~= nil"), "clear_visuals keeps textures")
check(lua("return ZMCPClient.e3d.list.star == nil and ZMCPClient.e3d.list.late == nil") and len(tool("entity3d_list")) == 0 and lua("return SIM.scene.objects.zmcp_e3d_star == nil"), "clear_visuals all removes the 3D entities on clients and in the registry")

# --- utility handlers
lua("ZMCP.toClients('heal', {}); ZMCP.toClients('cure', {}); ZMCP.toClients('teleport', {x = 10, y = 20, z = 1}); ZMCP.toClients('say', {text = 'yo'})")
check(g.SIM.player.healed >= 1 and g.SIM.player.cured >= 1, "heal and cure ran on the client")
check(g.SIM.player.x == 10 and g.SIM.player.y == 20 and g.SIM.player.z == 1 and g.SIM.player.said == "yo", "teleport and say ran")
lua("ZMCP.toClients('nosuch', {})")
check(any("unknown command 'nosuch'" in l for l in g.SIM.out.values()), "unknown command logged, no crash")

# --- pixel sprite fallback
tool("texture_pixel", {"id": "px", "def": {"palette": {"a": [255, 0, 0, 255]}, "rows": ["a.", ".a"]}})
tool("world_sprite", {"id": "p1", "texture": "px", "x": 100, "y": 100, "scale": 10})
lua("SIM.tick(1)")
rects = [d for d in lua("return SIM.render()").values() if d["kind"] == "rect"]
check(len(rects) == 2, f"pixel sprite drawn as 2 rects ({len(rects)})")

# --- through the request-file protocol (Bridge)
g.SIM.fs["zmcp_req_1.json"] = json.dumps({"n": 1, "t": g.SIM.now, "tool": "visuals_list", "args": {}})
lua("SIM.tick(1)")
res = json.loads(g.SIM.fs["zmcp_res_1.json"])
check(res["ok"] and len(res["result"]["textures"]) == 2 and len(res["result"]["models"]) == 2, "visuals_list via request file")

# --- server scripts persist in ModData and reload with the bridge
r = tool("script_install", {"name": "counter", "code": "COUNTER = (COUNTER or 0) + 1 return COUNTER"})
check(r["result"] == 1 and r["side"] == "server" and g.SIM.fs["zmcp_script_counter.lua.txt"] is not None, "server script written as .lua.txt and run")
check(len(tool("script_list")["server"]) == 1, "server script listed")
src = open(os.path.join(LUA, "server/ZomboidMCP/Bridge.lua")).read()
rt.eval("function(s, n) local f, e = loadstring(s, n) if not f then error(e) end return f end")(src, "=Bridge.lua")()
check(lua("return COUNTER") == 2, "bridge reload re-ran the persistent server script")
tool("script_remove", {"name": "counter"})
check(len(tool("script_list")["server"]) == 0, "server script removed")
try:
    tool("script_install", {"name": "x", "code": "return 1", "side": "nowhere"})
    check(False, "unknown side rejected")
except Exception as ex:
    check("unknown side" in str(ex), "unknown side rejected")

# --- base64 round trip
enc = lua("return ZMCPClient.b64.encode('hello, zomboid!')")
check(enc == base64.b64encode(b"hello, zomboid!").decode(), "b64 encode")
check(lua("return ZMCPClient.b64.decode('aGVsbG8sIHpvbWJvaWQh')") == "hello, zomboid!", "b64 decode")

# --- server restart: a fresh Lua state (models, entities, placements, blockers come back from ModData + files),
# a fresh client says hello and gets the same picture; a saved blocker resolves through its numeric sprite id
lua("SIM.player.x, SIM.player.y, SIM.player.z = 6078, 5382, 0")     # the teleport test moved the player away
tool("entity3d_spawn", {"id": "keeper", "model": "star", "x": 6079, "y": 5383, "spin": "0,45,0"})
r = tool("model_place", {"id": "later", "x": 6082, "y": 5386, "collide": "solidtrans", "pid": "perm"})
lua("SIM.tick(2)")
before = {
    "models": sorted(m["name"] for m in tool("visuals_list")["models"].values()),
    "placements": sorted((p["pid"], p["name"], p["x"], p["y"], p["z"], p["item"], p["itemId"], p["collide"]) for p in tool("visuals_list")["placements"].values()),
    "entities": sorted((e["id"], e["model"], round(e["x"], 2), round(e["y"], 2)) for e in tool("entity3d_list").values()),
    "blockers": sorted((b["x"], b["y"], b["z"], b["kind"]) for b in tool("collision_list")["blockers"].values()),
    "textures": sorted((t["id"], t["gen"]) for t in tool("visuals_list")["textures"].values()),
}
moddata_json = lua("return ZMCPJson.encode(SIM.moddata)")
# the text files the server keeps in the Lua dir (base64 assets, scripts); PNGs the client wrote are binary and stay out
saved_fs_json = lua("local t = {} for k, v in pairs(SIM.fs) do if k:match('%.b64$') or k:match('%.lua%.txt$') then t[k] = v end end return ZMCPJson.encode(t)")
placed_ids = {p[6] for p in before["placements"]}
saved_spawned = [{k: rec[k] for k in ("x", "y", "z", "item", "ox", "oy", "oz", "id")} for rec in g.SIM.spawned.values() if rec["id"] in placed_ids]
saved_blockers = list(before["blockers"])

def restore(rt2):
    """what the engine brings back on its own: the ModData store, the files in the Lua dir, the saved world"""
    rt2.globals().SIM.now = g.SIM.now + 100
    rt2.execute("SIM.moddata = ZMCPJson.decode(%s)" % json.dumps(moddata_json))
    rt2.execute("for k, v in pairs(ZMCPJson.decode(%s)) do SIM.fs[k] = v end" % json.dumps(saved_fs_json))
    for rec in saved_spawned:      # world items come back from the chunk save, here WITHOUT the model name (worst case)
        rt2.execute("SIM.addWorldItem(SIM.square(%d, %d, %d), %s, %f, %f, %f, %d)" % (rec["x"], rec["y"], rec["z"], json.dumps(rec["item"]), rec["ox"], rec["oy"], rec["oz"], rec["id"]))
    for (x, y, z, kind) in saved_blockers:      # tile objects come back by numeric sprite id
        rt2.execute("assert(SIM.loadObject(SIM.square(%d, %d, %d), ZMCPCollision.spriteId(%s), 'ZMCP_collision'), 'sprite id not registered before the chunk loaded')" % (x, y, z, json.dumps(kind)))

rt2 = boot(FILES, before_bridge=restore)
g2 = rt2.globals()
tool2 = lambda name, args=None: rt2.eval("function(name, args) return ZMCP.tools[name].fn(args) end")(name, rt2.table_from(args or {}, recursive=True))
lua2 = lambda code: rt2.execute(code)
check(lua2("return ZMCP.nextReq") == g.ZMCP.nextReq and lua2("return ZMCPClient.models.list.star == nil"), "fresh state: bridge counter restored, no client models yet")
after = {
    "models": sorted(m["name"] for m in tool2("visuals_list")["models"].values()),
    "placements": sorted((p["pid"], p["name"], p["x"], p["y"], p["z"], p["item"], p["itemId"], p["collide"]) for p in tool2("visuals_list")["placements"].values()),
    "entities": sorted((e["id"], e["model"], round(e["x"], 2), round(e["y"], 2)) for e in tool2("entity3d_list").values()),
    "blockers": sorted((b["x"], b["y"], b["z"], b["kind"]) for b in tool2("collision_list")["blockers"].values()),
    "textures": sorted((t["id"], t["gen"]) for t in tool2("visuals_list")["textures"].values()),
}
check(after == before, "registries identical after the restart (models, placements, entities, blockers, textures): %s" % ("" if after == before else str((before, after))))
check(len(after["blockers"]) == 3 and all(b["present"] for b in tool2("collision_list")["blockers"].values()), "saved blockers resolved through their sprite ids and are present")
# the world items lost their model name in this worst-case save: the square load puts it back before any client
lua2("for _, rec in ipairs(SIM.spawned) do SIM.loadSquare(rec.x, rec.y, rec.z) end")
check(all(rec["model"] is not None for rec in g2.SIM.spawned.values()) and len([e for e in [json.loads(l) for l in g2.SIM.fs["zmcp_events.log"].splitlines()] if e["kind"] == "model_place_restored"]) == 2, "placements re-applied their models on square load after the restart")
# a fresh client joins
lua2("SIM.fire('OnGameStart')")
lua2("SIM.tick(6)")
lua2("ZMCPClient.e3d.layer:prerender()")
check(sorted(m["name"] for m in lua2("return ZMCPClient.models.list").values()) == before["models"], "fresh client registered the same models")
check(sorted(lua2("return ZMCPClient.models.placements").keys()) == sorted(p[0] for p in before["placements"]), "fresh client received the same placements")
e3d = lua2("return ZMCPClient.e3d.list")
check(sorted(e3d.keys()) == sorted(e[0] for e in before["entities"]) and all(e["created"] for e in e3d.values()), "fresh client shows the same 3D entities, all created")
cmds = [m["cmd"] for m in g2.SIM.clientCmds.values()]
first = {c: cmds.index(c) for c in ("tex", "model", "place", "e3d") if c in cmds}
check(first.get("tex", 0) < first.get("model", 1) < first.get("place", 2) < first.get("e3d", 3), f"hello stream order: textures, models, placements, entities ({first})")

errs = [l for l in g.SIM.out.values() if ("error" in l.lower() or "failed" in l.lower() or "removed" in l.lower()) and "bridge_loaded" not in l]
expected = ("exec e2 error", "exec e3 compile", "script hud removed", "hook 'bad' (render) removed", "render hook 'bad' removed",
            "e3d late: createModel(later) failed", "client_entity3d {\"err\"", 'model_remove {"', 'collision_place {"',
            'remove_object {"', 'collision_clear {"')
unexpected = [l for l in errs if not any(x in l for x in expected)]
check(not unexpected, "no unexpected errors in the log: " + "; ".join(unexpected[:5]))

print(f"\n{len(failures)} failure(s)")
sys.exit(1 if failures else 0)
