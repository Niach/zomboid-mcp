#!/usr/bin/env python3
"""Offline end-to-end test of the scene SDK (Api/Scenes.lua + ClientScenes.lua) and screen apps (ClientApps.lua)
under a standalone Lua 5.1 (pip install lupa) with the mocked engine of tests/sim/sim_prelude.lua: waits, parallel,
triggers with cooldown, near-only ambience, actor walkTo with a mocked zombie, sprite actors (moveTo, frames, fade,
bubble, click), dialogs, signals, lights, snapshot/restore, error isolation, stop/cleanup, persistence across a reload,
and a screen app (start, focus, keys, mouse, score, Esc, error). Finally the shipped examples run in the sandbox."""
import json, os, sys
from lupa import lua51

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LUA = os.path.join(ROOT, "mod/Contents/mods/ZomboidMCP/42/media/lua")
EXAMPLES = os.path.join(ROOT, "examples")
FILES = [
    "shared/ZomboidMCP/Json.lua",
    "server/ZomboidMCP/Bridge.lua",
    "server/ZomboidMCP/Api/Visuals.lua",
    "server/ZomboidMCP/Api/Scenes.lua",
    "client/ZomboidMCP/ClientBase64.lua",
    "client/ZomboidMCP/ClientTextures.lua",
    "client/ZomboidMCP/ClientSprites.lua",
    "client/ZomboidMCP/ClientFalling.lua",
    "client/ZomboidMCP/ClientOverlay.lua",
    "client/ZomboidMCP/ClientInput.lua",
    "client/ZomboidMCP/ClientModels.lua",
    "client/ZomboidMCP/ClientScenes.lua",
    "client/ZomboidMCP/ClientApps.lua",
    "client/ZomboidMCP/Client.lua",
]

rt = lua51.LuaRuntime(unpack_returned_tuples=True)
g = rt.globals()
rt.execute(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "sim_prelude.lua")).read())
rt.execute("next = nil; io = nil; bit = nil; string.dump = nil; load = nil; dofile = nil; loadfile = nil; coroutine.wrap = nil; coroutine.running = nil")
loader = rt.eval("function(s, n) local f, e = loadstring(s, n) if not f then error(e) end return f end")


def load(f):
    loader(open(os.path.join(LUA, f)).read(), "=" + f)()


for f in FILES:
    load(f)

# world tools the SDK forwards to (Items/Objects/Environment/Zombies need the full engine): record calls instead
rt.execute("""
CALLS = {}
for _, name in ipairs({'spawn_item', 'give_item', 'place_object', 'remove_object', 'build_structure', 'set_weather', 'set_time',
                       'spawn_zombies', 'kill_zombies_area'}) do
    ZMCP.tool(name, 'mock', function(a) CALLS[#CALLS + 1] = { tool = name, args = a }; return { mock = name } end)
end
""")

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


def try_tool(name, args=None):
    try:
        return tool(name, args), None
    except Exception as ex:
        return None, str(ex)


def events(kind):
    return [json.loads(l) for l in (g.SIM.fs["zmcp_events.log"] or "").splitlines() if json.loads(l)["kind"] == kind]


def calls(name):
    return [c for c in g.CALLS.values() if c["tool"] == name]


def scene(name):
    for s in tool("scene_list")["scenes"].values():
        if s["name"] == name:
            return s
    return None


def logs(name):
    return list(tool("scene_logs", {"name": name})["logs"].values())


def advance(sec, step=0.1):
    """let game time pass: ticks every `step` seconds (the bridge tick drives the scheduler)"""
    n = max(1, int(round(sec / step)))
    lua("SIM.tick(%d, %f)" % (n, step))


PX, PY = 6078, 5382       # SIM.player position

# --- load
check(lua("return ZMCP.tools.scene_start ~= nil and ZMCP.tools.app_start ~= nil and ZMCP.tickHooks.scenes ~= nil"), "scene/app tools and tick hook registered")
check(len(events("scenes_loaded")) == 1, "scenes_loaded event")
lua("SIM.fire('OnGameStart')")
lua("function GHOST() return ZMCP.scenes.list.spr.env.GHOST end")   # scene globals live in the scene's sandbox

