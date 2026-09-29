"""api_search / lua_examples: lookups in the engine API index built by ``tools/build_api_index.py``.

Two gzipped JSON files ship next to this module (schema: ``docs/API_INDEX.md``):

* ``api_index.json.gz``    classes (fields, ctors, methods, inheritance) + global functions
* ``lua_examples.json.gz`` vanilla Lua definitions and call sites per engine symbol

Both are loaded lazily on first use; a missing file yields a clear message
instead of an error. The ranking rules mirror the reference lookup in the
generator (exact < prefix < substring, exposed before unexposed).
"""

import gzip
import json
import os
import re
import sys
import threading

API_INDEX_NAME = "api_index.json.gz"
LUA_EXAMPLES_NAME = "lua_examples.json.gz"
MISSING_MSG = ("%s is not available (%s). Build it with `make api-index` / tools/build_api_index.py from the repo "
               "(needs the game's projectzomboid.jar and media/lua), or point --api-index at the directory that holds "
               "it. Without it, use run_lua_server to introspect the engine directly.")


def default_index_dir(here):
    env = os.environ.get("ZMCP_API_INDEX")
    if env:
        env = os.path.expanduser(env)
        return env if os.path.isdir(env) else os.path.dirname(env)
    return here


def default_lua_dirs():
    """Vanilla Lua directories of a local game install, if any (grep fallback for lua_examples)."""
    home = os.path.expanduser("~")
    cands = [
        os.path.join(home, ".steam", "steam", "steamapps", "common", "ProjectZomboid", "projectzomboid", "media", "lua"),
        os.path.join(home, ".local", "share", "Steam", "steamapps", "common", "ProjectZomboid", "projectzomboid", "media", "lua"),
        "C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid/media/lua",
    ]
    env = os.environ.get("ZMCP_PZ_LUA")
    if env:
        cands.insert(0, os.path.expanduser(env))
    return [c for c in cands if os.path.isdir(c)]


def simple_name(fqn):
    return (fqn or "").rsplit(".", 1)[-1].rsplit("$", 1)[-1]


def fmt_params(entry):
    names = entry.get("pn")
    params = entry.get("p") or []
    if names:
        return ", ".join("%s %s" % (t, n) for t, n in zip(params, names))
    return ", ".join(params)


def lua_call_hint(cls, entry, kind):
    args = ", ".join(entry.get("pn") or ["a%d" % (i + 1) for i in range(len(entry.get("p") or []))])
    if kind == "global":
        return "%s(%s)" % (entry["n"], args)
    if kind == "ctor":
        return "%s.new(%s)" % (cls["name"], args)
    if kind == "field":
        return "%s.%s" % (cls["name"], entry["n"]) if entry.get("s") else "obj.%s" % entry["n"]
    if entry.get("s"):
        return "%s.%s(%s)" % (cls["name"], entry["n"], args)
    return "obj:%s(%s)" % (entry["n"], args)


