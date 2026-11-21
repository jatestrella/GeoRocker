#!/bin/bash
# GeoRocker for macOS: start the game (packed by standalone/make_mac_package.py).
# Everything stays in this folder, like the Windows package:
#   engine/arm64/luanti.app, engine/x86_64/luanti.app   official Luanti builds, unchanged (signature intact)
#   data/                                                user folder (MINETEST_USER_PATH): games, worlds, minetest.conf
# Each start: picks the engine for this Mac, clears the download quarantine, points main_menu_script
# at our start screen (absolute path, so the folder can be moved) and starts the engine.

HERE="$(cd "$(dirname "$0")" && pwd)"
DATA="$HERE/data"

pause() { echo; read -n 1 -r -s -p "按任意鍵關閉這個視窗…" _; echo; }
fail() { echo; echo "$1"; pause; exit 1; }

ARCH=x86_64
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] || [ "$(uname -m)" = "arm64" ]; then ARCH=arm64; fi
BIN="$HERE/engine/$ARCH/luanti.app/Contents/MacOS/luanti"
[ -x "$BIN" ] || fail "找不到遊戲引擎（engine/$ARCH）：請把下載的 zip 整個解壓縮，再打開這個檔。"
[ -f "$DATA/games/georocker/game.conf" ] || fail "找不到遊戲資料夾（data/games/georocker）：請把下載的 zip 整個解壓縮，再打開這個檔。"

if pgrep -f "$BIN" >/dev/null 2>&1; then
	echo "遊戲已經開著了。"
	exit 0
fi

# 從網路下載的檔案會被 macOS 標記，引擎會被擋：整個資料夾一次解除
xattr -dr com.apple.quarantine "$HERE" 2>/dev/null

mkdir -p "$DATA/worlds"
CONF="$DATA/minetest.conf"
touch "$CONF" || fail "無法寫入 $CONF（資料夾是唯讀的嗎？請把整個資料夾搬到「文件」或桌面再試）"
# setconf key value [only_if_missing]
setconf() {
	if [ -n "$3" ] && grep -q "^[[:space:]]*$1[[:space:]]*=" "$CONF"; then return; fi
	awk -v k="$1" -v v="$2" '
		$0 ~ "^[ \t]*" k "[ \t]*=" { if (!done) print k " = " v; done = 1; next }
		{ print }
		END { if (!done) print k " = " v }' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}
setconf main_menu_script "$DATA/games/georocker/standalone/mainmenu.lua"
setconf menu_last_game georocker
setconf language zh_TW 1

export MINETEST_USER_PATH="$DATA"
nohup "$BIN" --config "$CONF" >/dev/null 2>&1 &
disown
echo "遊戲啟動中，這個視窗可以關掉。"
