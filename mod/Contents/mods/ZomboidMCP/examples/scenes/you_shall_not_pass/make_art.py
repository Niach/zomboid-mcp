#!/usr/bin/env python3
"""Generate the art of the "You shall not pass" scene: Project Zomboid .x text meshes plus painted PNG textures.

    python3 make_art.py [--out art]        # then: python3 preview_art.py  (renders /tmp/zp/art_preview/*.png)

Everything is original, generated here (no ripped assets): a stone bridge pier (and its broken variant), a rock
pillar and a stalagmite for the cavern, a flat lava slab, and two low-poly 3D figures: the fire demon (hulking body,
horns, fiery mane, jagged bat wings, a whip and a blade of fire) and the grey wizard (robe, beard, wide-brimmed
pointed hat, staff with a crystal: held down, or raised overhead with both hands). Model space is Y-up with the
origin at ground level (docs/ENGINE_NOTES.md, "Runtime 3D models"); 1 model unit = 1 tile on a world item
(model_place) and on the entity layer (entity3d_*). The figures face +Z; the scene turns +Z towards the iso camera
with `ry` (default 45). Triangles wind counter-clockwise seen from outside (like the verified star).
Needs Pillow (pip install pillow) for the textures; the meshes are plain text.
"""
import argparse, math, os, random

try:
    from PIL import Image, ImageChops, ImageDraw, ImageFilter
except ImportError:                                   # pragma: no cover
    raise SystemExit("make_art.py needs Pillow: pip install pillow")

random.seed(42)


# ---------------------------------------------------------------- .x writer
class Mesh:
    def __init__(self, name, texture):
        self.name, self.texture = name, texture
        self.v, self.n, self.uv, self.f = [], [], [], []

    def add(self, v, n, uv):
        self.v.append(v); self.n.append(n); self.uv.append(uv)
        return len(self.v) - 1

    def tri(self, a, b, c):
        self.f.append((a, b, c))

    def quad(self, a, b, c, d):
        self.tri(a, b, c); self.tri(a, c, d)

    # a flat convex polygon (list of 3D points, CCW seen from the normal side) with one normal and per-point uvs
    def poly(self, pts, normal, uvs):
        ids = [self.add(p, normal, uv) for p, uv in zip(pts, uvs)]
        for i in range(1, len(ids) - 1):
            self.tri(ids[0], ids[i], ids[i + 1])

    def write(self, path):
        f = lambda x: "%.6f" % x
        sep = lambda i, n: "," if i < n - 1 else ";"
        out = ["xof 0303txt 0032", "", "Material mat0 {", " 1.000000;1.000000;1.000000;1.000000;;", " 10.000000;",
               " 0.000000;0.000000;0.000000;;", " 0.000000;0.000000;0.000000;;", "", " TextureFilename {",
               '  "%s";' % self.texture, " }", "}", "", "Frame %s {" % self.name, "", " FrameTransformMatrix {",
               "  1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000;;",
               " }", "", " Mesh %s {" % self.name, "  %d;" % len(self.v)]
        out += ["  %s;%s;%s;%s" % (f(x), f(y), f(z), sep(i, len(self.v))) for i, (x, y, z) in enumerate(self.v)]
        out += ["  %d;" % len(self.f)]
        out += ["  3;%d,%d,%d;%s" % (a, b, c, sep(i, len(self.f))) for i, (a, b, c) in enumerate(self.f)]
        out += ["", "  MeshNormals {", "   %d;" % len(self.n)]
        out += ["   %s;%s;%s;%s" % (f(x), f(y), f(z), sep(i, len(self.n))) for i, (x, y, z) in enumerate(self.n)]
        out += ["   %d;" % len(self.f)]
        out += ["   3;%d,%d,%d;%s" % (a, b, c, sep(i, len(self.f))) for i, (a, b, c) in enumerate(self.f)]
        out += ["  }", "", "  MeshMaterialList {", "   1;", "   %d;" % len(self.f)]
        out += ["   0%s" % sep(i, len(self.f)) for i in range(len(self.f))]
        out += ["   { mat0 }", "  }", "", "  MeshTextureCoords c1 {", "   %d;" % len(self.uv)]
        out += ["   %s;%s;%s" % (f(u), f(v), sep(i, len(self.uv))) for i, (u, v) in enumerate(self.uv)]
        out += ["  }", " }", "}", ""]
        with open(path, "w") as fh:
            fh.write("\n".join(out))
        return len(self.v), len(self.f)


