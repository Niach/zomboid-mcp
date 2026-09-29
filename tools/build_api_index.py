#!/usr/bin/env python3
"""Build the Zomboid MCP engine API index and the vanilla Lua example index.

Reads a local Project Zomboid install (projectzomboid.jar + media/lua) and writes
two gzipped JSON files into the mod's ``mcp/`` folder:

  api_index.json.gz     every class the Lua VM can reach (Kahlua exposer list),
                        with public fields, constructors, methods (parameter
                        types + names, return type, static), inheritance, and
                        the global functions from LuaManager$GlobalObject.
  lua_examples.json.gz  function definitions and call-site snippets from the
                        vanilla media/lua tree, keyed by engine symbol.

The schema is documented in docs/API_INDEX.md. The ``--search`` / ``--examples``
modes are the reference lookups for the MCP tools ``api_search`` and
``lua_examples``; ``--verify`` checks the acceptance symbols of ZOM-3.

Only the Python standard library and ``javap`` (JDK) are required.

Usage:
  tools/build_api_index.py [--pz-dir DIR] [--out-dir DIR] [--max-examples N]
  tools/build_api_index.py --search addLamppost [--kind method] [--limit 10]
  tools/build_api_index.py --examples setHairModel
  tools/build_api_index.py --verify
"""

from __future__ import annotations

import argparse
import collections
import gzip
import heapq
import json
import os
import re
import subprocess
import sys
import time

SCHEMA_VERSION = 1
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PZ_DIR = os.path.expanduser(
    "~/.steam/steam/steamapps/common/ProjectZomboid/projectzomboid")
DEFAULT_OUT_DIR = os.path.join(REPO_ROOT, "mod", "Contents", "mods", "ZomboidMCP", "mcp")
CURATED_FILE = os.path.join(REPO_ROOT, "tools", "curated_examples.json")
API_INDEX_NAME = "api_index.json.gz"
LUA_EXAMPLES_NAME = "lua_examples.json.gz"

EXPOSER_CLASS = "zombie.Lua.LuaManager$Exposer"
GLOBAL_OBJECT_CLASS = "zombie.Lua.LuaManager$GlobalObject"
CORE_CLASS = "zombie.core.Core"
GIT_VERSION_CLASS = "zombie.GitVersion"
# Superclasses we never index (no Lua-relevant members).
STOP_SUPERS = {"java.lang.Object", "java.lang.Enum", "java.lang.Record"}
JAVAP_CHUNK = 250

# Symbols the issue requires to resolve (ZOM-3 "done when").
VERIFY_SYMBOLS = ["addLamppost", "transmitAddObjectToSquare", "addZombiesInOutfit",
                  "getTexture", "setHairModel"]

LUA_KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function",
                "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true",
                "until", "while"}


# --------------------------------------------------------------------------- utils

def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run_javap(jar: str, flags: list[str], classes: list[str]) -> str:
    """Run javap over a list of classes, chunked to keep the command line short."""
    out = []
    for i in range(0, len(classes), JAVAP_CHUNK):
        chunk = classes[i:i + JAVAP_CHUNK]
        proc = subprocess.run(["javap", "-cp", jar, *flags, *chunk],
                              capture_output=True, text=True, errors="replace")
        if proc.returncode != 0 and not proc.stdout:
            raise SystemExit(f"javap failed: {proc.stderr.strip()[:500]}")
        if proc.stderr.strip():
            for line in proc.stderr.strip().splitlines()[:5]:
                log(f"  javap: {line}")
        out.append(proc.stdout)
    return "\n".join(out)


def split_top(s: str, sep: str = ",") -> list[str]:
    """Split on ``sep`` at generic-nesting depth 0."""
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    tail = "".join(cur).strip()
    if tail:
        parts.append(tail)
    return parts


def strip_generics(t: str) -> str:
    out, depth = [], 0
    for ch in t:
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
        elif depth == 0:
            out.append(ch)
    return "".join(out).strip()


_PKG_RE = re.compile(r"\b(?:[A-Za-z_]\w*\.)+([A-Za-z_][\w$]*)")
_INNER_RE = re.compile(r"\b[A-Za-z_]\w*\$(?=[A-Za-z_])")


def short_type(t: str) -> str:
    """``zombie.characters.skills.PerkFactory$Perk`` -> ``Perk`` (the Lua-visible name)."""
    t = _PKG_RE.sub(lambda m: m.group(1), t.strip())
    while _INNER_RE.search(t):
        t = _INNER_RE.sub("", t)
    return t


