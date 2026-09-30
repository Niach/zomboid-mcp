#!/bin/bash
# Sync the server-side Lua of the mod to the dev bind mount on the game host, for hot reload without a
# Workshop upload or restart. Reads ~/.config/zomboid-mcp/local.env (ZMCP_SSH, ZMCP_DEV_LUA_MOUNT).
#
#   tools/deploy_server.sh            sync mod/.../lua/server/ZomboidMCP (+ shared Json.lua) -> $ZMCP_SSH:$ZMCP_DEV_LUA_MOUNT/ZomboidMCP
#   tools/deploy_server.sh --reload   ... then `reloadlua ZomboidMCP/Bridge.lua` on the console (mount must exist, see below)
#   tools/deploy_server.sh --dry-run  show what would change
#
# Bind mount needed in the container (a compose change: owner only, see docs/PLAN.md step 6 / ZOM deploy):
#   /opt/zomboid-lua/ZomboidMCP -> /home/steam/pz-dedicated/media/lua/server/ZomboidMCP  (read-only)
# It replaces the old /opt/zomboid-lua/vapps mount. Files there load at server start like vanilla server
# Lua, and `reloadlua ZomboidMCP/<file>.lua` re-runs one of them live. Until the mount exists, use
# `tools/pz load` (loadstring through the Lua cache dir) to get the same files into the running server.
# Note for that deploy: when the Workshop mod is also enabled on the server, its copy of Bridge.lua loads
# after the mounted one (mods load after vanilla dirs); run `reloadlua ZomboidMCP/Bridge.lua` after the
# restart so the mounted (dev) version wins again.
set -euo pipefail
[ -f ~/.config/zomboid-mcp/local.env ] && . ~/.config/zomboid-mcp/local.env
: "${ZMCP_SSH:?set ZMCP_SSH in ~/.config/zomboid-mcp/local.env}"
MOUNT=${ZMCP_DEV_LUA_MOUNT:-/opt/zomboid-lua}
DIR=$(dirname "$(readlink -f "$0")")
ROOT=$(dirname "$DIR")
LUA=$ROOT/mod/Contents/mods/ZomboidMCP/42/media/lua
SRC=$LUA/server/ZomboidMCP
DEST=$ZMCP_SSH:$MOUNT/ZomboidMCP/

RSYNC_OPTS=(-rlptv --delete --chmod=D755,F644 --exclude '*.orig' --exclude '*.tmp')
[ "${1:-}" = "--dry-run" ] && RSYNC_OPTS+=(--dry-run)

# Json.lua and CollisionSprites.lua live in shared/ in the mod; the mount only covers server/ZomboidMCP, so ship
# copies alongside (the guarded requires find either).
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -r "$SRC"/. "$STAGE"/
cp "$LUA/shared/ZomboidMCP/Json.lua" "$STAGE/Json.lua"
cp "$LUA/shared/ZomboidMCP/CollisionSprites.lua" "$STAGE/CollisionSprites.lua"

ssh -o BatchMode=yes "$ZMCP_SSH" "mkdir -p $MOUNT/ZomboidMCP"
rsync "${RSYNC_OPTS[@]}" "$STAGE"/ "$DEST"
echo "synced to $DEST"

if ssh -o BatchMode=yes "$ZMCP_SSH" "docker inspect ${ZMCP_CONTAINER:-none} --format '{{range .Mounts}}{{.Destination}}{{println}}{{end}}' 2>/dev/null | grep -q 'media/lua/server/ZomboidMCP'"; then
  echo "container mount present: files load at startup; reload live with: tools/pz reload"
  [ "${1:-}" = "--reload" ] && "$DIR/pz" reload ZomboidMCP/Bridge.lua
else
  cat <<EOF
NOTE: the container does not mount $MOUNT/ZomboidMCP yet. Add to the compose (owner only, restart needed):
  volumes:
    - $MOUNT/ZomboidMCP:/home/steam/pz-dedicated/media/lua/server/ZomboidMCP:ro
Until then load the files live with: tools/pz load
EOF
fi
