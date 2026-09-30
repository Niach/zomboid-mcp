#!/usr/bin/env python3
"""Generate the art of the "You shall not pass" scene: Project Zomboid .x text meshes plus painted PNG textures.

    python3 make_art.py [--out art]

Everything is original, generated here (no ripped assets): a stone bridge pier (and its broken variant), a rock
pillar and a stalagmite for the cavern, a flat lava slab, the fire demon and the grey wizard (staff down / staff
raised) as extruded silhouettes. Model space is Y-up with the origin at ground level (docs/ENGINE_NOTES.md,
"Runtime 3D models"); 1 model unit = 1 tile on a world item (model_place) and on the entity layer (entity3d_*).
Silhouettes lie in the model XY plane and face +Z; the scene turns them towards the camera with `ry`.
Needs Pillow (pip install pillow) for the textures; the meshes are plain text.
"""
import argparse, math, os, random

try:
    from PIL import Image, ImageDraw, ImageFilter
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


def silhouette(mesh, parts, bbox):
    """Extruded convex polygons in the XY plane facing +Z: parts = [(points CCW, depth)]. UVs map the shared bbox
    (x0, y0, x1, y1) onto the texture, so paint_silhouette() draws the same polygons in the same place."""
    x0, y0, x1, y1 = bbox
    def uv(x, y): return ((x - x0) / (x1 - x0), 1 - (y - y0) / (y1 - y0))
    for pts, depth in parts:
        hz = depth / 2
        mesh.poly([(x, y, hz) for x, y in pts], (0, 0, 1), [uv(x, y) for x, y in pts])
        mesh.poly([(x, y, -hz) for x, y in reversed(pts)], (0, 0, -1), [uv(x, y) for x, y in reversed(pts)])
        n = len(pts)
        for i in range(n):
            (ax, ay), (bx, by) = pts[i], pts[(i + 1) % n]
            ex, ey = bx - ax, by - ay
            L = math.hypot(ex, ey) or 1
            normal = (ey / L, -ex / L, 0)
            mesh.poly([(ax, ay, hz), (bx, by, hz), (bx, by, -hz), (ax, ay, -hz)], normal,
                      [uv(ax, ay), uv(bx, by), uv(bx, by), uv(ax, ay)])


def mirror(pts):
    return [(-x, y) for x, y in reversed(pts)]


def ngon(cx, cy, r, n=8, rot=0.0):
    return [(cx + r * math.cos(rot + 2 * math.pi * i / n), cy + r * math.sin(rot + 2 * math.pi * i / n)) for i in range(n)]


def strip(points, width):
    """Thin quads along a polyline (a staff, a whip)."""
    parts = []
    for (ax, ay), (bx, by) in zip(points, points[1:]):
        ex, ey = bx - ax, by - ay
        L = math.hypot(ex, ey) or 1
        nx, ny = -ey / L * width / 2, ex / L * width / 2
        parts.append([(ax - nx, ay - ny), (bx - nx, by - ny), (bx + nx, by + ny), (ax + nx, ay + ny)])
    return parts


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


def stone_texture(path, size=128):
    img = noise_img(size, (118, 116, 112), 22, blur=1.2, seed=3)
    d = ImageDraw.Draw(img)
    rows, mortar = 4, (52, 48, 46)
    h = size / rows
    for r in range(rows):
        y = int(r * h)
        d.line([(0, y), (size, y)], fill=mortar, width=3)
        offset = int(h * 0.8) if r % 2 else 0
        for c in range(-1, 3):
            x = int(c * h * 1.6 + offset)
            d.line([(x, y), (x, int(y + h))], fill=mortar, width=3)
    img = img.filter(ImageFilter.GaussianBlur(0.6))
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


def paint_silhouette(path, parts, bbox, painter, size=256):
    """A texture that matches silhouette(): the parts filled through `painter(draw, to_px, size)`."""
    x0, y0, x1, y1 = bbox
    def to_px(pt):
        x, y = pt
        return ((x - x0) / (x1 - x0) * (size - 1), (1 - (y - y0) / (y1 - y0)) * (size - 1))
    img = Image.new("RGB", (size, size), (0, 0, 0))
    d = ImageDraw.Draw(img)
    painter(d, to_px, size, img)
    img.save(path)