def simple_name(fqn: str) -> str:
    return fqn.rsplit(".", 1)[-1].rsplit("$", 1)[-1]


# --------------------------------------------------------------------------- jar: version

def read_version(jar: str, pz_dir: str) -> dict:
    info = {"game_version": None, "git_revision": None, "source": None}
    vt = os.path.join(pz_dir, "version.txt")
    if os.path.isfile(vt):
        with open(vt, encoding="utf-8", errors="replace") as fh:
            txt = fh.read().strip()
        if txt:
            info["game_version"] = txt.splitlines()[0].strip()
            info["source"] = "version.txt"
    text = run_javap(jar, ["-c", "-p"], [CORE_CLASS])
    # Core's static initialiser does `gameVersion = new GameVersion(42, 21, "")`.
    clinit = text.split("\n  static {};", 1)
    body = clinit[1] if len(clinit) == 2 else text
    ints, string = [], ""
    for line in body.splitlines():
        line = line.strip()
        m = re.match(r"\d+: (bipush|sipush)\s+(-?\d+)", line)
        if m:
            ints.append(int(m.group(2)))
            continue
        m = re.match(r"\d+: iconst_(m1|\d)", line)
        if m:
            ints.append(-1 if m.group(1) == "m1" else int(m.group(1)))
            continue
        m = re.match(r"\d+: ldc(?:_w)?\s+#\d+\s+// String ?(.*)$", line)
        if m:
            string = m.group(1)
            continue
        if 'GameVersion."<init>":(IILjava/lang/String;)V' in line and len(ints) >= 2:
            ver = f"{ints[-2]}.{ints[-1]}{string}"
            if not info["game_version"]:
                info["game_version"] = ver
                info["source"] = "projectzomboid.jar zombie.core.Core.<clinit>"
            info["jar_version"] = ver
            break
        if line.startswith(("aload", "invoke", "putstatic", "getstatic", "return")) and \
                "GameVersion" not in line:
            ints, string = [], ""
    text = run_javap(jar, ["-constants", "-p"], [GIT_VERSION_CLASS])
    m = re.search(r'REVISION = "([^"]+)"', text)
    if m:
        info["git_revision"] = m.group(1)
    return info


# --------------------------------------------------------------------------- jar: exposed classes

def read_exposed_classes(jar: str) -> list[str]:
    """Class literals passed to setExposed() inside LuaManager$Exposer.exposeAll()."""
    text = run_javap(jar, ["-c", "-p"], [EXPOSER_CLASS])
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if re.match(r"\s*public void exposeAll\(\);", l)), None)
    if start is None:
        raise SystemExit("exposeAll() not found in LuaManager$Exposer")
    classes, pending, seen = [], None, set()
    for line in lines[start + 1:]:
        if re.match(r"  (public|private|protected|static|final) ", line):
            break
        m = re.search(r"ldc(?:_w)?\s+#\d+\s+// class (\S+)", line)
        if m:
            pending = m.group(1).replace("/", ".")
            continue
        if "setExposed" in line and pending:
            if pending not in seen:
                seen.add(pending)
                classes.append(pending)
            pending = None
    return classes


# --------------------------------------------------------------------------- jar: javap parsing

HEADER_RE = re.compile(
    r"^((?:public |protected |private |static |final |abstract |sealed |non-sealed |strictfp )*)"
    r"(class|interface|@interface|enum)\s+([\w.$]+)(<.*?>)?"
    r"(?:\s+extends\s+(.+?))?(?:\s+implements\s+(.+?))?(?:\s+permits\s+(.+?))?\s*\{$")
MODIFIER_RE = re.compile(
    r"(public|protected|private|static|final|abstract|synchronized|native|transient|volatile|"
    r"default|strictfp)\s+")
LVT_RE = re.compile(r"^\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)$")


