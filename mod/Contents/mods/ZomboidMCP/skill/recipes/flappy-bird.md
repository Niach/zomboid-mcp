# Flappy Bird (screen app)

A complete game drawn on the overlay for one player or everyone: Space or click flaps, Escape quits, Space restarts.
Client script, persistent while installed (late joiners get it too). The full source is the tested block in
`guides/2d-overlays-and-apps.md` ("Flappy Bird, complete"); the scene SDK issue ships the same as
`examples/apps/flappy.lua` (repository github.com/Niach/zomboid-mcp) with its `app_start` wrapper (in progress).

## Calls

```json
[
  {"tool": "status", "args": {}},
  {"tool": "players_list", "args": {}},
  {"tool": "run_lua_client", "args": {"player": "niach", "code": "-- paste the Flappy Bird block from guides/2d-overlays-and-apps.md", "timeout_s": 15}},
  {"tool": "events_poll", "args": {"kinds": ["client_exec_result"]}},
  {"tool": "script_install", "args": {"name": "flappy", "side": "client", "code": "-- the same block, to keep it for everyone"}},
  {"tool": "script_remove", "args": {"name": "flappy", "side": "client"}},
  {"tool": "clear_visuals", "args": {"what": "hooks"}}
]
```

1. `run_lua_client {player}` first: one player, returns `{results = {niach = {ok, value = "flappy running"}}}`.
2. `script_install side=client` to keep it (every client, and on join); `script_remove` drops every hook registered
   under the name `flappy` on every client and releases the mouse.
3. `clear_visuals {what = "hooks"}` is the panic button for any app (all hooks, capture off).

## How it is built

- `ZMCPClient.off("flappy")` first so a re-push replaces the previous instance; `ZMCPClient.capture(true)` makes the
  overlay swallow the mouse and sit above the vanilla UI.
- `tick(now)` advances physics with a clamped `dt`; `render(ui)` draws rectangles and text only from state; `keyDown`
  handles Space (57) and Escape (1); `mouseDown` flaps.
- Score to the server: add `sendClientCommand(getPlayer(), "flappy", "score", { score = S.score })` on death and a
  server script with `Events.OnClientCommand` (`guides/networking-and-sync.md`) to log or announce it.
- Textures instead of rectangles: `texture_upload {id = "bird"}`, then `ZMCPClient.tex.draw(ui, ZMCPClient.tex.get("bird"), x, y, w, h, 1, false)`.
- Keys still reach the game (WASD moves the player while playing); use keys the game does not bind, or accept it.