class ApiIndex(object):
    def __init__(self, index_dir, lua_dirs=None):
        self.index_dir = index_dir
        self.api_path = os.path.join(index_dir, API_INDEX_NAME)
        self.examples_path = os.path.join(index_dir, LUA_EXAMPLES_NAME)
        self.lua_dirs = lua_dirs if lua_dirs is not None else default_lua_dirs()
        self._lock = threading.Lock()
        self._api = None
        self._ex = None
        self._api_loaded = False
        self._ex_loaded = False

    # --- loading -----------------------------------------------------------
    @staticmethod
    def _load_gz(path):
        if not os.path.exists(path):
            return None
        try:
            opener = gzip.open if path.endswith(".gz") else open
            with opener(path, "rb") as f:
                data = json.loads(f.read().decode("utf-8"))
        except (OSError, ValueError) as e:
            sys.stderr.write("[zomboid-mcp] cannot read %s: %s\n" % (path, e))
            return None
        return data if isinstance(data, dict) else None

    def api(self):
        with self._lock:
            if not self._api_loaded:
                self._api_loaded = True
                self._api = self._load_gz(self.api_path)
                if self._api is not None and not isinstance(self._api.get("classes"), dict):
                    self._api = None
            return self._api

    def examples(self):
        with self._lock:
            if not self._ex_loaded:
                self._ex_loaded = True
                self._ex = self._load_gz(self.examples_path)
                if self._ex is not None and not isinstance(self._ex.get("calls"), dict):
                    self._ex = None
            return self._ex

    def info(self):
        api, ex = self.api(), self.examples()
        return {
            "api_index": None if api is None else {k: api.get(k) for k in ("game_version", "git_revision", "generated_at", "stats")},
            "lua_examples": None if ex is None else {k: ex.get(k) for k in ("game_version", "generated_at", "stats")},
        }

    # --- api_search --------------------------------------------------------
    def search(self, query, kind="any", limit=40):
        index = self.api()
        if index is None:
            return {"error": MISSING_MSG % (API_INDEX_NAME, self.api_path), "results": []}
        kind = None if not kind or kind == "any" else kind
        q = (query or "").strip()
        if not q:
            return {"error": "empty query", "results": []}
        classes = index["classes"]
        cls_filter = None
        if re.match(r"^[A-Za-z_]\w*[.:][A-Za-z_]\w*$", q):
            cls_filter, q = re.split(r"[.:]", q, 1)
        ql = q.lower()
        try:
            rx = re.compile(q, re.IGNORECASE) if re.search(r"[\\^$.*+?()\[\]{}|]", q) else None
        except re.error:
            rx = None

        def rank(name):
            nl = name.lower()
            if nl == ql:
                return 0
            if nl.startswith(ql):
                return 1
            if ql in nl:
                return 2
            if rx is not None and rx.search(name):
                return 3
            return None

        by_name = {}
        for fqn, c in classes.items():
            by_name.setdefault(c["name"].lower(), fqn)
        if cls_filter:
            base = by_name.get(cls_filter.lower())
            if not base:
                return {"total": 0, "results": [], "note": "no class named %s" % cls_filter}
            scope = [(base, None)] + [(s_, s_) for s_ in self._superclass_chain(index, base)]
        else:
            scope = [(fqn, None) for fqn in classes]

        results = []
        if kind in (None, "class") and not cls_filter:
            for fqn, c in classes.items():
                r = rank(c["name"])
                if r is not None:
                    results.append((r, 0 if c.get("exposed", True) else 1, c["name"], {
                        "kind": c.get("kind", "class"), "name": c["name"], "class": fqn, "exposed": c.get("exposed", True),
                        "extends": c.get("extends"), "implements": c.get("implements", []),
                        "signature": "%s %s" % (c.get("kind", "class"), c["name"]) +
                                     (" extends %s" % simple_name(c["extends"]) if c.get("extends") else ""),
                        "members": {"methods": len(c.get("methods", [])), "fields": len(c.get("fields", [])),
                                    "ctors": len(c.get("ctors", []))},
                    }))
        if kind in (None, "global") and not cls_filter:
            for g in index.get("globals", []):
                r = rank(g["n"])
                if r is not None:
                    results.append((r, 0, g["n"], {
                        "kind": "global", "name": g["n"], "class": None,
                        "signature": "%s %s(%s)" % (g.get("r", "void"), g["n"], fmt_params(g)),
                        "lua": lua_call_hint(None, g, "global"),
                    }))
        for fqn, inherited in scope:
            c = classes[fqn]
            exposed = c.get("exposed", True)
            if kind in (None, "method"):
                for m in c.get("methods", []):
                    r = rank(m["n"])
                    if r is None:
                        continue
                    entry = {
                        "kind": "method", "name": m["n"], "class": fqn, "static": bool(m.get("s")),
                        "signature": "%s %s%s%s(%s)" % (m.get("r", "void"), c["name"], "." if m.get("s") else ":",
                                                       m["n"], fmt_params(m)),
                        "lua": lua_call_hint(c, m, "method"),
                    }
                    if inherited:
                        entry["inherited_from"] = inherited
                    if not exposed:
                        entry["warning"] = "declaring class is not in the Lua exposer list; may not be callable"
                    results.append((r, 0 if exposed else 1, m["n"], entry))
            if kind in (None, "field"):
                for f in c.get("fields", []):
                    r = rank(f["n"])
                    if r is None:
                        continue
                    entry = {"kind": "field", "name": f["n"], "class": fqn, "static": bool(f.get("s")),
                             "signature": "%s %s.%s" % (f.get("t", "?"), c["name"], f["n"]),
                             "lua": lua_call_hint(c, f, "field")}
                    if inherited:
                        entry["inherited_from"] = inherited
                    results.append((r, 0 if exposed else 1, f["n"], entry))
            if kind in (None, "ctor"):
                r = rank(c["name"]) if not cls_filter or inherited is None else None
                if r is not None and c.get("ctors"):
                    for ct in c["ctors"]:
                        results.append((r, 0 if exposed else 1, c["name"], {
                            "kind": "ctor", "name": c["name"], "class": fqn,
                            "signature": "%s(%s)" % (c["name"], fmt_params(ct)), "lua": lua_call_hint(c, ct, "ctor")}))
        results.sort(key=lambda t: (t[0], t[1], t[2], t[3].get("class") or ""))
        out = {"total": len(results), "results": [r[3] for r in results[:limit]],
               "game_version": index.get("game_version")}
        if cls_filter:
            out["class_filter"] = cls_filter
        return out

    @staticmethod
    def _superclass_chain(index, fqn):
        chain, seen = [], set()
        cur = index["classes"].get(fqn, {}).get("extends")
        while cur and cur not in seen:
            seen.add(cur)
            chain.append(cur)
            cur = index["classes"].get(cur, {}).get("extends")
        return chain

    # --- lua_examples --------------------------------------------------------
    def lua_examples(self, symbol, limit=8, context=0):
        ex = self.examples()
        sym = (symbol or "").strip()
        if not sym:
            return {"error": "empty symbol", "calls": []}
        out = {"symbol": sym, "calls": [], "defs": [], "curated": [], "related": []}
        if ex is not None:
            files = ex.get("files", [])
            calls = ex.get("calls", {})
            keys = [sym] if sym in calls else [k for k in calls if k.lower() == sym.lower()]
            for k in keys:
                for f, line, snippet in calls[k]:
                    out["calls"].append({"key": k, "file": files[f] if isinstance(f, int) and f < len(files) else f,
                                         "line": line, "snippet": snippet})
            sl = sym.lower()
            for k, entries in ex.get("defs", {}).items():
                kl = k.lower()
                if kl == sl or kl.endswith(":" + sl) or kl.endswith("." + sl) or kl.startswith(sl + ":") or kl.startswith(sl + "."):
                    for f, line, params in entries:
                        out["defs"].append({"name": k, "file": files[f] if isinstance(f, int) and f < len(files) else f,
                                            "line": line, "params": params})
                        if len(out["defs"]) >= limit:
                            break
                if len(out["defs"]) >= limit:
                    break
            for k, entries in ex.get("curated", {}).items():
                kl = k.lower()
                if kl == sl or kl.endswith("." + sl) or kl.endswith(":" + sl):
                    out["curated"].extend(entries)
            if not out["calls"] and not out["defs"] and not out["curated"]:
                out["related"] = sorted(k for k in calls if sl in k.lower())[:limit]
            out["calls"] = out["calls"][:limit]
            out["game_version"] = ex.get("game_version")
        else:
            out["note"] = MISSING_MSG % (LUA_EXAMPLES_NAME, self.examples_path)
        # Fallback / complement: grep a local vanilla install when nothing indexed matched.
        if not out["calls"] and not out["defs"] and not out["curated"] and self.lua_dirs:
            rx = compile_query(sym)
            out["grep"] = grep_dirs(self.lua_dirs, rx, limit, context)
            out["grep_dirs"] = self.lua_dirs
        if ex is None and not self.lua_dirs:
            out["error"] = out.pop("note")
        return out


def compile_query(query):
    try:
        return re.compile(query, re.IGNORECASE)
    except re.error:
        return re.compile(re.escape(query), re.IGNORECASE)


def grep_dirs(dirs, rx, limit, context):
    hits = []
    for base in dirs:
        for root, _, files in os.walk(base):
            for fn in files:
                if not fn.endswith(".lua"):
                    continue
                path = os.path.join(root, fn)
                try:
                    with open(path, "r", encoding="utf-8", errors="replace") as f:
                        lines = f.read().split("\n")
                except OSError:
                    continue
                for i, line in enumerate(lines):
                    if rx.search(line):
                        lo, hi = max(0, i - context), min(len(lines), i + context + 1)
                        hit = {"file": os.path.relpath(path, base), "line": i + 1, "snippet": line.strip()}
                        if context:
                            hit["context"] = "\n".join(lines[lo:hi])
                        hits.append(hit)
                        if len(hits) >= limit:
                            return hits
    return hits
