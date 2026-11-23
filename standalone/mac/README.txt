GeoRocker（macOS）

需要 macOS 12.3 或更新。Apple 晶片和 Intel 的 Mac 都可以（會自動選）。
下載頁：https://github.com/jatestrella/GeoRocker/releases/latest

【方法一：下載 zip】
1. 把下載的 zip 解壓縮，整個資料夾搬到想放的地方（例如「文件」）。
2. 點兩下「開始遊戲.command」。第一次會跳出「無法驗證」的視窗，按「完成」。
3. 打開 系統設定 → 隱私權與安全性，拉到最下面，按「仍要打開」，輸入密碼，再按「打開」。
   只有第一次要這樣，之後直接點兩下就好。
   （macOS 14 以前也可以對「開始遊戲.command」按右鍵 →「打開」→ 再按「打開」。）

還是打不開：打開「終端機」，輸入下面這段（最後有一個空格），
把整個遊戲資料夾拖進終端機視窗，按 Enter，再點兩下「開始遊戲.command」：
xattr -dr com.apple.quarantine

【方法二：終端機一行安裝（不會跳警告）】
打開「終端機」，貼上下面這一行，按 Enter。會下載最新版，放到「文件」裡的 GeoRocker_mac，然後開始遊戲：
curl -L -o /tmp/GeoRocker_mac.zip https://github.com/jatestrella/GeoRocker/releases/latest/download/GeoRocker_mac.zip && ditto -x -k /tmp/GeoRocker_mac.zip ~/Documents && bash ~/Documents/GeoRocker_mac/開始遊戲.command
之後到「文件」→ GeoRocker_mac，點兩下「開始遊戲.command」就能玩。

存檔和設定都在這個資料夾的 data 裡面。換新版時，把舊的 data/worlds 搬到新資料夾的 data 裡，存檔就跟過去了。
