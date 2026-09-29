# Engine API index and vanilla Lua examples

Two gzipped JSON files ship inside the mod so the MCP server can answer
`api_search(query, kind?, limit)` and `lua_examples(symbol)` without the game
files being present:

| File | Content | Size (42.21) |
|------|---------|--------------|
| `mod/Contents/mods/ZomboidMCP/mcp/api_index.json.gz` | every Java class the PZ Lua VM can reach, with public fields, constructors, methods, inheritance and the global functions | 2.7 MB JSON, 0.35 MB gz |
| `mod/Contents/mods/ZomboidMCP/mcp/lua_examples.json.gz` | function definitions and call-site snippets from vanilla `media/lua` | 2.2 MB JSON, 0.5 MB gz |

Both are produced by `tools/build_api_index.py` from a local Project Zomboid
install. Regenerate after a game update with:

```sh
make api-index                 # uses ~/.steam/steam/steamapps/common/ProjectZomboid/projectzomboid
make api-index PZ_DIR=/path/to/projectzomboid
make verify-api-index          # checks the ZOM-3 acceptance symbols
```

The generator needs only Python 3 and `javap` (any JDK). It takes about 5 s.

## How the data is derived

- **Exposed classes:** `LuaManager$Exposer.exposeAll()` calls `setExposed(X.class)`
  for every class Lua may use. The `ldc class` constants in that method's
  bytecode (`javap -c -p`) are the authoritative list (999 classes in 42.21).
  Kahlua registers each class under its **simple name** (`IsoGridSquare`,
  `Perk` for `PerkFactory$Perk`) and also as the dotted path
  (`zombie.iso.IsoGridSquare`). Static methods and constructors are called as
  `IsoObject.new(...)` / `IsoDirections.fromIndex(...)`; instance methods with `:`.
- **Members:** `javap -l -public` on every exposed class plus the superclass
  closure. Parameter names come from the `LocalVariableTable` debug info in the
  jar (99 % coverage; JDK classes such as `ArrayList` have none).
- **Inheritance:** Kahlua exposes only the *declared* members of each class and
  links metatables to the superclass. Superclasses that are not themselves in
  the exposer list (45 in 42.21, for example `IsoLivingCharacter`) are included
  with `"exposed": false`. Their members are probably **not callable** from Lua,
  and the reference lookup flags them.
- **Global functions:** public methods of `LuaManager$GlobalObject` carrying
  `@LuaMethod(global=true)` (759 in 42.21), exposed under the annotation name.
  Twelve differ from the Java name (`instof` → `instanceof`, `getAverageFSP` →
  `getAverageFPS`, …); the Java name is kept in `"java"`.
- **Game version:** `version.txt` next to the jar if it exists, otherwise the
  `new GameVersion(42, 21, "")` call in `zombie.core.Core.<clinit>`. The git
  revision comes from `zombie.GitVersion.REVISION`.
- **Examples:** every `.lua` file under `media/lua/{client,server,shared}` is
  scanned once. Definitions (`function X:y(...)`, `X.y = function(...)`) are
  indexed by their full name. Call sites are indexed only for symbols that exist
  in the API index (method names, globals, `Class.new`) plus `Events.<Name>`
  handlers, so Lua-only helpers do not bloat the file. Per symbol the best
  `max_examples` (default 4) lines are kept: real code before comments, short
  lines before long, `shared/`/`server/` before `client/`, `DebugUIs` last, and
  at most one line per file when possible.
- **Curated examples:** `tools/curated_examples.json` holds hand-written calls
  for symbols vanilla never uses (`addLamppost`) and the calls verified live in
  `docs/ENGINE_NOTES.md`. Each entry says whether it was verified.

Type names are shortened to the Lua-visible simple name everywhere
(`java.lang.String` → `String`, `zombie.iso.IsoObject` → `IsoObject`,
`ArrayList<IsoZombie>`); the class table keeps the fully qualified name as key.

## api_index.json.gz

```jsonc
{
  "schema": 1,
  "game_version": "42.21",
  "git_revision": "4a0e9546ec",
  "version_source": "projectzomboid.jar zombie.core.Core.<clinit>",
  "generated_at": "2026-09-30T08:00:00Z",
  "generator": "tools/build_api_index.py",
  "stats": {"classes": 1044, "exposed_classes": 999, "unexposed_superclasses": 45,
            "methods": 22728, "fields": 16233, "ctors": 991, "globals": 759},
  "name_collisions": ["Clothing", "Radio", ...],   // exposed classes sharing a simple name
  "globals": [                                       // sorted by name
    {"n": "getTexture", "p": ["String"], "pn": ["filename"], "r": "Texture"},
    {"n": "instanceof", "java": "instof", "p": ["Object", "String"], "pn": ["obj", "name"], "r": "boolean"}
  ],
  "classes": {                                       // key = fully qualified Java name
    "zombie.iso.IsoCell": {
      "name": "IsoCell",                             // Lua-visible name
      "fqn": "zombie.iso.IsoCell",
      "kind": "class",                               // class | abstract class | interface | enum
      "exposed": true,                               // in the exposer list (false = superclass only)
      "extends": "zombie.iso.IsoObject" | null,      // fqn, walk it for inherited members
      "implements": ["Serializable"],
      "ctors":   [{"p": ["IsoGridSquare", "String", "String"], "pn": ["square", "tile", "name"]}],
      "fields":  [{"n": "N", "t": "IsoDirections", "s": true, "f": true}],   // s = static, f = final (omitted when false)
      "methods": [{"n": "addLamppost", "p": ["int","int","int","float","float","float","int"],
                   "pn": ["x","y","z","r","g","b","rad"], "r": "IsoLightSource"}, // "s": true when static
                  ...]
    }
  }
}
```

