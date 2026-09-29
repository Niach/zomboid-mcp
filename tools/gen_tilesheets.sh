#!/bin/bash
# Regenerate Api/TileSheets.lua from the local game's newtiledefinitions.tiles.txt.
#   tools/gen_tilesheets.sh [path/to/projectzomboid]
PZ=${1:-$HOME/.steam/steam/steamapps/common/ProjectZomboid/projectzomboid}
DIR=$(dirname "$(readlink -f "$0")")/..
OUT=$DIR/mod/Contents/mods/ZomboidMCP/42/media/lua/server/ZomboidMCP/Api/TileSheets.lua
{
  echo '-- Generated from media/newtiledefinitions.tiles.txt (Build 42.21): vanilla tilesheet name -> tile count.'
  echo '-- Sprite names are "<sheet>_<n>" with n in 0..count-1. Used by sprite_search as a fallback when the live sprite map'
  echo '-- is not readable, and to validate sprite names. Regenerate with tools/gen_tilesheets.sh.'
  echo 'require "ZomboidMCP/Bridge"'
  echo 'ZMCP.tileSheets = {'
  awk '/file = /{f=$3} /size = /{split($3,a,","); printf "    [\"%s\"] = %d,\n", f, a[1]*a[2]}' "$PZ/media/newtiledefinitions.tiles.txt" | sort
  echo '}'
} > "$OUT" && echo "wrote $OUT ($(grep -c '^    \[' "$OUT") sheets)"
