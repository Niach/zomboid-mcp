#!/usr/bin/env python3
"""Generate the skill's categorized engine API map (skill/reference/*.md) from the API index.

Input: mod/Contents/mods/ZomboidMCP/mcp/api_index.json.gz (every Lua-reachable Java class and the global
functions) and lua_examples.json.gz (vanilla call sites: how often a symbol is used). Output: one markdown file per
category under mod/Contents/mods/ZomboidMCP/skill/reference/ plus README.md, deterministic, under ~1.5 MB in total.

The map is selective on purpose: 22 000+ methods do not fit a skill. Every class keeps its constructors, its
enum-style constants and its most useful methods, ranked by vanilla usage (methods vanilla Lua calls come first,
then hand-picked keywords such as transmit/get/set/add), capped per class. The rest is one `api_search` away, and
each class entry says how many methods were left out.

    tools/gen_api_reference.py            # (re)write the files (make reference)
    tools/gen_api_reference.py --check    # exit 1 when the committed files differ from a fresh generation
"""

from __future__ import annotations

import argparse
import collections
import gzip
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MCP_DIR = os.path.join(ROOT, "mod", "Contents", "mods", "ZomboidMCP", "mcp")
OUT_DIR = os.path.join(ROOT, "mod", "Contents", "mods", "ZomboidMCP", "skill", "reference")
API_INDEX = os.path.join(MCP_DIR, "api_index.json.gz")
LUA_EXAMPLES = os.path.join(MCP_DIR, "lua_examples.json.gz")
SIZE_BUDGET = 1_500_000

