#!/usr/bin/env python3
"""Zomboid MCP server: gives an MCP client (Claude) live control over a running Project Zomboid game.

Pure Python 3.9+ standard library, ships inside the ZomboidMCP mod. Speaks the
Model Context Protocol (JSON-RPC 2.0, spec 2025-06-18) over stdio or over
streamable HTTP on 127.0.0.1, and talks to the game through the file bridge
(``Bridge.lua``) in the game's ``Zomboid/Lua`` directory, locally or over ssh.

Examples::

    # local single-player / hosted game (Lua dir auto-detected: ~/Zomboid/Lua)
    claude mcp add zomboid -- python3 /path/to/ZomboidMCP/mcp/zomboid_mcp.py

    # dedicated server over ssh, with raw console access through the docker container
    claude mcp add zomboid -- python3 zomboid_mcp.py --ssh root@host \\
        --lua-dir /var/lib/docker/volumes/<vol>/_data/Lua --console-container <container>

    # localhost HTTP for other clients
    python3 zomboid_mcp.py --http 8765 --ssh root@host --lua-dir ...

    # deployment env file (ZMCP_SSH, ZMCP_LUA_DIR, ZMCP_CONTAINER, ZMCP_POLL_FILE)
    python3 zomboid_mcp.py --env-file ~/.config/zomboid-mcp/local.env --check
"""

import argparse
import base64
import glob
import json
import os
import re
import sys
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import zmcp_catalog as catalog                       # noqa: E402
from zmcp_game import (GameBridge, GameError, LocalTransport, SshTransport,  # noqa: E402
                       default_lua_dir, log, poll_command, DEFAULT_POLL_FILE)
from zmcp_index import ApiIndex, default_index_dir   # noqa: E402

VERSION = "0.3.0"
SERVER_NAME = "zomboid-mcp"

# JSON-RPC error codes
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603

CONSOLE_NOISE = re.compile(r"AnimState|Property Name|Ragdoll|Saving took|Saving GlobalModData|Saving finish")
GAME_INTERNAL_TOOLS = {"ping", "tools_list", "run_file", "status", "client_results"}   # bridge plumbing, never exposed


class JsonRpcError(Exception):
    def __init__(self, code, message, data=None):
        Exception.__init__(self, message)
        self.code, self.message, self.data = code, message, data


