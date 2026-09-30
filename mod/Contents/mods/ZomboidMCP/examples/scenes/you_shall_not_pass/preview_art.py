#!/usr/bin/env python3
"""Offline preview of the scene's .x meshes: parse each art/*.x (checking counts, indices, normals and UVs), then
render it textured with a tiny software rasteriser from the game's iso camera (30 degrees down, orthographic, the
model turned by the scene's `ry` so its +Z front faces the camera) plus three turned views for checking the 3D shape.

    python3 preview_art.py [--art art] [--out /tmp/zp/art_preview] [models...]

Writes <out>/<model>.png (four views: game camera, turned -40 / +40 degrees, from behind) and <out>/scene.png (the
wizard on the deck next to the hovering demon, to scale). Needs Pillow and numpy. Lighting is an approximation;
the game's UI3DScene lighting is not reproduced.
"""
import argparse, math, os, re, sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
FIGURES = ("ysnp_wizard", "ysnp_wizard_up", "ysnp_demon")
TEXTURES = {"ysnp_pier": "ysnp_stone.png", "ysnp_pier_broken": "ysnp_stone.png", "ysnp_rock": "ysnp_rock.png",
            "ysnp_stalagmite": "ysnp_rock.png", "ysnp_lava": "ysnp_lava.png"}