# ---------------------------------------------------------------------------------------------- categories
# (file, title, intro, package prefixes / class names). The first matching rule wins; explicit class names beat
# package prefixes. Everything unmatched lands in "other".
CATEGORIES = [
    ("world-iso", "World, squares, objects and tiles", """
The isometric world. Entry points: `getCell()` (the loaded `IsoCell`), `getWorld()` (`IsoWorld`),
`getCell():getGridSquare(x, y, z)` (an `IsoGridSquare` or nil when not loaded), `sq:getObjects()` (tile objects,
`IsoObject` and subclasses), `sq:getWorldObjects()` (ground items, `IsoWorldInventoryObject`),
`sq:getMovingObjects()` (players, zombies, animals), `IsoObject.new(sq, spriteName)` +
`sq:transmitAddObjectToSquare(obj, -1)` (server, synced), `sq:transmitRemoveItemFromSquare(obj)`.
Guides: `guides/world-and-tiles.md`, `guides/items.md`.
""", ["zombie.iso.IsoCell", "zombie.iso.IsoWorld", "zombie.iso.IsoGridSquare", "zombie.iso.IsoObject",
      "zombie.iso.IsoMovingObject", "zombie.iso.IsoChunk", "zombie.iso.IsoDirections", "zombie.iso.IsoMetaGrid",
      "zombie.iso.", "zombie.tileDepth.", "zombie.erosion.", "zombie.globalObjects.", "zombie.basements.",
      "zombie.worldMap.", "zombie.pathfind.", "zombie.popman.", "zombie.seams.", "zombie.seating.",
      "zombie.spriteModel.", "zombie.iso.zones."]),
    ("characters", "Players, zombies, animals and body state", """
Everyone who moves. `IsoPlayer` (server: `getOnlinePlayers()`, `ZMCP.player(name)`; client: `getPlayer()`),
`IsoZombie` (server: `ZMCP.zombiesNear(x, y, z, r)`, `getCell():getZombieList()`, `addZombiesInOutfit(...)`),
`IsoAnimal`, and the shared `IsoGameCharacter` base (inventory, body damage, stats, traits, perks, moodles,
`Say`, `pathToLocation`, `setUseless`). `BodyDamage` / `BodyPart` are client-authoritative for players.
Guides: `guides/players.md`, `guides/zombies-and-actors.md`.
""", ["zombie.characters.", "zombie.ai.ZombieGroup", "zombie.ai.sadisticAIDirector.", "zombie.core.skinnedmodel.",
      "zombie.characterTextures.", "zombie.combat.", "zombie.characters.traits.",
      "zombie.scripting.objects.CharacterTrait", "zombie.scripting.objects.MoodleType",
      "zombie.characters.CharacterStat", "zombie.characters.skills.", "zombie.characters.Moodles."]),
    ("items-inventory", "Items, inventories and containers", """
`InventoryItem` and its subclasses (`Food`, `HandWeapon`, `Clothing`, `DrainableComboItem`...), `ItemContainer`
(`p:getInventory()`, `inv:AddItem("Base.Axe")` + `sendAddItemToContainer(inv, item)` on the server),
`IsoWorldInventoryObject` (an item lying on a square: `sq:AddWorldInventoryItem(type, ox, oy, oz)`), item scripts
(`getScriptManager():FindItem("Base.Banana")`, `getScriptManager():getAllItems()`), fluids and crafting entities.
Guide: `guides/items.md`.
""", ["zombie.inventory.", "zombie.entity.components.fluids.", "zombie.entity.components.crafting.",
      "zombie.entity.components.resources.", "zombie.entity.components.attributes.", "zombie.entity.",
      "zombie.scripting.objects.Item", "zombie.scripting.objects.Recipe", "zombie.scripting.objects.Fixing",
      "zombie.scripting.objects.EvolvedRecipe", "zombie.scripting.itemConfig."]),
    ("vehicles", "Vehicles", """
`BaseVehicle` (server: `addVehicleDebug(script, IsoDirections.S, nil, sq)`, `getVehicleById(id)`,
`sq:getVehicleContainer()`, `p:getVehicle()`), `VehiclePart` (`v:getPartById("GasTank")`), vehicle scripts
(`getScriptManager():getVehicle("Base.CarNormal")`, `getAllVehicleScripts()`), and `UI3DScene`, the 3D viewport
the moving-entity layer uses. Guide: `guides/vehicles.md`, `guides/3d-moving-entities.md`.
""", ["zombie.vehicles.", "zombie.scripting.objects.VehicleScript", "zombie.scripting.objects.VehicleTemplate"]),
    ("climate-time", "Weather, climate and time", """
`getClimateManager()` (rain, storms, fog, wind, temperature; server-side `transmitServer*` methods sync to
everyone), `getGameTime()` (clock, calendar, `setTimeOfDay`), `IsoWeatherFX`, `ErosionMain` seasons and
`getSandboxOptions()`. Guide: `guides/weather-time.md`.
""", ["zombie.iso.weather.", "zombie.GameTime", "zombie.SandboxOptions", "zombie.erosion.season.",
      "zombie.iso.SearchMode", "zombie.iso.weather.fog.", "zombie.iso.weather.fx."]),
    ("ui-rendering", "UI, rendering, textures and input", """
Client only. `UIElement` is the Java side of every `ISUIElement` (`ui:drawRect`, `drawTextureScaled`, `drawText`,
`drawLine2` from a render hook), `Texture` (`getTexture(path)`), `getCore()` (screen size, zoom), `isoToScreenX/Y`
and `screenToIsoX/Y` (globals), `UIManager`, fonts, colours, the `Keyboard`/`Mouse` polling helpers and
`ModelScript` / `ModelManager` for runtime 3D models. Guides: `guides/2d-overlays-and-apps.md`,
`guides/textures-runtime.md`, `guides/3d-static-models.md`.
""", ["zombie.ui.", "zombie.core.textures.", "zombie.core.Core", "zombie.core.Color", "zombie.core.Colors",
      "zombie.core.ImmutableColor", "zombie.core.fonts.", "zombie.input.", "zombie.gizmo.", "zombie.scripting.ui.",
      "zombie.scripting.objects.ModelScript", "zombie.scripting.objects.ModelAttachment", "zombie.core.opengl.",
      "zombie.core.SpriteRenderer", "zombie.core.Styles", "zombie.debug.", "zombie.core.physics.",
      "zombie.core.math.", "org.joml.", "org.lwjglx.", "zombie.iso.SpriteDetails.", "zombie.core.skinnedmodel.model."]),
    ("networking", "Networking and multiplayer", """
`sendServerCommand([player,] module, command, table)` / `sendClientCommand(player, module, command, table)`
(globals, received by `Events.OnServerCommand` / `Events.OnClientCommand`), `isServer()` / `isClient()`,
`GameClient` / `GameServer`, `ServerOptions`, `getOnlinePlayers()`, `sendPlayerExtraInfo`, `syncBodyPart`...
Guide: `guides/networking-and-sync.md`.
""", ["zombie.network.", "zombie.core.znet.", "zombie.core.raknet.", "zombie.chat.", "zombie.core.network."]),
    ("scripting-events", "Scripts, ModData, events, sound and radio", """
`getScriptManager()` (`ScriptManager`: item, vehicle, model and entity scripts), `ModData.getOrCreate(key)` (server
persistence, saved with the world), `Events.X.Add/Remove` (the vanilla event names are listed at the end),
`LuaManager` / `LuaEventManager`, sandbox and config, sounds (`getSoundManager()`, `playServerSound`), radio
and story systems. Guide: `guides/scripts-and-persistence.md`.
""", ["zombie.scripting.", "zombie.Lua.", "zombie.world.moddata.", "zombie.config.", "zombie.radio.",
      "zombie.audio.", "fmod.", "zombie.modding.", "zombie.core.stash.", "zombie.text.", "zombie.gameStates.",
      "zombie.core.properties.", "zombie.core.logger.", "zombie.ZomboidGlobals", "zombie.ZomboidFileSystem",
      "zombie.SystemDisabler", "zombie.core.", "zombie.util.", "zombie."]),
    ("java-util", "Java collections and helpers", """
JDK classes that come back from engine calls: `ArrayList` / `PZArrayList` (`:size()`, `:get(i)`, 0-based),
`HashMap` (`:containsKey`, `:get`, `transformIntoKahluaTable(map)`), `String`, `Math`, streams. Kahlua exposes
only the declared members and picks overloads by argument count.
""", ["java.", "gnu.", "se.krka."]),
]
OTHER = ("other", "Everything else", "AI states, randomized world stories (buildings, vehicles, zones, dead survivors) "
         "and classes that did not fit a category above.", ["zombie.ai.states.", "zombie.randomizedWorld."])