def parse_member(s: str, cls_fqn: str):
    """Parse one javap member line -> ('ctor'|'method'|'field', dict) or None."""
    s = s.strip().rstrip(";").strip()
    if not s or s == "static {}":
        return None
    s = re.sub(r"\s+throws\s+.*$", "", s)
    mods = set()
    while True:
        m = MODIFIER_RE.match(s)
        if not m:
            break
        mods.add(m.group(1))
        s = s[m.end():]
    if s.startswith("<"):  # generic method type parameters
        depth = 0
        for i, ch in enumerate(s):
            if ch == "<":
                depth += 1
            elif ch == ">":
                depth -= 1
                if depth == 0:
                    s = s[i + 1:].strip()
                    break
    if "(" in s:
        i = s.index("(")
        head = s[:i].strip()
        params = s[i + 1:s.rindex(")")]
        plist = [short_type(p) for p in split_top(params)]
        if " " in head:
            ret, name = head.rsplit(" ", 1)
            entry = {"n": name, "p": plist, "r": short_type(ret)}
            if "static" in mods:
                entry["s"] = True
            return "method", entry
        return "ctor", {"p": plist}
    if " " not in s:
        return None
    typ, name = s.rsplit(" ", 1)
    entry = {"n": name, "t": short_type(typ)}
    if "static" in mods:
        entry["s"] = True
    if "final" in mods:
        entry["f"] = True
    return "field", entry


def attach_param_names(entry: dict, lvt: list[tuple[int, str]]) -> None:
    """Use LocalVariableTable slots that start at pc 0 as the parameter names."""
    names = [n for _, n in sorted(lvt) if n != "this"]
    n = len(entry["p"])
    if n and len(names) >= n:
        entry["pn"] = names[:n]


def parse_javap_classes(text: str) -> dict[str, dict]:
    """Parse ``javap -l -public`` output for many classes."""
    classes: dict[str, dict] = {}
    cur = None
    member = None      # (kind, entry) awaiting LocalVariableTable
    lvt: list[tuple[int, str]] = []
    in_lvt = False

    def flush_member():
        nonlocal member, lvt, in_lvt
        if member is not None:
            kind, entry = member
            if kind in ("method", "ctor") and lvt:
                attach_param_names(entry, lvt)
            cur[{"method": "methods", "ctor": "ctors", "field": "fields"}[kind]].append(entry)
        member, lvt, in_lvt = None, [], False

    for raw in text.splitlines():
        if not raw.strip():
            continue
        if raw.startswith("Compiled from") or raw.startswith("Classfile"):
            continue
        if not raw.startswith(" "):
            if raw.startswith("}"):
                if cur is not None:
                    flush_member()
                cur = None
                continue
            m = HEADER_RE.match(raw.strip())
            if not m:
                log(f"  unparsed header: {raw[:120]}")
                cur = None
                continue
            mods, kw, fqn, _gen, ext, impl, _permits = m.groups()
            ext_fqn = strip_generics(ext) if ext else None
            kind = kw
            if kw == "class":
                if ext_fqn == "java.lang.Enum":
                    kind = "enum"
                elif "abstract" in mods:
                    kind = "abstract class"
            cur = {
                "name": simple_name(fqn), "fqn": fqn, "kind": kind, "exposed": False,
                "extends": ext_fqn if ext_fqn and ext_fqn not in STOP_SUPERS else None,
                "implements": [short_type(strip_generics(x)) for x in split_top(impl)] if impl else [],
                "ctors": [], "fields": [], "methods": [],
            }
            classes[fqn] = cur
            continue
        if cur is None:
            continue
        if raw.startswith("  ") and not raw.startswith("   "):
            flush_member()
            parsed = parse_member(raw, cur["fqn"])
            if parsed:
                member = parsed
            continue
        # deeper indentation: LineNumberTable / LocalVariableTable
        st = raw.strip()
        if st.startswith("LocalVariableTable"):
            in_lvt = True
            continue
        if st.startswith("LineNumberTable") or st.startswith("Start  Length"):
            if st.startswith("LineNumberTable"):
                in_lvt = False
            continue
        if in_lvt:
            m = LVT_RE.match(raw)
            if m and int(m.group(1)) == 0:
                lvt.append((int(m.group(3)), m.group(4)))
    if cur is not None:
        flush_member()
    return classes


def read_classes(jar: str, exposed: list[str]) -> dict[str, dict]:
    """javap every exposed class plus the superclass closure."""
    classes: dict[str, dict] = {}
    todo = list(exposed)
    exposed_set = set(exposed)
    while todo:
        text = run_javap(jar, ["-l", "-public"], todo)
        parsed = parse_javap_classes(text)
        missing = [c for c in todo if c not in parsed]
        for c in missing:
            log(f"  warning: javap returned nothing for {c}")
        classes.update(parsed)
        todo = []
        for fqn, cls in parsed.items():
            cls["exposed"] = fqn in exposed_set
            sup = cls["extends"]
            if sup and sup not in classes and sup not in todo:
                todo.append(sup)
    return classes