# --------------------------------------------------------------------------- the server
class ZomboidMCP(object):
    """Protocol handling plus tool execution. Transport-agnostic (stdio and HTTP both feed ``handle``)."""

    def __init__(self, bridge, index, console=None, docs_dirs=None, verbose=False):
        self.bridge = bridge
        self.index = index
        self.console = console or {}
        self.docs_dirs = docs_dirs or []
        self.verbose = verbose
        self.protocol_version = catalog.PROTOCOL_VERSION
        self._game_tools = None          # cached passthrough tools from the game
        self._game_tools_at = 0.0
        self._tools_lock = threading.Lock()

    def debug(self, msg):
        if self.verbose:
            log(msg)

    # --- JSON-RPC plumbing ---------------------------------------------------
    def handle(self, msg):
        """Handle one decoded JSON-RPC message (or batch). Returns the response object, or None."""
        if isinstance(msg, list):
            if not msg:
                return self._error(None, INVALID_REQUEST, "empty batch")
            out = [r for r in (self.handle(m) for m in msg) if r is not None]
            return out or None
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0":
            return self._error(msg.get("id") if isinstance(msg, dict) else None, INVALID_REQUEST,
                               "expected a JSON-RPC 2.0 message")
        if "method" not in msg:
            return None                  # a response from the client (e.g. to a ping): nothing to do
        method = msg["method"]
        params = msg.get("params") or {}
        has_id = "id" in msg and msg["id"] is not None
        self.debug("<- %s %s" % (method, json.dumps(params)[:200]))
        try:
            result = self.dispatch(method, params, has_id)
        except JsonRpcError as e:
            return self._error(msg.get("id"), e.code, e.message, e.data) if has_id else None
        except Exception as e:           # never let a bug kill the loop
            log("internal error in %s: %r" % (method, e))
            return self._error(msg.get("id"), INTERNAL_ERROR, "internal error: %s" % e) if has_id else None
        if not has_id:
            return None
        return {"jsonrpc": "2.0", "id": msg["id"], "result": result}

    @staticmethod
    def _error(id_, code, message, data=None):
        err = {"code": code, "message": message}
        if data is not None:
            err["data"] = data
        return {"jsonrpc": "2.0", "id": id_, "error": err}

    def dispatch(self, method, params, has_id):
        if method == "initialize":
            return self.initialize(params)
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": self.list_tools()}
        if method == "tools/call":
            return self.call_tool(params)
        if method == "resources/list":
            return {"resources": self.list_resources()}
        if method == "resources/read":
            return self.read_resource(params)
        if method == "resources/templates/list":
            return {"resourceTemplates": []}
        if method == "prompts/list":
            return {"prompts": []}
        if method == "logging/setLevel":
            return {}
        if method.startswith("notifications/"):
            if method == "notifications/initialized":
                self.debug("client initialized")
            return None
        raise JsonRpcError(METHOD_NOT_FOUND, "method not found: %s" % method)

    # --- lifecycle -----------------------------------------------------------
    def initialize(self, params):
        requested = str(params.get("protocolVersion") or "")
        self.protocol_version = requested if requested in catalog.SUPPORTED_PROTOCOL_VERSIONS else catalog.PROTOCOL_VERSION
        return {
            "protocolVersion": self.protocol_version,
            "capabilities": {"tools": {"listChanged": False}, "resources": {"subscribe": False, "listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": VERSION,
                           "title": "Zomboid MCP (%s)" % self.bridge.transport.describe()},
            "instructions": catalog.SERVER_INSTRUCTIONS,
        }

    # --- tools ---------------------------------------------------------------
    def list_tools(self):
        tools = [catalog.public(t) for t in catalog.TOOLS]
        known = set(catalog.BY_NAME)
        for t in self._passthrough_tools():
            if t["name"] not in known:
                tools.append(catalog.public(t))
        return tools

    def _passthrough_tools(self):
        """Tools the running game registers that the static catalogue does not know (cached for a minute)."""
        with self._tools_lock:
            if self._game_tools is not None and time.monotonic() - self._game_tools_at < 60:
                return self._game_tools
            found = {}
            try:
                live = self.bridge.is_live()
                # status.tools (bridge >= 0.2.0) lists names even while the server is not answering requests
                st = self.bridge.last_status or {}
                names = st.get("tools") if isinstance(st.get("tools"), list) else []
                hidden = GAME_INTERNAL_TOOLS | catalog.GAME_NAMES | set(catalog.BY_NAME)
                for name in names:
                    if isinstance(name, str) and name not in hidden:
                        found[name] = catalog.passthrough_tool(name, None)
                if live:
                    listed = self.bridge.call("tools_list", {}, timeout_s=3)
                    for entry in listed or []:
                        if not isinstance(entry, dict):
                            continue
                        name = entry.get("name")
                        if name and name not in hidden:
                            found[name] = catalog.passthrough_tool(name, entry.get("desc"))
                    self._game_tools_at = time.monotonic()
                else:
                    self._game_tools_at = time.monotonic() - 50   # retry soon
            except GameError as e:
                self.debug("tools_list from game failed: %s" % e)
                self._game_tools_at = time.monotonic() - 50
            self._game_tools = list(found.values())
            return self._game_tools

    def find_tool(self, name):
        t = catalog.BY_NAME.get(name)
        if t:
            return t
        for pt in self._passthrough_tools():
            if pt["name"] == name:
                return pt
        return None

    def call_tool(self, params):
        name = params.get("name")
        args = params.get("arguments") or {}
        if not isinstance(name, str):
            raise JsonRpcError(INVALID_PARAMS, "tools/call needs a tool name")
        if not isinstance(args, dict):
            raise JsonRpcError(INVALID_PARAMS, "arguments must be an object")
        t = self.find_tool(name)
        if t is None:
            # unknown here, maybe the game knows it (freshly installed module): pass it through
            t = catalog.passthrough_tool(name, None)
        try:
            validate_args(t["inputSchema"], args)
            started = time.time()
            if t.get("local"):
                result = getattr(self, "tool_" + t["local"])(args, t)
            else:
                result = self.bridge.call(t["game"], args, timeout_s=float(args.get("timeout_s") or 0) or None)
            self.debug("-> %s ok in %.2fs" % (name, time.time() - started))
            return tool_result(result)
        except GameError as e:
            return tool_error(str(e))
        except ValueError as e:
            return tool_error("invalid arguments: %s" % e)

    # --- local tools -----------------------------------------------------------
    def tool_status(self, args, t):
        st = self.bridge.status_summary()
        st["api_index"] = self.index.info()
        return st

    def tool_wait_for(self, args, t):
        timeout = float(args.get("timeout_s") or 300)
        want_player = (args.get("player") or "").strip().lower()
        min_players = int(args.get("min_players") if args.get("min_players") is not None else 1)
        deadline = time.time() + timeout
        last = None
        while True:
            last = self.bridge.status_summary()
            players = last.get("players") or []
            live = last.get("bridge") == "live"
            names = [str(p.get("user", "")).lower() for p in players] + [str(p.get("name", "")).lower() for p in players]
            if live and len(players) >= min_players and (not want_player or want_player in names):
                last["waited_s"] = round(timeout - (deadline - time.time()), 1)
                return last
            if time.time() >= deadline:
                raise GameError("wait_for timed out after %.0fs; last status: bridge=%s players=%s" % (
                    timeout, last.get("bridge"), [p.get("user") for p in players]))
            time.sleep(min(2.0, max(0.2, deadline - time.time())))

    def tool_events_poll(self, args, t):
        cursor = args.get("cursor")
        kinds = args.get("kinds")
        return self.bridge.events(cursor=int(cursor) if cursor is not None else None,
                                  limit=int(args.get("limit") or 100),
                                  kinds=set(kinds) if kinds else None)

    def tool_api_search(self, args, t):
        return self.index.search(str(args.get("query", "")), kind=args.get("kind") or "any",
                                 limit=int(args.get("limit") or 40))

    def tool_lua_examples(self, args, t):
        return self.index.lua_examples(str(args.get("query", "")), limit=int(args.get("limit") or 8),
                                       context=int(args.get("context") or 0))

    def tool_run_lua_client(self, args, t):
        """Send the chunk, then wait for the clients' replies so the caller gets values, not just an id."""
        timeout = float(args.get("timeout_s") or 10)
        game_args = {k: v for k, v in args.items() if k != "timeout_s"}
        sent = self.bridge.call("run_lua_client", game_args)
        if not isinstance(sent, dict) or not sent.get("id"):
            return sent
        if not sent.get("to"):
            sent["results"] = {}
            sent["note"] = "no client with the ZomboidMCP mod is connected; nothing ran"
            return sent
        status = self.bridge.wait_client_results(sent["id"], timeout)
        out = {"id": sent["id"], "to": sent.get("to"), "results": {}, "missing": []}
        if isinstance(status, dict):
            for user, r in (status.get("results") or {}).items():
                res = r.get("res")
                if isinstance(res, str):
                    try:
                        res = json.loads(res)
                    except ValueError:
                        pass
                out["results"][user] = {"ok": r.get("ok"), "value" if r.get("ok") else "error": res, "ms": r.get("ms")}
            out["missing"] = status.get("pending") or []
            out["done"] = bool(status.get("done"))
        if out["missing"]:
            out["note"] = "clients that did not answer within %.0fs are listed in missing; poll events_poll for late results" % timeout
        return out

    @staticmethod
    def _read_file_base64(path, what):
        path = os.path.expanduser(str(path))
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as e:
            raise GameError("cannot read %s file %s: %s" % (what, path, e))
        return base64.b64encode(data).decode("ascii")

    def _upload_args(self, args, pairs):
        """Resolve a path argument (a file on this machine) into its base64 argument for the game."""
        out = dict(args)
        for key, path_key, what in pairs:
            path = out.pop(path_key, None)
            if path and not out.get(key):
                out[key] = self._read_file_base64(path, what)
            if not out.get(key):
                raise GameError("give %s (base64) or %s (a file on this machine)" % (key, path_key))
        return out

    def tool_texture_upload(self, args, t):
        return self.bridge.call("texture_upload", self._upload_args(args, [("png_base64", "png_path", "PNG")]))

    def tool_model_upload(self, args, t):
        return self.bridge.call("model_upload", self._upload_args(
            args, [("mesh_base64", "mesh_path", "mesh"), ("png_base64", "png_path", "PNG")]))

    # --- scene templates (examples/ shipped next to the mod or in the repo) ------------
    TEMPLATES = {
        "merchant": ("scenes", "A passive zombie merchant who greets players, walks up to them and trades an item."),
        "supply_drop": ("scenes", "A parachute sprite drifts down and a real crate of items lands where it touches the ground."),
        "meteor_shower": ("scenes", "Meteors streak across the sky, strike with lightning and leave hot rocks and loot."),
        "haunted_house": ("scenes", "A persistent, trigger-driven haunted-house sequence with lights, sounds, puppets and a restorable area."),
        "companion": ("scenes", "A companion who follows the nearest player and comments on what happens."),
        "flappy": ("apps", "A complete flappy bird screen app drawn from shapes, score reported to the server."),
        "flappy_phone": ("apps", "The flappy bird inside a phone frame in the middle of the screen, the world visible around it (the showcase capture)."),
    }

    def _examples_dirs(self):
        env = os.environ.get("ZMCP_EXAMPLES_DIR")
        mod_root = os.path.dirname(HERE)                                   # .../mods/ZomboidMCP
        repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(mod_root))))   # mods/Contents/mod/<repo>
        out = [d for d in (env, os.path.join(mod_root, "examples"), os.path.join(repo_root, "examples")) if d]
        return [d for d in out if os.path.isdir(d)]

    def tool_scene_template(self, args, t):
        name = str(args.get("name") or "").strip()
        dirs = self._examples_dirs()
        if not name:
            items = []
            for n, (kind, summary) in self.TEMPLATES.items():
                items.append({"name": n, "kind": "scene" if kind == "scenes" else "app", "summary": summary,
                              "tool": "scene_start" if kind == "scenes" else "app_start"})
            return {"templates": items, "docs": "docs/SCENES.md", "examples_dirs": dirs}
        if name not in self.TEMPLATES:
            raise GameError("unknown template '%s' (known: %s)" % (name, ", ".join(sorted(self.TEMPLATES))))
        kind, summary = self.TEMPLATES[name]
        for d in dirs:
            path = os.path.join(d, kind, name + ".lua")
            if os.path.isfile(path):
                with open(path, "r", encoding="utf-8") as f:
                    code = f.read()
                return {"name": name, "kind": "scene" if kind == "scenes" else "app", "summary": summary, "code": code,
                        "path": path, "tool": "scene_start" if kind == "scenes" else "app_start", "docs": "docs/SCENES.md"}
        raise GameError("template '%s' not found: no examples/%s/%s.lua in %s (set ZMCP_EXAMPLES_DIR)" % (name, kind, name, dirs or ["<no examples dir>"]))

    def tool_server_console(self, args, t):
        c = self.console
        if not c.get("enabled"):
            raise GameError("server_console is not configured: start zomboid_mcp.py with --console-container <docker "
                            "name> (dedicated server in Docker) or --console-fifo <path> (FIFO the server reads).")
        cmd = str(args.get("command", "")).strip()
        if not cmd or "\n" in cmd:
            raise GameError("command must be a single non-empty line")
        wait_s = float(args.get("wait_s") or 2.0)
        out = self.bridge.console(cmd, c.get("container"), c.get("fifo"), c.get("log"), wait_s)
        lines = [l.rstrip() for l in out.splitlines()]
        if not args.get("raw"):
            lines = [l[:300] for l in lines if l.strip() and not CONSOLE_NOISE.search(l)]
        return {"command": cmd, "lines": lines, "line_count": len(lines)}

    # --- resources -----------------------------------------------------------
    def _doc_files(self):
        seen, out = set(), []
        for d in self.docs_dirs:
            for path in sorted(glob.glob(os.path.join(d, "*.md"))):
                name = os.path.basename(path)
                if name in seen:
                    continue
                seen.add(name)
                out.append((name, path))
        return out

    def list_resources(self):
        res = []
        for name, path in self._doc_files():
            res.append({"uri": "zomboid://docs/%s" % name, "name": name, "title": name[:-3].replace("_", " ").title(),
                        "description": "Zomboid MCP documentation: %s" % name, "mimeType": "text/markdown"})
        return res

    def read_resource(self, params):
        uri = str(params.get("uri", ""))
        for name, path in self._doc_files():
            if uri == "zomboid://docs/%s" % name:
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    return {"contents": [{"uri": uri, "mimeType": "text/markdown", "text": f.read()}]}
        raise JsonRpcError(-32002, "resource not found: %s" % uri)


