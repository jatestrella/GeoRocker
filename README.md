<p align="center"><img src="menu/header.png" alt="GeoRocker — Rock Mechanics · Mining · Geotechnics"></p>

<p align="center"><img src="docs/cover.jpg" alt="水泥礦地圖：台階式大理岩採場與機具"></p>

GeoRocker 是一款岩石力學、隧道與大地工程的採礦模擬遊戲，以 [Luanti](https://www.luanti.org/) 引擎製作。
玩家要自己探勘地質、鑽孔爆破、開挖支撐、運輸賣礦。岩體會依應力和節理崩塌，炸藥配比不對威力就打折。

*A rock mechanics and mining simulator built on the Luanti engine. Text in game is Traditional Chinese.*

**📖 遊戲說明（wiki）：https://jatestrella.github.io/GeoRocker/**

## 遊戲內容

- **岩體與開挖**：完整岩石加節理；應力、岩體強度、穩定性與崩塌
- **探勘**：岩芯鑽探、地質羅盤、GSI、Q 法、施密特錘、點荷重、孔內應力計
- **爆破**：鑿岩、裝藥、自己調配 ANFO（硝酸銨與柴油的比例決定威力）
- **支撐**：岩栓、噴凝土、木支撐、通風與空氣品質
- **機具與運輸**：怪手、推土機、礦卡、鑽機、裝藥車、輸送帶、收煤站
- **經營**：資金、礦價與市場事件、截止品位、貸款

## 地圖

| 地圖 | 說明 |
|---|---|
| 煤礦經營（單機） | 固定地質，從頭經營一座煤礦 |
| 隨機煤礦（單機） | 每次地質都不一樣 |
| 自訂煤礦（單機） | 自己設定地層、煤層、褶皺 |
| 水泥礦（單機） | 仿花蓮和平礦場山頂採場，1:1 地形 |

## 下載與安裝

**Windows**：到 [Releases](https://github.com/jatestrella/GeoRocker/releases/latest) 下載 `GeoRocker.zip`，解壓縮後點兩下 `開始遊戲.bat`。不用另外安裝任何東西。

**macOS、Linux**：先安裝 [Luanti](https://www.luanti.org/) 5.15，再下載本 repo（綠色 **Code** 按鈕 → Download ZIP），把解壓出來的資料夾**改名為 `georocker`**，放進 Luanti 的 `games` 資料夾，開 Luanti 選 GeoRocker 建立新世界。這種裝法沒有 GeoRocker 的開始畫面，建立的世界會用預設地圖。

## 意見與合作

問題回報、教學使用或合作詢問，請開 [Issue](https://github.com/jatestrella/GeoRocker/issues)。

## 授權

保留所有權利，僅公開閱覽，詳見 [LICENSE](LICENSE)。
`mods/` 下來自 Minetest Game 的模組與 Cubic 11 字型依其原授權。
