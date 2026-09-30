# Giant snail

A snail PNG, three tiles wide, crawls slowly back and forth next to the player, for everyone (verified live: the
snail and a 3-tile Claude logo standing next to the player).

## Calls

```json
[
  {"tool": "players_list", "args": {}},
  {"tool": "texture_upload", "args": {"id": "snail", "png_path": "/home/me/art/snail.png"}},
  {"tool": "events_poll", "args": {"kinds": ["client_texture"]}},
  {"tool": "world_sprite", "args": {"id": "snail", "texture": "snail", "x": 6403.5, "y": 5498.5, "z": 0, "tiles": 3,
    "path": [[6413.5, 5498.5], [6413.5, 5508.5], [6403.5, 5508.5]], "speed": 0.4, "loop": "pingpong", "flip": "auto", "fade": 1}},
  {"tool": "visuals_list", "args": {}},
  {"tool": "clear_visuals", "args": {"what": "sprites", "id": "snail"}}
]
```

1. `texture_upload` with a file path on the MCP machine (or `png_base64`). Keep it ≤ 256×256 / ≤ 100 kB; the stream
   takes about 1 s per 30 kB. `client_texture` events show `{user, ok, w, h}` per client.
2. `world_sprite`: bottom-centre at `x, y`, width `tiles` (or `scale` px multiplier at zoom 1), a `path` of waypoints
   walked at `speed` tiles/s, `pingpong` turns around at the end, `flip auto` mirrors it when moving left on screen.
   Without `ttl` or `player` it persists and late joiners get it.
3. A friend sees it too: every client with the mod draws it; `visuals_list` shows who loaded the texture.
4. Remove it with `clear_visuals {what = "sprites", id = "snail"}`.

No PNG at hand? `texture_pixel` draws palette art with rectangles:

```json
{"tool": "texture_pixel", "args": {"id": "snail", "def": {"palette": {"s": [0.55, 0.35, 0.2, 1], "g": [0.3, 0.7, 0.3, 1]}, "rows": [".ssss...", "ssssss..", "ssssssgg", ".ssss.g.", "gggggggg"]}}}
```

## Raw Lua (client render hook, what world_sprite does)

```lua
-- sim: client
-- client: draw texture "snail" 3 tiles wide, crawling 10 tiles east and back over 25 s, bottom-centred on the tile
ZMCPClient.off("snail")
local p = getPlayer()
local x0, y0, z0, t0 = p:getX() + 3, p:getY(), p:getZ(), ZMCPClient.now()
ZMCPClient.on("snail", "render", function(ui)
    local entry = ZMCPClient.tex.get("snail")
    if not entry then return end
    local t = (ZMCPClient.now() - t0) % 50
    local f = t < 25 and t / 25 or (50 - t) / 25          -- 0..1..0
    local wx = x0 + 10 * f
    local zoom = getCore():getZoom(0)
    local w = 3 * 64 / zoom
    local h = w * entry.h / entry.w
    local sx, sy = isoToScreenX(0, wx, y0, z0), isoToScreenY(0, wx, y0, z0)
    ZMCPClient.tex.draw(ui, entry, sx - w / 2, sy - h, w, h, 1, t >= 25)   -- flip on the way back
end)
return "snail crawling"
```

## Variations

- `bob` + `bobHz` for a hopping creature, `opacity` for a ghost, `anchor = center` for something floating.
- Several frames: upload `snail1`, `snail2` and switch by time in the hook (`guides/world-sprites.md`).
- Player-only preview while iterating: add `"player": "niach"` (not persisted).