# hand-picked classes get a larger method budget (they are the ones scripts touch all the time)
PRIORITY = {
    "zombie.iso.IsoGridSquare": 160, "zombie.characters.IsoPlayer": 140, "zombie.characters.IsoGameCharacter": 160,
    "zombie.characters.IsoZombie": 120, "zombie.iso.IsoObject": 90, "zombie.iso.IsoCell": 90, "zombie.iso.IsoWorld": 40,
    "zombie.iso.IsoMovingObject": 50, "zombie.inventory.InventoryItem": 120, "zombie.inventory.ItemContainer": 90,
    "zombie.iso.objects.IsoWorldInventoryObject": 40, "zombie.vehicles.BaseVehicle": 120, "zombie.vehicles.VehiclePart": 60,
    "zombie.iso.weather.ClimateManager": 90, "zombie.GameTime": 70, "zombie.ui.UIElement": 90,
    "zombie.core.textures.Texture": 40, "zombie.core.Core": 50, "zombie.scripting.ScriptManager": 60,
    "zombie.scripting.objects.ModelScript": 25, "zombie.vehicles.UI3DScene": 30, "zombie.characters.BodyDamage.BodyDamage": 80,
    "zombie.characters.BodyDamage.BodyPart": 60, "zombie.characters.CharacterTraits": 20, "zombie.characters.skills.PerkFactory$Perk": 20,
    "zombie.characters.HumanVisual": 30, "zombie.characters.IsoLivingCharacter": 30, "zombie.characters.animals.IsoAnimal": 60,
    "zombie.network.GameClient": 40, "zombie.network.GameServer": 40, "zombie.network.ServerOptions": 20,
    "zombie.iso.objects.IsoDoor": 30, "zombie.iso.objects.IsoWindow": 25, "zombie.iso.objects.IsoLightSwitch": 25,
    "zombie.iso.objects.IsoThumpable": 40, "zombie.iso.IsoLightSource": 20, "zombie.iso.objects.IsoTree": 20,
    "zombie.iso.objects.IsoDeadBody": 30, "zombie.inventory.types.HandWeapon": 40, "zombie.inventory.types.Food": 40,
    "zombie.inventory.types.Clothing": 30, "zombie.inventory.types.DrainableComboItem": 15, "zombie.scripting.objects.Item": 60,
    "zombie.scripting.objects.VehicleScript": 40, "zombie.characters.Stats": 30, "zombie.characters.Moodles.Moodles": 15,
    "zombie.SandboxOptions": 30, "zombie.core.skinnedmodel.model.ModelManager": 25, "zombie.audio.BaseSoundEmitter": 20,
    "zombie.iso.sprite.IsoSprite": 25, "zombie.iso.sprite.IsoSpriteManager": 15, "zombie.iso.IsoChunk": 30,
    "zombie.iso.objects.IsoFireManager": 15, "zombie.iso.IsoDirections": 20, "zombie.ui.UIManager": 30,
    "zombie.characters.SurvivorDesc": 40, "zombie.characters.WornItems.WornItems": 15, "zombie.characters.AttachedItems.AttachedItems": 15,
    "zombie.core.Color": 20, "zombie.core.ImmutableColor": 15, "zombie.world.moddata.GlobalModData": 10,
    "zombie.Lua.LuaEventManager": 10, "zombie.iso.objects.IsoCurtain": 10, "zombie.iso.objects.IsoBarricade": 15,
    "zombie.iso.IsoMetaGrid": 25, "zombie.iso.objects.RainManager": 10, "zombie.iso.weather.WeatherPeriod": 25,
    "zombie.erosion.ErosionMain": 10, "zombie.characters.Moodles.MoodleType": 40,
}
DEFAULT_BUDGET = 24          # methods per ordinary class
MIN_BUDGET_UNUSED = 8        # classes vanilla never touches: only a few methods
HEAD_METHOD_WORDS = ("transmit", "sync", "send", "add", "remove", "create", "spawn", "set", "get", "is", "has", "can",
                     "find", "play", "teleport", "kill", "delete", "update", "load", "save", "init", "reset", "clear")
