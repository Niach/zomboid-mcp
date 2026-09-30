# Steam Workshop page

The text below is the Workshop description (Steam BBCode). Paste it into the item's description on the Workshop page
after `tools/upload.sh` (SteamCMD only sets the short one-line description from `tools/workshop.vdf.template`).
Workshop descriptions cannot embed external images or GIFs, so the animated captures live in this repository
(`art/showcase/`) and the page links to them; the preview image is `mod/Contents/mods/ZomboidMCP/poster.png`.

```
[h1]Claude hacks the simulation[/h1]
A live scripting bridge between a running Project Zomboid (Build 42) game and Claude, or any other MCP client. Claude writes Lua, the game runs it: spawn things, build with tiles, change weather and time, move players, and push brand-new visuals to every connected player without a restart or a Workshop update.

[h2]What it can do[/h2]
[list]
[*][b]Scripted scenes[/b]: passive zombie puppets that greet you, walk over, open a dialog and trade; timed shows with lights, sounds and speech bubbles; scenes that survive a restart.
[*][b]Custom 3D models[/b]: upload a mesh and a texture at runtime, place it in the world with real collision, or let it fly around as a moving entity.
[*][b]Textures, sprites, falling items[/b]: new textures at runtime, world sprites, bananas from the sky.
[*][b]Screen apps[/b]: overlays that capture input, like a Flappy Bird inside a phone frame.
[*][b]World tools[/b]: items, vehicles, zombies, tile structures, weather, time, teleports, server messages.
[*][b]Everything scriptable[/b]: run_lua_server and run_lua_client execute Lua you write; script_install keeps it running after restarts.
[/list]

[h2]See it[/h2]
Animated captures (GIF): [url=https://github.com/Niach/zomboid-mcp/tree/main/art/showcase]github.com/Niach/zomboid-mcp/art/showcase[/url]
[list]
[*]A stone circle of custom 3D models with collision, on a meadow with cows and puppet villagers.
[*]A merchant puppet that greets the player, walks over, trades an axe and walks back.
[*]Flappy Bird inside a phone frame, drawn by the client mod.
[/list]

[h2]Setup[/h2]
[olist]
[*]Enable [b]Zomboid MCP[/b] (single player, hosted or dedicated server: add it to WorkshopItems / Mods).
[*]The MCP server ships inside the mod as plain Python 3 (no packages): [i]mcp/zomboid_mcp.py[/i]. Register it with Claude Code:
[code]claude mcp add zomboid -- python3 "<workshop>/3810456179/mods/ZomboidMCP/mcp/zomboid_mcp.py"[/code]
or run [i]mcp/install.sh[/i], which also installs the "zomboid engine" handbook skill.
[*]Ask Claude for something. Tool reference, protocol and engine notes: [url=https://github.com/Niach/zomboid-mcp]github.com/Niach/zomboid-mcp[/url]
[/olist]

[h2]Good to know[/h2]
[list]
[*]Server side only trusts the files in the game's Lua directory (no network port). On a dedicated server the MCP talks over ssh.
[*]Nothing in the mod runs unless an MCP client asks for it; without one it is inert.
[*]Build 42.21, tested in single player and on a dedicated Linux server.
[/list]
```