# --- waits, parallel, race, logs, state
r = tool("scene_start", {"name": "basic", "code": """
log('start', args.n)
local r = parallel(function() wait(1) return 'a' end, function() wait(2) return 'b' end)
log('parallel', r[1], r[2])
local who = race(function() wait(5) return 'slow' end, function() wait(0.5) return 'fast' end)
log('race', who)
state.runs = (state.runs or 0) + 1
local ok = waitUntil(function() return false end, 0.3)
log('timeout', tostring(ok))
""", "args": {"n": 7}})
check(r["status"] == "running" and r["persistent"] is False, "scene_start returns running")
check(logs("basic")[0].endswith("start 7"), "args reach the script, log() records")
advance(0.5)
check(scene("basic")["status"] == "running", "still running after 0.5 s")
advance(2.0)
check(any(l.endswith("parallel a b") for l in logs("basic")), "parallel waited for both and returned results")
advance(1.0)
check(any(l.endswith("race 2") for l in logs("basic")), "race returned the index of the fast task")
advance(0.5)
s = scene("basic")
check(s["status"] == "done" and s["state"]["runs"] == 1, "scene finished; state saved in ModData")
check(any(l.endswith("timeout false") for l in logs("basic")), "waitUntil timeout returns false")
check(len(events("scene_done")) == 1 and len(events("scene_start")) == 1, "scene_start / scene_done events")

# --- error isolation
tool("scene_start", {"name": "crash", "code": "wait(0.2) error('boom')"})
tool("scene_start", {"name": "steady", "code": "every(0.1, function(n) state.n = n end)"})
advance(0.5)
check(scene("crash")["status"] == "error" and "boom" in scene("crash")["error"], "a throwing scene ends with status error")
check(events("scene_error")[-1]["data"]["name"] == "crash" and "boom" in events("scene_error")[-1]["data"]["error"], "scene_error event")
check(scene("steady")["status"] == "running" and scene("steady")["state"]["n"] >= 3, "other scenes keep running")
_, err = try_tool("scene_start", {"name": "bad", "code": "this is not lua"})
check(err is not None and "compile" in err, "compile error is returned by scene_start")
r = tool("scene_start", {"name": "bad2", "code": "error('at once')"})
check(r["status"] == "error" and "at once" in r["error"], "an immediate runtime error is returned by scene_start")
tool("scene_start", {"name": "childerr", "code": "every(0.1, function() error('child') end) wait(1) log('main alive')"})
advance(1.2)
check(scene("childerr")["status"] == "done" and any("main alive" in l for l in logs("childerr")), "a failing child task does not kill the main task")
check(lua("return ZMCP.tickHooks.scenes(ZMCP.now()) == nil"), "tick hook never throws")

# --- actor: spawn, walkTo (mocked zombie walks 1 tile/tick), say, face, remove on stop
tool("scene_start", {"name": "merchant_t", "code": """
local m = spawnActor{ kind = 'zombie', outfit = 'Bandit', x = %d, y = %d, name = 'Bob', passive = true }
m:face(%d, %d)
local ok = m:walkTo(%d, %d, { dist = 1, timeout = 30 })
log('arrived', tostring(ok))
m:say('hello there')
state.actor = m.name
wait(60)
""" % (PX + 8, PY, PX, PY, PX, PY)})
zed = lua("return SIM.zombies[#SIM.zombies]")
check(zed is not None and zed["useless"] is True and zed["outfit"] == "Bandit", "actor spawned passive with the outfit")
check(zed["facing"][1] == PX, "actor:face called faceLocationF")
advance(1.5)
check(any(l.endswith("arrived true") for l in logs("merchant_t")), "walkTo returned true when the puppet arrived")
check(abs(zed["x"] - (PX + 0.5)) < 1.1 and zed["paths"] >= 1, "puppet pathed to the target")
check(zed["said"][1] == "hello there", "actor:say used the engine Say line")
check(lua("return ZMCPClient.scenes.info().bubbles") == 0, "single player: no duplicate bubble for a zombie without online id")
r = tool("scene_stop", {"name": "merchant_t"})
check(r["was_running"] is True and zed["removed"] is True, "scene_stop removed the puppet")
check(events("scene_stopped")[-1]["data"]["name"] == "merchant_t", "scene_stopped event")

