# Engine notes: Project Zomboid Build 42.21 (verified live on our server)

> Deployment specifics (SSH target, container, paths, Steam account) live in `~/.config/zomboid-mcp/local.env` on the dev machine (see `docs/local.env.example`). `$ZMCP_*` below refers to those variables.

Everything below was verified live on our dedicated server or in the 42.21 client code. Read this before writing Lua for the mod.

## Environment
- **Dedicated server:** hetzner-1, `$ZMCP_SSH`. It runs in Docker (Coolify service `$ZMCP_COOLIFY_SERVICE`, container `$ZMCP_CONTAINER`, image `danixu86/project-zomboid-dedicated-server`).
  - Data volume: `$ZMCP_VOLUME` (= `/home/steam/Zomboid` in the container).
  - Lua cache dir: `<volume>/Lua/`, the only place `getFileWriter`/`getFileReader`/`getFileOutput` can reach.
  - Bind mount for hot-reloadable server Lua: host `/opt/zomboid-lua/vapps` → `/home/steam/pz-dedicated/media/lua/server/vapps` (read-only). It currently holds the old prototype Guardian/Push/Reborn files and will become `ZomboidMCP`.
  - `DoLuaChecksum=false` is set in `Server/zomboid.ini`, so the server may run Lua that clients don't have.
  - Server console: write lines to the FIFO `/tmp/pz-console` inside the container (`docker exec <c> sh -c 'echo CMD > /tmp/pz-console'`). The output goes to `<volume>/server-console.txt`, not to `docker logs`.
  - `tools/pz` wraps all of this (`status`, `cmd`, `console`, `events`, `run`, `client`, `push`, `reload`).
- **Local client (Mint PC):** PZ at `~/.steam/steam/steamapps/common/ProjectZomboid/projectzomboid/`. Vanilla Lua is in `media/lua`, the Java is `projectzomboid.jar` (use `javap -cp projectzomboid.jar -public <class>` for signatures). The client log is `~/Zomboid/console.txt`.
- **Game version:** 42.21.0. The server uses a 3 GB heap and a 5 GB container. It autosaves every minute.

## Execution model
- Server `OnTick` fires about 10×/s **only while players are online**. With `PauseEmpty=true` an empty server is paused (the `f:` frame counter in the log stops), and **no Lua event fires**: not `OnTick`, not `EveryOneMinute`, and not `OnTickEvenPaused` (verified 2026-09-29: the event exists, a handler registered while paused never ran). Server console commands still work while paused, and `reloadlua <file>` runs Lua then; `Bridge.lua` uses `reloadlua ZomboidMCP/ZMCPPoll.lua` as the paused path (see `docs/PROTOCOL.md`).
- `OnPlayerUpdate` and `OnZombieUpdate` do **not** fire on the dedicated server.
- `loadstring` works (server and client). `require` of a file that was not loaded at startup did **not** work, so load new files by reading them and running them through `loadstring` (`run_file`).
- The `reloadlua <file>` console command re-runs an **already loaded** file (matched by suffix). Make every file re-runnable: store handlers in a table and `Events.X.Remove` them before re-adding.
- `getFileWriter(name, create, append)` / `getFileReader(name, create)` are text I/O inside the Lua cache dir. `getFileWriter` **returns nil for names ending in `.lua` or `.jsonl` and for names without an extension**; `.txt`, `.json`, `.log` and `.lua.txt` work. `getFileReader` reads any name (also `.lua`), and throws for a missing file (pcall it). `fileExists(path)` needs the **absolute** path (`getMyDocumentFolder() .. "/Lua/" .. name`; `getMyDocumentFolder()` is `/home/steam/Zomboid` on the server); relative names return false. There is no delete/list/rename. `loadstring(code, chunkname)` accepts the chunk name. `getFileOutput(name)` returns a **binary** `DataOutputStream` (`writeByte`) in the same dir; close it with `endFileOutput()`.
- `getMyDocumentFolder()` returns the `~/Zomboid` path and `getFileSeparator()` the path separator. `getTexture(absPath)` / `Texture.getSharedTexture(absPath)` should load a PNG from an absolute path. This is **unverified**: the spike is in `spikes/texture_spike.lua`.

