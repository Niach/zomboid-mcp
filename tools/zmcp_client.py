#!/usr/bin/env python3
"""Reference client for the Zomboid MCP file bridge (docs/PROTOCOL.md). Pure stdlib.

Library:
    from zmcp_client import Client
    c = Client.from_env()            # ZMCP_SSH + ZMCP_LUA_DIR, or ZMCP_LUA_DIR alone for a local game
    c.call("ping")                   # -> result or raises BridgeError
    c.status()                       # -> dict from zmcp_status.json (None if missing)

CLI (env from ~/.config/zomboid-mcp/local.env, tools/pz sources it):
    zmcp_client.py [--ssh HOST] [--dir LUA_DIR] [--timeout S] call <tool> [json-args]
    zmcp_client.py ... eval "<lua>"
    zmcp_client.py ... status | events [n] | bench [n]
"""
import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time

REQ, RES = "zmcp_req_", "zmcp_res_"
DEFAULT_TIMEOUT = 10.0
STALE_STATUS = 5.0        # status older than this: bridge not running
CLEANUP_MINUTES = 2       # leftover req/res files older than this are deleted on resync
MAX_AHEAD = 10            # never run further ahead of status.nextReq than the server probes (PROTOCOL.md)
POLL_AFTER = 3.0          # heartbeat older than this: the game loop is paused, trigger a poll (ZMCP_POLL_CMD)


class BridgeError(Exception):
    """Tool error (ok=false) or transport/timeout problem."""


class Timeout(BridgeError):
    pass