# --- sprite actor: pixel texture, moveTo (path + speed), frames, fade, bubble, click
tool("texture_pixel", {"id": "ghost", "def": {"palette": {"a": [255, 255, 255, 255]}, "rows": ["aa", "aa"]}})
tool("texture_pixel", {"id": "ghost2", "def": {"palette": {"a": [200, 200, 255, 255]}, "rows": ["aa", "aa"]}})
tool("scene_start", {"name": "spr", "code": """
local s = spriteActor{ texture = texture('ghost'), x = %d, y = %d, scale = 10, frames = {'ghost', 'ghost2'}, fps = 4 }
s:onClick(function(player, x, y) log('clicked by', name(player)) end)
GHOST = s
s:moveTo(%d, %d, { duration = 2 })
log('moved')
s:bubble('boo', 3)
s:fade(0, 1)
log('faded')
wait(30)
""" % (PX, PY, PX + 4, PY)})
advance(0.1)
sp = lua("return ZMCPClient.sprites.list[GHOST().id]")
check(sp is not None and sp["speed"] == 2 and sp["loop"] == "once" and abs(sp["path"][2][1] - (PX + 4)) < 0.001, "moveTo sent a once-path at distance/duration tiles per second")
check(lua("return ZMCPClient.scenes.anims[GHOST().id] ~= nil and #ZMCPClient.scenes.anims[GHOST().id].frames == 2"), "frame animation registered on the client")
lua("SIM.render()")
g.SIM.now = g.SIM.now + 0.3
lua("SIM.fire('OnTick')")
tex_now = lua("return ZMCPClient.sprites.list[GHOST().id].tex")
check(tex_now in ("ghost", "ghost2"), "animation swaps the sprite texture between frames")
check(lua("return ZMCPClient.scenes.watch.clicks[GHOST().id] == 'spr'"), "click watcher registered for the sprite")
advance(2.0)
check(any(l.endswith("moved") for l in logs("spr")), "moveTo returned after the duration")
sp = lua("return ZMCPClient.sprites.list[GHOST().id]")
check(abs(sp["x"] - (PX + 4)) < 0.001 and len(sp["path"]) == 1, "sprite pinned at the target without a path")
check(lua("return ZMCPClient.scenes.bubbles[GHOST().id] ~= nil and ZMCPClient.scenes.bubbles[GHOST().id].text == 'boo'"), "bubble attached to the sprite")
check(lua("return ZMCPClient.scenes.fades[GHOST().id] ~= nil"), "fade tween registered")
lua("SIM.render()")
g.SIM.now = g.SIM.now + 0.5
lua("SIM.fire('OnTick')")
op = lua("return ZMCPClient.sprites.list[GHOST().id].opacity")
check(0 < op < 1, "opacity tweens down (%.2f)" % op)
draws = lua("return SIM.render()")
kinds = [d["kind"] for d in draws.values()]
check("textc" in kinds and "border" in kinds, "bubble drawn (box + text)")
advance(0.6)
check(any(l.endswith("faded") for l in logs("spr")) and lua("return ZMCPClient.sprites.list[GHOST().id].opacity") == 0, "fade finished at opacity 0")
# click on the sprite: hit-test with the sprite's drawn rect
lua("local x, y, w, h = ZMCPClient.scenes.spriteRect(ZMCPClient.sprites.list[GHOST().id]); SIM.fire('OnMouseDown', x + w / 2, y + h / 2)")
advance(0.1)
check(any("clicked by niach" in l for l in logs("spr")), "a click on the sprite reached the scene handler with the player")
lua("GID = GHOST().id")
tool("scene_stop", {"name": "spr"})
advance(0.1)
check(lua("return ZMCPClient.sprites.list[GID] == nil and ZMCPClient.scenes.anims[GID] == nil and ZMCPClient.scenes.bubbles[GID] == nil"), "scene_stop removed sprite, animation and bubble on the client")
check(lua("return ZMCP.visuals.store().sprites[GID] == nil"), "sprite dropped from the late-join registry")

