#!/bin/bash
# Dev helpers for testing the mod's server Lua on the live server WITHOUT installing the mod:
#   tools/zmcp_dev.sh bundle            build /tmp/zmcp_bundle.lua (Json + Bridge + Api/*, require lines stripped)
#   tools/zmcp_dev.sh load              bundle + load it on the live server through `tools/pz run` (needs a player online)
#   tools/zmcp_dev.sh call <tool> [json] send one bridge request (zmcp_req_<n>.json) and print the response
#   tools/zmcp_dev.sh status            print zmcp_status.json
#   tools/zmcp_dev.sh events [n]        tail zmcp_events.jsonl
# Requires ~/.config/zomboid-mcp/local.env (ZMCP_SSH, ZMCP_VOLUME).
[ -f ~/.config/zomboid-mcp/local.env ] && . ~/.config/zomboid-mcp/local.env
H=$ZMCP_SSH; V=$ZMCP_VOLUME
DIR=$(dirname "$(readlink -f "$0")")/..
LUA=$DIR/mod/Contents/mods/ZomboidMCP/42/media/lua
BUNDLE=/tmp/zmcp_bundle.lua

bundle() {
  {
    for f in "$LUA/shared/ZomboidMCP/Json.lua" "$LUA/server/ZomboidMCP/Bridge.lua" "$LUA/server/ZomboidMCP/Api/Common.lua" \
             "$LUA"/server/ZomboidMCP/Api/TileSheets.lua "$LUA"/server/ZomboidMCP/Api/[A-SU-Z]*.lua; do
      echo "-- ==== $(basename "$f")"
      grep -v '^require "ZomboidMCP' "$f" | grep -v '^return J$'
    done
    echo 'return "zmcp bundle loaded, tools=" .. (function() local n = 0 for _ in pairs(ZMCP.tools) do n = n + 1 end return n end)()'
  } > "$BUNDLE"
  echo "bundle: $BUNDLE ($(wc -l < "$BUNDLE") lines)"
}

case "$1" in
  bundle) bundle ;;
  load) bundle && "$DIR/tools/pz" run "$BUNDLE" ;;
  call)
    TOOL=$2; ARGS=${3:-{\}}
    N=$(ssh $H "python3 -c \"import json;print(json.load(open('$V/Lua/zmcp_status.json'))['nextReq'])\" 2>/dev/null || echo 1")
    # skip ids that already have a response file (previous runs)
    while ssh $H "test -s $V/Lua/zmcp_res_$N.json"; do N=$((N+1)); done
    printf '{"tool":"%s","args":%s}' "$TOOL" "$ARGS" | ssh $H "cat > $V/Lua/zmcp_req_$N.json.tmp && mv $V/Lua/zmcp_req_$N.json.tmp $V/Lua/zmcp_req_$N.json"
    for i in $(seq 1 40); do
      OUT=$(ssh $H "cat $V/Lua/zmcp_res_$N.json 2>/dev/null")
      if [ -n "$OUT" ]; then echo "$OUT" | python3 -m json.tool 2>/dev/null || echo "$OUT"; ssh $H "rm -f $V/Lua/zmcp_req_$N.json $V/Lua/zmcp_res_$N.json"; exit 0; fi
      sleep 0.5
    done
    echo "timeout waiting for zmcp_res_$N.json (server paused? no player online?)"; exit 1 ;;
  status) ssh $H "cat $V/Lua/zmcp_status.json"; echo ;;
  events) ssh $H "tail -${2:-15} $V/Lua/zmcp_events.jsonl" ;;
  *) sed -n 2,8p "$0" ;;
esac
