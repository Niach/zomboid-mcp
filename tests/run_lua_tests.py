#!/usr/bin/env python3
"""Run the Lua unit tests (tests/*_test.lua) under a standalone Lua 5.1.

Runtime, in order of preference: a `lua5.1` or `luajit` binary on PATH, otherwise the `lupa` Python
package (pip install lupa; it bundles Lua 5.1 and LuaJIT). No Project Zomboid needed.
"""
import glob
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run_with_binary(binary, test):
    p = subprocess.run([binary, test], cwd=ROOT, capture_output=True, text=True)
    sys.stdout.write(p.stdout)
    sys.stderr.write(p.stderr)
    return p.returncode == 0


def run_with_lupa(test):
    try:
        from lupa.lua51 import LuaRuntime
    except ImportError:
        try:
            from lupa.luajit21 import LuaRuntime
        except ImportError:
            from lupa import LuaRuntime
    L = LuaRuntime(unpack_returned_tuples=True)
    # arg[0] tells the test where the repo root is
    L.execute(f'arg = {{ [0] = "{ROOT}/tests/{os.path.basename(test)}" }}')
    ok = L.eval("function(path) local f, e = loadfile(path) if not f then print(e) return false end local ok, err = pcall(f) if not ok then print(err) end return ok end")(test)
    return bool(ok)


def main():
    tests = sorted(glob.glob(os.path.join(ROOT, "tests", "*_test.lua")))
    binary = next((b for b in ("lua5.1", "luajit", "lua") if shutil.which(b)), None)
    ok_all = True
    for t in tests:
        if binary:
            ok = run_with_binary(binary, t)
        else:
            try:
                import lupa  # noqa: F401
            except ImportError:
                print("no lua5.1/luajit binary and no lupa module; pip install lupa (or use .venv/bin/python)", file=sys.stderr)
                return 2
            ok = run_with_lupa(t)
        ok_all = ok_all and ok
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