# --- triggers: onPlayerNear with cooldown, re-arm, once; ambient pauses when nobody is near
lua("SIM.player.x, SIM.player.y = %d, %d" % (PX, PY))
tool("scene_start", {"name": "trig", "code": """
state.hits = 0
onPlayerNear(%d, %d, 3, function(p, count) state.hits = count log('near', name(p)) end, { cooldown = 10 })
state.amb = 0
ambient(%d, %d, 5, 0.2, function() state.amb = state.amb + 1 end)
""" % (PX + 20, PY, PX + 40, PY)})
advance(1.0)
check(scene("trig")["state"]["hits"] == 0 and scene("trig")["state"]["amb"] == 0, "nothing fires while the player is far away")
lua("SIM.player.x = %d" % (PX + 19))
advance(1.0)
check(scene("trig")["state"]["hits"] == 1, "onPlayerNear fired once when the player entered")
advance(3.0)
check(scene("trig")["state"]["hits"] == 1, "staying inside does not re-fire")
lua("SIM.player.x = %d" % PX)
advance(1.0)
lua("SIM.player.x = %d" % (PX + 19))
advance(1.0)
check(scene("trig")["state"]["hits"] == 1, "re-entering within the cooldown does not fire")
g.SIM.now = g.SIM.now + 10
lua("SIM.player.x = %d" % PX)
advance(1.0)
lua("SIM.player.x = %d" % (PX + 19))
advance(1.0)
check(scene("trig")["state"]["hits"] == 2, "re-entering after the cooldown fires again")
lua("SIM.player.x = %d" % (PX + 40))
advance(2.0)
amb = scene("trig")["state"]["amb"]
check(amb >= 5, "ambient loop runs while a player is within its radius (%d runs)" % amb)
lua("SIM.player.x = %d" % PX)
advance(2.0)
check(scene("trig")["state"]["amb"] <= amb + 1, "ambient loop pauses when nobody is near")
tool("scene_stop", {"name": "trig"})
tool("scene_start", {"name": "once", "code": "trigger('t', function() return true end, function() state.n = (state.n or 0) + 1 end, { once = true })"})
advance(2.0)
check(scene("once")["state"]["n"] == 1 and scene("once")["status"] == "done", "trigger once fires once and the scene completes")

# --- dialogs (ask), signals, keys
tool("scene_start", {"name": "dlg", "code": """
onKey(57, function(p, key) log('key', key) end)
local choice = ask(players()[1], 'Trade?', { 'Yes', 'No' }, 30)
log('choice', tostring(choice))
local data = waitSignal('go', 30)
log('signal', data and data.act or 'nil')
"""})
advance(0.2)
check(lua("return ZMCPClient.scenes.info().dialogs") == 1 and g.SIM.consume is True and g.SIM.onTop is True, "dialog shown and the overlay captures the mouse")
lua("SIM.render()")  # lays out the buttons
lua("local d = ZMCPClient.scenes.dialogs[ZMCPClient.scenes.dialogOrder[1]]; local b = d.buttons[1]; ZMCPClient.overlay:onMouseDown(b.x + 5, b.y + 5)")
advance(0.2)
check(any(l.endswith("choice Yes") for l in logs("dlg")), "clicking a button answered ask()")
check(lua("return ZMCPClient.scenes.info().dialogs") == 0 and g.SIM.consume is False, "dialog closed and capture released")
check(len(events("scene_choice")) == 1, "scene_choice event")
r = tool("scene_signal", {"name": "dlg", "signal": "go", "data": {"act": 2}})
advance(0.2)
check(r["handlers"] == 1 and any(l.endswith("signal 2") for l in logs("dlg")), "scene_signal woke waitSignal with the data")
lua("SIM.fire('OnKeyStartPressed', 57)")
advance(0.2)
check(any(l.endswith("key 57") for l in logs("dlg")), "a watched key press was forwarded to the scene")
check(scene("dlg")["status"] == "running", "a scene with only listeners (onKey) stays alive after its main task returns")
tool("scene_stop", {"name": "dlg"})
advance(0.1)
check(lua("return ZMCPClient.scenes.watch.keys['57'] == nil"), "key watcher removed with the scene")

