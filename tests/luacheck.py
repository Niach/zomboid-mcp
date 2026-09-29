#!/usr/bin/env python3
"""Syntax-check Lua files with a standalone Lua 5.1 (pip install lupa). Usage: tests/luacheck.py [files...]"""
import os, sys, glob
from lupa import lua51
rt = lua51.LuaRuntime()
check = rt.eval("function(s, n) local f, e = loadstring(s, n) return f ~= nil, e end")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
files = sys.argv[1:] or sorted(glob.glob(os.path.join(ROOT, "mod/Contents/mods/ZomboidMCP/42/media/lua/**/*.lua"), recursive=True) + glob.glob(os.path.join(ROOT, "dev/**/*.lua"), recursive=True))
bad = 0
for f in files:
    ok, err = check(open(f).read(), "=" + f)
    print(("OK   " if ok else "FAIL ") + f + ("" if ok else "  " + str(err)))
    bad += 0 if ok else 1
sys.exit(1 if bad else 0)