## Authority (who owns what in MP)
- **Server-authoritative, synced to everyone:**
  - `zombie:setAttackedBy(p); zombie:Kill(p)` (a no-argument `Kill` does not exist; `Kill(nil)` works)
  - `inv:AddItem(type)` + `sendAddItemToContainer(inv, item)`
  - `square:AddWorldInventoryItem(type, 0, 0, 0)`
  - `IsoObject.new(square, sprite, name)` + `square:transmitAddObjectToSquare(obj, -1)`; remove with `square:transmitRemoveItemFromSquare(obj)`
  - `addVehicleDebug(script, IsoDirections.S, nil, square)`
  - `vehicle:repair()`
  - Gas tank: `part:setContainerContentAmount(cap)` + `vehicle:transmitPartModData(part)`
  - `addZombiesInOutfit(x, y, z, n, outfit|nil, femaleChance)`
  - `getClimateManager():transmitServerStartRain(f)` / `transmitServerStopWeather()` / `transmitServerTriggerStorm(f)` / `transmitServerTriggerLightning(x, y, strike, light, rumble)`
  - `playServerSound(name, square)`
  - Traits: `p:getCharacterTraits():add/remove(CharacterTrait.X)` (appeared to work)
  - `addXpNoMultiplier(p, Perks.X, xp)` with `perk:getTotalXpForLevel(n)`
  - `p:setGodMod(on, true)` + `sendPlayerExtraInfo(p)` (this is what the `godmodeplayer` console command does)
  - `getGameTime():setTimeOfDay(h)`
- **Client-authoritative (the server only sees a copy):**
  - Body damage and infection: the server-side cure was overwritten by the client every second. Heal and cure must run **on the client** (through the client mod). The vanilla admin path (`bodyPart:RestoreToFullHealth()` + `syncBodyPart(bp, 0xFFFFFFFFFFF)` on the server) is acceptable, but was not proven for infection.
  - Player position (teleport through the client), appearance (`getHumanVisual():setHairModel/setBeardModel/setHairColor` + `sendHumanVisual(p)`, not verified on the client), and moodles/stats (`stats:set(CharacterStat.X, v)` + `sendPlayerStatsChange(p)`, not verified).
- **Server → client:** `sendServerCommand([player,] module, command, table)`, received on the client by `Events.OnServerCommand(module, command, args)`. Table values should be flat strings or numbers. Chunk large payloads (about 3000 characters per message).
- **Client → server:** `sendClientCommand(player, module, command, table)`, received on the server by `Events.OnClientCommand(module, command, player, args)`.

## Useful facts
- `getOnlinePlayers()` works on the server; `getPlayerFromUsername` returned nil. `PerkFactory.PerkList`, `Perks.<Name>`, and `CharacterTrait.<CONST>` (upper snake case; see `javap zombie.scripting.objects.CharacterTrait`).
- Hair styles are listed in `media/hairStyles/hairStyles.xml`, beards in `beardStyles.xml`.
- Client drawing: in a full-screen `ISUIElement`, call `self.javaObject:setConsumeMouseEvents(false)` so clicks pass through. Draw with `drawLine2`, `drawRect`, `drawTextureScaled`, and `isoToScreenX/Y(playerNum, x, y, z)` for world → screen. Zoom is `getCore():getZoom(0)`. Keybinds: `PZAPI.ModOptions:create(...):addKeyBind(...)`. Mouse → world: `screenToIsoX/Y(0, mx, my, z)`.
- There are no human NPCs in B42 MP. Only players, zombies and animals exist.

## Pitfalls we hit
- **Workshop uploads:** SteamCMD `workshop_build_item` with `"visibility" "3"` produced a **private** item, and the dedicated server then answered no joins (`GettingServerInfo` hang). Use `visibility 0` (public).
- **SteamCMD** logging in with the owner's account **kicks their desktop Steam** ("lost connection"). Never run SteamCMD while the owner is playing. Always use the isolated HOME: `env HOME=$ZMCP_STEAMCMD_HOME $ZMCP_STEAMCMD +login $ZMCP_STEAM_USER ...`.
- **Heap:** 2 GB of heap ran out of memory during a save with 35 mods. It's 3 GB now, and the host has only about 1.2 GB spare. Avoid holding big data (for example textures) in Lua or ModData on the server; keep it in files.
- **Kahlua:** there's no `io` library, no `bit` operations (use arithmetic), and `os.date` works. Overloaded Java methods are chosen by argument count. `tostring()` with no arguments throws. Strings are Java strings (`string.char(256)` works, `string.byte` returns UTF-16 units). Pattern matching: an escaped char such as `%]` does **not** start a range inside a set (`[%]-~]` is not "] to ~"), so avoid ranges that begin with an escaped char (`Json.lua` escapes in two passes because of this).
  - **No `next()`** (verified 2026-09-30: `next(t) == nil` throws "Object tried to call nil" every frame). Use `for _ in pairs(t) do return false end return true` to test for an empty table. `pairs`, `ipairs`, `select`, `unpack`, `rawget` exist. Check `tests/sim/sim_prelude.lua` for the list of globals the offline harness provides (and deliberately leaves out).
