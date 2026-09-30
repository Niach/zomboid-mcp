# Engine notes: Project Zomboid Build 42.21 (verified live on our server)

> Deployment specifics (SSH target, container, paths, Steam account) live in `~/.config/zomboid-mcp/local.env` on the dev machine (see `docs/local.env.example`). `$ZMCP_*` below refers to those variables.

Everything below was verified live on our dedicated server or in the 42.21 client code. Read this before writing Lua for the mod.

## Environment
- **Dedicated server:** hetzner-1, `$ZMCP_SSH`. It runs in Docker (Coolify service `$ZMCP_COOLIFY_SERVICE`, container `$ZMCP_CONTAINER`, image `danixu86/project-zomboid-dedicated-server`).
  - Data volume: `$ZMCP_VOLUME` (= `/home/steam/Zomboid` in the container).
  - Lua cache dir: `<volume>/Lua/`, the only place `getFileWriter`/`getFileReader`/`getFileOutput` can reach.
  - Bind mount for hot-reloadable server Lua: host `/opt/zomboid-lua/ZomboidMCP` → `/home/steam/pz-dedicated/media/lua/server/ZomboidMCP` (read-only, since the ZOM-9 deploy on 2026-09-30; `tools/pz push` syncs it, `pz reload` re-runs Bridge.lua). The Workshop item 3810456179 is enabled on the server as well.
  - `DoLuaChecksum=false` is set in `Server/zomboid.ini`, so the server may run Lua that clients don't have.
  - Server console: write lines to the FIFO `/tmp/pz-console` inside the container (`docker exec <c> sh -c 'echo CMD > /tmp/pz-console'`). The output goes to `<volume>/server-console.txt`, not to `docker logs`.
  - `tools/pz` wraps all of this (`status`, `call`, `eval`, `console`, `events`, `log`, `load`, `run`, `push`, `reload`, `poll`).
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
- **Kahlua:** there's no `io` library, no `bit` operations (use arithmetic), and `os.date` works. **`math.random` is nil in the single-player / client Lua state** (verified 2026-09-30; the dedicated server has it): use `ZombRand(n)` / `ZombRandFloat(a, b)`. Overloaded Java methods are chosen by argument count. `tostring()` with no arguments throws. Strings are Java strings (`string.char(256)` works, `string.byte` returns UTF-16 units). Pattern matching: an escaped char such as `%]` does **not** start a range inside a set (`[%]-~]` is not "] to ~"), so avoid ranges that begin with an escaped char (`Json.lua` escapes in two passes because of this).
  - **No `next()`** (verified 2026-09-30: `next(t) == nil` throws "Object tried to call nil" every frame). Use `for _ in pairs(t) do return false end return true` to test for an empty table. `pairs`, `ipairs`, `select`, `unpack`, `rawget` exist. Check `tests/sim/sim_prelude.lua` for the list of globals the offline harness provides (and deliberately leaves out).
- **Never test on the owner's running single-player game without asking.** `dev/ZMCPDev` + `~/Zomboid/Lua/zmcp_dev_exec.lua` is a single shared file: two sessions writing it collide, and a render hook that throws breaks the owner's game every frame. Use static checks (`tests/luacheck.py`) and the offline Lua 5.1 harness (`tests/sim/test_sim.py`) instead; a live run needs the owner's OK.

- **Vision blur (Short Sighted):** B42 blurs everything beyond a few tiles for `CharacterTrait.SHORT_SIGHTED` without glasses (`IsoGameCharacter.blurFactor`). After `p:getCharacterTraits():remove(CharacterTrait.SHORT_SIGHTED)` (or `add`) call `p:updateVisionEffects()` once: the engine recomputes the blur target only on a clothing change, then lerps it every frame. `p:HasTrait(...)` throws in 42.21; use `getCharacterTraits():get(trait)`. The traits UI lists `getKnownTraits()`.
- **Search mode** (foraging, B42) also blurs the screen around the player: `getSearchMode():setEnabled(playerIndex, false)` / `ISSearchManager.players[player]:toggleSearchMode(false)`.