# ---------------------------------------------------------------- the pieces
def make_pier(out, broken=False):
    m = Mesh("YSNPPierBroken" if broken else "YSNPPier", "ysnp_stone.png")
    if not broken:
        box(m, -0.5, 0.0, -0.5, 0.5, 3.0, 0.5, tile=1.0)               # a full pier, floor level to the deck
    else:
        box(m, -0.5, 0.0, -0.5, 0.5, 1.3, 0.5, tile=1.0)               # the stump
        box(m, -0.45, 1.3, -0.2, 0.15, 1.75, 0.35, tile=1.0)            # a broken block on top
        box(m, 0.05, 1.3, -0.45, 0.5, 1.55, 0.05, tile=1.0)
    return m.write(os.path.join(out, "ysnp_pier_broken.x" if broken else "ysnp_pier.x"))


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


DEMON_BBOX = (-2.6, -0.1, 2.6, 3.8)

def demon_parts():
    body = [(-0.6, 0.0), (0.6, 0.0), (0.8, 1.6), (0.5, 2.6), (-0.5, 2.6), (-0.8, 1.6)]
    head = ngon(0, 2.85, 0.36, 7, rot=math.pi / 2)
    horn_r = [(0.12, 3.05), (0.3, 3.0), (0.6, 3.65)]
    wing_r = [(0.7, 1.3), (2.35, 1.0), (2.25, 3.25), (0.6, 2.4)]
    spike_r1 = [(2.2, 3.0), (2.55, 3.55), (2.0, 3.25)]
    spike_r2 = [(2.3, 1.05), (2.6, 0.55), (2.1, 1.2)]
    parts = [(body, 0.18), (head, 0.16), (horn_r, 0.14), (mirror(horn_r), 0.14), (wing_r, 0.10), (mirror(wing_r), 0.10),
             (spike_r1, 0.09), (mirror(spike_r1), 0.09), (spike_r2, 0.09), (mirror(spike_r2), 0.09)]
    for q in strip([(-0.75, 1.5), (-1.6, 0.9), (-2.2, 1.3), (-2.55, 0.6)], 0.08):      # the whip, left hand
        parts.append((q, 0.07))
    return parts


def paint_demon(d, to_px, size, img):
    rnd = random.Random(21)
    # fire body: painted per part with a vertical gradient (embers at the bottom, dark at the top) plus glow dots
    for pts, depth in demon_parts():
        d.polygon([to_px(p) for p in pts], fill=(120, 30, 10))
    # gradient inside the silhouette
    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    for pts, depth in demon_parts():
        md.polygon([to_px(p) for p in pts], fill=255)
    px, mp = img.load(), mask.load()
    for y in range(size):
        t = y / size
        for x in range(size):
            if mp[x, y]:
                k = rnd.uniform(-0.15, 0.15)
                g = max(0.0, min(1.0, 0.15 + t * 0.9 + k))               # 0 = top (dark), 1 = feet (bright)
                px[x, y] = (int(40 + 215 * g), int(10 + 120 * g * g), int(5 + 20 * g))
    glow = img.filter(ImageFilter.GaussianBlur(2.5))
    img.paste(glow, mask=mask)
    d = ImageDraw.Draw(img)
    for _ in range(140):                                               # embers
        x, y = rnd.randrange(size), rnd.randrange(size)
        if mp[x, y]:
            d.ellipse([x - 1, y - 1, x + 1, y + 1], fill=(255, 220, 90))
    for sx in (-0.13, 0.13):                                           # eyes
        ex, ey = to_px((sx, 2.9))
        d.ellipse([ex - 5, ey - 4, ex + 5, ey + 4], fill=(255, 250, 120))
        d.ellipse([ex - 2, ey - 2, ex + 2, ey + 2], fill=(20, 0, 0))
    mx, my = to_px((0, 2.68))                                          # mouth
    d.polygon([(mx - 12, my - 2), (mx + 12, my - 2), (mx + 8, my + 6), (mx - 8, my + 6)], fill=(255, 240, 150))


