"""Game access for the Zomboid MCP server.

Two layers, both pure stdlib:

* ``Transport`` reaches the game's Lua cache dir (``~/Zomboid/Lua`` for a local
  single-player/host game, or a directory on a remote machine over a persistent
  ssh ControlMaster for dedicated servers) and can send raw console commands.
* ``GameBridge`` speaks the file protocol implemented by ``Bridge.lua`` and
  specified in ``docs/PROTOCOL.md``:

    zmcp_req_<n>.json   request  {"n": n, "t": unixSeconds, "tool": "...", "args": {...}}   written by us
    zmcp_res_<n>.json   response {"n": n, "ok": true, "result": ...} / {"n": n, "ok": false, "error": "..."}
    zmcp_status.json    heartbeat (every 2 s and after each request): nextReq, bootId, paused, players, ...
    zmcp_events.jsonl   append-only event log

  Requests are numbered by the game's ``nextReq`` counter and executed in order
  on the server tick. A response is complete when its file ends with a newline
  (bridge >= 0.2.0) or when the game blanked the request file (bridge 0.1.0).
  We delete both files afterwards; the game never deletes anything. Request
  JSON is ASCII-only because the JVM reads it with its default charset.

Large string arguments (base64 PNGs, long Lua sources) are written to separate
``zmcp_blob_<n>_<key>.txt`` files and the argument ``<key>`` is replaced by
``<key>_file`` holding the file name (relative to the Lua dir), so the request
JSON itself stays small. Blob files are deleted with the request unless the
tool's result object contains ``"keep_files": true``.
"""

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import time

STATUS_FILE = "zmcp_status.json"
EVENTS_FILE = "zmcp_events.jsonl"
REQ_FILE = "zmcp_req_{n}.json"
RES_FILE = "zmcp_res_{n}.json"
BLOB_FILE = "zmcp_blob_{n}_{key}.txt"

STALE_AFTER_S = 5.0          # heartbeat every 2 s; PROTOCOL.md: "alive" means now - status.t < 5
LEFTOVER_MAX_AGE_S = 120.0   # req/res files older than this are deleted on resync
MAX_AHEAD = 10               # the game only probes this far past its nextReq
BLOB_THRESHOLD = 32 * 1024   # string args longer than this go to a blob file
MAX_READ = 4 * 1024 * 1024   # never pull more than this from one file in one go
DEFAULT_TIMEOUT_S = 20.0


class GameError(Exception):
    """A tool-level failure to report to the MCP client (not a protocol error)."""


def log(msg):
    sys.stderr.write("[zomboid-mcp] %s\n" % msg)
    sys.stderr.flush()


def _sh_quote(s):
    return shlex.quote(str(s))


# --------------------------------------------------------------------------- transports
class Transport(object):
    """Access to the Lua cache dir. Subclasses implement the primitive operations."""

    kind = "?"

    def __init__(self, lua_dir):
        self.lua_dir = lua_dir

    # --- primitives -------------------------------------------------------
    def read(self, name):
        """Return the text of ``name`` (relative to the Lua dir) or None when missing."""
        raise NotImplementedError

    def write(self, name, text):
        """Atomically write ``text`` to ``name``."""
        raise NotImplementedError

    def remove(self, names):
        raise NotImplementedError

    def read_from(self, path, offset, max_bytes=MAX_READ):
        """Return (bytes from ``offset``, total size). ``path`` may be relative to the Lua dir or absolute."""
        raise NotImplementedError

    def now(self):
        """Wall clock of the machine holding the Lua dir (the game writes epoch seconds in its status)."""
        return time.time()

    def roundtrip(self, n, req_text, timeout_s):
        """Write request ``n`` then wait for its response.

        Returns ``(res_text_or_None, status_text_or_None, now)``.
        """
        raise NotImplementedError

    def list_protocol_files(self):
        """Return ``([(name, age_seconds)], now)`` for the zmcp_req_*/zmcp_res_* files in the Lua dir."""
        raise NotImplementedError

    def console(self, command, container, fifo, log_path, wait_s):
        """Send a raw server console command and return the new console log output."""
        raise NotImplementedError

    def describe(self):
        return "%s %s" % (self.kind, self.lua_dir)

    # --- helpers ------------------------------------------------------------
    def resolve(self, path):
        if path.startswith("/") or (len(path) > 1 and path[1] == ":"):
            return path
        return self.lua_dir.rstrip("/\\") + "/" + path

    @staticmethod
    def response_complete(res_text, req_text):
        # Bridge >= 0.2.0 terminates the response with "\n" (the write itself is not atomic);
        # Bridge 0.1.0 blanked the request file after writing the response.
        if not res_text:
            return False
        return res_text.endswith("\n") or not req_text