- **World-item model rotation:** `item:setWorldYRotation(a)` ROLLS a Y-up model (tips it over), it does not turn it around the vertical axis; for upright props leave the rotation at 0 (verified 2026-09-30 with the standing stones: yrot 75 laid the stone flat).
- **World-item model scale:** a runtime `ModelScript` on a world item renders about 1 tile per model unit; the same mesh on the UI3DScene layer needs `ZMCPClient.e3d.MODEL_SCALE = 1.6` to match (verified side by side).
- **Animals (B42):** `addAnimal(cell, x, y, z, "cow", AnimalDefinitions.getDef("cow"):getBreedByName("angus"))` then `animal:addToWorld()` (the debug menu does both). Breeds: angus, simmental, holstein. Animals are drawn only near the player and inside the view cone (`getAlpha(0)` is 0 otherwise) and they flee while stressed: `setDebugStress(0)`; `isWild()` was already false. Invisible `solidtrans` blockers did not keep them in.
- **Corpses and blood:** `IsoDeadBody` objects are in `sq:getStaticMovingObjects()` (`removeFromWorld` + `removeFromSquare`); floor blood goes with the vanilla `sq:removeBlood(false, false)` followed by `sq:getChunk():invalidateRenderChunkLevels(0)` so the chunk redraws.
- **Chunk render cache:** after removing or changing world objects from Lua call `sq:getChunk():invalidateRenderChunkLevels(0)`, otherwise the old picture can stay in the cached chunk FBO.
- **Single-player Lua state:** `math.random` is nil (use `ZombRand` / `ZombRandFloat`); the UI manager can drop a full-screen `ISUIElement` after a hot reload (`isRemoved()` stays true even after re-adding; check `UIManager.getUI():contains(el.javaObject)` and `addToUIManager()` again); the debug console hides with `UIManager.getDebugConsole():setVisible(false)`.
- **Passive actors:** `addZombiesInOutfit(x, y, z, 1, outfit, 50)` then `z:setUseless(true)`; `pathToLocation(x, y, z)` walks a useless zombie (verified: Farmer, Chef, Doctor outfits wandering), and `zombiesNear` tools can skip them via `isUseless()`. Three traps (verified in single player, `IsoGameCharacter.pathToAux` disassembled): when the straight line to the target is clear (`PolygonalMap2.lineClearCollide`) the engine sets `bMoving` without `bPathfind`, a "walk straight" mode that a useless zombie in `ZombieIdleState` never executes (`movex/movey` are zeroed), so it stays idle; call `pathToLocation(x, y, z)` and then `setVariable("bPathfind", true)` + `setMoving(false)` to force `PathFindState`, which walks the real path (scene `walkTo` / `follow` do). A path onto the tile a **player stands on** fails too, so aim at a neighbouring tile. And a zombie's `Say(text)` line is **not drawn** in single player (the player's is), so scenes draw their own bubble on the client. Kahlua: `tostring(z:pathToLocation(...))` fails with "Not enough arguments" because a void Java method returns no value.

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
- **Display:** a carrier world item, e.g. `sq:AddWorldInventoryItem("Base.TirePiece", ox, oy, oz)`, then `item:setWorldStaticModel(name)` (stored in the item's ModData, saved with the world; see "3D permanence").
- **Model space is Y-up for world items.** An XY-plane disc stands upright, and `setWorldYRotation` rolls it like a wheel. The origin is at ground level, so lift it or put the mesh bottom at y=0.
- **Static objects render perfectly. Animating them flickers:** B42 chunk FBO caching (`PerformanceSettings.fboRenderChunk`) plus the `WorldItemAtlas` get invalidated on every offset or rotation change. Moving 3D needs a dynamic carrier (ZOM-11).
- **Not usable:** `ScriptManager.ParseScript` parses item scripts but doesn't finalize them ("Couldn't find item"), and `ScriptBucket` isn't exposed. Use vanilla carrier items plus `ModelScript`.

## 3D permanence: what survives a restart and a rejoin (ZOM-14, bytecode-verified 2026-09-30, live test pending)
Everything the runtime 3D system needs lives in three places that the engine brings back on its own:
- **ModData `"ZomboidMCP"`** (saved with the world): `visuals.textures / models / cscripts / sprites / placements /
  entities3d` and `collision` (registries, metadata only). Bridge.lua reads it on every load.
- **Files in the Lua cache dir**: `zmcp_model_<id>.x.b64` / `.png.b64`, `zmcp_tex_<id>.b64`, `zmcp_cscript_*.lua.txt`
  (the data; streamed to clients on demand, never held in the server heap).
- **The chunk save**: carrier world items (`model_place`) and blocker objects (`collision_place`).
Every client `hello` (join, reconnect) is answered with the whole state in dependency order: textures, models,
client scripts, world sprites, **model placements**, **moving entities** (`V.sendAllTo` in Api/Visuals.lua calls
`Api/Models.lua` last). `tests/sim/test_sim.py` ("server restart") wipes the Lua state, reloads the mod from the
stored ModData + files, replays a hello and asserts the same models / placements / entities / blockers.
- **World items keep their static model in the save.** `InventoryItem.setWorldStaticModel(name)` is
  `setWorldStaticItem`: it writes `"worldStaticModel"` into the item's ModData table, and `InventoryItem.save`
  writes that table (`KahluaTable.save`) plus `worldXRotation / worldYRotation / worldZRotation`
  (`javap -c zombie.inventory.InventoryItem`). `getWorldStaticModel` reads the same key (with a `Flatpack`
  special case). The item's ModData also travels with the item to clients. In MP `AddWorldInventoryItem` sends
  the carrier before the name is set, so `model_place` calls `wo:transmitCompleteItemToClients()` afterwards
  (`IsoObject`, re-sends the object with `InventoryItem.saveWithSize`; **unverified live**).
- **Safety net:** `model_place` records `{square, carrier type + item id, model name, offsets, yrot}` in
  `visuals.placements`; on every `LoadGridsquare` (fires on the server and on clients for each square a chunk
  brings in) the carrier is looked up (by item id, then by type + model name) and the model re-applied if it is
  missing (`model_place_restored` event, `restored` counter in `visuals_list`); a carrier that is gone (picked up)
  is flagged `missing`. Clients do the same from the streamed `place` commands (ClientModels.lua).
- **A placed model whose ModelScript is not registered yet** (fresh client, model files still streaming): the
  engine draws the carrier item's flat sprite (a tire piece icon) instead. `ItemModelRenderer.renderMain` →
  `itemHasModel` checks `ScriptManager.getModelScript(getWorldStaticItem())` **every frame** and returns
  `RenderStatus.NoModel`, nothing is cached, so the 3D model appears on the first frame after the registration.
  The B42 chunk FBO may hold the old picture; the client calls `square:invalidateRenderChunkLevel(16)`
  (`FBORenderChunk.DIRTY_ITEM_MODIFY`) for every placement on that model after registering it. Hence the
  hello order (models before placements and entities) and the client-side re-apply after `modelResult`.
- **Moving entities** are pure client state driven by the `e3d` stream: nothing to save on clients; the server
  registry (`entities3d`) plus the hello resend (with `elapsed`) is the persistence.

## Collision blockers for custom 3D models (ZOM-14, bytecode-verified 2026-09-30, live test pending)
Custom models (`model_place` carriers, `entity3d_*` scene objects) have no collision. `collision_place` places
invisible tile objects that carry the vanilla flags; the engine then treats them as walls / solid objects.
- **How collision works in 42.21** (all from `javap -c`): `IsoGridSquare.RecalcProperties` clears the square's
  `PropertyContainer` and `AddProperties` of every object's `IsoObject.getProperties()` (= its **sprite's**
  properties; there are no per-object properties). `isSolid()` = `has(solid)`, `isSolidTrans()` =
  `has(solidtrans)`. `CalculateCollide` (movement, `collideMatrix`) reads `collideN / collideW`, `HoppableN/W`,
  `solid`, `solidtrans`, `trans`, `water`, `windowN/W`, `canPathN/W`; `CalculateVisionBlocked` reads
  `blocksight`, `collideN / collideW`, `doorN/W`, `solid`, `solidfloor`, `trans`, `transparentN/W`,
  `transparentFloor`. `IsoWorld.LoadTileDefinitions` derives the flags from the tile properties: `WallN` ⇒
  `collideN + cutN`, `WallW` ⇒ `collideW + cutW`, `WallNW` ⇒ both, `WallNTrans` adds `transparentN`,
  `HoppableN` ⇒ `collideN + canPathN + transparentN`, `WindowN` ⇒ `canPathN + collideN + cutN + transparentN`.
  `AddTileObject` / `RemoveTileObject` call `RecalcAllWithNeighbours` and `PolygonalMap2.squareChanged`, so
  zombie pathing follows a transmitted object at once (`setSquareChanged` also notifies `IsoRegions`).