# --- lights (addLamppost on clients, resent to late joiners, removed on stop)
tool("scene_start", {"name": "lit", "code": "L = light(%d, %d, 0, 1, 0.2, 0.2, 8) wait(100)" % (PX + 1, PY + 1)})
advance(0.1)
check(len(g.SIM.lights) == 1 and g.SIM.lights[1]["radius"] == 8 and lua("return ZMCPClient.scenes.info().lights") == 1, "light added on the client via addLamppost")
lua("SIM.player = SIM.newPlayer('friend', %d, %d, 0); ZMCPClient.scenes.lights = {}; SIM.lights = {}" % (PX, PY))
lua("SIM.fire('OnGameStart')")
advance(0.3)
check(len(g.SIM.lights) == 1, "late joiner received the running scene's light")
lua("ZMCP.scenes.list.lit.env.L.remove()")
advance(0.1)
check(len(g.SIM.lights) == 0, "light handle remove() removed it")
tool("scene_start", {"name": "lit", "code": "light(1, 1, 0, 1, 1, 1, 5) light(2, 2, 0, 1, 1, 1, 5) wait(100)"})
advance(0.1)
check(len(g.SIM.lights) == 2, "replacing a scene re-creates its lights")
tool("scene_stop", {"name": "lit"})
advance(0.1)
check(len(g.SIM.lights) == 0, "scene_stop removed the lights")
lua("SIM.player = SIM.newPlayer('niach', %d, %d, 0)" % (PX, PY))

# --- snapshot / restore of an area
lua("""
local function put(x, y, sprite, floor) local sq = getCell():getGridSquare(x, y, 0); local o = IsoObject.new(sq, sprite); o.floor = floor; sq:transmitAddObjectToSquare(o) end
put(%d, %d, 'floors_01_1', true); put(%d, %d, 'walls_01_5'); put(%d, %d, 'floors_01_1', true)
""" % (PX + 2, PY + 2, PX + 2, PY + 2, PX + 3, PY + 2))
tool("scene_start", {"name": "snap", "code": """
SNAP = snapshotArea(%d, %d, %d, %d, 0)
state.snap = SNAP
""" % (PX + 2, PY + 2, PX + 3, PY + 3)})
snap_file = lua("return ZMCP.scenes.list.snap.env.SNAP")
check(snap_file.startswith("zmcp_snap_snap_") and g.SIM.fs[snap_file] is not None, "snapshot written to the Lua dir")
snap = json.loads(g.SIM.fs[snap_file])
check(len(snap["squares"]) == 4 and any(len(sq["o"]) == 2 for sq in snap["squares"]), "snapshot lists the objects per square")
lua("""
local sq = getCell():getGridSquare(%d, %d, 0)
sq:transmitAddObjectToSquare(IsoObject.new(sq, 'graffiti_01_3'))       -- added after the snapshot
local objs, wall = sq:getObjects(), nil
for i = 0, objs:size() - 1 do if objs:get(i).sprite == 'walls_01_5' then wall = objs:get(i) end end
sq:transmitRemoveItemFromSquare(wall)
""" % (PX + 2, PY + 2))
tool("scene_start", {"name": "snap2", "code": "RESTORED = restoreArea('%s')" % snap_file})
res = lua("return ZMCP.scenes.list.snap2.env.RESTORED")
tiles = lua("return SIM.tiles['%d,%d,0']" % (PX + 2, PY + 2))
sprites = sorted(o["sprite"] for o in tiles.values())
check(res["removed"] == 1 and res["added"] == 1 and sprites == ["floors_01_1", "walls_01_5"], "restoreArea removed the graffiti and rebuilt the wall (%s)" % sprites)

