#!/usr/bin/env python3
"""Dev-only bridge client for a LOCAL game (~/Zomboid/Lua). Usage:
  dev/zmcp_local.py call <tool> ['{"json": "args"}']
  dev/zmcp_local.py eval '<lua>'
  dev/zmcp_local.py status | events [n]
Numbering follows docs/PROTOCOL.md: n = max(status.nextReq, highest existing request + 1)."""
import glob, json, os, re, sys, time
LUA = os.path.expanduser("~/Zomboid/Lua")

def status():
    try:
        return json.load(open(os.path.join(LUA, "zmcp_status.json")))
    except Exception:
        return {}

def next_n():
    n = int(status().get("nextReq", 1) or 1)
    for f in glob.glob(os.path.join(LUA, "zmcp_req_*.json")):
        m = re.search(r"zmcp_req_(\d+)\.json$", f)
        if m and os.path.getsize(f) > 0:
            n = max(n, int(m.group(1)) + 1)
    return n

def call(tool, args=None, timeout=15):
    n = next_n()
    req = os.path.join(LUA, f"zmcp_req_{n}.json")
    res = os.path.join(LUA, f"zmcp_res_{n}.json")
    tmp = req + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"n": n, "t": time.time(), "tool": tool, "args": args or {}}, f, ensure_ascii=True)
    os.rename(tmp, req)
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.exists(res):
            text = open(res).read()
            if text.strip():
                try:
                    out = json.loads(text)
                except json.JSONDecodeError:
                    time.sleep(0.05); continue
                for p in (req, res):
                    try: os.remove(p)
                    except OSError: pass
                return out
        time.sleep(0.05)
    try: os.remove(req)
    except OSError: pass
    return {"ok": False, "error": f"timeout after {timeout}s (status age {time.time() - status().get('t', 0):.1f}s)"}

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        print(json.dumps(status(), indent=1))
    elif cmd == "events":
        lines = open(os.path.join(LUA, "zmcp_events.log")).read().splitlines()
        print("\n".join(lines[-int(sys.argv[2] if len(sys.argv) > 2 else 10):]))
    elif cmd == "eval":
        print(json.dumps(call("lua_eval", {"code": sys.argv[2]}), indent=1))
    elif cmd == "call":
        args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
        print(json.dumps(call(sys.argv[2], args), indent=1))
