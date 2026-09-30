#!/usr/bin/env python3
"""Generate docs/TOOLS.md from the MCP tool catalogue (mcp/zmcp_catalog.py).

The catalogue is the single source of truth for tool names, argument schemas and descriptions;
tests/mcp/test_catalog.py checks it against the Lua and tests/mcp/test_docs.py checks that this
file's output is committed. Run `make docs` after changing the catalogue.
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "mod", "Contents", "mods", "ZomboidMCP", "mcp"))

import zmcp_catalog as catalog  # noqa: E402

OUT = os.path.join(ROOT, "docs", "TOOLS.md")

GROUPS = [
    ("Scripting (primary)", ["run_lua_server", "run_lua_client", "script_install", "script_list", "script_remove"]),
    ("Discover", ["status", "players_list", "player_info", "world_query", "wait_for", "events_poll", "api_search",
                  "lua_examples"]),
    ("Players", ["teleport", "give_item"]),
    ("World", ["spawn_item", "spawn_vehicle", "vehicle_fix", "spawn_zombies", "kill_zombies_area", "place_object",
               "remove_object", "build_structure", "collision_place", "collision_list", "collision_clear",
               "set_weather", "set_time"]),
    ("Visuals (client push)", ["texture_upload", "texture_pixel", "model_upload", "model_place", "model_remove", "model_move", "model_swap", "world_sprite",
                               "falling_items", "overlay_draw", "server_message", "capture_input", "visuals_list",
                               "clear_visuals"]),
    ("Moving 3D entities (client push)", ["entity3d_spawn", "entity3d_move", "entity3d_rotate", "entity3d_remove",
                                          "entity3d_list"]),
    ("Scenes and screen apps", ["scene_start", "scene_stop", "scene_list", "scene_logs", "scene_signal", "scene_template",
                                "app_start", "app_stop", "app_list"]),
    ("Server admin", ["server_console"]),
]


def type_of(spec):
    t = spec.get("type", "any")
    if t == "array":
        return "array of %s" % type_of(spec.get("items", {}))
    if "enum" in spec:
        return " \\| ".join("`%s`" % e for e in spec["enum"])
    return t


def arg_rows(schema):
    required = set(schema.get("required", []))
    rows = []
    for name, spec in schema["properties"].items():
        extras = []
        if "default" in spec:
            extras.append("default `%s`" % (spec["default"],))
        if "minimum" in spec or "maximum" in spec:
            extras.append("%s..%s" % (spec.get("minimum", ""), spec.get("maximum", "")))
        desc = spec.get("description", "").replace("|", "\\|")
        if extras:
            desc += " (" + ", ".join(extras) + ")"
        rows.append("| `%s`%s | %s | %s |" % (name, " *" if name in required else "", type_of(spec), desc))
    return rows


def render():
    by_name = dict(catalog.BY_NAME)
    grouped = {n for _, names in GROUPS for n in names}
    missing = [n for n in by_name if n not in grouped]
    if missing:
        raise SystemExit("gen_tools_md.py: add these tools to a group: %s" % missing)
    out = ["# MCP tools", "",
           "Every tool the Zomboid MCP server exposes, with its arguments and where it runs, in the families below: "
           "scripting (run Lua on the server or clients, persistent scripts), discovery (status, players, world queries, "
           "the engine API index), players, world (items, vehicles, zombies, tiles, collision, weather and time), "
           "visuals pushed to clients (textures, 3D models, sprites, overlays), moving 3D entities, scenes and screen "
           "apps, and server admin. The table right below lists them all with one line each; the sections after it "
           "give the full description and argument table of each tool.", "",
           "Generated from `mod/Contents/mods/ZomboidMCP/mcp/zmcp_catalog.py` by `tools/gen_tools_md.py` (`make docs`); "
           "do not edit by hand. The catalogue is the schema every tool is validated against, and "
           "`tests/mcp/test_catalog.py` checks it against the Lua tools (`ZMCP.tool(...)` in `Api/*.lua` and "
           "`Bridge.lua`). Direction: **scripting-first** (top of `docs/PLAN.md`): `run_lua_server` / `run_lua_client` "
           "do everything, the curated tools below cover the common operations with validated arguments. The raw Lua "
           "behind each one is in `docs/recipes/`.", "",
           "Arguments marked * are required. `player` arguments accept the account name or the character name and may "
           "be omitted when exactly one player is online. Coordinates are world tiles (`x` east, `y` south, `z` floor). "
           "Tools that the MCP process answers itself are marked *local*; the others run in the game through the bridge "
           "(`docs/PROTOCOL.md`).", ""]
    out.append("| tool | what |")
    out.append("|---|---|")
    for title, names in GROUPS:
        for n in names:
            first = by_name[n]["description"].split(". ")[0].rstrip(".")
            out.append("| [`%s`](#%s) | %s |" % (n, n.replace("_", "_"), first))
    out.append("")
    for title, names in GROUPS:
        out.append("## %s" % title)
        out.append("")
        for n in names:
            t = by_name[n]
            where = "local" if t["local"] and not t["game"] else ("game + local" if t["local"] else "game")
            out.append("### `%s`" % n)
            out.append("")
            out.append("*%s*. %s" % (where, t["description"].replace("\n", " ")))
            out.append("")
            if t["inputSchema"]["properties"]:
                out.append("| argument | type | description |")
                out.append("|---|---|---|")
                out.extend(arg_rows(t["inputSchema"]))
            else:
                out.append("No arguments.")
            out.append("")
    return "\n".join(out).rstrip() + "\n"


def main(argv=None):
    text = render()
    if argv and argv[0] == "--check":
        try:
            current = open(OUT, "r", encoding="utf-8").read()
        except OSError:
            current = ""
        if current != text:
            print("docs/TOOLS.md is out of date: run `make docs`", file=sys.stderr)
            return 1
        return 0
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote %s (%d tools)" % (os.path.relpath(OUT, ROOT), len(catalog.TOOLS)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