NOISE_PREFIX = re.compile(r"^(hashCode|equals|toString|clone|compareTo|finalize|getClass|wait|notify|notifyAll|values|valueOf|ordinal|name|access\$|lambda\$)")


def load_gz(path):
    with gzip.open(path, "rb") as f:
        return json.loads(f.read().decode("utf-8"))


def category_of(fqn, cls):
    for file, title, intro, rules in CATEGORIES:
        for rule in rules:
            if rule.endswith("."):
                if fqn.startswith(rule):
                    return file
            elif fqn == rule:
                return file
    return OTHER[0]


def resolve_categories(classes):
    """fqn -> category file. Explicit class names win over package prefixes across categories."""
    out = {}
    explicit = {}
    for file, _, _, rules in CATEGORIES:
        for rule in rules:
            if not rule.endswith("."):
                explicit.setdefault(rule, file)
    for fqn, cls in classes.items():
        if fqn in explicit:
            out[fqn] = explicit[fqn]
            continue
        best = None
        for file, _, _, rules in CATEGORIES + [OTHER]:
            for rule in rules:
                if rule.endswith(".") and fqn.startswith(rule) and (best is None or len(rule) > best[1]):
                    best = (file, len(rule))
        out[fqn] = best[0] if best else OTHER[0]
    return out


def sig(m, cls_name=None, static=False):
    params = m.get("p") or []
    names = m.get("pn")
    if names and len(names) == len(params):
        args = ", ".join("%s %s" % (t, n) for t, n in zip(params, names))
    else:
        args = ", ".join(params)
    return args


def method_line(cls, m):
    args = sig(m)
    call = "%s.%s(%s)" % (cls["name"], m["n"], args) if m.get("s") else "%s(%s)" % (m["n"], args)
    r = m.get("r", "void")
    return "- `%s` → %s" % (call, r) if r != "void" else "- `%s`" % call


def rank_methods(cls, calls):
    """Order: used by vanilla (more call sites first) > useful verbs > name; dedupe overloads by (name, arity)."""
    seen = set()
    out = []
    for m in cls["methods"]:
        if NOISE_PREFIX.match(m["n"]):
            continue
        key = (m["n"], len(m.get("p") or []))
        if key in seen:
            continue
        seen.add(key)
        uses = len(calls.get(m["n"], ()))
        verb = 1 if any(m["n"].startswith(w) for w in HEAD_METHOD_WORDS) else 0
        out.append((-uses, -verb, m["n"], len(m.get("p") or []), m))
    out.sort(key=lambda t: t[:4])
    return [t[4] for t in out], sum(1 for t in out if t[0] < 0)


def budget_for(fqn, cls, used):
    if fqn in PRIORITY:
        return PRIORITY[fqn]
    if not cls.get("exposed", True):
        return 6
    if used == 0:
        return MIN_BUDGET_UNUSED
    return DEFAULT_BUDGET