# ---------------------------------------------------------------- transports
class LocalTransport:
    """Direct file access (single player / host on this machine)."""

    def __init__(self, lua_dir, poll_cmd=None):
        self.dir = os.path.expanduser(lua_dir)
        self.poll_cmd = poll_cmd

    def status_age(self):
        try:
            return time.time() - os.path.getmtime(self._p("zmcp_status.json"))
        except OSError:
            return 1e9

    def says_paused(self):
        return '"paused":true' in (self.read("zmcp_status.json") or "")

    def poll(self):
        """Ask a paused server to run one bridge pass (no-op without a poll command)."""
        if self.poll_cmd:
            subprocess.Popen(self.poll_cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        return False

    def _p(self, name):
        return os.path.join(self.dir, name)

    def read(self, name):
        try:
            with open(self._p(name), "r", encoding="utf-8", errors="replace") as f:
                return f.read()
        except FileNotFoundError:
            return None

    def request(self, n, text, timeout):
        tmp, req, res = self._p(f"{REQ}{n}.json.tmp"), self._p(f"{REQ}{n}.json"), self._p(f"{RES}{n}.json")
        with open(tmp, "w", encoding="ascii") as f:
            f.write(text)
        os.replace(tmp, req)
        if self.status_age() > POLL_AFTER or self.says_paused():
            self.poll()
        deadline = time.time() + timeout
        while time.time() < deadline:
            body = self.read(f"{RES}{n}.json")
            if body and body.endswith("\n"):
                for p in (req, res):
                    try:
                        os.remove(p)
                    except OSError:
                        pass
                return body
            time.sleep(0.02)
        try:
            os.remove(req)      # withdraw
        except OSError:
            pass
        return None

    def resync_info(self):
        status = self.read("zmcp_status.json")
        names = os.listdir(self.dir)
        now = time.time()
        for name in names:
            if re.match(r"zmcp_re[qs]_\d+\.json(\.tmp)?$", name):
                try:
                    if now - os.path.getmtime(self._p(name)) > CLEANUP_MINUTES * 60:
                        os.remove(self._p(name))
                except OSError:
                    pass
        return status, names

    def tail(self, name, n):
        text = self.read(name) or ""
        return "\n".join(text.splitlines()[-n:])

    def remove(self, names):
        for name in names:
            try:
                os.remove(self._p(name))
            except OSError:
                pass

    def put(self, name, text):
        tmp = self._p(name + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, self._p(name))


class SshTransport:
    """Files on a remote host. One ssh exec per request (write, poll, cat, delete) over a ControlMaster."""

    def __init__(self, host, lua_dir, ssh_opts=None, poll_cmd=None):
        self.host, self.dir = host, lua_dir
        self.poll_cmd = poll_cmd      # runs on the remote host when the heartbeat is stale
        ctl_dir = os.path.expanduser("~/.ssh") if os.path.isdir(os.path.expanduser("~/.ssh")) else "/tmp"
        self.base = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlMaster=auto",
                     "-o", f"ControlPath={ctl_dir}/zmcp-%C", "-o", "ControlPersist=600"] + (ssh_opts or []) + [host]

    def _sh(self, script, stdin=None, timeout=60):
        p = subprocess.run(self.base + ["sh", "-c", shlex.quote(script)], input=stdin, capture_output=True,
                           text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr

    def read(self, name):
        rc, out, _ = self._sh(f'cat {shlex.quote(self.dir + "/" + name)} 2>/dev/null')
        return out if rc == 0 else None

    def status_age(self):
        _, out, _ = self._sh(f'echo $(( $(date +%s) - $(stat -c %Y {shlex.quote(self.dir + "/zmcp_status.json")} 2>/dev/null || echo 0) ))')
        try:
            return float(out.strip())
        except ValueError:
            return 1e9

    def poll(self):
        if self.poll_cmd:
            self._sh(self.poll_cmd)
            return True
        return False

    def request(self, n, text, timeout):
        d = shlex.quote(self.dir)
        ticks = max(1, int(timeout / 0.05))
        # paused game loop: nothing ticks, so ask the server to poll (heartbeat stale, or it says paused)
        poll = (f"if [ $(( $(date +%s) - $(stat -c %Y \"$D/zmcp_status.json\" 2>/dev/null || echo 0) )) -gt {int(POLL_AFTER)} ] "
                f"|| grep -q '\"paused\":true' \"$D/zmcp_status.json\" 2>/dev/null; then ({self.poll_cmd}) >/dev/null 2>&1 & fi") if self.poll_cmd else ""
        script = f"""
D={d}; N={n}
umask 022
cat > "$D/{REQ}$N.json.tmp" && mv -f "$D/{REQ}$N.json.tmp" "$D/{REQ}$N.json" || exit 4
{poll}
i=0
while [ $i -lt {ticks} ]; do
  f="$D/{RES}$N.json"
  if [ -s "$f" ] && [ -z "$(tail -c1 "$f")" ]; then cat "$f"; rm -f "$f" "$D/{REQ}$N.json"; exit 0; fi
  sleep 0.05; i=$((i+1))
done
rm -f "$D/{REQ}$N.json"
exit 3
"""
        rc, out, err = self._sh(script, stdin=text, timeout=timeout + 15)
        if rc == 0:
            return out
        if rc == 3:
            return None
        raise BridgeError(f"ssh transport failed (rc={rc}): {err.strip() or out.strip()}")

    def resync_info(self):
        d = shlex.quote(self.dir)
        script = (f'find {d} -maxdepth 1 -regex ".*/zmcp_re[qs]_[0-9]+\\.json\\(\\.tmp\\)?" -mmin +{CLEANUP_MINUTES} -delete 2>/dev/null; '
                  f'cat {d}/zmcp_status.json 2>/dev/null; echo; echo "--- ls"; ls {d}')
        rc, out, err = self._sh(script)
        if rc != 0 and "--- ls" not in out:
            raise BridgeError(f"ssh failed: {err.strip()}")
        status, _, listing = out.partition("--- ls\n")
        return (status.strip() or None), listing.split()

    def tail(self, name, n):
        _, out, _ = self._sh(f'tail -n {int(n)} {shlex.quote(self.dir + "/" + name)} 2>/dev/null')
        return out

    def remove(self, names):
        if names:
            self._sh("rm -f " + " ".join(shlex.quote(self.dir + "/" + n) for n in names))

    def put(self, name, text):
        q = shlex.quote(self.dir + "/" + name)
        rc, _, err = self._sh(f'umask 022; cat > {q}.tmp && mv -f {q}.tmp {q}', stdin=text)
        if rc != 0:
            raise BridgeError(f"upload {name} failed: {err.strip()}")


# ---------------------------------------------------------------- client
class Client:
    def __init__(self, transport, timeout=DEFAULT_TIMEOUT):
        self.t = transport
        self.timeout = timeout
        self.n = None            # next request number, None = needs resync
        self.synced_next = None  # status.nextReq at the last resync

    @classmethod
    def from_env(cls, ssh=None, lua_dir=None, timeout=DEFAULT_TIMEOUT, poll_cmd=None):
        """ZMCP_SSH, ZMCP_LUA_DIR and ZMCP_POLL_CMD (or ZMCP_CONTAINER + ZMCP_POLL_FILE) from the environment."""
        ssh = ssh or os.environ.get("ZMCP_SSH")
        lua_dir = lua_dir or os.environ.get("ZMCP_LUA_DIR") or os.path.expanduser("~/Zomboid/Lua")
        poll_cmd = poll_cmd or os.environ.get("ZMCP_POLL_CMD")
        if not poll_cmd and os.environ.get("ZMCP_CONTAINER"):
            poll_file = os.environ.get("ZMCP_POLL_FILE", "ZomboidMCP/ZMCPPoll.lua")
            poll_cmd = f"echo 'reloadlua {poll_file}' | docker exec -i {os.environ['ZMCP_CONTAINER']} sh -c 'cat > /tmp/pz-console'"
        t = SshTransport(ssh, lua_dir, poll_cmd=poll_cmd) if ssh else LocalTransport(lua_dir, poll_cmd=poll_cmd)
        return cls(t, timeout)

    # -- status / events
    def status(self, refresh=True):
        """zmcp_status.json as a dict. With refresh, a stale heartbeat (paused server) is refreshed by a poll."""
        if refresh and self.t.poll_cmd and self.t.status_age() > POLL_AFTER and self.t.poll():
            deadline = time.time() + 3
            while time.time() < deadline and self.t.status_age() > POLL_AFTER:
                time.sleep(0.1)
        text = self.t.read("zmcp_status.json")
        if not text:
            return None
        try:
            return json.loads(text)
        except ValueError:
            return None

    def events(self, n=20):
        out = []
        for line in self.t.tail("zmcp_events.log", n).splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out

    # -- numbering
    def resync(self):
        status_text, names = self.t.resync_info()
        status = None
        if status_text:
            try:
                status = json.loads(status_text)
            except ValueError:
                status = None
        next_req = int(status.get("nextReq", 1)) if status else 1
        highest, dead = 0, []
        for name in names:
            m = re.match(r"zmcp_re[qs]_(\d+)\.json$", name)
            if not m:
                continue
            k = int(m.group(1))
            if next_req <= k < next_req + MAX_AHEAD and name.startswith(REQ):
                highest = max(highest, k)      # still reachable by the server's gap probe: keep it
            else:
                dead.append(name)              # already consumed, or beyond the probe window: never processed
        self.t.remove(dead)
        self.n = max(next_req, highest + 1)
        self.synced_next = next_req
        return status

    def _explain_timeout(self, n, tool):
        status = self.status(refresh=False)
        now = time.time()
        if not status or now - float(status.get("t", 0)) > STALE_STATUS:
            age = "missing" if not status else f"{now - float(status['t']):.0f} s old"
            if self.t.poll_cmd:
                return (f"no answer for request {n} ({tool}): the game loop is paused (no players online) and the "
                        f"poll command did not wake the bridge, or the bridge is not loaded (heartbeat {age}); "
                        f"check tools/pz log, then tools/pz load")
            return (f"no answer for request {n} ({tool}): heartbeat {age}. Either the server is paused (no players "
                    f"online; configure ZMCP_POLL_CMD, see docs/PROTOCOL.md) or the bridge is not loaded (tools/pz load)")
        if int(status.get("nextReq", 0)) > n:
            return f"response for request {n} ({tool}) was lost (server nextReq={status['nextReq']})"
        return (f"no answer for request {n} ({tool}) within the timeout; server nextReq={status.get('nextReq')}, "
                f"tps={status.get('tps')}, bootId={status.get('bootId')}")

    # -- calls
    def call(self, tool, args=None, timeout=None):
        """Execute a tool. Returns the result; raises BridgeError with the server's message on ok=false."""
        timeout = timeout or self.timeout
        if self.n is None or (self.synced_next is not None and self.n - self.synced_next >= MAX_AHEAD):
            self.resync()
        for attempt in (1, 2):
            n = self.n
            self.n += 1
            req = json.dumps({"n": n, "t": time.time(), "tool": tool, "args": args or {}}, ensure_ascii=True)
            body = self.t.request(n, req, timeout)
            if body is not None:
                try:
                    res = json.loads(body)
                except ValueError as e:
                    raise BridgeError(f"bad response json for request {n}: {e}: {body[:200]!r}")
                if res.get("ok"):
                    return res.get("result")
                raise BridgeError(res.get("error", "unknown error"))
            # timeout: figure out why, resync once and retry if our number was simply unreachable
            reason = self._explain_timeout(n, tool)
            status = self.resync()
            if attempt == 1 and status and time.time() - float(status.get("t", 0)) <= STALE_STATUS and self.n != n + 1:
                continue     # numbering was off (server restarted with another counter): retry at the fresh number
            raise Timeout(reason)

    def eval(self, code, timeout=None):
        return self.call("lua_eval", {"code": code}, timeout)


# ---------------------------------------------------------------- CLI
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ssh", default=os.environ.get("ZMCP_SSH"), help="user@host (env ZMCP_SSH); omit for a local game")
    ap.add_argument("--dir", default=os.environ.get("ZMCP_LUA_DIR"), help="Lua cache dir on that host (env ZMCP_LUA_DIR)")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    ap.add_argument("--local", action="store_true", help="ignore ZMCP_SSH, use --dir on this machine")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("call"); p.add_argument("tool"); p.add_argument("args", nargs="?", default="{}")
    p = sub.add_parser("eval"); p.add_argument("code")
    sub.add_parser("status")
    p = sub.add_parser("events"); p.add_argument("n", nargs="?", type=int, default=20)
    p = sub.add_parser("bench"); p.add_argument("n", nargs="?", type=int, default=10)
    a = ap.parse_args(argv)

    c = Client.from_env(ssh=None if a.local else a.ssh, lua_dir=a.dir, timeout=a.timeout)
    try:
        if a.cmd == "status":
            s = c.status()
            if s is None:
                print("no status file", file=sys.stderr); return 2
            s["_age"] = round(time.time() - float(s.get("t", 0)), 1)
            print(json.dumps(s, indent=2))
        elif a.cmd == "events":
            for e in c.events(a.n):
                print(json.dumps(e))
        elif a.cmd == "call":
            print(json.dumps(c.call(a.tool, json.loads(a.args)), indent=2))
        elif a.cmd == "eval":
            print(json.dumps(c.eval(a.code), indent=2))
        elif a.cmd == "bench":
            times = []
            for _ in range(a.n):
                t0 = time.time(); c.call("ping"); times.append(time.time() - t0)
            print(f"ping x{a.n}: min {min(times)*1000:.0f} ms, avg {sum(times)/len(times)*1000:.0f} ms, max {max(times)*1000:.0f} ms")
    except BridgeError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