- **Invisible:** `IsoFlagType.invisible` on the sprite makes `IsoObject.isSpriteInvisible()` true, and
  `render / renderFloorTile / renderWallTile* / renderAttachedAndOverlaySprites` skip it. Vanilla uses it for
  the tent footprints (`camping_04_*`: `invisible + solidtrans`, also `IsMoveAble`, so players could pick them
  up); no vanilla tile is `invisible + solid` or an invisible wall.
- **Sprite properties from Lua:** `IsoSpriteManager.instance:getSprite(name):getProperties():set(IsoFlagType.x)`
  / `unset` / `has`, exactly what vanilla `shared/Util/CustomTileProps.lua` does on `OnGameStart` and
  `OnServerStarted`. `PropertyContainer.CreateKeySet()` only rebuilds the key list (no derived flags).
- **Our sprites** (`shared/ZomboidMCP/CollisionSprites.lua`, loaded by the server and by every client):
  `zmcp_collision_solid {invisible, solid}`, `_solidtrans {invisible, solidtrans}`, `_wall_n {invisible, WallN,
  collideN, cutN}`, `_wall_w {…W}`, `_wall_nw {both}`. `IsoObject.save` writes only the **numeric sprite id**
  (`sprite.id`, -1 without a sprite) and `load` resolves it through `IsoSpriteManager.getSprite(int)` (after
  `WorldConverter.tilesetConversions`), so the sprites are created with **fixed ids** via `AddSprite(name, id)`:
  `2097676288 + kind` = `IsoWorld.getSpriteID(8000, 1, k)` = `1048576 + (8000 - 2) * 262144 + k`; vanilla tile
  ids end near 121 million (tileset 460), `IsoChunk.Fix2x` only remaps ids below ~250 000. `AddSprite(name)`
  without an id (what `getSprite(name)` does for unknown names) would leave id -1 and the object would lose its
  sprite on reload. `AddSprite(name, id)` on a name that already exists **replaces** the sprite object in both maps but keeps the
  old id, so the registration reuses an existing named sprite and only re-sets its flags. It runs at file load,
  `OnLoadedTileDefinitions` (each world init, before chunks load), `OnGameStart` and `OnServerStarted`;
  `collision_place` also calls it lazily.