# --------------------------------------------------------------------------- jar: global functions

def read_globals(jar: str) -> list[dict]:
    """Public methods of LuaManager$GlobalObject annotated @LuaMethod(global=true)."""
    text = run_javap(jar, ["-v", "-p", "-l"], [GLOBAL_OBJECT_CLASS])
    globals_: list[dict] = []
    cur = None          # dict for the current method
    lua_name, is_global = None, False
    lvt: list[tuple[int, str]] = []
    in_lvt = False

    def flush():
        nonlocal cur, lua_name, is_global, lvt, in_lvt
        if cur is not None and is_global:
            name = lua_name or cur["n"]
            entry = {"n": name, "p": cur["p"], "r": cur["r"]}
            if name != cur["n"]:
                entry["java"] = cur["n"]
            if lvt:
                attach_param_names(entry, lvt)
            globals_.append(entry)
        cur, lua_name, is_global, lvt, in_lvt = None, None, False, [], False

    for raw in text.splitlines():
        if raw.startswith("  ") and not raw.startswith("   ") and raw.rstrip().endswith(";"):
            flush()
            if raw.lstrip().startswith("public") and "(" in raw:
                parsed = parse_member(raw, GLOBAL_OBJECT_CLASS)
                if parsed and parsed[0] == "method":
                    cur = parsed[1]
            continue
        if cur is None:
            continue
        st = raw.strip()
        if st.startswith("LocalVariableTable"):
            in_lvt = True
            continue
        if st.startswith(("LineNumberTable", "RuntimeVisibleAnnotations", "Exceptions",
                          "StackMapTable", "Signature", "MethodParameters")):
            in_lvt = False
        if in_lvt:
            m = LVT_RE.match(raw)
            if m and int(m.group(1)) == 0:
                lvt.append((int(m.group(3)), m.group(4)))
            continue
        if "annotations.LuaMethod(" in st:
            continue
        m = re.match(r'name="([^"]*)"$', st)
        if m:
            lua_name = m.group(1) or None
            continue
        if st == "global=true":
            is_global = True
    flush()
    globals_.sort(key=lambda e: e["n"])
    return globals_


# --------------------------------------------------------------------------- lua examples

DEF_RE = re.compile(r"^\s*(local\s+)?function\s+([A-Za-z_][\w.:]*)\s*\(([^)]*)\)")
ASSIGN_DEF_RE = re.compile(r"^\s*(local\s+)?([A-Za-z_][\w.]*)\s*=\s*function\s*\(([^)]*)\)")
CALL_RE = re.compile(r"([A-Za-z_]\w*)\s*\(")
EVENT_RE = re.compile(r"Events\.([A-Za-z_]\w*)\.Add\s*\(")
LEADING_RECV_RE = re.compile(r"([A-Za-z_]\w*)\s*$")


def make_snippet(lines: list[str], i: int, limit: int = 240) -> str:
    s = lines[i].strip()
    j = i
    while s.count("(") > s.count(")") and j + 1 < len(lines) and j - i < 2:
        j += 1
        s += " " + lines[j].strip()
    s = re.sub(r"\s+", " ", s)
    if len(s) > limit:
        s = s[:limit - 1] + "…"
    return s


class Bucket:
    """Keeps the N best-scoring candidates for one symbol."""
    __slots__ = ("heap", "cap", "seq")

    def __init__(self, cap: int):
        self.heap: list = []
        self.cap = cap
        self.seq = 0

    def add(self, score: float, item) -> None:
        self.seq += 1
        entry = (score, self.seq, item)   # min-heap: root = worst candidate
        if len(self.heap) < self.cap:
            heapq.heappush(self.heap, entry)
        elif score > self.heap[0][0]:
            heapq.heapreplace(self.heap, entry)

    def best(self, n: int) -> list:
        ranked = sorted(self.heap, key=lambda e: (-e[0], e[1]))   # best score, then first seen
        picked, used_files, rest = [], set(), []
        for _, _, item in ranked:
            if item[0] in used_files:
                rest.append(item)
                continue
            used_files.add(item[0])
            picked.append(item)
            if len(picked) == n:
                return picked
        return picked + rest[:n - len(picked)]


def score_line(rel: str, snippet: str, is_comment: bool) -> float:
    score = 100.0 - min(len(snippet), 240) / 4.0
    if is_comment:
        score -= 100
    if rel.startswith("client/DebugUIs/"):
        score -= 15
    if rel.startswith("shared/") or rel.startswith("server/"):
        score += 5
    return score