# --- world helpers forward to the curated tools with the right argument names
tool("scene_start", {"name": "world", "code": """
spawnItem('Base.Axe', %d, %d, 0, 2)
giveItem(players()[1], 'Base.Banana', 3)
placeTile('walls_01_5', %d, %d, 0, 'Wall')
removeTile('walls_01_5', %d, %d, 0)
weather('storm', 0.9)
time(21)
zombies(%d, %d, 0, 2, 'Bandit')
lightning(%d, %d)
sound('Thunder', %d, %d, 0)
sound('UIActivateButton')
message('hello all', 'notify')
dropItemsFromSky('Base.Banana', 3, %d, %d, { radius = 1, duration = 0.1, fall = 0.3 })
""" % ((PX, PY) * 7)})
check(calls("spawn_item")[0]["args"]["item"] == "Base.Axe" and calls("spawn_item")[0]["args"]["count"] == 2, "spawnItem forwarded")
check(calls("give_item")[0]["args"]["player"] == "niach" and calls("give_item")[0]["args"]["count"] == 3, "giveItem forwarded with the username")
check(calls("place_object")[0]["args"]["sprite"] == "walls_01_5" and calls("place_object")[0]["args"]["name"] == "Wall", "placeTile forwarded")
check(calls("remove_object")[0]["args"]["sprite"] == "walls_01_5", "removeTile forwarded")
check(calls("set_weather")[0]["args"]["kind"] == "storm" and calls("set_time")[0]["args"]["hour"] == 21, "weather/time forwarded")
check(calls("spawn_zombies")[0]["args"]["outfit"] == "Bandit" and calls("spawn_zombies")[0]["args"]["count"] == 2, "zombies forwarded")
check(g.SIM.weather[len(g.SIM.weather)]["lightning"][1] == PX, "lightning triggered through the climate manager")
check(any(s["server"] and s["name"] == "Thunder" for s in g.SIM.sounds.values()), "positional sound is a server sound")
advance(0.1)
check(any(s["ui"] and s["name"] == "UIActivateButton" for s in g.SIM.sounds.values()), "sound without a position is a client UI sound")
check(lua("return #ZMCPClient.draw.notices") >= 1 and lua("return #ZMCPClient.falling.list") == 3, "message and dropItemsFromSky reached the client")
check(scene("world")["status"] == "done", "world scene completed without errors")

# --- persistence: file + ModData, restart of the Lua state, state survives, stop forgets
r = tool("scene_start", {"name": "perm", "persistent": True, "args": {"tag": "keep"}, "code": """
state.boots = (state.boots or 0) + 1
log('boot', state.boots, args.tag)
L = light(1, 2, 0, 1, 1, 1, 4)
every(1, function() end)
"""})
check(r["persistent"] is True and g.SIM.fs["zmcp_scene_perm.lua.txt"] is not None, "persistent scene stored as a .lua.txt file")
check(lua("return ZMCP.scenes.store().persistent.perm ~= nil and ZMCP.scenes.store().state.perm.boots == 1"), "ModData records the scene and its state")
check(lua("return ZMCP.tools.scene_list.fn({}).scenes[1] ~= nil"), "scene_list works")
advance(0.2)
lights_before = len(g.SIM.lights)
# simulate a server restart: new Lua tables, ModData (SIM.moddata) and files stay
lua("ZMCP.scenes = nil; ZMCP.tickHooks.scenes = nil")
load("server/ZomboidMCP/Bridge.lua")
load("server/ZomboidMCP/Api/Visuals.lua")
load("server/ZomboidMCP/Api/Scenes.lua")
rt.execute("for _, name in ipairs({'spawn_item', 'give_item', 'place_object', 'remove_object', 'build_structure', 'set_weather', 'set_time', 'spawn_zombies', 'kill_zombies_area'}) do ZMCP.tool(name, 'mock', function(a) CALLS[#CALLS + 1] = { tool = name, args = a }; return { mock = name } end) end")
advance(0.2)
s = scene("perm")
check(s is not None and s["status"] == "running" and s["restored"] is True, "persistent scene restarted after the reload")
check(s["state"]["boots"] == 2 and any(l.endswith("boot 2 keep") for l in logs("perm")), "state and args came back from ModData")
check(events("scenes_loaded")[-1]["data"]["restored"][0] == "perm", "scenes_loaded reports the restored scene")
check(len(g.SIM.lights) == lights_before + 1, "the restarted scene re-added its light (lamppost lights are not saved by the engine)")
check(scene("basic") is None, "non-persistent scenes are gone after a restart")
r = tool("scene_stop", {"name": "perm"})
check(r["persistent"] is True and lua("return ZMCP.scenes.store().persistent.perm == nil and ZMCP.scenes.store().state.perm.boots == 2"), "scene_stop forgets the persistent scene but keeps its state")
tool("scene_start", {"name": "perm", "code": "state.boots = state.boots + 1 log('again', state.boots)"})
check(any(l.endswith("again 3") for l in logs("perm")), "a new scene with the same name finds the kept state")
tool("scene_stop", {"name": "perm", "clear_state": True})
check(lua("return ZMCP.scenes.store().state.perm == nil"), "clear_state wipes the saved state")
_, err = try_tool("scene_stop", {"name": "perm"})
check(err is not None and "no such scene" in err, "stopping an unknown scene errors")
_, err = try_tool("scene_start", {"name": "permbad", "persistent": True, "code": "not lua at all"})
check(err is not None and "compile" in err and lua("return ZMCP.scenes.store().persistent.permbad == nil"), "a persistent scene that fails to compile is not recorded")

