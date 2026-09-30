#!/bin/bash
# Upload the mod to the Steam Workshop (item $ZMCP_WORKSHOP_ID, PUBLIC) with SteamCMD, then verify it.
#
#   tools/upload.sh ["change note"]      build + upload + verify
#   tools/upload.sh --dry-run            only generate the VDF and show what would run
#   tools/upload.sh --verify             only run the verification (anonymous download + public API)
#
# Reads ~/.config/zomboid-mcp/local.env: ZMCP_STEAMCMD (steamcmd.sh), ZMCP_STEAMCMD_HOME (isolated HOME so the login
# never touches the desktop Steam install), ZMCP_STEAM_USER, ZMCP_WORKSHOP_ID (3810456179).
#
# PITFALLS (docs/ENGINE_NOTES.md):
#   * SteamCMD logging in with the owner's account KICKS their desktop Steam. Only run this when the owner is not
#     playing, and tell them first.
#   * "visibility" "3" (unlisted) produced a PRIVATE item and the dedicated server then hung every join at
#     GettingServerInfo. The template pins visibility 0 (public). Verify after every upload.
#   * The first login needs Steam Guard: run `env HOME=$ZMCP_STEAMCMD_HOME $ZMCP_STEAMCMD +login $ZMCP_STEAM_USER +quit`
#     once by hand and enter the code; the isolated HOME then keeps the session.
set -euo pipefail
[ -f ~/.config/zomboid-mcp/local.env ] && . ~/.config/zomboid-mcp/local.env
: "${ZMCP_STEAMCMD:?set ZMCP_STEAMCMD in ~/.config/zomboid-mcp/local.env}"
: "${ZMCP_STEAMCMD_HOME:?set ZMCP_STEAMCMD_HOME}"
: "${ZMCP_STEAM_USER:?set ZMCP_STEAM_USER}"
: "${ZMCP_WORKSHOP_ID:?set ZMCP_WORKSHOP_ID}"

DIR=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
CONTENT="$DIR/mod/Contents"
PREVIEW="$DIR/art/showcase/ysnp.jpg"   # the Workshop header image (the in-game mod list uses poster.png via mod.info)
STEAMCMD=$(eval echo "$ZMCP_STEAMCMD")
STEAMCMD_HOME=$(eval echo "$ZMCP_STEAMCMD_HOME")
MODE=upload
NOTE=${1:-"Zomboid MCP $(git -C "$DIR" describe --always --dirty 2>/dev/null || date +%F)"}
case "${1:-}" in --dry-run) MODE=dry ;; --verify) MODE=verify ;; esac

verify() {
  echo "== public API: GetPublishedFileDetails"
  local json
  json=$(curl -s -d "itemcount=1&publishedfileids[0]=$ZMCP_WORKSHOP_ID" \
    https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/)
  python3 - "$json" <<'EOF'
import json, sys, time
d = json.loads(sys.argv[1])["response"]["publishedfiledetails"][0]
ok = d.get("result") == 1
vis = d.get("visibility")
print("result=%s title=%r visibility=%s (0=public) updated=%s size=%s" % (
    d.get("result"), d.get("title"), vis, time.strftime("%F %T", time.localtime(d.get("time_updated", 0))), d.get("file_size")))
if not ok or vis != 0:
    print("NOT PUBLIC or not found: the dedicated server will hang joins at GettingServerInfo", file=sys.stderr)
    sys.exit(1)
EOF
  echo "== anonymous download (what the server will fetch)"
  local tmp
  tmp=$(mktemp -d)
  env HOME="$tmp" "$STEAMCMD" +login anonymous +workshop_download_item 108600 "$ZMCP_WORKSHOP_ID" +quit >"$tmp/log" 2>&1 || true
  if grep -q "Success. Downloaded item" "$tmp/log"; then
    local got
    got=$(find "$tmp" -path "*content/108600/$ZMCP_WORKSHOP_ID/mods/ZomboidMCP/mod.info" | head -1)
    if [ -n "$got" ]; then
      echo "downloaded: $(dirname "$got")"; sed -n 's/^\(id\|modversion\)=/  &/p' "$got"
      diff -rq "$CONTENT/mods/ZomboidMCP" "$(dirname "$got")" && echo "content matches the repo"
    else
      echo "download succeeded but mods/ZomboidMCP/mod.info is missing (wrong contentfolder?)" >&2; rm -rf "$tmp"; return 1
    fi
  else
    echo "anonymous download failed:"; tail -5 "$tmp/log"; rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
}

if [ "$MODE" = verify ]; then verify; exit $?; fi

[ -f "$CONTENT/mods/ZomboidMCP/mod.info" ] || { echo "no mod.info under $CONTENT" >&2; exit 1; }
[ -f "$PREVIEW" ] || { echo "no preview image $PREVIEW" >&2; exit 1; }
find "$CONTENT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

VDF=$(mktemp --suffix=.vdf)
trap 'rm -f "$VDF"' EXIT
sed -e "s#@WORKSHOP_ID@#$ZMCP_WORKSHOP_ID#" -e "s#@CONTENT_FOLDER@#$CONTENT#" -e "s#@PREVIEW_FILE@#$PREVIEW#" \
    -e "s#@CHANGENOTE@#${NOTE//#/}#" "$DIR/tools/workshop.vdf.template" >"$VDF"
# the description is the BBCode block of docs/WORKSHOP.md (a VDF string cannot hold straight double quotes)
python3 - "$VDF" "$DIR/docs/WORKSHOP.md" <<'PY'
import re, sys
vdf, page = sys.argv[1], open(sys.argv[2]).read()
desc = page.split("```\n")[1].strip().replace('"', "'")
s = open(vdf).read()
s = re.sub(r'("description"\s+)"[^"]*"', lambda m: m.group(1) + '"' + desc + '"', s)
open(vdf, "w").write(s)
PY
echo "== VDF"; cat "$VDF"
CMD=(env HOME="$STEAMCMD_HOME" "$STEAMCMD" +login "$ZMCP_STEAM_USER" +workshop_build_item "$VDF" +quit)
echo "== command: ${CMD[*]}"
if [ "$MODE" = dry ]; then exit 0; fi

echo "!! This logs in as $ZMCP_STEAM_USER and kicks the desktop Steam session. Continue? [y/N]"
read -r ans; [ "$ans" = y ] || exit 1
"${CMD[@]}" 2>&1 | tee /tmp/zmcp_upload.log | grep -vE '^\s*$' | tail -20
grep -q "Success" /tmp/zmcp_upload.log || { echo "upload did not report Success (see /tmp/zmcp_upload.log)" >&2; exit 1; }
sleep 5
verify