def parse_x(path):
    """Parse the text .x subset the project writes; raises ValueError on anything inconsistent."""
    text = open(path).read()
    if not text.startswith("xof 0303txt"):
        raise ValueError("not a text .x file")
    num = lambda s: [float(t) for t in re.findall(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?", s)]
    m = re.search(r"\bMesh\s+\w+\s*\{", text)
    i_n, i_mat, i_uv = text.index("MeshNormals"), text.index("MeshMaterialList"), text.index("MeshTextureCoords")
    body = num(text[m.end():i_n])
    nv = int(body[0]); V = np.array(body[1:1 + 3 * nv]).reshape(nv, 3)
    rest = body[1 + 3 * nv:]
    nf = int(rest[0]); F = np.array(rest[1:1 + 4 * nf], dtype=int).reshape(nf, 4)
    if (F[:, 0] != 3).any() or F[:, 1:].min() < 0 or F[:, 1:].max() >= nv or len(rest) != 1 + 4 * nf:
        raise ValueError("bad face list")
    F = F[:, 1:]
    nb = num(text[i_n:i_mat]); nn = int(nb[0]); N = np.array(nb[1:1 + 3 * nn]).reshape(nn, 3)
    nfaces = np.array(nb[2 + 3 * nn:], dtype=int).reshape(-1, 4)[:, 1:]
    if nn != nv or len(nfaces) != nf or (nfaces != F).any():
        raise ValueError("normals do not match the vertices / faces")
    if np.abs(np.linalg.norm(N, axis=1) - 1).max() > 1e-3:
        raise ValueError("normals are not unit length")
    ub = num(text[text.index("{", i_uv):]); nu = int(ub[0]); UV = np.array(ub[1:1 + 2 * nu]).reshape(nu, 2)
    if nu != nv:
        raise ValueError("uv count")
    if os.path.splitext(os.path.basename(path))[0] in FIGURES and (UV.min() < 0 or UV.max() > 1):
        raise ValueError("figure uvs leave the atlas")          # the props tile their textures (uv > 1) on purpose
    tex = re.search(r'TextureFilename\s*\{\s*"([^"]+)"', text).group(1)
    return V, F, N, UV, tex


def rot_y(deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])      # +Z -> (sin, 0, cos), +X -> (cos, 0, -sin) (JOML rotateY)


def camera(elev=30.0):
    """Orthographic camera in the space where the model's front (+Z, after the scene's ry) faces the viewer."""
    e = math.radians(elev)
    right = np.array([1.0, 0, 0])
    up = np.array([0, math.cos(e), -math.sin(e)])
    back = np.array([0, math.sin(e), math.cos(e)])               # towards the camera
    return right, up, back


def render(items, size=(520, 620), ppu=None, bg=(34, 30, 36), elev=30.0, light=(-0.5, 0.8, 0.6), frame=None):
    """items = [(V, F, N, UV, texture_array, yaw_deg, offset)]; returns a PIL image (2x supersampled)."""
    ss = 2
    W, H = size[0] * ss, size[1] * ss
    right, up, back = camera(elev)
    L = np.array(light, float); L /= np.linalg.norm(L)
    projected = []
    for V, F, N, UV, tex, yaw, off in items:
        R = rot_y(yaw)
        Vw, Nw = V @ R.T + np.array(off), N @ R.T
        projected.append((Vw @ right, Vw @ up, Vw @ back, Nw, F, UV, tex))
    if frame is None:
        xs = np.concatenate([p[0] for p in projected]); ys = np.concatenate([p[1] for p in projected])
        frame = (xs.min(), xs.max(), ys.min(), ys.max())
    x0, x1, y0, y1 = frame
    k = min((W * 0.9) / (x1 - x0), (H * 0.9) / (y1 - y0)) if ppu is None else ppu * ss
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    color = np.zeros((H, W, 3)); color[:] = bg
    zbuf = np.full((H, W), -1e9)
    for sx_, sy_, sz, Nw, F, UV, tex in projected:
        px = (sx_ - cx) * k + W / 2
        py = H / 2 - (sy_ - cy) * k
        th, tw = tex.shape[:2]
        for a, b, c in F:
            xa, xb, xc, ya, yb, yc = px[a], px[b], px[c], py[a], py[b], py[c]
            area = (xb - xa) * (yc - ya) - (xc - xa) * (yb - ya)
            if abs(area) < 1e-9:
                continue
            bx0, bx1 = max(0, int(min(xa, xb, xc))), min(W - 1, int(max(xa, xb, xc)) + 1)
            by0, by1 = max(0, int(min(ya, yb, yc))), min(H - 1, int(max(ya, yb, yc)) + 1)
            if bx0 > bx1 or by0 > by1:
                continue
            gx, gy = np.meshgrid(np.arange(bx0, bx1 + 1) + 0.5, np.arange(by0, by1 + 1) + 0.5)
            w0 = ((xb - gx) * (yc - gy) - (xc - gx) * (yb - gy)) / area
            w1 = ((xc - gx) * (ya - gy) - (xa - gx) * (yc - gy)) / area
            w2 = 1 - w0 - w1
            inside = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
            if not inside.any():
                continue
            z = w0 * sz[a] + w1 * sz[b] + w2 * sz[c]
            sub = zbuf[by0:by1 + 1, bx0:bx1 + 1]
            vis = inside & (z > sub)
            if not vis.any():
                continue
            u = w0 * UV[a, 0] + w1 * UV[b, 0] + w2 * UV[c, 0]
            v = w0 * UV[a, 1] + w1 * UV[b, 1] + w2 * UV[c, 1]
            tx = np.clip((u if 0 <= u.min() and u.max() <= 1 else u % 1.0) * (tw - 1), 0, tw - 1).astype(int)
            ty = np.clip((v if 0 <= v.min() and v.max() <= 1 else v % 1.0) * (th - 1), 0, th - 1).astype(int)
            n = w0[..., None] * Nw[a] + w1[..., None] * Nw[b] + w2[..., None] * Nw[c]
            n /= np.linalg.norm(n, axis=-1, keepdims=True) + 1e-9
            facing = n @ back
            n = np.where(facing[..., None] < 0, -n, n)            # show back faces lit like front faces
            shade = 0.5 + 0.6 * np.clip(n @ L, 0, 1)
            col = tex[ty, tx] * shade[..., None]
            sub[vis] = z[vis]
            color[by0:by1 + 1, bx0:bx1 + 1][vis] = np.clip(col[vis], 0, 255)
    img = Image.fromarray(color.astype(np.uint8))
    return img.resize(size, Image.LANCZOS)


def load(art, name):
    V, F, N, UV, tex = parse_x(os.path.join(art, name + ".x"))
    png = TEXTURES.get(name, name + ".png")
    T = np.asarray(Image.open(os.path.join(art, png)).convert("RGB"), dtype=float)
    return V, F, N, UV, T


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--art", default=os.path.join(HERE, "art"))
    ap.add_argument("--out", default="/tmp/zp/art_preview")
    ap.add_argument("--ry", type=float, default=45.0, help="the scene's face / ry (the preview camera is relative to it)")
    ap.add_argument("models", nargs="*")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    names = a.models or sorted(os.path.splitext(f)[0] for f in os.listdir(a.art) if f.endswith(".x"))
    meshes = {}
    for name in names:
        V, F, N, UV, T = meshes[name] = load(a.art, name)
        lo, hi = V.min(axis=0), V.max(axis=0)
        print("%-18s %5d verts %5d tris  %6.1f KB .x  bbox x %.2f..%.2f y %.2f..%.2f z %.2f..%.2f  tex %dx%d" % (
            name, len(V), len(F), os.path.getsize(os.path.join(a.art, name + ".x")) / 1024, lo[0], hi[0], lo[1], hi[1], lo[2], hi[2], T.shape[1], T.shape[0]))
        if name not in FIGURES:
            continue
        views = [render([(V, F, N, UV, T, yaw, (0, 0, 0))], size=(360, 460)) for yaw in (0, -40, 40, 180)]
        sheet = Image.new("RGB", (360 * 4, 460), (0, 0, 0))
        for i, im in enumerate(views):
            sheet.paste(im, (i * 360, 0))
        sheet.save(os.path.join(a.out, name + ".png"))
        print("  ->", os.path.join(a.out, name + ".png"))
    if all(n in meshes for n in ("ysnp_wizard", "ysnp_demon", "ysnp_wizard_up")):
        # the strike moment to scale: 1 unit = 1 tile; the demon hovers 0.63 floors (3 units per floor... on the entity
        # layer a floor is 96 px vs 32 px per tile along x, i.e. about 2.1 units up the screen) above the deck, 3.5
        # tiles east of the wizard. World +x runs screen right and towards the camera: (cos45, 0, sin45) in the camera space used here.
        W = meshes["ysnp_wizard_up"]; D = meshes["ysnp_demon"]
        e = np.array([math.cos(math.radians(45)), 0, math.sin(math.radians(45))])    # world +x in camera space
        items = [(W[0], W[1], W[2], W[3], W[4], 0, (0, 0, 0)), (D[0], D[1], D[2], D[3], D[4], 0, tuple(e * 3.5 + np.array([0, 0.63 * 2.45, 0])))]
        render(items, size=(900, 600)).save(os.path.join(a.out, "scene.png"))
        print("  ->", os.path.join(a.out, "scene.png"))


if __name__ == "__main__":
    sys.exit(main())