def build_lua_examples(lua_root: str, engine_symbols: set[str], class_names: set[str],
                       max_examples: int, max_defs: int) -> dict:
    files: list[str] = []
    defs: dict[str, list] = collections.defaultdict(list)
    calls: dict[str, Bucket] = {}
    events: set[str] = set()
    cap = max(40, max_examples * 10)
    n_lines = n_matches = 0

    lua_files = []
    for base, _dirs, names in os.walk(lua_root):
        for name in names:
            if name.endswith(".lua"):
                lua_files.append(os.path.join(base, name))
    lua_files.sort()

    for path in lua_files:
        rel = os.path.relpath(path, lua_root).replace(os.sep, "/")
        fidx = len(files)
        files.append(rel)
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
        n_lines += len(lines)
        for i, line in enumerate(lines):
            if "(" not in line:
                continue
            m = DEF_RE.match(line) or ASSIGN_DEF_RE.match(line)
            if m:
                lst = defs[m.group(2)]
                if len(lst) < max_defs:
                    lst.append([fidx, i + 1, re.sub(r"\s+", " ", m.group(3).strip())])
                continue
            stripped = line.lstrip()
            is_comment = stripped.startswith("--")
            for em in EVENT_RE.finditer(line):
                events.add(em.group(1))
                key = "Events." + em.group(1)
                snippet = make_snippet(lines, i)
                calls.setdefault(key, Bucket(cap)).add(
                    score_line(rel, snippet, is_comment), (fidx, i + 1, snippet))
                n_matches += 1
            for cm in CALL_RE.finditer(line):
                name = cm.group(1)
                if name in LUA_KEYWORDS:
                    continue
                before = line[:cm.start()].rstrip()
                sep = before[-1:] if before else ""
                recv = None
                if sep in (".", ":"):
                    rm = LEADING_RECV_RE.search(before[:-1])
                    recv = rm.group(1) if rm else None
                if name == "new" and sep == "." and recv in class_names:
                    key = recv + ".new"
                elif name in engine_symbols:
                    if recv == "Events" or (sep == ":" and recv and recv[0:1].isupper()
                                            and recv not in class_names and name == "new"):
                        continue
                    key = name
                else:
                    continue
                snippet = make_snippet(lines, i)
                calls.setdefault(key, Bucket(cap)).add(
                    score_line(rel, snippet, is_comment), (fidx, i + 1, snippet))
                n_matches += 1

    out_calls = {k: [list(item) for item in b.best(max_examples)] for k, b in sorted(calls.items())}
    return {
        "files": files,
        "events": sorted(events),
        "defs": dict(sorted(defs.items())),
        "calls": out_calls,
        "stats": {"lua_files": len(files), "lua_lines": n_lines, "call_sites_seen": n_matches,
                  "def_keys": len(defs), "call_keys": len(out_calls), "events": len(events)},
    }


# --------------------------------------------------------------------------- build

