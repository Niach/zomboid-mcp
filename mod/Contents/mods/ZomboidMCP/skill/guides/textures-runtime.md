# Runtime textures (the verified PNG pipeline)

Verified on 42.21 (single player and the client mod): a PNG can reach every client at runtime, without a Workshop
update or restart, and be drawn like any texture. Use it for sprites, HUD art, falling-item icons and 3D model textures.

## The tool path

```json
[
  {"tool": "texture_upload", "args": {"id": "snail", "png_path": "/home/me/art/snail.png"}},
  {"tool": "events_poll", "args": {"kinds": ["client_texture"]}},
  {"tool": "world_sprite", "args": {"id": "snail1", "texture": "snail", "x": 6403, "y": 5498, "tiles": 3}}
]
```

- `texture_upload {id, png_path | png_base64, player?}`: the MCP base64-encodes the file, the server stores it as
  `zmcp_tex_<id>.b64` in its Lua dir and streams it to every client (or one) in ~3 kB chunks (about 1 s per 30 kB).
- Each client decodes it (pure Lua, arithmetic only) into `~/Zomboid/Lua/zmcp_tex_<id>_<gen>.png` and loads it with
  `getTexture(absolutePath)`; it answers with a `client_texture` event `{id, gen, user, ok, w, h}` or `err`.
- **Generations:** re-uploading the same id makes a new generation and a new file name, because the engine caches
  textures by path. Never reuse a file name for new content.
- Late joiners receive every uploaded texture on `hello`. `clear_visuals {what = "textures"}` makes clients forget the
  loaded entries (files stay); `visuals_list` lists ids, generations and which client loaded what.
- Where it can be used: `world_sprite {texture = id}`, `overlay_draw {kind = "texture", tex = id}`,
  `falling_items {tex}` (default is the item icon), and your own client code through `ZMCPClient.tex.get(id)`.

Limits: keep PNGs ≤ 256×256 and ≤ 100 kB where possible (bigger works, up to 1.2 M base64 chars ≈ 900 kB, but every
client decodes byte by byte in Lua and the stream takes seconds). Alpha works. A negative width mirrors horizontally.

## Drawing an uploaded texture from client code

```lua
-- sim: client
-- client: draw texture "snail" in the top-left corner, 2x, mirrored, until stopped
ZMCPClient.off("snaildemo")
ZMCPClient.on("snaildemo", "render", function(ui)
    local entry = ZMCPClient.tex.get("snail")          -- {tex, w, h} for a PNG, {pixel, w, h} for pixel art, nil if unknown
    if not entry then return end
    ZMCPClient.tex.draw(ui, entry, 20, 60, entry.w * 2, entry.h * 2, 1, true)   -- (ui, entry, x, y, w, h, alpha, flip)
end)
return "drawing"
```

`ZMCPClient.tex.get(ref)` also resolves `"item:Base.Banana"` (the inventory icon) and any vanilla texture path that
`getTexture` accepts (`"media/ui/Furniture_Pickup.png"`); the raw `Texture` is `entry.tex`.

## Doing it by hand (what the mod does)

Only needed when you cannot use the tool (for example a client-only experiment). Base64 → bytes → PNG file → texture:

```lua
-- client: write a small base64 PNG to the Lua dir and load it as a texture
local B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local map = {}
for i = 1, 64 do map[chars:sub(i, i)] = i - 1 end
local name = "my_tex_1.png"                         -- new content = new name (textures are cached by path)
local out = getFileOutput(name)                     -- binary writer inside ~/Zomboid/Lua (parent dirs are created)
local n, buf, bits = 0, 0, 0
for i = 1, #B64 do
    local v = map[B64:sub(i, i)]
    if v then
        buf = buf * 64 + v
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            out:writeByte(math.floor(buf / 2 ^ bits) % 256)
            n = n + 1
            buf = buf % (2 ^ bits)
        end
    end
end
endFileOutput()
local sep = getFileSeparator()
local tex = getTexture(getMyDocumentFolder() .. sep .. "Lua" .. sep .. name)
return { bytes = n, loaded = tex ~= nil, w = tex and tex:getWidth() or 0, h = tex and tex:getHeight() or 0 }
```

Facts: the written file is byte-identical to the source (md5 verified); `getTexture(absPath)` returns a real `Texture`
with correct `getWidth()` / `getHeight()`; `Texture.getSharedTexture(absPath)` is the fallback; there is no `bit`
library, hence the arithmetic.

## Pixel art without a PNG

`texture_pixel {id, def}` registers a palette + rows sprite drawn with `drawRect` (`.` = transparent); usable wherever a
texture id is. Keep it small: a 32×32 sprite is 1024 rectangles per frame.

```json
{"tool": "texture_pixel", "args": {"id": "heart", "def": {"palette": {"r": [1, 0.1, 0.2, 1]}, "rows": [".rr.rr.", "rrrrrrr", ".rrrrr.", "..rrr..", "...r..."]}}}
```

## Generating art on the MCP machine

Any PNG works: draw it with Pillow, export it from an editor, or grab a game icon. For a flat-colour texture (3D models)
the stdlib is enough (see `3d-static-models.md`). Keep transparent margins small: the sprite's size in the world is the
image's pixel size times `scale` (or `tiles` for the width).
