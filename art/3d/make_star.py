#!/usr/bin/env python3
"""Generate the Claude star as a Project Zomboid .x text mesh plus a flat PNG texture (pure stdlib).

    art/3d/make_star.py [--rays 12] [--radius 0.45] [--inner 0.4] [--depth 0.06] [--out art/3d/zmcp_star]

The verified spike mesh from the game session is art/3d/zmcp_star.x (same geometry); this script is its source
and default-writes the orange variant next to it. The mesh is an extruded star centred on the origin in the model XY plane (Y up in PZ model space), so it
stands upright like a coin and rolls around its Z axis. The texture is a single flat colour (Claude orange
by default); `--color rrggbb`. Output: <out>.x and <out>.png. Upload with model_upload / model_register
(base64 of both files into the Lua dir, see docs/recipes/entity3d.md).
"""
import argparse, math, struct, zlib


def png_solid(path, w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def star(rays, radius, inner, depth, tex_name):
    outline = []                      # 2D star outline, alternating outer/inner points, CCW
    for i in range(rays * 2):
        a = math.pi / 2 + i * math.pi / rays
        r = radius if i % 2 == 0 else radius * inner
        outline.append((r * math.cos(a), r * math.sin(a)))
    verts, norms, uvs, faces = [], [], [], []
    hz = depth / 2

    def add(v, n, uv):
        verts.append(v); norms.append(n); uvs.append(uv)
        return len(verts) - 1

    def uv_of(x, y):
        return (0.5 + x / (2 * radius) * 0.9, 0.5 - y / (2 * radius) * 0.9)

    # front (+Z) and back (-Z) caps as triangle fans around the centre
    for sign in (1, -1):
        c = add((0, 0, sign * hz), (0, 0, sign), (0.5, 0.5))
        ring = [add((x, y, sign * hz), (0, 0, sign), uv_of(x, y)) for x, y in outline]
        n = len(ring)
        for i in range(n):
            a, b = ring[i], ring[(i + 1) % n]
            faces.append((c, a, b) if sign == 1 else (c, b, a))
    # sides: one quad per outline edge with its own flat normal
    n = len(outline)
    for i in range(n):
        (x1, y1), (x2, y2) = outline[i], outline[(i + 1) % n]
        ex, ey = x2 - x1, y2 - y1
        L = math.hypot(ex, ey) or 1
        nx, ny = ey / L, -ex / L
        q = [add((x1, y1, hz), (nx, ny, 0), (0.2, 0.2)), add((x2, y2, hz), (nx, ny, 0), (0.8, 0.2)),
             add((x2, y2, -hz), (nx, ny, 0), (0.8, 0.8)), add((x1, y1, -hz), (nx, ny, 0), (0.2, 0.8))]
        faces.append((q[0], q[1], q[2])); faces.append((q[0], q[2], q[3]))

    f = lambda v: "%.6f" % v
    out = ["xof 0303txt 0032", "", "Material mat0 {", " 1.000000;1.000000;1.000000;1.000000;;", " 10.000000;",
           " 0.000000;0.000000;0.000000;;", " 0.000000;0.000000;0.000000;;", "", " TextureFilename {",
           '  "%s";' % tex_name, " }", "}", "", "Frame ZMCPStar {", "", " FrameTransformMatrix {",
           "  1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000,0.000000,0.000000,0.000000,0.000000,1.000000;;",
           " }", "", " Mesh ZMCPStar {", "  %d;" % len(verts)]
    out += ["  %s;%s;%s;%s" % (f(x), f(y), f(z), "," if i < len(verts) - 1 else ";") for i, (x, y, z) in enumerate(verts)]
    out += ["  %d;" % len(faces)]
    out += ["  3;%d,%d,%d;%s" % (a, b, c, "," if i < len(faces) - 1 else ";") for i, (a, b, c) in enumerate(faces)]
    out += ["", "  MeshNormals {", "   %d;" % len(norms)]
    out += ["   %s;%s;%s;%s" % (f(x), f(y), f(z), "," if i < len(norms) - 1 else ";") for i, (x, y, z) in enumerate(norms)]
    out += ["   %d;" % len(faces)]
    out += ["   3;%d,%d,%d;%s" % (a, b, c, "," if i < len(faces) - 1 else ";") for i, (a, b, c) in enumerate(faces)]
    out += ["  }", "", "  MeshMaterialList {", "   1;", "   %d;" % len(faces)]
    out += ["   0%s" % ("," if i < len(faces) - 1 else ";") for i in range(len(faces))]
    out += ["   { mat0 }", "  }", "", "  MeshTextureCoords c1 {", "   %d;" % len(uvs)]
    out += ["   %s;%s;%s" % (f(u), f(v), "," if i < len(uvs) - 1 else ";") for i, (u, v) in enumerate(uvs)]
    out += ["  }", " }", "}", ""]
    return "\n".join(out), len(verts), len(faces)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--rays", type=int, default=12)
    ap.add_argument("--radius", type=float, default=0.45)
    ap.add_argument("--inner", type=float, default=0.55, help="inner radius as a fraction of the outer one")
    ap.add_argument("--depth", type=float, default=0.06)
    ap.add_argument("--color", default="d97757", help="hex rgb (Claude orange)")
    ap.add_argument("--out", default="art/3d/zmcp_star_orange")
    a = ap.parse_args()
    rgb = tuple(int(a.color[i:i + 2], 16) for i in (0, 2, 4))
    png_solid(a.out + ".png", 64, 64, rgb)
    tex_name = a.out.split("/")[-1] + ".png"
    text, nv, nf = star(a.rays, a.radius, a.inner, a.depth, tex_name)
    open(a.out + ".x", "w").write(text)
    print("%s.x: %d vertices, %d faces; %s.png: 64x64 #%s" % (a.out, nv, nf, a.out, a.color))