class LocalTransport(Transport):
    kind = "local"

    def _p(self, name):
        return os.path.join(self.lua_dir, name) if not os.path.isabs(name) else name

    def read(self, name):
        try:
            with open(self._p(name), "rb") as f:
                return f.read(MAX_READ).decode("utf-8", "replace")
        except (IOError, OSError):
            return None

    def write(self, name, text):
        path = self._p(name)
        d = os.path.dirname(path)
        if not os.path.isdir(d):
            raise GameError("Lua dir does not exist: %s (is the game installed / has it been started once?)" % d)
        fd, tmp = tempfile.mkstemp(prefix=".zmcp_", dir=d)
        with os.fdopen(fd, "wb") as f:
            f.write(text.encode("utf-8"))
        os.replace(tmp, path)

    def remove(self, names):
        for n in names:
            try:
                os.remove(self._p(n))
            except OSError:
                pass

    def read_from(self, path, offset, max_bytes=MAX_READ):
        path = self._p(path)
        try:
            size = os.path.getsize(path)
        except OSError:
            return b"", 0
        if offset >= size:
            return b"", size
        with open(path, "rb") as f:
            f.seek(offset)
            return f.read(max_bytes), size

    def roundtrip(self, n, req_text, timeout_s):
        req, res = REQ_FILE.format(n=n), RES_FILE.format(n=n)
        self.write(req, req_text)
        deadline = time.time() + timeout_s
        while True:
            res_text = self.read(res)
            if self.response_complete(res_text, self.read(req)):
                return res_text, self.read(STATUS_FILE), time.time()
            if time.time() >= deadline:
                return None, self.read(STATUS_FILE), time.time()
            time.sleep(0.05)

    def list_protocol_files(self):
        out, now = [], time.time()
        try:
            names = os.listdir(self.lua_dir)
        except OSError:
            return out, now
        for name in names:
            if name.startswith(("zmcp_req_", "zmcp_res_")) and name.endswith(".json"):
                try:
                    out.append((name, max(0.0, now - os.path.getmtime(self._p(name)))))
                except OSError:
                    pass
        return out, now

    def console(self, command, container, fifo, log_path, wait_s):
        log_path = self._p(log_path)
        _, before = self.read_from(log_path, 0, 0)
        data = (command.rstrip("\n") + "\n").encode("utf-8")
        if container:
            cmd = ["docker", "exec", "-i", container, "sh", "-c", "cat > %s" % _sh_quote(fifo)]
            p = subprocess.run(cmd, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            if p.returncode != 0:
                raise GameError("docker exec failed (%d): %s" % (p.returncode, p.stderr.decode("utf-8", "replace").strip()))
        else:
            try:
                with open(fifo, "wb") as f:
                    f.write(data)
            except OSError as e:
                raise GameError("cannot write console FIFO %s: %s" % (fifo, e))
        time.sleep(wait_s)
        out, _ = self.read_from(log_path, before, 512 * 1024)
        return out.decode("utf-8", "replace")


class SshTransport(Transport):
    """Runs small shell scripts on the remote host over one persistent ssh connection."""

    kind = "ssh"

    def __init__(self, lua_dir, host, port=None, identity=None, control_persist="10m", extra_opts=None):
        Transport.__init__(self, lua_dir)
        self.host = host
        self.port = port
        self.identity = identity
        self.control_persist = control_persist
        self.extra_opts = list(extra_opts or [])
        self._control_path = self._pick_control_path()

    @staticmethod
    def _pick_control_path():
        d = os.path.join(os.path.expanduser("~"), ".ssh")
        if not os.path.isdir(d):
            d = tempfile.gettempdir()
        return os.path.join(d, "zmcp-cm-%C")

    def describe(self):
        return "ssh %s:%s" % (self.host, self.lua_dir)

    def _ssh_base(self):
        cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=auto",
               "-o", "ControlPath=%s" % self._control_path,
               "-o", "ControlPersist=%s" % self.control_persist,
               "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
               "-o", "LogLevel=ERROR"]
        if self.port:
            cmd += ["-p", str(self.port)]
        if self.identity:
            cmd += ["-i", self.identity]
        cmd += self.extra_opts
        cmd.append(self.host)
        return cmd

    def sh(self, script, stdin=None, timeout=None):
        """Run a POSIX shell script remotely. Returns (rc, stdout_bytes, stderr_text)."""
        cmd = self._ssh_base() + ["sh", "-c", _sh_quote(script)]
        try:
            p = subprocess.run(cmd, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=timeout)
        except subprocess.TimeoutExpired:
            raise GameError("ssh to %s timed out" % self.host)
        except FileNotFoundError:
            raise GameError("ssh binary not found; --ssh needs an OpenSSH client on this machine")
        err = p.stderr.decode("utf-8", "replace").strip()
        if p.returncode == 255:
            raise GameError("ssh connection to %s failed: %s" % (self.host, err or "exit 255"))
        return p.returncode, p.stdout, err

    def _abs(self, name):
        return self.resolve(name)

    def read(self, name):
        rc, out, _ = self.sh("cat %s 2>/dev/null" % _sh_quote(self._abs(name)), timeout=60)
        if rc != 0:
            return None
        return out.decode("utf-8", "replace")

    def write(self, name, text):
        path = self._abs(name)
        script = "cat > {t} && mv -f {t} {p}".format(t=_sh_quote(path + ".tmp"), p=_sh_quote(path))
        rc, _, err = self.sh(script, stdin=text.encode("utf-8"), timeout=120)
        if rc != 0:
            raise GameError("remote write of %s failed: %s" % (path, err))

    def remove(self, names):
        if names:
            self.sh("rm -f " + " ".join(_sh_quote(self._abs(n)) for n in names), timeout=60)

    def read_from(self, path, offset, max_bytes=MAX_READ):
        path = self._abs(path)
        script = ("f={p}; if [ -f \"$f\" ]; then wc -c < \"$f\"; tail -c +{o} \"$f\" | head -c {m}; "
                  "else echo 0; fi").format(p=_sh_quote(path), o=int(offset) + 1, m=int(max_bytes))
        rc, out, err = self.sh(script, timeout=120)
        if rc != 0:
            raise GameError("remote read of %s failed: %s" % (path, err))
        head, _, data = out.partition(b"\n")
        try:
            size = int(head.strip() or b"0")
        except ValueError:
            raise GameError("unexpected remote output while reading %s" % path)
        if offset >= size:
            return b"", size
        return data, size

    def now(self):
        rc, out, _ = self.sh("date +%s", timeout=30)
        try:
            return float(out.strip())
        except ValueError:
            return time.time()

    _MARK_OK = b"__ZMCP_OK__"
    _MARK_TIMEOUT = b"__ZMCP_TIMEOUT__"
    _MARK_STATUS = b"\n__ZMCP_STATUS__\n"
    _MARK_NOW = b"\n__ZMCP_NOW__ "

    def roundtrip(self, n, req_text, timeout_s):
        d = self.lua_dir.rstrip("/")
        req = _sh_quote("%s/%s" % (d, REQ_FILE.format(n=n)))
        res = _sh_quote("%s/%s" % (d, RES_FILE.format(n=n)))
        status = _sh_quote("%s/%s" % (d, STATUS_FILE))
        tenths = max(1, int(timeout_s * 10))
        script = (
            "cat > {req}.tmp && mv -f {req}.tmp {req} || exit 9; i=0; "
            "while :; do "
            "if [ -s {res} ] && {{ [ -z \"$(tail -c 1 {res})\" ] || ! [ -s {req} ]; }}; then echo __ZMCP_OK__; cat {res}; break; fi; "
            "i=$((i+1)); if [ $i -ge {t} ]; then echo __ZMCP_TIMEOUT__; break; fi; sleep 0.1; done; "
            "printf '\\n__ZMCP_STATUS__\\n'; cat {status} 2>/dev/null; printf '\\n__ZMCP_NOW__ %s' $(date +%s)"
        ).format(req=req, res=res, status=status, t=tenths)
        rc, out, err = self.sh(script, stdin=req_text.encode("utf-8"), timeout=timeout_s + 60)
        if rc == 9:
            raise GameError("cannot write request into %s on %s: %s" % (self.lua_dir, self.host, err))
        if rc != 0:
            raise GameError("remote request failed (%d): %s" % (rc, err))
        body, _, now_s = out.rpartition(self._MARK_NOW)
        try:
            now = float(now_s.strip())
        except ValueError:
            now = time.time()
        body, _, status_text = body.partition(self._MARK_STATUS)
        status_text = status_text.decode("utf-8", "replace").strip() or None
        body = body.strip()
        if body.startswith(self._MARK_OK):
            return body[len(self._MARK_OK):].strip().decode("utf-8", "replace"), status_text, now
        return None, status_text, now

    def list_protocol_files(self):
        d = _sh_quote(self.lua_dir.rstrip("/"))
        script = ("cd %s 2>/dev/null || exit 0; date +%%s; for f in zmcp_req_*.json zmcp_res_*.json; do "
                  "[ -e \"$f\" ] && stat -c '%%n %%Y' \"$f\"; done; exit 0") % d
        rc, out, err = self.sh(script, timeout=60)
        lines = out.decode("utf-8", "replace").split("\n")
        try:
            now = float(lines[0].strip())
        except (ValueError, IndexError):
            return [], time.time()
        files = []
        for line in lines[1:]:
            parts = line.strip().rsplit(" ", 1)
            if len(parts) == 2:
                try:
                    files.append((parts[0], max(0.0, now - float(parts[1]))))
                except ValueError:
                    pass
        return files, now

    def console(self, command, container, fifo, log_path, wait_s):
        log_path = _sh_quote(self._abs(log_path))
        if container:
            send = "docker exec -i %s sh -c %s" % (_sh_quote(container), _sh_quote("cat > %s" % _sh_quote(fifo)))
        else:
            send = "cat > %s" % _sh_quote(fifo)
        script = (
            "N=$(wc -c < {log} 2>/dev/null || echo 0); CMD=$(cat); printf '%s\\n' \"$CMD\" | {send} || exit 7; "
            "sleep {w}; tail -c +$((N+1)) {log} | head -c 524288"
        ).format(log=log_path, send=send, w=float(wait_s))
        rc, out, err = self.sh(script, stdin=command.rstrip("\n").encode("utf-8"), timeout=wait_s + 60)
        if rc == 7:
            raise GameError("could not write to the console FIFO %s%s: %s" % (
                fifo, " in container %s" % container if container else "", err))
        if rc != 0:
            raise GameError("server_console failed (%d): %s" % (rc, err))
        return out.decode("utf-8", "replace")