# --- screen apps
r = tool("app_start", {"name": "game", "focus": True, "code": """
focus = true
local keys, clicks, frames = {}, {}, 0
APP_TICKS = 0
function update(dt) APP_TICKS = APP_TICKS + 1 end
function draw(ui) frames = frames + 1 app.rect(ui, 10, 10, 50, 50, 1, 0, 0, 1) app.text(ui, 'score', 20, 20, 1, 1, 1, 1, 'small', true) end
function onKey(key, down) if down then keys[#keys + 1] = key end if key == app.keys.SPACE and down then app.score(#keys) end end
function onMouse(x, y, button, down) if down then clicks[#clicks + 1] = x .. ',' .. y .. ',' .. button end end
function onExit(reason) EXIT_REASON = reason end
APP_STATE = { keys = keys, clicks = clicks }
"""})
check(r["chunks"] == 1 and list(r["to"].values()) == ["niach"], "app_start queued the app for the player")
advance(0.1)
check(lua("return ZMCPClient.apps.list.game ~= nil and ZMCPClient.apps.list.game.focus == true"), "app running and focused")
lua("GAME = ZMCPClient.apps.list.game.env")   # app globals live in the app's sandbox
check(g.SIM.consume is True and g.SIM.onTop is True and g.SIM.player.blocked is True, "focus captures the mouse and blocks player movement")
check(events("app_result")[-1]["data"]["ok"] is True and events("app_result")[-1]["data"]["state"] == "running", "client reported app_result running")
lua("SIM.fire('OnKeyStartPressed', 57); SIM.fire('OnKeyPressed', 57); ZMCPClient.overlay:onMouseDown(100, 120); SIM.fire('OnMouseDown', 1, 1)")
check(lua("return GAME.APP_STATE.keys[1] == 57 and #GAME.APP_STATE.keys == 1"), "onKey received the press (release not counted)")
check(lua("return #GAME.APP_STATE.clicks == 1 and GAME.APP_STATE.clicks[1] == '100,120,0'"), "onMouse received the captured click, not the global one")
check(events("app_score")[-1]["data"]["score"] == 1 and events("app_score")[-1]["data"]["name"] == "game", "app.score reported an app_score event")
advance(0.2)
kinds = [d["kind"] for d in lua("return SIM.render()").values()]
check("rect" in kinds and "textc" in kinds and lua("return GAME.APP_TICKS") >= 1, "draw and update callbacks ran")
al = tool("app_list")
check(al[1]["name"] == "game" and al[1]["scores"]["niach"] == 1 and al[1]["clients"]["niach"]["ok"] is True, "app_list shows client state and score")
lua("SIM.fire('OnKeyStartPressed', 1)")
check(lua("return ZMCPClient.apps.list.game == nil and GAME.EXIT_REASON == 'esc'"), "Esc stops the focused app and runs onExit")
check(g.SIM.consume is False and g.SIM.player.blocked is False, "capture and movement released after Esc")
check(events("app_result")[-1]["data"]["state"] == "stopped", "client reported the stop")
tool("app_start", {"name": "broken", "code": "function draw(ui) error('draw boom') end"})
advance(0.1)
lua("SIM.render()")
check(lua("return ZMCPClient.apps.list.broken == nil") and "draw boom" in events("app_result")[-1]["data"]["err"], "a throwing callback stops the app and reports the error")
tool("app_start", {"name": "bad", "code": "this is not lua"})
advance(0.1)
check("compile" in events("app_result")[-1]["data"]["err"], "compile errors are reported")
tool("app_start", {"name": "quiet", "code": "return { update = function() end, draw = function(ui) end }"})
advance(0.1)
check(lua("return ZMCPClient.apps.list.quiet ~= nil and ZMCPClient.apps.list.quiet.focus == false") and g.SIM.consume is False, "an app may return its callbacks as a table; unfocused apps do not capture")
tool("app_stop", {"name": "quiet"})
advance(0.1)
check(lua("return ZMCPClient.apps.list.quiet == nil") and sorted(a["name"] for a in tool("app_list").values()) == ["bad", "broken", "game"], "app_stop stops the app and forgets it")

