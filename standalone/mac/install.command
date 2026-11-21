#!/bin/bash
# GeoRocker installer for macOS (packed by standalone/make_mac_package.py).
# Copies the game folder next to this file into Luanti's user folder and points
# main_menu_script in minetest.conf at our start screen. Saves (worlds) are kept.
# Run again with a newer package to update.

cd "$(dirname "$0")" || exit 1
SRC="$PWD/georocker"

pause() { echo; read -n 1 -r -s -p "按任意鍵關閉這個視窗…" _; echo; }
fail() { echo; echo "$1"; pause; exit 1; }

echo "=== 安裝 GeoRocker ==="
[ -f "$SRC/game.conf" ] || fail "找不到 georocker 資料夾：請先把下載的 zip 整個解壓縮，再執行這個檔。"

APP=""
for a in "/Applications/Luanti.app" "$HOME/Applications/Luanti.app"; do
	if [ -d "$a" ]; then APP="$a"; break; fi
done

# Luanti 的使用者資料夾：有 minetest.conf 的那個；兩個都有就用最近改過的
SUP="$HOME/Library/Application Support"
USERDIR=""
for d in "$SUP/minetest" "$SUP/luanti"; do
	if [ -d "$d" ]; then
		if [ -z "$USERDIR" ] || [ "$d/minetest.conf" -nt "$USERDIR/minetest.conf" ]; then USERDIR="$d"; fi
	fi
done
if [ -z "$USERDIR" ]; then
	if [ -z "$APP" ]; then
		fail "還沒安裝 Luanti：請到 https://www.luanti.org 下載 macOS 版，拖進「應用程式」，打開一次再關掉，然後再執行這個檔。"
	fi
	fail "請先打開 Luanti 一次再關掉（讓它建立資料夾），然後再執行這個檔。"
fi

if pgrep -f "Luanti.app/Contents/MacOS" >/dev/null 2>&1; then
	fail "Luanti 正在執行：請先關掉 Luanti，再執行這個檔。"
fi

echo "Luanti 資料夾：$USERDIR"
mkdir -p "$USERDIR/games" "$USERDIR/worlds" || fail "無法建立資料夾：$USERDIR/games"
rm -rf "$USERDIR/games/georocker"
cp -R "$SRC" "$USERDIR/games/georocker" || fail "複製遊戲失敗。"
xattr -dr com.apple.quarantine "$USERDIR/games/georocker" 2>/dev/null
echo "遊戲已複製。"

CONF="$USERDIR/minetest.conf"
touch "$CONF" || fail "無法寫入 $CONF"
# setconf key value [only_if_missing]
setconf() {
	if [ -n "$3" ] && grep -q "^[[:space:]]*$1[[:space:]]*=" "$CONF"; then return; fi
	awk -v k="$1" -v v="$2" '
		$0 ~ "^[ \t]*" k "[ \t]*=" { if (!done) print k " = " v; done = 1; next }
		{ print }
		END { if (!done) print k " = " v }' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}
setconf main_menu_script "$USERDIR/games/georocker/standalone/mainmenu.lua"
setconf menu_last_game georocker
setconf language zh_TW 1
setconf name player 1
setconf enable_esc_dialog false 1
setconf server_announce false 1
echo "設定已寫入。"

echo
echo "安裝完成。打開 Luanti 就會看到 GeoRocker 的開始畫面。"
if [ -n "$APP" ]; then open -a "$APP"; fi
pause