def build(args) -> int:
    pz_dir = os.path.abspath(os.path.expanduser(args.pz_dir))
    jar = os.path.join(pz_dir, "projectzomboid.jar")
    lua_root = os.path.join(pz_dir, "media", "lua")
    if not os.path.isfile(jar):
        raise SystemExit(f"projectzomboid.jar not found in {pz_dir} (use --pz-dir or PZ_DIR)")
    if not os.path.isdir(lua_root):
        raise SystemExit(f"media/lua not found in {pz_dir}")
    if subprocess.run(["javap", "-version"], capture_output=True).returncode != 0:
        raise SystemExit("javap is not on PATH (install a JDK)")
    os.makedirs(args.out_dir, exist_ok=True)
    t0 = time.time()

    log("reading version …")
    version = read_version(jar, pz_dir)
    log(f"  game {version['game_version']} rev {version['git_revision']}")

    log("reading exposed classes from LuaManager$Exposer.exposeAll() …")
    exposed = read_exposed_classes(jar)
    log(f"  {len(exposed)} exposed classes")

    log("javap over exposed classes + superclass closure …")
    classes = read_classes(jar, exposed)
    n_unexposed = sum(1 for c in classes.values() if not c["exposed"])
    log(f"  {len(classes)} classes ({n_unexposed} unexposed superclasses)")

    log("reading global functions from LuaManager$GlobalObject …")
    globals_ = read_globals(jar)
    log(f"  {len(globals_)} global functions")

    dup_names = collections.Counter(c["name"] for c in classes.values() if c["exposed"])
    collisions = sorted(n for n, k in dup_names.items() if k > 1)

    n_methods = sum(len(c["methods"]) for c in classes.values())
    n_fields = sum(len(c["fields"]) for c in classes.values())
    n_ctors = sum(len(c["ctors"]) for c in classes.values())
    generated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    api_index = {
        "schema": SCHEMA_VERSION,
        "game_version": version["game_version"],
        "git_revision": version["git_revision"],
        "version_source": version["source"],
        "generated_at": generated_at,
        "generator": "tools/build_api_index.py",
        "stats": {"classes": len(classes), "exposed_classes": len(exposed),
                  "unexposed_superclasses": n_unexposed, "methods": n_methods,
                  "fields": n_fields, "ctors": n_ctors, "globals": len(globals_)},
        "name_collisions": collisions,
        "globals": globals_,
        "classes": {fqn: classes[fqn] for fqn in sorted(classes)},
    }

    log("indexing vanilla Lua …")
    engine_symbols = {m["n"] for c in classes.values() for m in c["methods"]}
    engine_symbols |= {g["n"] for g in globals_}
    class_names = {c["name"] for c in classes.values() if c["exposed"]}
    ex = build_lua_examples(lua_root, engine_symbols, class_names, args.max_examples, args.max_defs)
    log(f"  {ex['stats']}")

    curated = {}
    if os.path.isfile(CURATED_FILE):
        with open(CURATED_FILE, encoding="utf-8") as fh:
            curated = json.load(fh)
    lua_examples = {
        "schema": SCHEMA_VERSION,
        "game_version": version["game_version"],
        "git_revision": version["git_revision"],
        "generated_at": generated_at,
        "generator": "tools/build_api_index.py",
        "lua_root": "media/lua",
        "max_examples": args.max_examples,
        "stats": ex["stats"],
        "files": ex["files"],
        "events": ex["events"],
        "defs": ex["defs"],
        "calls": ex["calls"],
        "curated": curated,
    }

    for name, data in ((API_INDEX_NAME, api_index), (LUA_EXAMPLES_NAME, lua_examples)):
        path = os.path.join(args.out_dir, name)
        raw = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        with gzip.GzipFile(path, "wb", compresslevel=9, mtime=0) as gz:
            gz.write(raw)
        log(f"wrote {path}: {len(raw) / 1e6:.2f} MB json, {os.path.getsize(path) / 1e6:.2f} MB gz")
    if collisions:
        log(f"  note: {len(collisions)} exposed classes share a simple name (Lua sees the last one "
            f"registered): {', '.join(collisions[:12])}{' …' if len(collisions) > 12 else ''}")
    log(f"done in {time.time() - t0:.1f}s")
    return 0


# --------------------------------------------------------------------------- lookup (reference for api_search / lua_examples)

def load_gz(path: str) -> dict:
    with gzip.open(path, "rt", encoding="utf-8") as fh:
        return json.load(fh)


def fmt_params(entry: dict) -> str:
    names = entry.get("pn")
    if names:
        return ", ".join(f"{t} {n}" for t, n in zip(entry["p"], names))
    return ", ".join(entry["p"])


def lua_call_hint(cls: dict | None, entry: dict, kind: str) -> str:
    args = ", ".join(entry.get("pn") or [f"a{i + 1}" for i in range(len(entry.get("p", [])))])
    if kind == "global":
        return f"{entry['n']}({args})"
    if kind == "ctor":
        return f"{cls['name']}.new({args})"
    if kind == "field":
        return f"{cls['name']}.{entry['n']}" if entry.get("s") else f"obj.{entry['n']}"
    if entry.get("s"):
        return f"{cls['name']}.{entry['n']}({args})"
    return f"obj:{entry['n']}({args})"


def superclass_chain(index: dict, fqn: str) -> list[str]:
    chain, seen = [], set()
    cur = index["classes"].get(fqn, {}).get("extends")
    while cur and cur not in seen:
        seen.add(cur)
        chain.append(cur)
        cur = index["classes"].get(cur, {}).get("extends")
    return chain


