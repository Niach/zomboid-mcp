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
- Server `OnTick` fires about 10×/s **only while players are online**. With `PauseEmpty=true` an empty server is paused (`f:0`), and neither `OnTick` nor `EveryOneMinute` fire. `OnTickEvenPaused` is used as the fallback in `Bridge.lua`; verify it actually fires while empty.
- `OnPlayerUpdate` and `OnZombieUpdate` do **not** fire on the dedicated server.
- `loadstring` works (server and client). `require` of a file that was not loaded at startup did **not** work, so load new files by reading them and running them through `loadstring` (`run_file`).
- The `reloadlua <file>` console command re-runs an **already loaded** file (matched by suffix). Make every file re-runnable: store handlers in a table and `Events.X.Remove` them before re-adding.
- `getFileWriter(name, create, append)` / `getFileReader(name, create)` are text I/O inside the Lua cache dir. `getFileOutput(name)` returns a **binary** `DataOutputStream` (`writeByte`) in the same dir; close it with `endFileOutput()`.
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
- **Kahlua:** there's no `io` library, no `bit` operations (use arithmetic), and `os.date` works. Overloaded Java methods are chosen by argument count. `tostring()` with no arguments throws.
  - **No `next()`** (verified 2026-09-30: `next(t) == nil` throws "Object tried to call nil" every frame). Use `for _ in pairs(t) do return false end return true` to test for an empty table. `pairs`, `ipairs`, `select`, `unpack`, `rawget` exist. Check `dev/sim_prelude.lua` for the list of globals the offline harness provides (and deliberately leaves out).
- **Never test on the owner's running single-player game without asking.** `dev/ZMCPDev` + `~/Zomboid/Lua/zmcp_dev_exec.lua` is a single shared file: two sessions writing it collide, and a render hook that throws breaks the owner's game every frame. Use static checks (`dev/luacheck.py`) and the offline Lua 5.1 harness (`dev/test_sim.py`) instead; a live run needs the owner's OK.

## Live server rules for sessions
- **Allowed:**
  - Read-only inspection
  - `tools/pz status/events`
  - Non-destructive `tools/pz run` / `lua_eval` tests
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

## Runtime 3D models: VERIFIED 2026-09-30 (coordinator's spike, for ZOM-10/11)
- **Runtime 3D models work.** `local ms = ModelScript.new()`, `ms:setModule(getScriptManager():getModule("Base"))`,
  `ms:InitLoadPP(name)`, `ms:Load(name, "{ mesh = <absolute path containing 'media/' incl. .x>, texture = <absolute .png>, scale = N, }")`,
  then `getScriptManager():addModelScript(ms)`. A world item uses it with `item:setWorldStaticModel(name)`.
- World-item model space is **Y-up**. `worldYRotation` rolls an upright XY-plane disc like a wheel.
- Per-frame rotation/offset updates flicker (still under investigation).
