# World sprites (world-anchored billboards)

A world sprite is a texture drawn on the overlay at a world position, scaled with the camera zoom, always on top of the
world (owner preference: no wall occlusion). It is not an object: no collision, no save, nothing on the server except
the registry that re-sends it to late joiners. This is how the giant snail and a 3-tile Claude logo were shown.

```json
{"tool": "world_sprite", "args": {"id": "snail", "texture": "snail", "x": 6403.5, "y": 5498.5, "z": 0, "tiles": 3,
  "path": [[6413, 5498], [6413, 5508], [6403, 5508]], "speed": 0.4, "loop": "pingpong", "bob": 0, "flip": "auto", "fade": 1}}
```

| argument | meaning |
|---|---|
| `texture` | an uploaded id (`texture_upload` / `texture_pixel`), `item:Base.Banana` (inventory icon), or a vanilla texture path |
| `x, y, z` | tile position (fractional ok); the sprite's bottom-centre sits there (`anchor = center` for the middle) |
| `scale` | pixel multiplier at zoom 1 (a 160 px wide PNG at `scale` 1 spans 2.5 tiles: one tile is 64 px wide at zoom 1) |
| `tiles` | width in world tiles instead of `scale` |
| `path`, `speed`, `loop` | waypoints after `x,y`, tiles per second, `loop` / `pingpong` / `once` |
| `bob`, `bobHz` | hop height in px at zoom 1 and hops per second |
| `flip` | `auto` mirrors when travelling left on screen, `1` always, `0` never |
| `opacity`, `ttl`, `fade` | 0..1, seconds until removal (not persisted), fade in/out seconds |
| `player` | one client only (not persisted) |

Reusing an `id` replaces or moves the sprite. Remove with `clear_visuals {what = "sprites", id}` (or all sprites).
Southern sprites are drawn over northern ones (sorted by `z`, then `x + y`).

## The maths (for your own render hooks)

```lua
-- sim: client
-- client: a texture standing on a tile, done by hand in a render hook
ZMCPClient.off("billboard")
local wx, wy, wz = getPlayer():getX() + 2, getPlayer():getY() + 2, getPlayer():getZ()
ZMCPClient.on("billboard", "render", function(ui)
    local entry = ZMCPClient.tex.get("item:Base.Banana")    -- any texture ref
    if not entry then return end
    local zoom = getCore():getZoom(0)                        -- 1 = default; sizes are divided by it
    local w = 3 * 64 / zoom                                  -- 3 tiles wide
    local h = w * entry.h / entry.w
    local sx = isoToScreenX(0, wx, wy, wz)                   -- world -> screen (player 0's camera)
    local sy = isoToScreenY(0, wx, wy, wz)
    ZMCPClient.tex.draw(ui, entry, sx - w / 2, sy - h, w, h, 1, false)   -- bottom-centre at the point
end)
return "billboard on"
```

- `isoToScreenX/Y(playerNum, x, y, z)` gives the screen pixel of a world point; `screenToIsoX/Y(playerNum, mx, my, z)`
  the reverse (mouse → tile). Screen x grows with world x and shrinks with world y, so "moving left on screen" is
  `dx - dy < 0`.
- One tile is 64 px wide and 32 px tall at zoom 1; one floor level is 96 px.
- Draw bottom-centre (`y - h`) so the sprite "stands" on the tile.
- A hook that throws is removed after the first error; keep the per-frame work tiny (no allocation loops, no file I/O).

## Animation

- Frames: upload one texture per frame (`walk1`, `walk2`...) and pick by time in a render hook, or upload a sprite sheet
  and draw it with `ui:drawTextureScaledUniform` / sub-rect draws when available (`api_search "UIElement:DrawTextureScaled"`).
- Motion: the built-in `path` + `speed` is deterministic on every client (same start time), so all players see the same
  position; for scripted motion use a client script with a `tick` hook and keep the state in a global table.

```lua
-- sim: client
-- client: two-frame animation from uploaded textures "bird1" / "bird2" (falls back to an icon if missing)
ZMCPClient.off("flap")
ZMCPClient.on("flap", "render", function(ui)
    local frame = (math.floor(ZMCPClient.now() * 4) % 2 == 0) and "bird1" or "bird2"
    local entry = ZMCPClient.tex.get(frame) or ZMCPClient.tex.get("item:Base.Banana")
    if entry then ZMCPClient.tex.draw(ui, entry, 100, 100, 64, 64, 1, false) end
end)
return "flapping"
```

## When not to use a sprite

- It must occlude behind walls or cast shadows: use a tile object (`place_object`) or a 3D model (`model_place`).
- Players must interact with it (pick up, hit): use real items, objects or zombies.
- It should be visible to players without the mod: nothing client-side is; use world objects.