def api_search(index: dict, query: str, kind: str | None = None, limit: int = 20) -> list[dict]:
    """Reference implementation of the ``api_search`` MCP tool.

    Ranks exact name matches first, then prefix, then substring (case-insensitive).
    ``Class.member`` / ``Class:member`` queries restrict to that class and its superclasses.
    """
    q = query.strip()
    cls_filter = None
    if re.match(r"^[A-Za-z_]\w*[.:][A-Za-z_]\w*$", q):
        cls_filter, q = re.split(r"[.:]", q, 1)
    ql = q.lower()
    classes = index["classes"]

    def rank(name: str) -> int | None:
        nl = name.lower()
        if nl == ql:
            return 0
        if nl.startswith(ql):
            return 1
        if ql in nl:
            return 2
        return None

    by_name = {c["name"].lower(): fqn for fqn, c in classes.items()}
    scope: list[tuple[str, str | None]] = []   # (fqn, inherited_from)
    if cls_filter:
        base = by_name.get(cls_filter.lower())
        if not base:
            return []
        scope = [(base, None)] + [(s, s) for s in superclass_chain(index, base)]
    else:
        scope = [(fqn, None) for fqn in classes]

    results = []
    if kind in (None, "class") and not cls_filter:
        for fqn, c in classes.items():
            r = rank(c["name"])
            if r is not None:
                results.append((r, 0 if c["exposed"] else 1, c["name"], {
                    "kind": c["kind"], "name": c["name"], "class": fqn, "exposed": c["exposed"],
                    "extends": c["extends"], "implements": c["implements"],
                    "signature": f"{c['kind']} {c['name']}" + (f" extends {simple_name(c['extends'])}" if c["extends"] else ""),
                    "members": {"methods": len(c["methods"]), "fields": len(c["fields"]), "ctors": len(c["ctors"])},
                }))
    if kind in (None, "global") and not cls_filter:
        for g in index["globals"]:
            r = rank(g["n"])
            if r is not None:
                results.append((r, 0, g["n"], {
                    "kind": "global", "name": g["n"], "class": None,
                    "signature": f"{g['r']} {g['n']}({fmt_params(g)})",
                    "lua": lua_call_hint(None, g, "global"),
                }))
    for fqn, inherited in scope:
        c = classes[fqn]
        if kind in (None, "method"):
            for m in c["methods"]:
                r = rank(m["n"])
                if r is None:
                    continue
                entry = {
                    "kind": "method", "name": m["n"], "class": fqn, "static": bool(m.get("s")),
                    "signature": f"{m['r']} {c['name']}{'.' if m.get('s') else ':'}{m['n']}({fmt_params(m)})",
                    "lua": lua_call_hint(c, m, "method"),
                }
                if inherited:
                    entry["inherited_from"] = inherited
                if not c["exposed"]:
                    entry["warning"] = "declaring class is not in the Lua exposer list; may not be callable"
                results.append((r, 0 if c["exposed"] else 1, m["n"], entry))
        if kind in (None, "field"):
            for f in c["fields"]:
                r = rank(f["n"])
                if r is None:
                    continue
                entry = {"kind": "field", "name": f["n"], "class": fqn, "static": bool(f.get("s")),
                         "signature": f"{f['t']} {c['name']}.{f['n']}", "lua": lua_call_hint(c, f, "field")}
                if inherited:
                    entry["inherited_from"] = inherited
                results.append((r, 0 if c["exposed"] else 1, f["n"], entry))
        if kind in (None, "ctor"):
            r = rank(c["name"]) if not cls_filter or inherited is None else None
            if r is not None and c["ctors"]:
                for ct in c["ctors"]:
                    results.append((r, 0 if c["exposed"] else 1, c["name"], {
                        "kind": "ctor", "name": c["name"], "class": fqn,
                        "signature": f"{c['name']}({fmt_params(ct)})", "lua": lua_call_hint(c, ct, "ctor")}))
    results.sort(key=lambda t: (t[0], t[1], t[2], t[3].get("class") or ""))
    return [r[3] for r in results[:limit]]


def lua_examples(ex: dict, symbol: str, limit: int = 8) -> dict:
    """Reference implementation of the ``lua_examples`` MCP tool."""
    sym = symbol.strip()
    files = ex["files"]
    out = {"symbol": sym, "calls": [], "defs": [], "curated": [], "related": []}
    keys = [sym] if sym in ex["calls"] else [k for k in ex["calls"] if k.lower() == sym.lower()]
    for k in keys:
        for f, line, snippet in ex["calls"][k]:
            out["calls"].append({"key": k, "file": files[f], "line": line, "snippet": snippet})
    sl = sym.lower()
    for k, entries in ex["defs"].items():
        kl = k.lower()
        if kl == sl or kl.endswith(":" + sl) or kl.endswith("." + sl) or kl.startswith(sl + ":") or kl.startswith(sl + "."):
            for f, line, params in entries:
                out["defs"].append({"name": k, "file": files[f], "line": line, "params": params})
                if len(out["defs"]) >= limit:
                    break
        if len(out["defs"]) >= limit:
            break
    for k, entries in ex.get("curated", {}).items():
        if k.lower() == sl or k.lower().endswith("." + sl) or k.lower().endswith(":" + sl):
            out["curated"].extend(entries)
    if not out["calls"] and not out["defs"] and not out["curated"]:
        out["related"] = sorted(k for k in ex["calls"] if sl in k.lower())[:limit]
    out["calls"] = out["calls"][:limit]
    return out