def render_class(fqn, cls, calls):
    lines = []
    kind = cls.get("kind", "class")
    head = "### `%s`" % cls["name"]
    meta = [kind]
    if cls.get("extends"):
        meta.append("extends `%s`" % cls["extends"].rsplit(".", 1)[-1].rsplit("$", 1)[-1])
    if not cls.get("exposed", True):
        meta.append("**not exposed** (superclass only: its members are probably not callable)")
    lines.append(head)
    lines.append("`%s` (%s)" % (fqn, ", ".join(meta)))
    ctors = cls.get("ctors") or []
    if ctors:
        lines.append("- new: " + "; ".join("`%s.new(%s)`" % (cls["name"], sig(c)) for c in ctors[:4])
                     + (" (+%d)" % (len(ctors) - 4) if len(ctors) > 4 else ""))
    # enum constants and static final fields (the things scripts name: IsoDirections.S, CharacterStat.HUNGER)
    consts = [f["n"] for f in cls.get("fields") or [] if f.get("s") and f.get("f")]
    if consts:
        shown = consts[:60]
        lines.append("- constants: " + ", ".join("`%s`" % c for c in shown) + (" … (+%d)" % (len(consts) - 60) if len(consts) > 60 else ""))
    methods, used = rank_methods(cls, calls)
    budget = budget_for(fqn, cls, used)
    for m in methods[:budget]:
        lines.append(method_line(cls, m))
    if len(methods) > budget:
        lines.append("- … %d more: `api_search \"%s:\"` or `api_search \"%s:<name>\"`" % (len(methods) - budget, cls["name"], cls["name"]))
    lines.append("")
    return "\n".join(lines)


GLOBAL_GROUPS = [
    ("World and squares", re.compile(r"^(getCell|getWorld|getSquare|getGridSquare|getOutside|getSprite|IsoDir|getRandom|ZombRand|getGametime|getGameTime|getClimate|getWorldAge|getNumActivePlayers|getPlayer|getSpecificPlayer|getOnlinePlayers|getPlayerByOnlineID|getVehicle|addVehicle|addZombies|createZombie|spawn|addSound|AddWorldSound|AddNoiseToken|getZone|getZones|isoToScreen|screenToIso|addBloodSplat|addCarCrash|addLamppost|getServerOptions)", re.I)),
    ("Networking and server", re.compile(r"^(send|isServer|isClient|isCoop|isAdmin|getAccessLevel|sync|isMultiplayer|isHost|getServer|connect|kick|ban|voice|udp|isDemo|ServerOptions|getConnected|writeLog|isGamePaused|isIngameState|getSteam|isSteam)", re.I)),
    ("Items and scripts", re.compile(r"^(instanceItem|InventoryItemFactory|getItemTex|getScriptManager|getAllItems|getRecipe|getAllRecipes|Recipe|getItemNameFromFullType|getFluid|getEvolved|takeItem|addItem|InvMng|getMoveable|getContainer|getTexture|getTextureFromSaveDir|MakeTexture|getModelName|loadStaticZomboidModel|reloadModels|getAllHairStyles|getAllBeardStyles|getAllOutfits|getFileWriter|getFileReader|getFileOutput|getFileInput|endFileOutput|endFileInput|fileExists|serverFileExists|getMyDocumentFolder|getFileSeparator|getModFile|getLoadedFile|getMod|getMods|getActivated|getZomboidRadio|getGameFiles|getSaveDirectory|getAbsoluteSave|getCacheDir|getWorkshop)", re.I)),
    ("Player and character", re.compile(r"^(addXp|getPerk|getPerks|PerkFactory|getTrait|CharacterTrait|getMoodle|triggerEvent|addExperience|getPlayerData|getPlayerScreen|isPlayer|getPlayerInventory|getPlayerLoot|getPlayerHotbar|getPlayerMoodles|getPlayerStatus|getPlayerInfo|getPlayerTimedAction|getPlayerClothing|getPlayerHealth|getPlayerCraft|getPlayerModData|getPlayerSafe|getPlayerBuild|getPlayerMechanics|getPlayerVehicle|getPlayerFarm|getPlayerHunt|getPlayerMap|getPlayerRadio|getPlayerAnim|getPlayerDebug|getPlayerFishing|getPlayerSkill|getPlayerXp|getPlayerBookRead|getPlayerCook|getPlayerNote|getPlayerBuilding|getPlayerSavefile|getPlayerText|getPlayerTeleport|getSurvivor|createSurvivor|createRandomDeadBody|getDeadBody|isSystemLinux|isSystemWindows|isSystemMac|useTextureFiltering|deleteSave|forceChangeState|getSpecificPlayer)", re.I)),
    ("UI, input and rendering", re.compile(r"^(getCore|getTextManager|getTextOrNull|getText|getTextManager|getMouse|isMouse|isKeyDown|isKeyPressed|getKeyName|getKeyCode|isShiftKey|isCtrlKey|isAltKey|UIManager|getUIManager|getRenderer|getSpriteRenderer|toInt|setShowConnectionInfo|setShowPausedMessage|getFPS|getAverage|getTickTime|getTimestamp|getTimeInMillis|getCurrentTime|getHourMinute|getDebug|isDebug|DebugLog|debugDraw|drawBox|getFonts|getTexture|getMouseX|getMouseY|setMouse|showWrapped|getScreen|getZoom|isXBox|getGameClient|getGameServer|activateSteam|isJoypad|getJoypad|Joypad|getController|getButtonName|getSteam|getPlayerScreenLeft|getPlayerScreenTop|getPlayerScreenWidth|getPlayerScreenHeight|getPlayerScreen|toggle|getLatestSave|getSoundManager|getSoundVolume|getMusicVolume|getWorldSoundManager|getAmbientStreamManager|playSound|stopSound|getRadio|setAmbient|isSoundPlaying|getFMOD)", re.I)),
]