# ---------------------------------------------------------------- shapes
def box(mesh, x0, y0, z0, x1, y1, z1, tile=1.0):
    """An axis-aligned box; every face gets the texture tiled every `tile` units."""
    def face(pts, normal, axes):
        uvs = [(p[axes[0]] / tile, p[axes[1]] / tile) for p in pts]
        mesh.poly(pts, normal, uvs)
    face([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], (0, 0, 1), (0, 1))      # front +Z
    face([(x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0)], (0, 0, -1), (0, 1))     # back -Z
    face([(x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1)], (1, 0, 0), (2, 1))      # +X
    face([(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)], (-1, 0, 0), (2, 1))     # -X
    face([(x0, y1, z1), (x1, y1, z1), (x1, y1, z0), (x0, y1, z0)], (0, 1, 0), (0, 2))      # top +Y
    face([(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], (0, -1, 0), (0, 2))     # bottom -Y


def prism(mesh, outline, height, taper=0.6, tile=1.0, jitter=0.0):
    """A tapered prism: `outline` = [(x, z)] CCW seen from above at y=0, scaled by `taper` at y=height."""
    n = len(outline)
    top = [(x * taper + random.uniform(-jitter, jitter), z * taper + random.uniform(-jitter, jitter)) for x, z in outline]
    for i in range(n):
        (x1, z1), (x2, z2) = outline[i], outline[(i + 1) % n]
        (tx1, tz1), (tx2, tz2) = top[i], top[(i + 1) % n]
        ex, ez = x2 - x1, z2 - z1
        L = math.hypot(ex, ez) or 1
        normal = (ez / L, 0.15, -ex / L)
        nl = math.sqrt(sum(c * c for c in normal))
        normal = tuple(c / nl for c in normal)
        u0, u1 = (i / n) * 3, ((i + 1) / n) * 3
        mesh.poly([(x1, 0, z1), (x2, 0, z2), (tx2, height, tz2), (tx1, height, tz1)], normal,
                  [(u0, height / tile), (u1, height / tile), (u1, 0), (u0, 0)])
    # cap
    mesh.poly([(x, height, z) for x, z in reversed(top)], (0, 1, 0), [(0.5 + x, 0.5 + z) for x, z in reversed(top)])


def ngon(cx, cy, r, n=8, rot=0.0):
    return [(cx + r * math.cos(rot + 2 * math.pi * i / n), cy + r * math.sin(rot + 2 * math.pi * i / n)) for i in range(n)]


# ---------------------------------------------------------------- textures
def noise_img(size, base, spread, blur=1.5, seed=1):
    rnd = random.Random(seed)
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            k = rnd.uniform(-spread, spread)
            px[x, y] = tuple(max(0, min(255, int(c + k))) for c in base)
    return img.filter(ImageFilter.GaussianBlur(blur))


def stone_texture(path, size=256):
    """The pier texture (layout: see make_pier): dark basalt blocks, one per octagon face and course, staggered,
    with dark mortar; the foot glows faintly from the lava; a cracked copy and a molten strip for the broken pier."""
    rnd = random.Random(3)
    face_w, courses = 14, 12                                      # 8 faces x 14 px = 112 px around; 12 courses over 3 tiles
    ch = size / courses
    img = noise_img(size, (84, 80, 82), 16, blur=1.0, seed=3)
    px = img.load()
    for c in range(courses):                                      # per-block tint so the courses read
        y0, y1 = int(c * ch), int((c + 1) * ch)
        off = face_w // 2 if c % 2 else 0
        for b in range(-1, 224 // face_w + 1):
            x0 = b * face_w + off
            k = rnd.randint(-14, 12)
            for y in range(y0, y1):
                for x in range(max(0, x0), min(224, x0 + face_w)):
                    r, g, bl = px[x, y]
                    px[x, y] = (max(0, min(255, r + k)), max(0, min(255, g + k)), max(0, min(255, bl + k)))
    d = ImageDraw.Draw(img)
    mortar = (34, 30, 32)
    for half in (0, 112):
        for c in range(courses + 1):
            y = int(c * ch)
            d.line([(half, y), (half + 111, y)], fill=mortar, width=2)
            if c < courses:
                off = face_w // 2 if c % 2 else 0
                for b in range(0, 112 // face_w + 1):
                    x = half + (b * face_w + off) % 112
                    d.line([(x, y), (x, int(y + ch))], fill=mortar, width=2)
        d.line([(half, 0), (half, size)], fill=(58, 54, 56), width=1)
    # the lava glow at the foot: warm light rising from below, strongest in the mortar
    for y in range(int(size * 0.72), size):
        t = max(0.0, (y - size * 0.72) / (size * 0.28)) ** 1.6
        for x in range(224):
            r, g, b = px[x, y]
            dark = r < 50
            k = t * (0.85 if dark else 0.45)
            px[x, y] = (int(r + (235 - r) * k), int(g + (90 - g) * k * 0.9), int(b + (20 - b) * k * 0.6))
    # the cracked copy: glowing fissures running down the shaft
    cr = Image.new("L", (112, size), 0)
    dc = ImageDraw.Draw(cr)
    for i in range(6):
        x, y = rnd.randint(4, 107), rnd.randint(int(size * 0.3), int(size * 0.66))
        for _ in range(rnd.randint(6, 10)):
            nx, ny = x + rnd.randint(-7, 7), y + rnd.randint(-18, 18)
            dc.line([(x, y), (nx, ny)], fill=255, width=2)
            x, y = max(0, min(111, nx)), max(0, min(size - 1, ny))
    halo = cr.filter(ImageFilter.GaussianBlur(2.5))
    for y in range(size):
        for x in range(112):
            h, c = halo.getpixel((x, y)) / 255.0, cr.getpixel((x, y)) / 255.0
            r, g, b = px[112 + x, y]
            r, g, b = r + (220 - r) * min(1, h * 1.6), g + (70 - g) * min(1, h * 1.6), b + (15 - b) * min(1, h * 1.6)
            if c > 0.5:
                r, g, b = 255, 200, 90
            px[112 + x, y] = (int(r), int(g), int(b))
    # the molten strip for the break faces
    for y in range(size):
        for x in range(224, size):
            v = (math.sin(x * 0.7 + y * 0.13) + math.sin(y * 0.31) + rnd.uniform(-0.5, 0.5)) / 2.5
            v = max(0.0, min(1.0, 0.5 + v * 0.5))
            px[x, y] = (255, int(110 + 120 * v), int(20 + 80 * v * v))
    img = img.filter(ImageFilter.GaussianBlur(0.5))
    img.save(path)


def rock_texture(path, size=128):
    img = noise_img(size, (48, 44, 46), 26, blur=2.0, seed=5)
    d = ImageDraw.Draw(img)
    rnd = random.Random(7)
    for _ in range(40):                                   # cracks
        x, y = rnd.randrange(size), rnd.randrange(size)
        d.line([(x, y), (x + rnd.randint(-20, 20), y + rnd.randint(-30, 30))], fill=(22, 20, 22), width=1)
    for _ in range(30):                                   # lit facets
        x, y = rnd.randrange(size), rnd.randrange(size)
        d.line([(x, y), (x + rnd.randint(-12, 12), y + rnd.randint(2, 18))], fill=(84, 80, 82), width=1)
    img.filter(ImageFilter.GaussianBlur(0.5)).save(path)


def lava_texture(path, size=128):
    rnd = random.Random(11)
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            v = (math.sin(x * 0.19) + math.sin(y * 0.23) + math.sin((x + y) * 0.11) + rnd.uniform(-0.6, 0.6)) / 3
            v = max(0.0, min(1.0, 0.5 + v * 0.5))
            if v > 0.62: col = (255, int(150 + 100 * (v - 0.62) / 0.38), 40)     # bright vein
            elif v > 0.45: col = (int(200 + 55 * (v - 0.45) / 0.17), int(60 + 90 * (v - 0.45) / 0.17), 20)
            else: col = (int(40 + 90 * v / 0.45), int(8 + 30 * v / 0.45), 8)     # dark crust
            px[x, y] = col
    img.filter(ImageFilter.GaussianBlur(1.0)).save(path)


# ---------------------------------------------------------------- the bridge pier (slender octagonal stone column)
# One pier stands on every tile under the deck (scene.lua: one per tile, carrier centred on the square), so it has to
# be slim for the lava to show between the piers: an octagonal shaft 0.36 tiles across on a wider plinth, with a
# flared capital 0.62 tiles across whose top (y = 3.0 = one floor) carries the deck. World items get a random turn
# about the vertical axis, so the pier is 8-fold symmetric and never relies on its orientation.
# ysnp_stone.png (256x256): x 0..111 the intact stone wrapped once around the column (v = 0 at the top, y = 3.0;
# v = 1 at the foot, y = 0; a faint lava glow near the foot), x 112..223 the same stone split by glowing cracks (the
# broken pier), x 224..255 a strip of molten rock for the fresh break faces.
PIER_H, PIER_N = 3.0, 8
PIER_U = {"stone": (0 / 256, 112 / 256), "cracked": (112 / 256, 224 / 256), "glow": (226 / 256, 254 / 256)}
PIER_PROFILE = [(0.00, 0.33), (0.18, 0.33), (0.30, 0.25), (0.40, 0.20), (2.45, 0.18), (2.62, 0.21),
                (2.78, 0.33), (3.00, 0.33)]                         # (y, octagon radius) from the foot up


def _newell(pts):
    n = [0.0, 0.0, 0.0]
    for i, p in enumerate(pts):
        q = pts[(i + 1) % len(pts)]
        n[0] += (p[1] - q[1]) * (p[2] + q[2]); n[1] += (p[2] - q[2]) * (p[0] + q[0]); n[2] += (p[0] - q[0]) * (p[1] + q[1])
    L = math.sqrt(sum(c * c for c in n)) or 1.0
    return tuple(c / L for c in n)


def _face(m, pts, uvs, inside):
    """A flat polygon wound CCW seen from outside: flipped when its normal points towards `inside`."""
    n = _newell(pts)
    c = tuple(sum(p[k] for p in pts) / len(pts) for k in range(3))
    if sum(n[k] * (c[k] - inside[k]) for k in range(3)) < 0:
        pts, uvs, n = pts[::-1], uvs[::-1], tuple(-x for x in n)
    m.poly(pts, n, uvs)


def _oct(y, r, jag=None, n=PIER_N):
    return [(r * math.cos(math.pi / n + 2 * math.pi * j / n), y + (jag[j] if jag else 0.0),
             r * math.sin(math.pi / n + 2 * math.pi * j / n)) for j in range(n)]


def _column(m, rings, region, xf=lambda p: p, glow_top=False, glow_bottom=False):
    """Loft octagon rings (bottom to top) into flat-shaded faces; the side uvs wrap `region` once around and map the
    height y to v = 1 - y / PIER_H; the end caps are stone, or molten rock when they are a fresh break."""
    u0, u1 = PIER_U[region]
    n = len(rings[0])
    uv = lambda j, p: (u0 + (u1 - u0) * j / n, 1.0 - p[1] / PIER_H)
    for a, b in zip(rings, rings[1:]):
        axis = (0.0, (sum(p[1] for p in a) + sum(p[1] for p in b)) / (2 * n), 0.0)
        for j in range(n):
            k = (j + 1) % n
            pts = [a[j], a[k], b[k], b[j]]
            _face(m, [xf(p) for p in pts], [uv(j, a[j]), uv(j + 1, a[k]), uv(j + 1, b[k]), uv(j, b[j])], xf(axis))
    for ring_, top, hot in ((rings[0], False, glow_bottom), (rings[-1], True, glow_top)):
        c = (0.0, sum(p[1] for p in ring_) / n, 0.0)
        inside = xf((0.0, c[1] + (-1.0 if top else 1.0), 0.0))
        if hot:                                                     # a jagged break: a fan of molten triangles
            g0, g1 = PIER_U["glow"]
            for j in range(n):
                k = (j + 1) % n
                _face(m, [xf(c), xf(ring_[j]), xf(ring_[k])], [((g0 + g1) / 2, 0.5), (g0, 0.2 + 0.6 * j / n), (g1, 0.2 + 0.6 * k / n)], inside)
        else:
            s0, s1 = PIER_U["stone"]
            _face(m, [xf(p) for p in ring_], [(s0 + (s1 - s0) * (0.5 + p[0]), 0.05 + 0.1 * (0.5 + p[2])) for p in ring_], inside)


def _tilt(deg_z, deg_x, pivot, shift):
    az, ax = math.radians(deg_z), math.radians(deg_x)
    def xf(p):
        x, y, z = p[0] - pivot[0], p[1] - pivot[1], p[2] - pivot[2]
        x, y = x * math.cos(az) - y * math.sin(az), x * math.sin(az) + y * math.cos(az)
        y, z = y * math.cos(ax) - z * math.sin(ax), y * math.sin(ax) + z * math.cos(ax)
        return (x + pivot[0] + shift[0], y + pivot[1] + shift[1], z + pivot[2] + shift[2])
    return xf


def make_pier(out, broken=False):
    m = Mesh("YSNPPierBroken" if broken else "YSNPPier", "ysnp_stone.png")
    prof = PIER_PROFILE
    if not broken:
        _column(m, [_oct(y, r) for y, r in prof], "stone")
    else:
        rnd = random.Random(77)                                     # own generator: the global one feeds the rocks
        cut_lo, cut_hi = 1.30, 1.62                                 # the break: stump top .. upper piece bottom
        jag_lo = [rnd.uniform(-0.12, 0.14) for _ in range(PIER_N)]
        jag_hi = [j + rnd.uniform(0.02, 0.08) for j in jag_lo]      # the upper piece's underside follows the break
        shaft_r = lambda y: 0.20 + (0.18 - 0.20) * (y - 0.40) / (2.45 - 0.40)
        lower = [(y, r) for y, r in prof if y < cut_lo] + [(cut_lo, shaft_r(cut_lo))]
        upper = [(cut_hi, shaft_r(cut_hi))] + [(y, r) for y, r in prof if y > cut_hi]
        rings_lo = [_oct(y, r) for y, r in lower[:-1]] + [_oct(cut_lo, lower[-1][1], jag_lo)]
        rings_hi = [_oct(cut_hi, upper[0][1], jag_hi)] + [_oct(y, r) for y, r in upper[1:]]
        _column(m, rings_lo, "cracked", glow_top=True)
        # the upper half: knocked sideways and tilted about the top of the capital, hanging from the deck
        _column(m, rings_hi, "cracked", xf=_tilt(9.0, -5.0, (0.0, PIER_H, 0.0), (0.05, -0.04, 0.03)), glow_bottom=True)
        # two fallen chunks at the foot (small tilted octagonal blocks)
        for (cx, cz, r, h, tz, tx) in ((0.30, 0.18, 0.09, 0.12, 25.0, 10.0), (-0.22, 0.30, 0.07, 0.10, -18.0, 30.0)):
            xf = _tilt(tz, tx, (0.0, h / 2, 0.0), (cx, 0.0, cz))
            _column(m, [_oct(0.0, r, n=5), _oct(h, r * 0.85, n=5)], "cracked", xf=xf, glow_top=True)
    return m.write(os.path.join(out, "ysnp_pier_broken.x" if broken else "ysnp_pier.x"))


# ---------------------------------------------------------------- the pieces
def make_rock(out):
    m = Mesh("YSNPRock", "ysnp_rock.png")
    outline = [(r * math.cos(a), r * math.sin(a)) for i in range(9)
               for a, r in [(2 * math.pi * i / 9, 0.55 + random.uniform(-0.12, 0.12))]]
    prism(m, outline, 4.2, taper=0.45, tile=1.2, jitter=0.08)
    return m.write(os.path.join(out, "ysnp_rock.x"))


def make_stalagmite(out):
    m = Mesh("YSNPStalagmite", "ysnp_rock.png")
    outline = ngon(0, 0, 0.32, 7)
    prism(m, [(x, y) for x, y in outline], 1.8, taper=0.12, tile=1.0, jitter=0.03)
    return m.write(os.path.join(out, "ysnp_stalagmite.x"))


def make_lava(out):
    m = Mesh("YSNPLava", "ysnp_lava.png")
    s = 1.5                                                            # a 3x3 tile slab centred on the carrier square
    m.poly([(-s, 0.03, s), (s, 0.03, s), (s, 0.03, -s), (-s, 0.03, -s)], (0, 1, 0), [(0, 1), (2, 1), (2, 0), (0, 0)])
    return m.write(os.path.join(out, "ysnp_lava.x"))


# ---------------------------------------------------------------- low-poly 3D figures
# The wizard and the demon are real closed meshes built from lofted rings (lathe bodies, tubes along a path,
# low-poly spheres, cones) and extruded wing membranes, UV-mapped into one small painted atlas per model.
# Front = +Z (the scene's `ry` turns +Z towards the iso camera), +X = the figure's left hand side = screen right.
def v_add(a, b): return (a[0] + b[0], a[1] + b[1], a[2] + b[2])
def v_sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def v_mul(a, k): return (a[0] * k, a[1] * k, a[2] * k)
def v_dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def v_cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def v_len(a): return math.sqrt(v_dot(a, a))
def v_norm(a):
    L = v_len(a)
    return (a[0] / L, a[1] / L, a[2] / L) if L > 1e-12 else (0.0, 1.0, 0.0)
def v_lerp(a, b, t): return tuple(x + (y - x) * t for x, y in zip(a, b))


class Atlas:
    """Named pixel rectangles of one square texture; uv() maps (u, v) in 0..1 into a rectangle (with a margin)."""
    def __init__(self, size, regions):
        self.size, self.regions = size, regions

    def uv(self, name, u, v, pad=3):
        x0, y0, x1, y1 = self.regions[name]
        u, v = min(1.0, max(0.0, u)), min(1.0, max(0.0, v))
        return ((x0 + pad + u * (x1 - x0 - 2 * pad)) / self.size, (y0 + pad + v * (y1 - y0 - 2 * pad)) / self.size)

    def box(self, name, pad=0):
        x0, y0, x1, y1 = self.regions[name]
        return (x0 + pad, y0 + pad, x1 - pad, y1 - pad)


def ring(c, rx, rz, n, ax=(1, 0, 0), az=(0, 0, 1)):
    """A closed ellipse around c in the plane (ax, az). Point j sits at angle 2*pi*j/n measured from -az towards -ax,
    so for a vertical lathe u = j/n runs back (0) -> right side of the figure, -X (0.25) -> front, +Z (0.5) -> +X (0.75)."""
    pts = []
    for j in range(n):
        t = 2 * math.pi * j / n
        s, co = -math.sin(t), -math.cos(t)
        pts.append(v_add(c, v_add(v_mul(ax, rx * s), v_mul(az, rz * co))))
    return pts


class Figure:
    def __init__(self, atlas):
        self.atlas, self.parts = atlas, []

    def loft(self, rings, region, smooth=True, caps=(True, True)):
        """Connect equal-sized closed rings into a tube (u around, v along the rings), capped at both ends."""
        n, nr, A = len(rings[0]), len(rings), self.atlas
        P, UV, G, T = [], [], [], []
        W = n + 1
        for i, rg in enumerate(rings):
            for j in range(W):
                P.append(rg[j % n]); UV.append(A.uv(region, j / n, i / (nr - 1))); G.append(0)
        for i in range(nr - 1):
            for j in range(n):
                a = i * W + j
                T += [(a, a + 1, a + W + 1), (a, a + W + 1, a + W)]
        for end, flip in ((0, False), (nr - 1, True)):
            if not caps[0 if end == 0 else 1]:
                continue
            rg = rings[end]
            c = v_mul(tuple(map(sum, zip(*rg))), 1.0 / n)
            if max(v_len(v_sub(p, c)) for p in rg) < 1e-6:
                continue
            base = len(P)
            P.append(c); UV.append(A.uv(region, 0.5, 0.0 if end == 0 else 1.0)); G.append(1 + end)
            for j in range(n):
                P.append(rg[j]); UV.append(A.uv(region, j / n, 0.0 if end == 0 else 1.0)); G.append(1 + end)
            for j in range(n):
                a, b = base + 1 + j, base + 1 + (j + 1) % n
                T.append((base, a, b) if flip else (base, b, a))
        self.add(P, UV, T, smooth, G)

    def add(self, P, UV, T, smooth, G=None):
        T = [t for t in T if v_len(v_cross(v_sub(P[t[1]], P[t[0]]), v_sub(P[t[2]], P[t[0]]))) > 1e-9]
        vol = sum(v_dot(P[a], v_cross(P[b], P[c])) for a, b, c in T)
        if vol < 0:                                   # closed part: make every triangle wind CCW seen from outside
            T = [(a, c, b) for a, b, c in T]
        self.parts.append((P, UV, T, smooth, G or [0] * len(P)))

    def lathe(self, profile, region, n=10, smooth=True):
        """profile = [(y, rx, rz, cz)] from top to bottom (v = 0 at the top); cz shifts the ring centre forward."""
        self.loft([ring((0, y, cz), rx, rz, n) for y, rx, rz, cz in profile], region, smooth)

    def sphere(self, c, r, region, n=8, k=5, ry=None, smooth=True):
        """A low-poly (ellipsoid) sphere; r = radius or (rx, rz), ry = vertical radius (default rx)."""
        rx, rz = r if isinstance(r, tuple) else (r, r)
        ry = ry or rx
        rings = []
        for i in range(k + 1):
            p = math.pi * i / k
            rings.append(ring((c[0], c[1] + ry * math.cos(p), c[2]), rx * math.sin(p), rz * math.sin(p), n))
        self.loft(rings, region, smooth)

    def tube(self, path, radii, region, n=8, smooth=True, flat=1.0):
        """Rings along a polyline (parallel-transported frame); flat < 1 squashes the cross-section."""
        rings, prev = [], None
        for i, p in enumerate(path):
            a, b = path[max(0, i - 1)], path[min(len(path) - 1, i + 1)]
            t = v_norm(v_sub(b, a))
            if prev is None:
                ref = (0, 1, 0) if abs(t[1]) < 0.9 else (1, 0, 0)
                nx = v_norm(v_cross(t, ref))
            else:
                nx = v_norm(v_sub(prev, v_mul(t, v_dot(prev, t))))
            prev = nx
            nz = v_cross(t, nx)
            rings.append(ring(p, radii[i], radii[i] * flat, n, nx, nz))
        self.loft(rings, region, smooth)

    def sheet(self, outline, to3d, region, uvmap, depth):
        """A thin extruded membrane: outline = [(s, t)] (a simple polygon), to3d(s, t, side) -> 3D point."""
        tris = ear_clip(outline)
        P, UV, T, G = [], [], [], []
        n = len(outline)
        for side, grp in ((1, 0), (-1, 1)):
            base = len(P)
            for s, t in outline:
                P.append(to3d(s, t, side * depth / 2)); UV.append(self.atlas.uv(region, *uvmap(s, t))); G.append(grp)
            T += [(base + a, base + b, base + c) if side > 0 else (base + a, base + c, base + b) for a, b, c in tris]
        for i in range(n):                             # the rim
            j = (i + 1) % n
            base = len(P)
            for s, t, sd in ((outline[i][0], outline[i][1], 1), (outline[j][0], outline[j][1], 1),
                             (outline[j][0], outline[j][1], -1), (outline[i][0], outline[i][1], -1)):
                P.append(to3d(s, t, sd * depth / 2)); UV.append(self.atlas.uv(region, *uvmap(s, t))); G.append(2 + i)
            T += [(base, base + 2, base + 1), (base, base + 3, base + 2)]
        self.add(P, UV, T, False, G)

    def to_mesh(self, name, texture):
        m = Mesh(name, texture)
        for P, UV, T, smooth, G in self.parts:
            fn = [v_norm(v_cross(v_sub(P[b], P[a]), v_sub(P[c], P[a]))) for a, b, c in T]
            if not smooth:
                for (a, b, c), nn in zip(T, fn):
                    ids = [m.add(P[i], nn, UV[i]) for i in (a, b, c)]
                    m.tri(*ids)
                continue
            acc = {}
            key = lambda i: (round(P[i][0], 5), round(P[i][1], 5), round(P[i][2], 5), G[i])
            for (a, b, c), nn in zip(T, fn):
                area = v_len(v_cross(v_sub(P[b], P[a]), v_sub(P[c], P[a])))
                for i in (a, b, c):
                    acc[key(i)] = v_add(acc.get(key(i), (0, 0, 0)), v_mul(nn, area))
            ids = {}
            for a, b, c in T:
                out = []
                for i in (a, b, c):
                    if i not in ids:
                        ids[i] = m.add(P[i], v_norm(acc[key(i)]), UV[i])
                    out.append(ids[i])
                m.tri(*out)
        return m


def ear_clip(poly):
    """Triangulate a simple polygon (list of (x, y), either winding); returns index triples in CCW order."""
    area = sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1] for i in range(len(poly)))
    idx = list(range(len(poly))) if area > 0 else list(reversed(range(len(poly))))
    def cross(o, a, b): return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    def inside(p, a, b, c): return cross(a, b, p) >= 0 and cross(b, c, p) >= 0 and cross(c, a, p) >= 0
    out, guard = [], 0
    while len(idx) > 3 and guard < 10000:
        guard += 1
        for k in range(len(idx)):
            i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            a, b, c = poly[i0], poly[i1], poly[i2]
            if cross(a, b, c) <= 1e-12:
                continue
            if any(inside(poly[j], a, b, c) for j in idx if j not in (i0, i1, i2)):
                continue
            out.append((i0, i1, i2)); idx.pop(k)
            break
        else:
            raise ValueError("ear_clip: polygon is not simple")
    out.append(tuple(idx))
    return out


def paint_noise(img, box, base, spread, seed, blur=1.0):
    x0, y0, x1, y1 = box
    tile = noise_img(max(x1 - x0, y1 - y0), base, spread, blur=blur, seed=seed).crop((0, 0, x1 - x0, y1 - y0))
    img.paste(tile, (x0, y0))


def vgrad(img, box, top, bottom, noise=0, seed=0):
    """A vertical gradient (plus a little noise) inside box."""
    rnd = random.Random(seed)
    x0, y0, x1, y1 = box
    px = img.load()
    for y in range(y0, y1):
        t = (y - y0) / max(1, y1 - y0 - 1)
        for x in range(x0, x1):
            k = rnd.uniform(-noise, noise)
            px[x, y] = tuple(max(0, min(255, int(a + (b - a) * t + k))) for a, b in zip(top, bottom))


# ---------------------------------------------------------------- the grey wizard
WIZARD_ATLAS = Atlas(256, {
    "robe": (0, 0, 128, 128), "sleeve": (128, 0, 192, 64), "skin": (192, 0, 256, 64), "face": (128, 64, 192, 128),
    "beard": (192, 64, 256, 128), "hat": (0, 128, 64, 192), "brim": (64, 128, 128, 192), "staff": (128, 128, 192, 192),
    "crystal": (192, 128, 256, 192), "belt": (0, 192, 64, 256), "hair": (64, 192, 128, 256), "dark": (128, 192, 192, 256),
    "glow": (192, 192, 256, 256)})


def build_wizard(raised):
    f = Figure(WIZARD_ATLAS)
    # the robe: a lathe from the shoulders (v = 0) to the flared hem (v = 1), front a little fuller
    f.lathe([(1.40, 0.07, 0.07, 0.0), (1.36, 0.15, 0.12, 0.0), (1.28, 0.25, 0.16, 0.01), (1.12, 0.25, 0.18, 0.02),
             (0.92, 0.26, 0.20, 0.02), (0.55, 0.31, 0.25, 0.02), (0.12, 0.38, 0.32, 0.03), (0.0, 0.40, 0.34, 0.03)],
            "robe", n=10)
    f.lathe([(0.97, 0.275, 0.215, 0.02), (0.90, 0.28, 0.22, 0.02)], "belt", n=10)          # rope belt
    # head, nose, hair, beard
    f.sphere((0, 1.49, 0.02), (0.12, 0.125), "face", n=8, k=5, ry=0.13)
    f.tube([(0, 1.50, 0.13), (0, 1.455, 0.175)], [0.03, 0.0], "skin", n=5)
    f.lathe([(1.58, 0.11, 0.09, -0.03), (1.45, 0.14, 0.10, -0.06), (1.30, 0.15, 0.07, -0.10), (1.22, 0.10, 0.04, -0.12)], "hair", n=8)
    f.loft([ring((0, 1.46, 0.08), 0.105, 0.06, 8), ring((0, 1.36, 0.155), 0.13, 0.06, 8),
            ring((0, 1.18, 0.20), 0.105, 0.055, 8), ring((0, 1.00, 0.225), 0.06, 0.04, 8), ring((0, 0.90, 0.23), 0.0, 0.0, 8)], "beard")
    # the hat: a wide, slightly drooping brim and a crooked cone
    tilt = lambda rg: [(x, y + 0.22 * z, z - 0.03) for x, y, z in rg]    # brim and cone lean back: the camera sees the face
    f.loft([tilt(ring((0, 1.585, 0.0), 0.0, 0.0, 12)), tilt(ring((0, 1.585, 0.0), 0.18, 0.18, 12)), tilt(ring((0, 1.56, 0.0), 0.35, 0.35, 12)),
            tilt(ring((0, 1.54, 0.0), 0.35, 0.35, 12)), tilt(ring((0, 1.565, 0.0), 0.18, 0.18, 12)), tilt(ring((0, 1.565, 0.0), 0.0, 0.0, 12))],
           "brim", smooth=False)
    f.loft([tilt(ring((0, 1.57, 0.0), 0.155, 0.155, 10)), tilt(ring((0, 1.78, -0.03), 0.11, 0.11, 10)), tilt(ring((0, 1.97, -0.08), 0.065, 0.065, 10)),
            tilt(ring((0, 2.11, -0.16), 0.03, 0.03, 10)), tilt(ring((0, 2.17, -0.25), 0.0, 0.0, 10))], "hat")
    # arms (wide sleeves), hands, the staff and its crystal
    if raised:
        # the staff thrust up high in the left hand (+X, screen right), the right hand raised open beside the hat
        right_arm = [(-0.22, 1.30, 0.0), (-0.44, 1.50, 0.08), (-0.50, 1.86, 0.14)]      # figure's right = -X
        left_arm = [(0.22, 1.30, 0.0), (0.44, 1.52, 0.08), (0.46, 1.92, 0.14)]
        hands = [(-0.51, 1.92, 0.15), (0.46, 1.98, 0.15)]
        staff = [(0.47, 1.10, 0.15), (0.44, 3.02, 0.15)]
        crystal, cr = (0.44, 3.10, 0.15), 0.085
    else:
        right_arm = [(-0.22, 1.30, 0.0), (-0.33, 1.04, 0.05), (-0.30, 0.84, 0.10)]
        left_arm = [(0.22, 1.30, 0.0), (0.35, 1.08, 0.08), (0.44, 0.93, 0.14)]
        hands = [(-0.30, 0.79, 0.11), (0.46, 0.90, 0.16)]
        staff = [(0.46, 0.0, 0.16), (0.46, 2.02, 0.16)]
        crystal, cr = (0.46, 2.09, 0.16), 0.06
    for arm in (right_arm, left_arm):
        f.tube(arm, [0.075, 0.085, 0.115], "sleeve", n=6)
    for h in hands:
        f.sphere(h, 0.06, "skin", n=5, k=3)
    f.tube(staff, [0.042, 0.032], "staff", n=6)
    top = staff[-1]
    # a gnarled head: three little claws around the crystal
    for a in (0, 2.1, 4.2):
        tip = v_add(crystal, (0.07 * math.cos(a), 0.05, 0.07 * math.sin(a)))
        f.tube([v_add(top, (0, -0.02, 0)), v_add(top, (0.05 * math.cos(a), 0.05, 0.05 * math.sin(a))), tip], [0.022, 0.018, 0.0], "staff", n=4, smooth=False)
    f.loft([ring(v_add(crystal, (0, cr * 1.4, 0)), 0.0, 0.0, 6), ring(crystal, cr, cr, 6),
            ring(v_add(crystal, (0, -cr * 1.1, 0)), 0.0, 0.0, 6)], "crystal", smooth=False)
    if raised:                                                           # a burst of light around the raised crystal
        for a in range(8):
            ang = 2 * math.pi * a / 8
            d = (math.cos(ang), math.sin(ang) * 0.9, 0.35)
            f.tube([v_add(crystal, v_mul(d, 0.05)), v_add(crystal, v_mul(d, 0.26 if a % 2 else 0.18))], [0.035, 0.0], "glow", n=4, smooth=False)
    return f


def paint_wizard(path, raised):
    A = WIZARD_ATLAS
    img = Image.new("RGB", (A.size, A.size), (120, 120, 128))
    d = ImageDraw.Draw(img)
    rnd = random.Random(31)
    # robe: grey wool, vertical folds, a darker dusty hem; u = 0.5 is the front
    box = A.box("robe")
    vgrad(img, box, (150, 152, 160), (104, 104, 110), noise=10, seed=32)
    img.paste(img.crop(box).filter(ImageFilter.GaussianBlur(0.8)), box[:2])
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = box
    for i in range(14):
        x = x0 + 4 + i * (x1 - x0 - 8) / 13.0 + rnd.uniform(-2, 2)
        d.line([(x, y0 + 10), (x + rnd.uniform(-3, 3), y1)], fill=(112, 114, 122), width=2)
        d.line([(x + 3, y0 + 18), (x + 3 + rnd.uniform(-2, 2), y1)], fill=(146, 148, 156), width=1)
    d.rectangle([x0, y1 - 10, x1, y1], fill=(84, 82, 84))
    d.line([(x0 + (x1 - x0) * 0.5, y0), (x0 + (x1 - x0) * 0.5, y0 + 30)], fill=(80, 80, 88), width=2)   # collar slit
    vgrad(img, A.box("sleeve"), (140, 142, 150), (112, 112, 120), noise=8, seed=33)
    x0, y0, x1, y1 = A.box("sleeve")
    d.rectangle([x0, y1 - 8, x1, y1], fill=(92, 92, 100))                 # cuff
    paint_noise(img, A.box("skin"), (220, 184, 156), 8, 34)
    # the face: skin, bushy white brows, eyes, a nose shadow, the white moustache; hair at the back
    box = A.box("face")
    paint_noise(img, box, (218, 182, 154), 6, 35)
    x0, y0, x1, y1 = box
    W, H = x1 - x0, y1 - y0
    P = lambda u, v: (x0 + u * W, y0 + v * H)
    d.rectangle([x0, y0, x1, y0 + H * 0.28], fill=(200, 200, 206))        # grey hair under the hat
    d.rectangle([x0, y0, x0 + W * 0.26, y1], fill=(200, 200, 206))
    d.rectangle([x0 + W * 0.74, y0, x1, y1], fill=(200, 200, 206))
    for eu in (0.43, 0.57):
        ex, ey = P(eu, 0.47)
        d.ellipse([ex - 3, ey - 2, ex + 3, ey + 2], fill=(245, 245, 245))
        d.ellipse([ex - 1.5, ey - 1.5, ex + 1.5, ey + 1.5], fill=(40, 50, 70))
        bx, by = P(eu, 0.40)
        d.polygon([(bx - 6, by + 1), (bx + 6, by - 2), (bx + 6, by + 2), (bx - 6, by + 3)], fill=(236, 236, 240))
    d.polygon([P(0.5, 0.45), P(0.47, 0.58), P(0.53, 0.58)], fill=(196, 156, 128))
    d.polygon([P(0.35, 0.60), P(0.65, 0.60), P(0.70, 0.78), P(0.5, 0.70), P(0.30, 0.78)], fill=(236, 236, 240))
    d.rectangle([x0 + W * 0.3, y0 + H * 0.72, x0 + W * 0.7, y1], fill=(232, 232, 236))
    # beard, hair: white / light grey strands
    for name, base, strand in (("beard", (228, 228, 234), (190, 190, 198)), ("hair", (196, 196, 204), (160, 160, 170))):
        box = A.box(name)
        paint_noise(img, box, base, 6, 36)
        x0, y0, x1, y1 = box
        for i in range(22):
            x = rnd.uniform(x0, x1)
            d.line([(x, y0), (x + rnd.uniform(-3, 3), y1)], fill=strand, width=1)
    # hat and brim: weathered grey, a dark band above the brim
    vgrad(img, A.box("hat"), (122, 124, 134), (100, 100, 110), noise=8, seed=37)
    x0, y0, x1, y1 = A.box("hat")
    d.rectangle([x0, y0, x1, y0 + 8], fill=(70, 68, 72))
    paint_noise(img, A.box("brim"), (112, 114, 124), 8, 38)
    # staff: brown wood with grain along it; the crystal and the glow
    box = A.box("staff")
    paint_noise(img, box, (104, 72, 44), 10, 39)
    x0, y0, x1, y1 = box
    for i in range(12):
        x = rnd.uniform(x0, x1)
        d.line([(x, y0), (x + rnd.uniform(-2, 2), y1)], fill=(70, 46, 28), width=1)
    vgrad(img, A.box("crystal"), (255, 255, 255) if raised else (236, 246, 255), (190, 225, 255) if raised else (150, 190, 235))
    vgrad(img, A.box("glow"), (255, 255, 255), (215, 238, 255))
    paint_noise(img, A.box("belt"), (92, 80, 66), 10, 40)
    paint_noise(img, A.box("dark"), (60, 60, 66), 6, 41)
    img.save(path)


def make_wizard(out, raised):
    name = "ysnp_wizard_up" if raised else "ysnp_wizard"
    m = build_wizard(raised).to_mesh("YSNPWizardUp" if raised else "YSNPWizard", name + ".png")
    paint_wizard(os.path.join(out, name + ".png"), raised)
    return m.write(os.path.join(out, name + ".x"))


# ---------------------------------------------------------------- the fire demon
DEMON_ATLAS = Atlas(256, {
    "wing": (0, 0, 128, 128), "body": (128, 0, 256, 64), "limb": (128, 64, 256, 128), "face": (0, 128, 64, 192),
    "horn": (64, 128, 128, 192), "fire": (128, 128, 192, 192), "blade": (192, 128, 256, 192), "claw": (0, 192, 64, 256),
    "bone": (64, 192, 128, 256), "ember": (128, 192, 256, 256)})

# the wing in its own plane: s = out along the span, t = up; the root sits on the shoulder blade
WING = [(0.0, 0.0), (0.55, 0.62), (1.10, 1.02), (1.30, 1.42), (1.62, 1.22), (2.40, 1.50), (2.12, 0.82), (2.62, 0.26),
        (2.08, -0.02), (2.16, -0.78), (1.62, -0.50), (1.30, -1.22), (0.92, -0.62), (0.48, -1.02), (0.12, -0.46)]
WING_BONES = [[(0.0, 0.0), (0.55, 0.62), (1.10, 1.02), (1.30, 1.42)], [(1.10, 1.02), (2.40, 1.50)],
              [(1.10, 1.02), (2.62, 0.26)], [(1.10, 1.02), (2.16, -0.78)], [(1.10, 1.02), (1.30, -1.22)], [(0.55, 0.62), (0.48, -1.02)]]
WING_S, WING_T = (0.0, 2.7), (-1.3, 1.6)


def wing_uv(s, t):
    return ((s - WING_S[0]) / (WING_S[1] - WING_S[0]), (WING_T[1] - t) / (WING_T[1] - WING_T[0]))


def wing_point(side):
    """(s, t, dz) -> 3D: from the shoulder blade out and up, swept back and cupped forward at the fingertips."""
    def to3d(s, t, dz):
        x = side * (0.42 + s * 1.05)
        y = 2.45 + t * 1.05 + s * 0.22
        z = -0.32 - s * 0.30 + 0.10 * math.sin(s / 2.62 * math.pi) * (1 if t > 0 else 0.5) + dz
        return (x, y, z)
    return to3d


def build_demon():
    f = Figure(DEMON_ATLAS)
    # a hunched, hulking torso (lathe, shoulders pushed forward) on thick digitigrade legs
    f.lathe([(2.62, 0.20, 0.18, 0.10), (2.52, 0.50, 0.34, 0.06), (2.34, 0.80, 0.44, 0.04), (2.05, 0.74, 0.44, 0.06),
             (1.72, 0.58, 0.38, 0.06), (1.40, 0.46, 0.32, 0.02), (1.12, 0.40, 0.28, 0.0), (0.98, 0.20, 0.18, 0.0)], "body", n=10)
    for sx in (-1, 1):
        f.tube([(sx * 0.30, 1.14, 0.0), (sx * 0.40, 0.70, 0.20), (sx * 0.44, 0.24, -0.06), (sx * 0.46, 0.06, 0.12)],
               [0.22, 0.19, 0.13, 0.11], "limb", n=6)
        f.tube([(sx * 0.46, 0.08, -0.02), (sx * 0.47, 0.06, 0.20), (sx * 0.48, 0.03, 0.36)], [0.12, 0.11, 0.03], "claw", n=6)
        # arms: shoulder, elbow, wrist, a big clawed fist
        f.tube([(sx * 0.70, 2.28, 0.04), (sx * 1.02, 1.80, 0.22), (sx * 1.05, 1.32, 0.46)], [0.24, 0.19, 0.15], "limb", n=6)
        f.sphere((sx * 1.05, 1.22, 0.50), 0.17, "claw", n=6, k=3)
        # horns: out, up, then forward
        f.tube([(sx * 0.20, 2.98, 0.20), (sx * 0.46, 3.10, 0.12), (sx * 0.66, 3.36, 0.06), (sx * 0.68, 3.66, 0.18), (sx * 0.56, 3.86, 0.36)],
               [0.11, 0.09, 0.07, 0.04, 0.0], "horn", n=6)
        # wings: an extruded membrane with jagged fingers, bones along the fingers
        to3d = wing_point(sx)
        f.sheet(WING, to3d, "wing", wing_uv, 0.05)
        for bone in WING_BONES:
            pts = [to3d(s, t, 0.035) for s, t in bone]
            f.tube(pts, [0.06] + [0.04] * (len(pts) - 2) + [0.015], "bone", n=5, smooth=False)
    # the head: a heavy skull with a jutting jaw, glowing eyes and mouth painted on the front (u = 0.5)
    f.lathe([(3.10, 0.0, 0.0, 0.20), (3.06, 0.14, 0.14, 0.20), (2.98, 0.25, 0.25, 0.21), (2.84, 0.30, 0.29, 0.22),
             (2.70, 0.29, 0.31, 0.26), (2.58, 0.24, 0.28, 0.30), (2.50, 0.14, 0.18, 0.32), (2.48, 0.0, 0.0, 0.30)], "face", n=8)
    # a mane of fire over the head and the shoulders
    rnd = random.Random(55)
    for i in range(7):
        x = -0.62 + 1.24 * i / 6
        c = 1 - abs(x) / 0.62
        base = (x, 2.50 + 0.40 * c + rnd.uniform(-0.04, 0.04), -0.10 - 0.10 * c)
        L = 0.50 + 0.55 * c + rnd.uniform(-0.1, 0.1)
        mid = v_add(base, (x * 0.30, L * 0.50, -L * 0.30))
        tip = v_add(base, (x * 0.55 + rnd.uniform(-0.12, 0.12), L * 0.85, -L * 0.95))
        f.tube([base, mid, tip], [0.17, 0.11, 0.0], "fire", n=5)
    # the whip of fire trailing from the right fist (-X) and a flaming blade in the left (+X)
    f.tube([(-1.05, 1.18, 0.55), (-1.35, 0.70, 0.85), (-1.85, 0.30, 0.95), (-2.35, 0.14, 0.60), (-2.65, 0.22, 0.10), (-2.70, 0.45, -0.35)],
           [0.08, 0.075, 0.065, 0.05, 0.035, 0.0], "fire", n=6)
    hilt, tip = (1.05, 1.30, 0.58), (1.45, 2.95, 0.95)
    ax = v_norm(v_sub(tip, hilt))
    side = v_norm(v_cross(ax, (0, 0, 1)))
    thick = v_norm(v_cross(side, ax))
    rings = []
    for k, w in ((0.0, 0.05), (0.08, 0.13), (0.6, 0.11), (0.92, 0.06), (1.0, 0.0)):
        c = v_lerp(hilt, tip, k)
        rings.append([v_add(c, v_mul(side, w)), v_add(c, v_mul(thick, 0.03)), v_add(c, v_mul(side, -w)), v_add(c, v_mul(thick, -0.03))])
    f.loft(rings, "blade", smooth=False)
    return f


def crack_network(d, box, rnd, n, color, width=1, seg=(4, 10)):
    x0, y0, x1, y1 = box
    for _ in range(n):
        x, y = rnd.uniform(x0, x1), rnd.uniform(y0, y1)
        a = rnd.uniform(0, 2 * math.pi)
        pts = [(x, y)]
        for _ in range(rnd.randint(3, 6)):
            a += rnd.uniform(-0.9, 0.9)
            L = rnd.uniform(*seg)
            x, y = x + math.cos(a) * L, y + math.sin(a) * L
            pts.append((min(x1 - 1, max(x0, x)), min(y1 - 1, max(y0, y))))
        d.line(pts, fill=color, width=width)


def glow_cracks(img, box, seed, n, hot=(255, 150, 30), core=(255, 230, 120), blur=2.0):
    """Molten cracks: a blurred orange network (the glow) under thin bright lines (the core)."""
    x0, y0, x1, y1 = box
    layer = Image.new("RGB", (x1 - x0, y1 - y0), (0, 0, 0))
    ld = ImageDraw.Draw(layer)
    rnd = random.Random(seed)
    local = (0, 0, x1 - x0, y1 - y0)
    crack_network(ld, local, rnd, n, hot, width=3)
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    rnd = random.Random(seed)
    crack_network(ImageDraw.Draw(layer), local, rnd, n, core, width=1)
    base = img.crop(box)
    img.paste(ImageChops.lighter(base, layer), (x0, y0))


def paint_demon(path):
    A = DEMON_ATLAS
    img = Image.new("RGB", (A.size, A.size), (40, 16, 10))
    d = ImageDraw.Draw(img)
    rnd = random.Random(21)
    # body and limbs: charred basalt skin split by molten cracks, hotter towards the chest
    for name, seed in (("body", 22), ("limb", 23), ("ember", 24)):
        box = A.box(name)
        vgrad(img, box, (44, 28, 24), (58, 26, 18), noise=14, seed=seed)
        glow_cracks(img, box, seed, 26 if name != "ember" else 60)
    x0, y0, x1, y1 = A.box("body")
    glow = Image.new("RGB", (x1 - x0, y1 - y0), (0, 0, 0))
    ImageDraw.Draw(glow).ellipse([(x1 - x0) * 0.38, (y1 - y0) * 0.25, (x1 - x0) * 0.62, (y1 - y0) * 0.75], fill=(150, 50, 0))
    img.paste(ImageChops.add(img.crop((x0, y0, x1, y1)), glow.filter(ImageFilter.GaussianBlur(6))), (x0, y0))
    # the face: dark skull, a heavy brow, burning eyes and a glowing maw (u = 0.5 is the front)
    box = A.box("face")
    vgrad(img, box, (40, 24, 20), (54, 26, 18), noise=12, seed=25)
    glow_cracks(img, box, 25, 10, blur=1.5)
    d = ImageDraw.Draw(img)
    x0, y0, x1, y1 = box
    W, H = x1 - x0, y1 - y0
    P = lambda u, v: (x0 + u * W, y0 + v * H)
    d.polygon([P(0.33, 0.33), P(0.67, 0.33), P(0.62, 0.40), P(0.38, 0.40)], fill=(20, 12, 10))       # brow
    for eu in (0.43, 0.57):
        ex, ey = P(eu, 0.45)
        d.ellipse([ex - 4, ey - 3, ex + 4, ey + 3], fill=(255, 190, 40))
        d.ellipse([ex - 2, ey - 1.5, ex + 2, ey + 1.5], fill=(255, 255, 200))
    d.polygon([P(0.38, 0.66), P(0.62, 0.66), P(0.58, 0.78), P(0.42, 0.78)], fill=(255, 120, 20))    # maw
    d.polygon([P(0.42, 0.69), P(0.58, 0.69), P(0.55, 0.75), P(0.45, 0.75)], fill=(255, 235, 140))
    for i in range(5):
        tx = 0.40 + i * 0.05
        d.polygon([P(tx, 0.66), P(tx + 0.03, 0.66), P(tx + 0.015, 0.71)], fill=(230, 220, 200))
    # horns: bone at the base darkening to black tips, ridged
    box = A.box("horn")
    vgrad(img, box, (96, 78, 64), (18, 14, 14), noise=8, seed=26)
    x0, y0, x1, y1 = box
    for i in range(7):
        y = y0 + (i + 0.5) * (y1 - y0) / 7
        d.line([(x0, y), (x1, y)], fill=(30, 22, 20), width=1)
    # fire (mane, whip): white-yellow at the root, orange, red tongues at the tips
    for name in ("fire", "blade"):
        box = A.box(name)
        x0, y0, x1, y1 = box
        ym = (y0 + y1) // 2
        vgrad(img, (x0, y0, x1, ym), (255, 236, 120), (255, 132, 20), noise=14, seed=27)
        vgrad(img, (x0, ym, x1, y1), (255, 132, 20), (150, 18, 4), noise=14, seed=28)
        for i in range(8):                                   # bright tongues licking up from the root
            cx = x0 + (i + 0.5) * (x1 - x0) / 8
            d.polygon([(cx - 3, y0), (cx + 3, y0), (cx + rnd.uniform(-2, 2), y0 + (y1 - y0) * rnd.uniform(0.35, 0.7))], fill=(255, 214, 80))
    paint_noise(img, A.box("claw"), (30, 22, 20), 10, 28)
    box = A.box("bone")
    vgrad(img, box, (62, 34, 26), (30, 16, 12), noise=8, seed=29)
    # the wing membrane: leathery, dark at the root, burning towards the jagged edge, veins and ember cracks
    box = A.box("wing")
    x0, y0, x1, y1 = box
    to_px = lambda s, t: A.uv("wing", *wing_uv(s, t))
    to_px2 = lambda s, t: (to_px(s, t)[0] * A.size, to_px(s, t)[1] * A.size)
    rootx, rooty = to_px2(0, 0)
    px = img.load()
    rnd2 = random.Random(30)
    for y in range(y0, y1):
        for x in range(x0, x1):
            r = math.hypot(x - rootx, y - rooty) / (x1 - x0)
            k = rnd2.uniform(-10, 10)
            g = min(1.0, r / 0.95)
            px[x, y] = (int(max(0, min(255, 42 + 110 * g * g + k))), int(max(0, 12 + 30 * g * g + k * 0.4)), int(max(0, 10 + 6 * g)))
    d = ImageDraw.Draw(img)
    for bone in WING_BONES:                                  # veins fanning out between the bones
        (s0, t0), (s1, t1) = bone[0], bone[-1]
        for k in range(1, 4):
            a = rnd.uniform(0.2, 0.8)
            sa, ta = s0 + (s1 - s0) * a, t0 + (t1 - t0) * a
            d.line([to_px2(sa, ta), to_px2(sa + rnd.uniform(-0.5, 0.5), ta + rnd.uniform(-0.6, 0.2))], fill=(28, 10, 8), width=1)
    glow_cracks(img, box, 31, 18, blur=1.6)
    d = ImageDraw.Draw(img)
    edge = [to_px2(s, t) for s, t in WING]
    d.line(edge + [edge[0]], fill=(255, 110, 20), width=2)
    for bone in WING_BONES:
        d.line([to_px2(s, t) for s, t in bone], fill=(22, 12, 10), width=4)
    img.save(path)


def make_demon(out):
    m = build_demon().to_mesh("YSNPDemon", "ysnp_demon.png")
    paint_demon(os.path.join(out, "ysnp_demon.png"))
    return m.write(os.path.join(out, "ysnp_demon.x"))

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "art"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    stone_texture(os.path.join(a.out, "ysnp_stone.png"))
    rock_texture(os.path.join(a.out, "ysnp_rock.png"))
    lava_texture(os.path.join(a.out, "ysnp_lava.png"))
    for name, fn in (("pier", lambda: make_pier(a.out)), ("pier_broken", lambda: make_pier(a.out, True)),
                     ("rock", lambda: make_rock(a.out)), ("stalagmite", lambda: make_stalagmite(a.out)),
                     ("lava", lambda: make_lava(a.out)), ("demon", lambda: make_demon(a.out)),
                     ("wizard", lambda: make_wizard(a.out, False)), ("wizard_up", lambda: make_wizard(a.out, True))):
        nv, nf = fn()
        print("%-12s %4d vertices %4d faces" % (name, nv, nf))
    print("textures: ysnp_stone.png ysnp_rock.png ysnp_lava.png ysnp_demon.png ysnp_wizard.png ysnp_wizard_up.png in", a.out)