- **Trade-offs:** (a) vanilla invisible tiles: only `solidtrans` exists, they are moveable (pick-up-able) and
  carry tent metadata; (b) flags on an existing visible sprite would change every instance of that tile on the map;
  (c) own sprites (chosen): nothing drawn, exact flags, persistent by id, but the client must run the same
  registration (it does: the Workshop mod is required on clients) and a texture-less sprite must never be drawn
  (`invisible` guarantees that; the sprite has no `IsoObjectType`, so it is not thumpable: zombies cannot break it).
- **Not verified live yet:** that a client's `loadFromRemoteBuffer` / chunk load resolves the id before
  `OnLoadedTileDefinitions` ran on that client (it runs at world init, chunks come later; a client that joins
  without the mod cannot see the blocker), player collision on the client for `wall_n/w` (movement is
  client-authoritative), zombie pathing around a fresh blocker, and the FBO redraw after a late model
  registration. Verify with the owner: a player and a zombie blocked by `solid`, walking along a bridge of blocks.

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
  `removeFromSquare()`. `Say` goes to `ProcessSay`, but a zombie's line is not drawn in single player and the dedicated
  server may not transmit it, so scenes always send a client bubble that follows the zombie (online id on clients, `getID()` in single player).
- Vanilla sound names (media/scripts): `Thunder`, `ZombieThumpGeneric`, `HouseAlarm`, `LightSwitch`, `WoodDoorOpen`,
  `WoodDoorClose`, `ZombieSurprisedPlayer`, `UIActivateButton`, `UIActivateMainMenuItem`, `Helicopter`. Items:
  `Base.Stone2` (a rock), `Base.Log`, `Base.Plank`, `Base.Nails`, `Base.Hammer`, `Base.FirstAidKit`, `Base.TinnedBeans`.
