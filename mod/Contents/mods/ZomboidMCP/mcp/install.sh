#!/usr/bin/env bash
# Zomboid MCP installer: registers the MCP server with Claude Code and installs the "zomboid-engine" skill.
#
#   mcp/install.sh [--copy] [--skill-only] [--mcp-only] [--scope local|user|project] [-- <zomboid_mcp.py args>]
#
# Examples:
#   mcp/install.sh                                    # local game: ~/Zomboid/Lua auto-detected
#   mcp/install.sh -- --env-file ~/.config/zomboid-mcp/local.env        # remote dedicated server
#   mcp/install.sh -- --ssh root@host --lua-dir /var/lib/docker/volumes/<vol>/_data/Lua --console-container <c>
#   mcp/install.sh --copy                             # copy the skill instead of symlinking it
#
# Idempotent: re-running replaces the MCP registration and refreshes the skill link/copy. Prints what it did.
# Python 3.9+ and the `claude` CLI must be on PATH (install.py is the fallback for Windows / no bash).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_DIR="$(cd "$HERE/.." && pwd)"
SERVER="$HERE/zomboid_mcp.py"
SKILL_SRC="$MOD_DIR/skill"
SKILL_DST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/zomboid-engine"
NAME="${ZMCP_MCP_NAME:-zomboid}"
SCOPE="${ZMCP_MCP_SCOPE:-user}"
MODE=symlink
DO_MCP=1
DO_SKILL=1

while [ $# -gt 0 ]; do
    case "$1" in
        --copy) MODE=copy ;;
        --skill-only) DO_MCP=0 ;;
        --mcp-only) DO_SKILL=0 ;;
        --scope) SCOPE="$2"; shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        --) shift; break ;;
        *) echo "unknown option: $1 (server arguments go after --)" >&2; exit 2 ;;
    esac
    shift
done

[ -f "$SERVER" ] || { echo "not found: $SERVER" >&2; exit 1; }
[ -f "$SKILL_SRC/SKILL.md" ] || { echo "not found: $SKILL_SRC/SKILL.md" >&2; exit 1; }
PYTHON="${PYTHON:-python3}"
command -v "$PYTHON" >/dev/null || { echo "python3 not found on PATH" >&2; exit 1; }

if [ "$DO_MCP" = 1 ]; then
    if ! command -v claude >/dev/null; then
        echo "claude CLI not found on PATH: skipping the MCP registration. Register it yourself with:" >&2
        echo "  claude mcp add -s $SCOPE $NAME -- $PYTHON \"$SERVER\" $*" >&2
    else
        if claude mcp get "$NAME" >/dev/null 2>&1; then
            claude mcp remove -s "$SCOPE" "$NAME" >/dev/null 2>&1 || claude mcp remove "$NAME" >/dev/null 2>&1 || true
            echo "mcp: replaced the existing '$NAME' registration"
        fi
        claude mcp add -s "$SCOPE" "$NAME" -- "$PYTHON" "$SERVER" "$@"
        echo "mcp: registered '$NAME' (scope $SCOPE): $PYTHON $SERVER $*"
    fi
fi

if [ "$DO_SKILL" = 1 ]; then
    mkdir -p "$(dirname "$SKILL_DST")"
    if [ "$MODE" = symlink ]; then
        if [ -L "$SKILL_DST" ] && [ "$(readlink "$SKILL_DST")" = "$SKILL_SRC" ]; then
            echo "skill: already linked: $SKILL_DST -> $SKILL_SRC"
        else
            if [ -e "$SKILL_DST" ] && [ ! -L "$SKILL_DST" ]; then
                rm -rf "$SKILL_DST"
                echo "skill: removed the old copy at $SKILL_DST"
            fi
            ln -sfn "$SKILL_SRC" "$SKILL_DST"
            echo "skill: linked $SKILL_DST -> $SKILL_SRC"
        fi
    else
        [ -L "$SKILL_DST" ] && rm -f "$SKILL_DST"
        mkdir -p "$SKILL_DST"
        if command -v rsync >/dev/null; then
            rsync -a --delete "$SKILL_SRC/" "$SKILL_DST/"
        else
            rm -rf "$SKILL_DST" && cp -R "$SKILL_SRC" "$SKILL_DST"
        fi
        echo "skill: copied $SKILL_SRC -> $SKILL_DST"
    fi
fi

echo "check the connection: $PYTHON \"$SERVER\" --check $*"
