# 遊戲內截圖（wiki 的資訊框）

- `gallery.lua`：放進測試世界的 worldmod（`worldmods/vt/init.lua`），在空中平台擺好所有元件，玩家 `wikibot` 進來後依序移動鏡頭，log 寫 `[SHOT] id`。
- `shoot.ps1`：開伺服器（`--config` 要給 `disable_anticheat = true`）和一個 client，只擷取 Luanti 視窗（PrintWindow），存成 `<id>.png`。
- 拍完把圖裁掉上方的 HUD、縮成 480×360 的 JPG 放到 `../shots/<id>.jpg`，再跑 `python build.py`。
- 注意：螢幕要開著、沒有鎖定，不然抓到的是黑畫面；使用者開著 Luanti 時不要跑。
- 不要用 PowerShell 的 Get-Content／Out-File 改 gallery.lua（會把 UTF-8 弄壞、加 BOM）。