# --- the shipped examples compile and run in the sandbox
for name in ("merchant", "supply_drop", "meteor_shower", "haunted_house", "companion"):
    code = open(os.path.join(EXAMPLES, "scenes", name + ".lua")).read()
    r, err = try_tool("scene_start", {"name": "ex_" + name, "code": code, "args": {"x": PX + 6, "y": PY, "z": 0}})
    check(err is None and r["status"] == "running", "example %s starts (%s)" % (name, err or r["error"]))
lua("SIM.player.x, SIM.player.y = %d, %d" % (PX, PY))
advance(12.0)
for name in ("merchant", "supply_drop", "meteor_shower", "haunted_house", "companion"):
    s = scene("ex_" + name)
    check(s["status"] in ("running", "done"), "example %s alive after 12 s (%s: %s)" % (name, s["status"], s["error"]))
check(len(events("scene_error")) == 3, "no scene_error from the examples (%d total, 3 expected from the isolation tests)" % len(events("scene_error")))
m = scene("ex_merchant")
check(m["actors"] == 1 and any("Merchant" in l for l in logs("ex_merchant")), "merchant spawned its puppet")
check(any("crate" in l.lower() for l in logs("ex_supply_drop")) and len(calls("spawn_item")) > 1, "supply drop landed a crate of real items")
for name in ("merchant", "supply_drop", "meteor_shower", "haunted_house", "companion"):
    tool("scene_stop", {"name": "ex_" + name})
check(scene("ex_merchant") is None and len(g.SIM.zombies) >= 3 and all(z["removed"] or z["dead"] for z in g.SIM.zombies.values()), "stopping the examples removed every puppet")
flappy = open(os.path.join(EXAMPLES, "apps", "flappy.lua")).read()
tool("app_start", {"name": "flappy", "code": flappy})
advance(0.4)          # the queue still holds the examples' removals (12 messages per tick)
check(lua("return ZMCPClient.apps.list.flappy ~= nil and ZMCPClient.apps.list.flappy.focus == true"), "flappy app starts focused (%s)" % events("app_result")[-1]["data"].get("err"))
lua("SIM.fire('OnKeyStartPressed', 57)")
for _ in range(60):
    g.SIM.now = g.SIM.now + 1 / 30.0
    lua("SIM.fire('OnTick')")
    lua("SIM.render()")
kinds = [d["kind"] for d in lua("return SIM.render()").values()]
check(kinds.count("rect") > 5 and ("text" in kinds or "textc" in kinds), "flappy draws pipes/bird/score (%d rects)" % kinds.count("rect"))
for _ in range(600):
    g.SIM.now = g.SIM.now + 1 / 30.0
    lua("SIM.fire('OnTick')")
check(any(e["data"]["name"] == "flappy" for e in events("app_score")), "flappy reports a score when the bird dies")
lua("SIM.fire('OnKeyStartPressed', 1)")
check(lua("return ZMCPClient.apps.list.flappy == nil") and g.SIM.consume is False, "Esc leaves flappy")

errs = [l for l in g.SIM.out.values() if ("error" in l.lower() or "failed" in l.lower()) and "bridge_loaded" not in l]
expected = ("boom", "child", "at once", "draw boom", "compile error", "scene_error", "scenes_loaded", "not lua", "app broken stopped")
unexpected = [l for l in errs if not any(x in l for x in expected)]
check(not unexpected, "no unexpected errors in the log: " + "; ".join(unexpected[:5]))

print("\n%d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