def make_demon(out):
    parts = demon_parts()
    m = Mesh("YSNPDemon", "ysnp_demon.png")
    silhouette(m, parts, DEMON_BBOX)
    paint_silhouette(os.path.join(out, "ysnp_demon.png"), parts, DEMON_BBOX, paint_demon)
    return m.write(os.path.join(out, "ysnp_demon.x"))


WIZARD_BBOX = (-0.7, -0.05, 0.7, 2.75)

def wizard_parts(raised):
    robe = [(-0.42, 0.0), (0.42, 0.0), (0.24, 1.15), (-0.24, 1.15)]
    torso = [(-0.3, 1.05), (0.3, 1.05), (0.28, 1.36), (-0.28, 1.36)]
    head = ngon(0, 1.47, 0.16, 8)
    beard = [(-0.15, 1.42), (0.15, 1.42), (0.0, 1.0)]
    brim = [(-0.42, 1.55), (0.42, 1.55), (0.42, 1.61), (-0.42, 1.61)]
    cone = [(-0.22, 1.6), (0.22, 1.6), (0.07, 2.08), (-0.03, 2.08)]
    parts = [(robe, 0.2), (torso, 0.18), (head, 0.16), (beard, 0.14), (brim, 0.12), (cone, 0.14)]
    if raised:
        arm = [(0.25, 1.2), (0.42, 1.02), (0.5, 1.1), (0.32, 1.32)]
        parts.append((arm, 0.14))
        for q in strip([(0.44, 0.95), (0.44, 2.55)], 0.07): parts.append((q, 0.08))
        parts.append((ngon(0.44, 2.6, 0.11, 8), 0.1))                    # the glowing tip
    else:
        arm = [(0.25, 1.2), (0.4, 0.75), (0.48, 0.8), (0.32, 1.3)]
        parts.append((arm, 0.14))
        for q in strip([(0.44, 0.0), (0.44, 1.9)], 0.07): parts.append((q, 0.08))
        parts.append((ngon(0.44, 1.95, 0.07, 8), 0.1))
    return parts


def paint_wizard(raised):
    def painter(d, to_px, size, img):
        parts = wizard_parts(raised)
        rnd = random.Random(31)
        robe, torso, head, beard, brim, cone, arm = [p for p, _ in parts[:7]]
        grey = (128, 130, 138)
        for poly, col in ((robe, grey), (torso, (112, 114, 122)), (arm, (118, 120, 128)), (brim, (90, 92, 100)), (cone, (104, 106, 114))):
            d.polygon([to_px(p) for p in poly], fill=col)
        # folds on the robe
        for i in range(6):
            x = -0.3 + i * 0.12
            d.line([to_px((x, 0.05)), to_px((x * 0.55, 1.1))], fill=(92, 94, 102), width=2)
        d.polygon([to_px(p) for p in head], fill=(214, 178, 150))
        d.polygon([to_px(p) for p in beard], fill=(225, 225, 230))
        for sx in (-0.06, 0.06):
            ex, ey = to_px((sx, 1.5))
            d.ellipse([ex - 2, ey - 2, ex + 2, ey + 2], fill=(30, 30, 40))
        # staff and tip
        for q in [p for p, _ in parts[7:-1]]:
            d.polygon([to_px(p) for p in q], fill=(96, 68, 40))
        tip = parts[-1][0]
        d.polygon([to_px(p) for p in tip], fill=(255, 255, 255) if raised else (200, 200, 220))
        if raised:
            cx, cy = to_px((0.44, 2.6))
            for r, col in ((16, (255, 255, 255)), (11, (240, 250, 255)), (6, (255, 255, 255))):
                d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)
    return painter


def make_wizard(out, raised):
    parts = wizard_parts(raised)
    name = "ysnp_wizard_up" if raised else "ysnp_wizard"
    m = Mesh("YSNPWizardUp" if raised else "YSNPWizard", name + ".png")
    silhouette(m, parts, WIZARD_BBOX)
    paint_silhouette(os.path.join(out, name + ".png"), parts, WIZARD_BBOX, paint_wizard(raised))
    return m.write(os.path.join(out, name + ".x"))


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