Field meanings: `n` name, `p` parameter types, `pn` parameter names (absent when
the jar has no debug names for that method), `r` return type, `t` field type,
`s` static, `f` final. Overloads appear as separate entries with the same `n`.
Enum constants are static final fields of the enum class.

## lua_examples.json.gz

```jsonc
{
  "schema": 1,
  "game_version": "42.21",
  "git_revision": "4a0e9546ec",
  "generated_at": "...",
  "lua_root": "media/lua",                        // paths in "files" are relative to this
  "max_examples": 4,
  "stats": {"lua_files": 1395, "lua_lines": 443695, "call_keys": 5776, "def_keys": 17520, "events": 184, ...},
  "files": ["client/ISUI/ISButton.lua", ...],     // referenced by index below
  "events": ["EveryOneMinute", "OnTick", ...],     // every Events.<Name>.Add seen in vanilla
  "defs": {                                       // Lua function definitions
    "ISCutHair:perform": [[fileIdx, line, "params"]],
    "luautils.round": [[fileIdx, line, "num, idp"]]
  },
  "calls": {                                      // engine call sites, best first
    "setHairModel":  [[fileIdx, line, "self.character:getHumanVisual():setHairModel(self.hairStyle);"]],
    "IsoObject.new": [[fileIdx, line, "sq:AddTileObject(IsoObject.new(sq, \"walls_exterior_wooden_01_54\"))"]],
    "Events.OnTick": [[fileIdx, line, "Events.OnTick.Add(func)"]]
  },
  "curated": {                                    // tools/curated_examples.json, verbatim
    "addLamppost": [{"lua": "local light = getCell():addLamppost(x, y, z, 1.0, 0.8, 0.4, 10)", "note": "..."}]
  }
}
```

Snippets are single lines (call continued over at most two more lines when the
parenthesis is open), whitespace-collapsed and cut at 240 characters. Commented
lines are kept when nothing better exists; they still show the calling shape.

## Lookup reference (what ZOM-2 should implement)

`tools/build_api_index.py --search Q [--kind K] [--limit N] [--json]` and
`--examples SYMBOL [--json]` are the reference implementations; the JSON output
is the shape the MCP tools should return.

**api_search(query, kind?, limit)**
1. Load the index once at startup; 2.7 MB of JSON parses in well under a second.
2. If the query is `Class.member` or `Class:member`, resolve the class by simple
   name and search only that class and its `extends` chain, tagging hits with
   `inherited_from`.
3. Otherwise match the query case-insensitively against class names, global
   names, method names, field names and constructor class names. Rank exact
   match < prefix < substring, then exposed before unexposed, then name.
4. `kind` filters to `class | method | field | ctor | global`.
5. Each hit carries a human signature (`IsoLightSource IsoCell:addLamppost(int x, …)`),
   a `lua` call hint (`obj:addLamppost(x, y, z, r, g, b, rad)`,
   `IsoObject.new(square, tile, name)`, `getTexture(filename)`) and, for
   declaring classes with `exposed: false`, a warning that the member may not
   be callable.

**lua_examples(symbol)**
1. `calls[symbol]` (exact, then case-insensitive). `Class.new` and
   `Events.Name` are valid symbols.
2. `defs` entries whose key equals the symbol, ends with `:symbol` / `.symbol`,
   or starts with `symbol:` / `symbol.` (so a table name lists its methods).
3. `curated[symbol]`.
4. If all three are empty, return the `calls` keys containing the symbol as
   `related` so the caller can retry.

Example output of the acceptance checks (`make verify-api-index`):

```
game_version=42.21 rev=4a0e9546ec classes=1044 methods=22728 globals=759
ok  addLamppost                  sigs= 2 examples=0 curated=1  void IsoCell:addLamppost(IsoLightSource light)
ok  transmitAddObjectToSquare    sigs= 1 examples=1 curated=1  void IsoGridSquare:transmitAddObjectToSquare(IsoObject obj, int index)
ok  addZombiesInOutfit           sigs= 6 examples=4 curated=1  ArrayList<IsoZombie> addZombiesInOutfit(int x, int y, int z, int totalZombies, String outfit, Integer femaleChance)
ok  getTexture                   sigs=19 examples=4 curated=1  Texture getTexture(String filename)
ok  setHairModel                 sigs= 1 examples=4 curated=1  void HumanVisual:setHairModel(String model)
```

## Caveats

- 34 exposed classes share a simple name with another exposed class (listed in
  `name_collisions`, e.g. `Clothing`, `Radio`, `Enum`). Lua sees whichever was
  registered last; use the dotted `zombie.x.y.Name` form to disambiguate.
- Kahlua picks overloads by **argument count** only. When two overloads have the
  same arity, the first registered wins; the index lists all of them.
- `javap` reads JDK classes (`ArrayList`, `HashMap`, …) from the JDK running
  javap, not from the game's bundled `jre64`; signatures are the same in practice.
- Keyboard keys (`Keyboard.KEY_*`), mouse buttons and the Lua calendar are
  exposed by separate `LuaManager` helpers and are not in the index.
- The examples index cannot tell an engine method from a same-named Lua method
  (`getWidth` on `Texture` vs `ISUIElement`); the snippet's receiver usually
  makes it obvious.