- **Never test on the owner's running single-player game without asking.** `dev/ZMCPDev` + `~/Zomboid/Lua/zmcp_dev_exec.lua` is a single shared file: two sessions writing it collide, and a render hook that throws breaks the owner's game every frame. Use static checks (`tests/luacheck.py`) and the offline Lua 5.1 harness (`tests/sim/test_sim.py`) instead; a live run needs the owner's OK.

## Live server rules for sessions
- **Allowed:**
  - Read-only inspection
  - `tools/pz status/events`
  - Non-destructive `tools/pz run` / `run_lua_server` tests
  - Pushing to `/opt/zomboid-lua` + `reloadlua`
- **Needs the owner's OK, because players are usually online:**
  - Server restarts
  - Compose or `zomboid.ini` changes
  - SteamCMD / Workshop uploads
  - Spawning hordes
  - Anything that affects a player's character

## Textures at runtime: VERIFIED 2026-09-30 (ZOM-7)
Tested in single-player 42.21 on Linux with the `dev/ZMCPDev` exec watcher:
- **Writing:** a pure-Lua base64 decode (arithmetic only), then `getFileOutput(name)` + `out:writeByte(b)` + `endFileOutput()`, writes a **byte-identical** PNG (md5 matches) to `~/Zomboid/Lua/<name>`.
- **Loading:** `getTexture(getMyDocumentFolder()..sep.."Lua"..sep..name)` returns a real `Texture` (`w`/`h` correct, e.g. 160×128 and 256×256). The alpha channel works.
- **New images:** use a **new file name** (e.g. `zmcp_tex_<id>_<n>.png`) for new content, because textures are cached by path.
- **Drawing:** `ISUIElement:drawTextureScaled(tex, x, y, w, h, a, r, g, b)` from a full-screen overlay (`setConsumeMouseEvents(false)`). A negative width mirrors horizontally.
- **World anchoring:**
  - screen position is `isoToScreenX/Y(0, wx, wy, wz)`
  - divide sizes by `getCore():getZoom(0)`
  - draw the sprite bottom-centre at the point (`y - h`)
  - Verified with a crawling snail and a 3-tile Claude logo standing next to the player.
- **Owner preference:** world sprites are drawn **always on top** (no wall occlusion needed).
- **Performance:** a 22 KB PNG (≈29 KB base64) decodes instantly. Keep textures ≤ 256×256 and ≤ 100 KB where possible (network chunks of ~3000 characters).
- **Dev tip:** `dev/ZMCPDev` is a local-only mod (copy it to `~/Zomboid/mods/`). It runs `~/Zomboid/Lua/zmcp_dev_exec.lua` every time the file changes and writes `zmcp_dev_result.txt`. Draw hooks go in `ZMCPDev.hooks[name] = function(ui) ... end`. This gives a live single-player test loop without restarts. Note: `OnTick` doesn't run while the game is paused.

## Runtime 3D models: VERIFIED 2026-09-30 (static)
Tested live with the owner in single-player (see ZOM-11 for details):
- **Files:** write the `.x` mesh (text) and the `.png` into a path containing `media/`, e.g. `~/Zomboid/Lua/media/<name>.x`. The model loader uses a mesh name verbatim only when it contains `media/` and an extension.
- **Registration:**
  ```lua
  ms = ModelScript.new()
  ms:setModule(getScriptManager():getModule("Base"))
  ms:InitLoadPP(name)
  ms:Load(name, "{ mesh = <abs>.x, texture = <abs>.png, scale = N, }")
  getScriptManager():addModelScript(ms)
  ```
  Leaving out `setModule` makes `addModelScript` throw an NPE.
