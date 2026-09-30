#!/usr/bin/env python3
"""Zomboid MCP installer (cross-platform fallback for install.sh; the same behaviour on Windows).

    python3 mcp/install.py [--copy] [--skill-only] [--mcp-only] [--scope local|user|project] [-- <zomboid_mcp.py args>]

Registers `zomboid` with Claude Code (`claude mcp add`) and installs the skill into ~/.claude/skills/zomboid-engine
(symlink where possible, copy on Windows or with --copy). Idempotent; prints what it did.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MOD_DIR = os.path.dirname(HERE)
SERVER = os.path.join(HERE, "zomboid_mcp.py")
SKILL_SRC = os.path.join(MOD_DIR, "skill")
SKILL_DST = os.path.join(os.environ.get("CLAUDE_SKILLS_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "skills"),
                         "zomboid-engine")
NAME = os.environ.get("ZMCP_MCP_NAME", "zomboid")


def main(argv):
    scope = os.environ.get("ZMCP_MCP_SCOPE", "user")
    mode = "copy" if os.name == "nt" else "symlink"
    do_mcp = do_skill = True
    server_args = []
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--copy":
            mode = "copy"
        elif a == "--skill-only":
            do_mcp = False
        elif a == "--mcp-only":
            do_skill = False
        elif a == "--scope":
            scope = args.pop(0)
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        elif a == "--":
            server_args = args
            break
        else:
            print("unknown option: %s (server arguments go after --)" % a, file=sys.stderr)
            return 2
    if not os.path.isfile(SERVER) or not os.path.isfile(os.path.join(SKILL_SRC, "SKILL.md")):
        print("mod files missing next to this script", file=sys.stderr)
        return 1
    python = sys.executable or "python3"
    if do_mcp:
        claude = shutil.which("claude")
        if not claude:
            print("claude CLI not found on PATH: register the MCP yourself with:\n  claude mcp add -s %s %s -- %s %s %s"
                  % (scope, NAME, python, SERVER, " ".join(server_args)), file=sys.stderr)
        else:
            if subprocess.run([claude, "mcp", "get", NAME], capture_output=True).returncode == 0:
                subprocess.run([claude, "mcp", "remove", "-s", scope, NAME], capture_output=True)
                subprocess.run([claude, "mcp", "remove", NAME], capture_output=True)
                print("mcp: replaced the existing '%s' registration" % NAME)
            subprocess.run([claude, "mcp", "add", "-s", scope, NAME, "--", python, SERVER] + server_args, check=True)
            print("mcp: registered '%s' (scope %s): %s %s %s" % (NAME, scope, python, SERVER, " ".join(server_args)))
    if do_skill:
        os.makedirs(os.path.dirname(SKILL_DST), exist_ok=True)
        if mode == "symlink":
            if os.path.islink(SKILL_DST) and os.path.realpath(SKILL_DST) == os.path.realpath(SKILL_SRC):
                print("skill: already linked: %s -> %s" % (SKILL_DST, SKILL_SRC))
            else:
                if os.path.islink(SKILL_DST):
                    os.remove(SKILL_DST)
                elif os.path.isdir(SKILL_DST):
                    shutil.rmtree(SKILL_DST)
                    print("skill: removed the old copy at %s" % SKILL_DST)
                try:
                    os.symlink(SKILL_SRC, SKILL_DST, target_is_directory=True)
                    print("skill: linked %s -> %s" % (SKILL_DST, SKILL_SRC))
                except OSError:
                    mode = "copy"
        if mode == "copy":
            if os.path.islink(SKILL_DST):
                os.remove(SKILL_DST)
            if os.path.isdir(SKILL_DST):
                shutil.rmtree(SKILL_DST)
            shutil.copytree(SKILL_SRC, SKILL_DST)
            print("skill: copied %s -> %s" % (SKILL_SRC, SKILL_DST))
    print("check the connection: %s %s --check %s" % (python, SERVER, " ".join(server_args)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