# --------------------------------------------------------------------------- helpers
def tool_result(result):
    if isinstance(result, str):
        text = result
    else:
        text = json.dumps(result, ensure_ascii=False, indent=1, sort_keys=False)
    out = {"content": [{"type": "text", "text": text}], "isError": False}
    if isinstance(result, dict):
        out["structuredContent"] = result
    return out


def tool_error(message):
    return {"content": [{"type": "text", "text": message}], "isError": True}


_TYPE_CHECKS = {
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool) or (isinstance(v, float) and v.is_integer()),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "array": lambda v: isinstance(v, list),
    "object": lambda v: isinstance(v, dict),
}


def validate_args(schema, args):
    """Small JSON-schema subset check (types, required, enum, min/max) so mistakes fail fast with a clear message."""
    props = schema.get("properties") or {}
    for req in schema.get("required") or []:
        if req not in args or args[req] is None:
            raise ValueError("missing required argument '%s'" % req)
    for key, val in args.items():
        spec = props.get(key)
        if spec is None:
            if schema.get("additionalProperties") is False:
                raise ValueError("unknown argument '%s' (known: %s)" % (key, ", ".join(sorted(props)) or "none"))
            continue
        if val is None:
            continue
        typ = spec.get("type")
        if typ in _TYPE_CHECKS and not _TYPE_CHECKS[typ](val):
            raise ValueError("argument '%s' must be a %s" % (key, typ))
        if typ == "integer" and isinstance(val, float):
            args[key] = int(val)
        if "enum" in spec and val not in spec["enum"]:
            raise ValueError("argument '%s' must be one of %s" % (key, spec["enum"]))
        if isinstance(val, (int, float)) and not isinstance(val, bool):
            if "minimum" in spec and val < spec["minimum"]:
                raise ValueError("argument '%s' must be >= %s" % (key, spec["minimum"]))
            if "maximum" in spec and val > spec["maximum"]:
                raise ValueError("argument '%s' must be <= %s" % (key, spec["maximum"]))
        if typ == "string" and "pattern" in spec and not re.match(spec["pattern"], val):
            raise ValueError("argument '%s' does not match %s" % (key, spec["pattern"]))
        if typ == "string" and "maxLength" in spec and len(val) > spec["maxLength"]:
            raise ValueError("argument '%s' is longer than %d characters" % (key, spec["maxLength"]))


