GeoRocker 班級伺服器（只有伺服器，沒有遊戲畫面）

啟動：雙擊 start_class_server.bat
  每次啟動會先備份世界（backups\，留 7 天）、把遊戲更新到 GitHub 的 release 版，再開伺服器（埠 30000）。
  每天 04:00 自動重開一次（同時更新）。當掉會自己重開；60 秒內連續掛三次就停下來等人看。
  關掉：在那個視窗按 Ctrl+C（會先存檔）。不要同時開兩個。

需要：git（更新遊戲用）。第一次 pull 如果要登入 GitHub，照畫面登入一次就好。

資料夾：
  bin\、builtin\、minetest.conf   Luanti 引擎
  games\mining_sim\               遊戲（git，release 分支，只抓最新版）
  worlds\class_coal\              班級世界（名單 students.csv、設定 rockmech.conf 在這裡）
  backups\                        自動備份（第一次啟動才會出現）

玩家用自己的 GeoRocker（打包版）連這台電腦的 IP、埠 30000。