def cmd_search(args) -> int:
    index = load_gz(os.path.join(args.out_dir, API_INDEX_NAME))
    hits = api_search(index, args.search, args.kind, args.limit)
    if args.json:
        print(json.dumps(hits, indent=1, ensure_ascii=False))
        return 0
    if not hits:
        print("no matches")
        return 1
    for h in hits:
        extra = ""
        if h.get("inherited_from"):
            extra += f"  [inherited from {simple_name(h['inherited_from'])}]"
        if h.get("warning"):
            extra += f"  [!] {h['warning']}"
        print(f"{h['kind']:7} {h['signature']}{extra}")
        if h.get("lua"):
            print(f"        lua: {h['lua']}")
    return 0


def cmd_examples(args) -> int:
    ex = load_gz(os.path.join(args.out_dir, LUA_EXAMPLES_NAME))
    res = lua_examples(ex, args.examples, args.limit)
    if args.json:
        print(json.dumps(res, indent=1, ensure_ascii=False))
        return 0
    for c in res["calls"]:
        print(f"{c['file']}:{c['line']}: {c['snippet']}")
    for d in res["defs"]:
        print(f"def {d['name']}({d['params']})  {d['file']}:{d['line']}")
    for c in res["curated"]:
        print(f"curated: {c['lua']}   -- {c.get('note', '')}")
    if res["related"]:
        print("no examples; related symbols: " + ", ".join(res["related"]))
    return 0 if (res["calls"] or res["defs"] or res["curated"]) else 1


def cmd_verify(args) -> int:
    index = load_gz(os.path.join(args.out_dir, API_INDEX_NAME))
    ex = load_gz(os.path.join(args.out_dir, LUA_EXAMPLES_NAME))
    ok = True
    print(f"game_version={index['game_version']} rev={index['git_revision']} "
          f"classes={index['stats']['classes']} methods={index['stats']['methods']} "
          f"globals={index['stats']['globals']}")
    for sym in VERIFY_SYMBOLS:
        hits = [h for h in api_search(index, sym, None, 50) if h["name"] == sym and h["kind"] in ("method", "global")]
        res = lua_examples(ex, sym)
        n_ex = len(res["calls"]) + len(res["curated"])
        status = "ok " if hits and n_ex else "FAIL"
        ok &= bool(hits and n_ex)
        sig = hits[0]["signature"] if hits else "<not found>"
        print(f"{status} {sym:28} sigs={len(hits):2} examples={len(res['calls'])} curated={len(res['curated'])}  {sig}")
    return 0 if ok else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pz-dir", default=os.environ.get("PZ_DIR", DEFAULT_PZ_DIR),
                    help="Project Zomboid install dir (projectzomboid.jar + media/lua)")
    ap.add_argument("--out-dir", default=DEFAULT_OUT_DIR, help="where the .json.gz files go")
    ap.add_argument("--max-examples", type=int, default=4, help="call-site examples kept per symbol")
    ap.add_argument("--max-defs", type=int, default=6, help="definitions kept per Lua function name")
    ap.add_argument("--search", metavar="QUERY", help="query the built index (api_search reference)")
    ap.add_argument("--kind", choices=["class", "method", "field", "ctor", "global"])
    ap.add_argument("--examples", metavar="SYMBOL", help="show vanilla examples (lua_examples reference)")
    ap.add_argument("--limit", type=int, default=20)
    ap.add_argument("--json", action="store_true", help="print lookup results as JSON")
    ap.add_argument("--verify", action="store_true", help="check the ZOM-3 acceptance symbols")
    args = ap.parse_args(argv)
    if args.search:
        return cmd_search(args)
    if args.examples:
        return cmd_examples(args)
    if args.verify:
        return cmd_verify(args)
    return build(args)


if __name__ == "__main__":
    sys.exit(main())