def render_globals(globals_, calls):
    lines = ["## Global functions (%d)" % len(globals_), "",
             "Callable from anywhere as plain functions. `n` uses in vanilla Lua are marked (`✓`); the rest exist but "
             "vanilla never calls them (`api_search` shows the signature).", ""]
    grouped = collections.OrderedDict((title, []) for title, _ in GLOBAL_GROUPS)
    grouped["Other"] = []
    for g in globals_:
        placed = False
        for title, rx in GLOBAL_GROUPS:
            if rx.match(g["n"]):
                grouped[title].append(g)
                placed = True
                break
        if not placed:
            grouped["Other"].append(g)
    for title, items in grouped.items():
        if not items:
            continue
        lines.append("### " + title)
        for g in sorted(items, key=lambda g: (len(calls.get(g["n"], ())) == 0, g["n"].lower())):
            used = "✓ " if g["n"] in calls else ""
            r = g.get("r", "void")
            lines.append("- %s`%s(%s)`%s" % (used, g["n"], sig(g), (" → " + r) if r != "void" else ""))
        lines.append("")
    return "\n".join(lines)


def render_events(examples):
    events = examples.get("events") or []
    lines = ["## Vanilla event names (%d)" % len(events), "",
             "`Events.<Name>.Add(fn)` / `.Remove(fn)`. Server: `OnTick` (only while players are online), `EveryOneMinute`, "
             "`EveryTenMinutes`, `OnClientCommand(module, command, player, args)`, `OnZombieDead`, `OnPlayerDeath`, "
             "`OnCharacterDeath`, `OnWeaponHitCharacter`, `LoadGridsquare`, `OnGameStart` (client) / `OnServerStarted` (server). "
             "Client: `OnServerCommand(module, command, args)`, `OnKeyStartPressed`, `OnKeyPressed`, `OnKeyKeepPressed`, "
             "`OnMouseDown/Up`, `OnMouseMove`, `OnMouseWheel`, `OnRightMouseDown/Up`, `OnRenderTick`, `OnPreUIDraw`, `OnPostUIDraw`, "
             "`OnObjectLeftMouseButtonDown(obj, x, y)`. `OnPlayerUpdate` / `OnZombieUpdate` do not fire on the dedicated server.", "",
             ", ".join("`%s`" % e for e in events), ""]
    return "\n".join(lines)