- **Display:** a carrier world item, e.g. `sq:AddWorldInventoryItem("Base.TirePiece", ox, oy, oz)`, then `item:setWorldStaticModel(name)`.
- **Model space is Y-up for world items.** An XY-plane disc stands upright, and `setWorldYRotation` rolls it like a wheel. The origin is at ground level, so lift it or put the mesh bottom at y=0.
- **Static objects render perfectly. Animating them flickers:** B42 chunk FBO caching (`PerformanceSettings.fboRenderChunk`) plus the `WorldItemAtlas` get invalidated on every offset or rotation change. Moving 3D needs a dynamic carrier (ZOM-11).
- **Not usable:** `ScriptManager.ParseScript` parses item scripts but doesn't finalize them ("Couldn't find item"), and `ScriptBucket` isn't exposed. Use vanilla carrier items plus `ModelScript`.

## Moving 3D entities: UI3DScene layer (ZOM-11, bytecode-verified 2026-09-30, live test pending)
Carrier evaluation for a smoothly moving, rotating custom model (all from `javap` of 42.21 + vanilla Lua; nothing
below was run in the game yet unless marked):
- **World item (dynamic flag): no.** `IsoWorldInventoryObject` has no per-object dynamic path; `WorldItemModelDrawer`
  draws into the chunk FBO / `WorldItemAtlas`. The only switch is the global `PerformanceSettings.fboRenderChunk`.
- **Physics objects: no.** `IsoPhysicsObject` / `IsoBall` (B42 thrown ball) are `IsoMovingObject`s but are not
  exposed to Lua (`LuaManager.Exposer`), and `IsoBall.render` draws the item's *sprite*, not a model.
- **Zombie / animal carrier: partial.** `createZombie(x, y, z, desc|nil, outfit, IsoDirections)` +
  `zombie:setUseless(true)`, `setAttachedItem(location, item)` with `item:setStaticModel("zmcp_<id>_<gen>")`
  (`ModelManager.addEquippedModelInstance` reads `InventoryItem.getStaticModel()`, so the per-instance override
  works and custom locations can be added with `AttachedLocations.getGroup("Human"):getOrCreateLocation(...)` +
  a `ModelAttachment` on `getScriptManager():getModelScript("MaleBody")`; `Vector3f` is exposed for offsets).
  Movement is smooth and MP-synced, but the model cannot be rotated per frame from Lua (attachment rotation is
  per model script), the zombie body stays visible (`setInvisible` is only read by `IsoPlayer`; `ghost` is unused
  in rendering; `ModelInstance.scale` is not reachable), and animals use a different skeleton. Keep for "a zombie
  carrying a thing"; wrong for a rolling star.
- **Vehicle carrier: no.** `ScriptManager` has no `addVehicleScript` (`ScriptBucketCollection<VehicleScript>` is
  private, only `ParseScript` fills it), a vehicle needs wheels/physics shapes/skins, and physics fights any
  manual rotation.
- **UI3DScene layer: yes (chosen).** `zombie.vehicles.UI3DScene` (the vehicle / attachment / sprite-model editor
  viewport) is Lua-exposed (`UI3DScene.new(luaTable)` like vanilla `ISUI3DScene`). Facts:
  - `render()` clears **only the depth buffer** (`glClear(256)`), so a full-screen element is transparent; the
    grey background is drawn by vanilla `ISUI3DScene:prerender`, not by Java. The debug text is only drawn while
    `setDrawGrid(true)`. `setConsumeMouseEvents(false)` on the Java object makes it click-through.
  - Camera: `fromLua1("setView", "UserDefined")` + `fromLua3("setViewRotation", 30, 315, 0)` + `setZoom` is what
    `SpriteModelEditor:resetView` uses to preview tile models, i.e. the game's 2:1 iso orthographic projection
    (`Matrix4f.setOrtho`). `sceneToUIX/Y(x, y, z)` (public Java methods) give the pixel of any scene point, so the
    layer calibrates the affine scene→pixel map every frame (4 probes) and converts world tiles → scene units:
    `k = (32 / zoom) / px_per_unit_x` scene units per tile, `ky = (96 / zoom) / px_per_unit_y` per z level. The
    world point under the scene origin is `screenToIsoX/Y(0, u0, v0, 0)`. Objects get scale `k * scale` so the
    scene zoom does not matter.
  - Objects: `fromLua2("createModel", objectName, modelScriptName)` (looks up `ScriptManager.getModelScript` +
    `ModelManager.getLoadedModel`, so runtime `ModelScript`s and vanilla ones like `RadioBlue_Ground` work),
    `fromLua1("getObjectTranslation" | "getObjectRotation" | "getObjectScale", name)` return the live `Vector3f`
    (mutate with `:set(x, y, z)`); rotation is **degrees**, applied as `translate * rotateXYZ(rx, ry, rz) * scale`
    (Z first in model space, then Y, then X). `removeObject`, `setObjectVisible`, `getObjectExists`. Model space
    is Y-up like world items; a disc in the model XY plane stands upright, heading = rotation about Y
    (`+X → (cos, 0, -sin)`), rolling = negative rotation about Z per distance / radius.
  - Turn off `setDrawGrid/setDrawGridAxes/setDrawGridPlane` and `setGizmoVisible("none")`.
  - Scene objects are drawn on top of the world (own depth buffer, no wall occlusion; owner preference), below the
    2D overlay (`backMost()` after the overlay exists). Pure client side: MP clients each run the same motion from
    the server's `e3d` commands (with `elapsed` so late joiners are in phase).
  - Client: `ZMCPClient.e3d` (`ClientModels.lua`); server: `Api/Models.lua` (`entity3d_*` tools). Offline
    verified with `dev/test_sim.py` (projection maths, motion, late join); live demo: `dev/e3d_demo.lua` with the
    owner. Knobs if the live picture is off: `ZMCPClient.e3d.MODEL_SCALE`, `.YAW`, `.PITCH`, `.ZOOM`.