# --------------------------------------------------------------------------- bridge
class GameBridge(object):
    """Client side of the Bridge.lua file protocol. Thread-safe; calls are serialized."""

    def __init__(self, transport, timeout_s=DEFAULT_TIMEOUT_S):
        self.transport = transport
        self.timeout_s = timeout_s
        self.lock = threading.RLock()
        self.next_id = None
        self.boot_id = None           # status.bootId we synced against; a change means the server restarted
        self.last_status = None
        self.last_status_at = 0.0     # local monotonic time when last_status was read
        self.last_status_age = None   # heartbeat age in seconds (remote clock) when read
        self.events_cursor = None

    # --- status ------------------------------------------------------------
    def _adopt_status(self, text, now):
        if not text:
            return None
        try:
            st = json.loads(text)
        except ValueError:
            return None
        if not isinstance(st, dict):
            return None
        self.last_status = st
        self.last_status_at = time.monotonic()
        try:
            self.last_status_age = max(0.0, float(now) - float(st.get("t", 0)))
        except (TypeError, ValueError):
            self.last_status_age = None
        return st

    def read_status(self):
        """Re-read the heartbeat. Returns the dict or None if the file is missing/unparseable."""
        with self.lock:
            text = self.transport.read(STATUS_FILE)
            now = self.transport.now() if text else time.time()
            return self._adopt_status(text, now)

    def status_summary(self):
        """Status enriched with liveness info; never raises."""
        try:
            st = self.read_status()
            err = None
        except GameError as e:
            st, err = None, str(e)
        out = {"transport": self.transport.describe(), "bridge": "unknown"}
        if err:
            out["bridge"] = "unreachable"
            out["error"] = err
            return out
        if st is None:
            out["bridge"] = "not_running"
            out["hint"] = self.not_running_hint()
            return out
        age = self.last_status_age
        players = st.get("players") or []
        out.update(st)
        out["heartbeat_age_s"] = None if age is None else round(age, 1)
        if age is not None and age > STALE_AFTER_S:
            out["bridge"] = "paused" if not players else "stale"
            out["hint"] = (self.paused_hint() if not players else
                           "The bridge stopped writing its heartbeat although players are listed; "
                           "the game may have crashed, been restarted, or is saving.")
        else:
            out["bridge"] = "live"
            if st.get("paused"):
                out["hint"] = ("The game loop is paused (no players online) but the bridge still answers "
                               "requests; the world does not simulate and only areas near players exist.")
        return out

    def not_running_hint(self):
        return ("No %s in %s. Is the game (or dedicated server) running with the ZomboidMCP mod enabled, "
                "and does --lua-dir point at its Zomboid/Lua directory?" % (STATUS_FILE, self.transport.describe()))

    @staticmethod
    def paused_hint():
        return ("server paused (no players online): a dedicated server with PauseEmpty=true stops ticking when "
                "nobody is connected, so the bridge cannot execute requests. Use the wait_for tool to block until "
                "a player joins, then retry. Console commands (server_console) still work.")

    def is_live(self, max_age_s=STALE_AFTER_S):
        st = self.read_status()
        return st is not None and self.last_status_age is not None and self.last_status_age <= max_age_s

    # --- requests ------------------------------------------------------------
    def _prepare_args(self, n, args):
        """Move oversized string args into blob files. Returns (args, blob_names)."""
        blobs = []
        if not isinstance(args, dict):
            return args, blobs
        out = dict(args)
        for key, val in list(args.items()):
            if isinstance(val, str) and len(val) > BLOB_THRESHOLD:
                name = BLOB_FILE.format(n=n, key=key)
                self.transport.write(name, val)
                del out[key]
                out[key + "_file"] = name
                blobs.append(name)
        return out, blobs

    def resync(self, st=None):
        """PROTOCOL.md: n = max(status.nextReq, highest existing request + 1); drop old leftovers."""
        if st is None:
            st = self.read_status()
        if st is None:
            raise GameError("Zomboid MCP bridge is not running. " + self.not_running_hint())
        try:
            n = int(st.get("nextReq") or 1)
        except (TypeError, ValueError):
            n = 1
        files, _ = self.transport.list_protocol_files()
        stale = []
        for name, age in files:
            m = re.match(r"zmcp_(req|res)_(\d+)\.json$", name)
            if not m:
                continue
            if age > LEFTOVER_MAX_AGE_S:
                stale.append(name)
            elif m.group(1) == "req":
                n = max(n, int(m.group(2)) + 1)
        if stale:
            self.transport.remove(stale)
        self.next_id = n
        self.boot_id = st.get("bootId")
        return n

    def call(self, tool, args=None, timeout_s=None):
        """Execute a game-side tool and return its result. Raises GameError on failure."""
        timeout_s = timeout_s or self.timeout_s
        with self.lock:
            if self.next_id is None:
                self.resync()
            n = self.next_id
            args, blobs = self._prepare_args(n, args or {})
            res_text, status_text, now = self._exchange(n, tool, args, timeout_s, blobs)
            st = self._adopt_status(status_text, now)
            if res_text is None:
                # Not answered in time. Withdraw the request: it must not run whenever the server wakes up.
                self.transport.remove([REQ_FILE.format(n=n), RES_FILE.format(n=n)] + blobs)
                fresh = st is not None and self.last_status_age is not None and self.last_status_age <= STALE_AFTER_S
                if fresh and (st.get("bootId") != self.boot_id or int(st.get("nextReq") or 0) != n):
                    # The game's counter moved (restart, reload, lost response): resync and retry once.
                    old = n
                    self.resync(st)
                    log("resync: game nextReq=%s bootId=%s, we used %s; retrying %s" % (
                        st.get("nextReq"), st.get("bootId"), old, tool))
                    n = self.next_id
                    args, blobs = self._prepare_args(n, args)
                    res_text, status_text, now = self._exchange(n, tool, args, timeout_s, blobs)
                    st = self._adopt_status(status_text, now)
                    if res_text is None:
                        self.transport.remove([REQ_FILE.format(n=n), RES_FILE.format(n=n)] + blobs)
                        raise GameError(self._timeout_message(st, tool, timeout_s))
                else:
                    raise GameError(self._timeout_message(st, tool, timeout_s))
            res = self._parse_response(n, res_text, blobs)
            keep = isinstance(res.get("result"), dict) and res["result"].get("keep_files")
            self.transport.remove([REQ_FILE.format(n=n), RES_FILE.format(n=n)] + ([] if keep else blobs))
            self.next_id = n + 1
            if st is not None:
                try:
                    self.next_id = max(self.next_id, int(st.get("nextReq") or 0))
                except (TypeError, ValueError):
                    pass
                if self.boot_id is not None and st.get("bootId") not in (None, self.boot_id):
                    self.boot_id = st.get("bootId")   # restarted between requests: trust its counter
                    self.next_id = int(st.get("nextReq") or self.next_id)
            if res.get("ok"):
                return res.get("result")
            raise GameError(self._game_error_message(res.get("error"), tool))

    def _exchange(self, n, tool, args, timeout_s, blobs):
        req_text = json.dumps({"n": n, "t": round(time.time(), 3), "tool": tool, "args": args}, ensure_ascii=True)
        try:
            return self.transport.roundtrip(n, req_text, timeout_s)
        except GameError:
            self.transport.remove(blobs)
            raise

    def _parse_response(self, n, res_text, blobs):
        try:
            res = json.loads(res_text)
        except ValueError:
            # We read the file while the game was still flushing it: wait for the terminating newline.
            deadline = time.time() + 2.0
            res = None
            while time.time() < deadline:
                time.sleep(0.1)
                text = self.transport.read(RES_FILE.format(n=n)) or ""
                if text.endswith("\n"):
                    try:
                        res = json.loads(text)
                        break
                    except ValueError:
                        pass
            if res is None:
                self.transport.remove([REQ_FILE.format(n=n), RES_FILE.format(n=n)] + blobs)
                raise GameError("unreadable response from the game for request %d: %r" % (n, res_text[:200]))
        if not isinstance(res, dict):
            self.transport.remove([REQ_FILE.format(n=n), RES_FILE.format(n=n)] + blobs)
            raise GameError("malformed response from the game: %r" % res_text[:200])
        return res

    def _timeout_message(self, st, tool, timeout_s):
        if st is None:
            return "no answer from the game after %.0fs and no heartbeat file: %s" % (timeout_s, self.not_running_hint())
        players = st.get("players") or []
        age = self.last_status_age
        if age is not None and age > STALE_AFTER_S:
            if not players:
                return "%s (heartbeat is %.0fs old, tool %s not executed)" % (self.paused_hint(), age, tool)
            return ("the game bridge is not responding (heartbeat %.0fs old, %d player(s) listed): the server may be "
                    "saving, frozen or restarting; retry in a few seconds" % (age, len(players)))
        return ("tool %s did not finish within %.0fs although the bridge is alive: the request may be stuck behind "
                "a long-running one, or the tool is blocking the server tick (bridge nextReq=%s, paused=%s). "
                "Check events_poll for tool errors." % (tool, timeout_s, st.get("nextReq"), st.get("paused")))

    @staticmethod
    def _game_error_message(err, tool):
        err = str(err)
        if err.startswith("unknown tool"):
            return ("%s. The running mod does not implement the game side of '%s' (older mod version or module "
                    "not loaded). Script it with run_lua_server instead, or add the tool with script_install." % (err, tool))
        return err

    # --- events --------------------------------------------------------------
    def events(self, cursor=None, limit=100, kinds=None, tail_bytes=256 * 1024):
        """Read events since ``cursor`` (byte offset). Returns dict(events, cursor, size, truncated)."""
        with self.lock:
            if cursor is None:
                cursor = self.events_cursor
            if cursor is None:
                # first call: the tail of the file, then continue from its end
                _, size = self.transport.read_from(EVENTS_FILE, 0, 0)
                cursor = max(0, size - tail_bytes)
                if cursor > 0:               # we landed mid-line: skip to the next line start
                    head, _ = self.transport.read_from(EVENTS_FILE, cursor, 64 * 1024)
                    nl = head.find(b"\n")
                    cursor += (nl + 1) if nl >= 0 else len(head)
            data, size = self.transport.read_from(EVENTS_FILE, cursor, MAX_READ)
            truncated = False
            if size < cursor:            # the file was rotated/truncated: start over
                cursor, truncated = 0, True
                data, size = self.transport.read_from(EVENTS_FILE, 0, MAX_READ)
            events = []
            lines = data.split(b"\n")
            if data.endswith(b"\n"):
                lines.pop()                      # trailing empty piece
                consumed = len(data)
            else:
                partial = lines.pop()            # incomplete last line: leave it for next time
                consumed = len(data) - len(partial)
            for line in lines:
                s = line.strip()
                if not s:
                    continue
                try:
                    ev = json.loads(s.decode("utf-8", "replace"))
                except ValueError:
                    ev = {"kind": "unparsed", "data": s.decode("utf-8", "replace")}
                if kinds and ev.get("kind") not in kinds:
                    continue
                events.append(ev)
            new_cursor = min(cursor + consumed, size)
            self.events_cursor = new_cursor
            if limit and len(events) > limit:
                events = events[-limit:]
            return {"events": events, "cursor": new_cursor, "size": size, "truncated": truncated}

    # --- console ---------------------------------------------------------------
    def console(self, command, container, fifo, log_path, wait_s=2.0):
        with self.lock:
            return self.transport.console(command, container, fifo, log_path, wait_s)


# --------------------------------------------------------------------------- discovery
def default_lua_dir():
    """Best guess for the local game's Lua cache dir."""
    env = os.environ.get("ZOMBOID_LUA_DIR") or os.environ.get("ZMCP_LUA_DIR")
    if env:
        return os.path.expanduser(env)
    home = os.path.expanduser("~")
    candidates = [os.path.join(home, "Zomboid", "Lua")]
    if sys.platform.startswith("win"):
        up = os.environ.get("USERPROFILE")
        if up:
            candidates.insert(0, os.path.join(up, "Zomboid", "Lua"))
    for c in candidates:
        if os.path.isdir(c):
            return c
    return candidates[0]