def generate():
    api = load_gz(API_INDEX)
    examples = load_gz(LUA_EXAMPLES)
    calls = examples.get("calls") or {}
    classes = api["classes"]
    cats = resolve_categories(classes)
    by_cat = collections.defaultdict(list)
    for fqn, file in cats.items():
        by_cat[file].append(fqn)
    files = collections.OrderedDict()
    version = api.get("game_version", "?")
    header = ("Generated by `tools/gen_api_reference.py` (`make reference`) from the engine API index (Project Zomboid %s, "
              "`mcp/api_index.json.gz`); do not edit by hand. Methods vanilla Lua calls come first, `→ type` is the return "
              "type, `Class.method(...)` marks a static method, `obj:method(...)` is how instance methods are called. "
              "Every class is cut to its most useful methods: the last line of an entry says how many more `api_search` "
              "knows.\n\n") % version
    index_rows = []
    for file, title, intro, _ in CATEGORIES + [OTHER]:
        fqns = sorted(by_cat.get(file, []), key=lambda f: (-len([m for m in classes[f]["methods"] if m["n"] in calls]), classes[f]["name"]))
        if not fqns and file == OTHER[0]:
            continue
        body = ["# %s" % title, "", header, intro.strip(), "",
                "Classes (%d), most used first. Jump with `api_search \"<Class>\"` for the full member list." % len(fqns), ""]
        # quick class index for the file
        body.append(", ".join("`%s`" % classes[f]["name"] for f in fqns))
        body.append("")
        for fqn in fqns:
            body.append(render_class(fqn, classes[fqn], calls))
        if file == "scripting-events":
            body.append(render_events(examples))
        files[file + ".md"] = "\n".join(body).rstrip() + "\n"
        index_rows.append((file, title, len(fqns)))
    files["globals.md"] = "# Global functions\n\n" + header + render_globals(api.get("globals") or [], calls)
    readme = ["# Engine API reference (generated)", "", header.strip(), "",
              "| file | category | classes |", "|---|---|---|"]
    for file, title, n in index_rows:
        readme.append("| [%s.md](%s.md) | %s | %d |" % (file, file, title, n))
    readme.append("| [globals.md](globals.md) | Global functions | %d |" % len(api.get("globals") or []))
    readme += ["", "## How to use it with `api_search` and `lua_examples`", "",
               "- Skim the category file for the class and method names, then `api_search \"IsoGridSquare:transmitAddObjectToSquare\"` "
               "for the exact signature (parameter names and types, static or not, inherited from which superclass).",
               "- `api_search \"addLamppost\"` finds a method by name across every class; `kind: class` lists classes only; "
               "a regex such as `\"^transmit.*Object\"` works too.",
               "- `lua_examples \"setHairModel\"` shows real vanilla call sites (file:line); `lua_examples \"Events.OnTick\"` lists "
               "handlers; `lua_examples \"IsoObject.new\"` constructors; curated entries mark what was verified live.",
               "- Overloads: Kahlua picks by argument count only. A method listed twice with different arities is two overloads; "
               "same arity means the first registered wins.",
               "- A class marked *not exposed* is a superclass that Kahlua did not register: its members are listed for "
               "orientation but may not be callable on the subclass.",
               "- Stats: %d classes, %d methods, %d globals in the index; this reference lists a ranked subset." % (
                   api["stats"]["classes"], api["stats"]["methods"], api["stats"]["globals"]),
               ""]
    files["README.md"] = "\n".join(readme)
    return files


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="compare with the committed files instead of writing")
    ap.add_argument("--out-dir", default=OUT_DIR)
    args = ap.parse_args(argv)
    files = generate()
    total = sum(len(v.encode("utf-8")) for v in files.values())
    if total > SIZE_BUDGET:
        sys.stderr.write("reference too large: %d bytes (budget %d)\n" % (total, SIZE_BUDGET))
        return 2
    if args.check:
        bad = []
        for name, text in files.items():
            path = os.path.join(args.out_dir, name)
            if not os.path.exists(path) or open(path, encoding="utf-8").read() != text:
                bad.append(name)
        stale = [n for n in os.listdir(args.out_dir) if n.endswith(".md") and n not in files] if os.path.isdir(args.out_dir) else []
        if bad or stale:
            sys.stderr.write("skill/reference is out of date (run `make reference`): %s\n" % ", ".join(bad + stale))
            return 1
        print("skill/reference is current (%d files, %d bytes)" % (len(files), total))
        return 0
    os.makedirs(args.out_dir, exist_ok=True)
    for name in os.listdir(args.out_dir):
        if name.endswith(".md") and name not in files:
            os.remove(os.path.join(args.out_dir, name))
    for name, text in files.items():
        with open(os.path.join(args.out_dir, name), "w", encoding="utf-8") as f:
            f.write(text)
    print("wrote %d files, %d bytes, to %s" % (len(files), total, os.path.relpath(args.out_dir, ROOT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