## Coordination
- Only one agent may drive the owner's running game (`dev/ZMCPDev`) at a time. Ask the owner or coordinator first.
- A crashing render hook spams errors every frame and breaks the game, so always `pcall` hooks and remove them on error.
- `getFileWriter` / `getFileOutput` create missing parent directories (`mkdirs`), so `media/zmcp_x.x` under the Lua dir works for model pushes (bytecode-verified 2026-09-30).
- Client input events available to scripts: `OnKeyStartPressed` (down), `OnKeyPressed` (release), `OnKeyKeepPressed` (held), `OnMouseDown`, `OnMouseMove`, `OnMouseWheel`, `OnRightMouseDown/Up`; polling: `isKeyDown(int)`, `isMouseButtonDown(int)`, `getMouseX/Y()`.

## Scenes and screen apps (ZOM-10): verified facts
- **Kahlua base library** (bytecode strings of `se.krka.kahlua.stdlib.BaseLib`, 42.21): `setfenv`, `getfenv`, `pcall`, `select`,
  `unpack`, `rawget/rawset/rawequal`, `getmetatable/setmetatable`, `tonumber/tostring/type`, `error`, `print`,
  `collectgarbage`. `CoroutineLib` has only `create`, `resume`, `yield`, `status` (no `wrap`, no `running`). Sandboxing a
  chunk therefore works with `setfenv(fn, env)` + `setmetatable(env, {__index = _G})` (Api/Scenes.lua, ClientApps.lua).
- **Lamppost lights are not saved.** `IsoCell.lamppostPositions` is referenced only by the constructor, `addLamppost`,
  `removeLamppost`, `getLightSourceAt`, `updateInternal` and `Dispose` (javap of `zombie.iso.IsoCell`); no save/load
  path. `getCell():addLamppost(x, y, z, r, g, b, radius)` returns the `IsoLightSource`, `removeLamppost(light)` removes
  it. Lights are render state, so they are created on the clients and re-created on every start (scene SDK `light()`).
- `IsoPlayer:setBlockMovement(boolean)` exists (focused screen apps use it); the animal variant is what vanilla Lua calls.
- Server-side events `OnPlayerDeath`, `OnCharacterDeath`, `OnZombieDead`, `OnZombieCreate` exist in `LuaEventManager`.
- `IsoZombie`: `setUseless(boolean)` (vanilla tutorial puppets), `pathToLocation(int, int, int)`, `pathToLocationF`,
  `pathToCharacter`, `faceLocationF(float, float)`, `setWalkType(String)`, `getOnlineID()`, `removeFromWorld()` +
  `removeFromSquare()`. `Say` goes to `ProcessSay` (client rendering); whether the dedicated server transmits a zombie's
  line is unverified, so scenes also send a client bubble that follows the zombie by online id.
- Vanilla sound names (media/scripts): `Thunder`, `ZombieThumpGeneric`, `HouseAlarm`, `LightSwitch`, `WoodDoorOpen`,
  `WoodDoorClose`, `ZombieSurprisedPlayer`, `UIActivateButton`, `UIActivateMainMenuItem`, `Helicopter`. Items:
  `Base.Stone2` (a rock), `Base.Log`, `Base.Plank`, `Base.Nails`, `Base.Hammer`, `Base.FirstAidKit`, `Base.TinnedBeans`.