def load_env_file(path):
    """KEY=VALUE lines (shell-ish, `$VAR` references to earlier keys are expanded) into os.environ if unset."""
    env = {}
    try:
        with open(os.path.expanduser(path), "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k, v = k.strip(), v.strip().strip('"').strip("'")
                v = re.sub(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", lambda m: env.get(m.group(1), os.environ.get(m.group(1), "")), v)
                env[k] = v
    except OSError as e:
        log("cannot read env file %s: %s" % (path, e))
        return
    for k, v in env.items():
        os.environ.setdefault(k, v)


def find_docs_dirs(explicit):
    dirs = [os.path.expanduser(d) for d in explicit or []]
    mod_root = os.path.dirname(HERE)                       # .../mods/ZomboidMCP
    dirs += [os.path.join(mod_root, "skill"), os.path.join(mod_root, "docs")]
    d = HERE
    for _ in range(8):                                       # repo checkout: walk up to docs/ENGINE_NOTES.md
        d = os.path.dirname(d)
        if os.path.exists(os.path.join(d, "docs", "ENGINE_NOTES.md")):
            dirs.append(os.path.join(d, "docs"))
            break
    return [x for x in dirs if os.path.isdir(x)]


# --------------------------------------------------------------------------- stdio transport
def serve_stdio(server):
    out_lock = threading.Lock()
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    def send(obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8") + b"\n"
        with out_lock:
            stdout.write(data)
            stdout.flush()

    def work(msg):
        resp = server.handle(msg)
        if resp is not None:
            send(resp)

    log("stdio server ready (%s)" % server.bridge.transport.describe())
    while True:
        line = stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line.decode("utf-8"))
        except ValueError as e:
            send(ZomboidMCP._error(None, PARSE_ERROR, "parse error: %s" % e))
            continue
        # Tool calls can block for a long time (wait_for, game timeouts); keep answering pings meanwhile.
        if isinstance(msg, dict) and msg.get("method") == "tools/call":
            threading.Thread(target=work, args=(msg,), daemon=True).start()
        else:
            work(msg)
    log("stdin closed, exiting")


# --------------------------------------------------------------------------- HTTP transport
def serve_http(server, port, path="/mcp"):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    sessions = set()
    allowed_origins = re.compile(r"^https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "%s/%s" % (SERVER_NAME, VERSION)

        def log_message(self, fmt, *args):
            if server.verbose:
                log("http %s" % (fmt % args))

        def _send(self, code, body=b"", ctype="application/json", extra=None):
            self.send_response(code)
            if body:
                self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if body:
                self.wfile.write(body)

        def _check(self):
            if self.path.split("?")[0] not in (path, "/"):
                self._send(404, b'{"error":"not found; use POST %s"}' % path.encode())
                return False
            origin = self.headers.get("Origin")
            if origin and not allowed_origins.match(origin):
                self._send(403, b'{"error":"origin not allowed"}')
                return False
            return True

        def do_POST(self):
            if not self._check():
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
                body = self.rfile.read(length) if length else b""
                msg = json.loads(body.decode("utf-8"))
            except ValueError as e:
                self._send(400, json.dumps(ZomboidMCP._error(None, PARSE_ERROR, "parse error: %s" % e)).encode())
                return
            extra = {}
            is_init = isinstance(msg, dict) and msg.get("method") == "initialize"
            if is_init:
                sid = uuid.uuid4().hex
                sessions.add(sid)
                extra["Mcp-Session-Id"] = sid
            resp = server.handle(msg)
            if resp is None:
                self._send(202, extra=extra)
                return
            self._send(200, json.dumps(resp, ensure_ascii=False).encode("utf-8"), extra=extra)

        def do_GET(self):
            if not self._check():
                return
            # SSE streaming is optional in the spec; we only answer requests.
            self._send(405, b'{"error":"server-initiated streams are not supported; POST JSON-RPC to this path"}',
                       extra={"Allow": "POST, DELETE"})

        def do_DELETE(self):
            if not self._check():
                return
            sessions.discard(self.headers.get("Mcp-Session-Id"))
            self._send(200)

    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    httpd.daemon_threads = True
    actual = httpd.server_address[1]
    log("http server listening on http://127.0.0.1:%d%s (%s)" % (actual, path, server.bridge.transport.describe()))
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


# --------------------------------------------------------------------------- CLI
def build_parser():
    p = argparse.ArgumentParser(prog="zomboid_mcp.py", description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog=__doc__.split("Examples::", 1)[1] if "Examples::" in __doc__ else None)
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--stdio", action="store_true", help="serve MCP over stdin/stdout (default)")
    mode.add_argument("--http", type=int, metavar="PORT", help="serve streamable HTTP on 127.0.0.1:PORT (POST /mcp); 0 picks a free port")
    p.add_argument("--lua-dir", metavar="DIR", help="the game's Zomboid/Lua directory (default: auto-detect ~/Zomboid/Lua, or $ZOMBOID_LUA_DIR / $ZMCP_LUA_DIR)")
    p.add_argument("--ssh", metavar="USER@HOST", help="reach --lua-dir on a remote host over ssh (persistent ControlMaster); default $ZOMBOID_SSH / $ZMCP_SSH")
    p.add_argument("--ssh-port", type=int, metavar="PORT")
    p.add_argument("--ssh-identity", metavar="KEYFILE")
    p.add_argument("--ssh-opt", action="append", default=[], metavar="OPT", help="extra `ssh -o OPT` (repeatable)")
    p.add_argument("--console-container", metavar="NAME", help="docker container running the dedicated server; enables server_console via its FIFO (default $ZMCP_CONTAINER)")
    p.add_argument("--console-fifo", metavar="PATH", default="/tmp/pz-console", help="console FIFO path (inside the container if one is given)")
    p.add_argument("--console-log", metavar="PATH", help="server-console.txt path (default: <lua-dir>/../server-console.txt)")
    p.add_argument("--poll-file", metavar="LUAFILE",
                   help="loaded server Lua file whose `reloadlua` polls the bridge while the server is paused "
                        "(default $ZMCP_POLL_FILE or %s; needs the console)" % DEFAULT_POLL_FILE)
    p.add_argument("--no-poll", action="store_true", help="never poll a paused server through the console")
    p.add_argument("--api-index", metavar="DIR", help="directory holding api_index.json.gz and lua_examples.json.gz (default: next to this script, or $ZMCP_API_INDEX)")
    p.add_argument("--docs-dir", action="append", metavar="DIR", help="extra directory of *.md files to expose as resources (repeatable)")
    p.add_argument("--timeout", type=float, default=20.0, metavar="SECONDS", help="default wait for a game response (default 20)")
    p.add_argument("--env-file", metavar="FILE", help="load KEY=VALUE defaults (ZMCP_SSH, ZMCP_LUA_DIR, ZMCP_CONTAINER, ...) from this file")
    p.add_argument("--check", action="store_true", help="print the game status as JSON and exit (connectivity test)")
    p.add_argument("--list-tools", action="store_true", help="print the tool catalogue as JSON and exit")
    p.add_argument("-v", "--verbose", action="store_true", help="log every request to stderr")
    p.add_argument("--version", action="version", version="%s %s" % (SERVER_NAME, VERSION))
    return p


def build_server(args):
    if args.env_file:
        load_env_file(args.env_file)
    ssh = args.ssh or os.environ.get("ZOMBOID_SSH") or os.environ.get("ZMCP_SSH")
    lua_dir = args.lua_dir or (os.environ.get("ZOMBOID_LUA_DIR") or os.environ.get("ZMCP_LUA_DIR") if ssh else None)
    container = args.console_container or os.environ.get("ZMCP_CONTAINER")
    console_enabled = bool(container) or args.console_fifo != "/tmp/pz-console"
    poll_file = args.poll_file or os.environ.get("ZMCP_POLL_FILE") or DEFAULT_POLL_FILE   # after --env-file
    poll_cmd = poll_command(container, args.console_fifo, poll_file) if console_enabled and not args.no_poll else None
    if ssh:
        if not lua_dir:
            sys.exit("--ssh needs --lua-dir <remote Zomboid/Lua directory> (or $ZMCP_LUA_DIR)")
        transport = SshTransport(lua_dir, ssh, port=args.ssh_port, identity=args.ssh_identity,
                                 extra_opts=[o for opt in args.ssh_opt for o in ("-o", opt)], poll_cmd=poll_cmd)
    else:
        lua_dir = os.path.expanduser(lua_dir or default_lua_dir())
        transport = LocalTransport(lua_dir, poll_cmd=poll_cmd)
    bridge = GameBridge(transport, timeout_s=args.timeout)
    if args.api_index:
        idx = os.path.expanduser(args.api_index)
        index = ApiIndex(idx if os.path.isdir(idx) else os.path.dirname(idx))
    else:
        index = ApiIndex(default_index_dir(HERE))
    console = {
        "enabled": console_enabled,
        "container": container,
        "fifo": args.console_fifo,
        "log": args.console_log or (lua_dir.rstrip("/\\").rsplit("/", 1)[0] + "/server-console.txt"
                                    if "/" in lua_dir.rstrip("/\\") else "server-console.txt"),
    }
    return ZomboidMCP(bridge, index, console=console, docs_dirs=find_docs_dirs(args.docs_dir), verbose=args.verbose)


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.list_tools:
        print(json.dumps([catalog.public(t) for t in catalog.TOOLS], indent=1))
        return 0
    server = build_server(args)
    if args.check:
        st = server.bridge.status_summary()
        print(json.dumps(st, indent=1))
        return 0 if st.get("bridge") == "live" else 1
    if args.http is not None:
        serve_http(server, args.http)
    else:
        serve_stdio(server)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
