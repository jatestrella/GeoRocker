-- rockmech/config.lua
-- 岩性表與節理組表（純資料 + 設定解析）。
-- 本檔不可使用任何引擎 API（core.*、vector.*），以便在引擎外單元測試。
--
-- 單位約定：
--   長度 m（1 格 = 1 m）、單位重 γ kN/m³、強度 MPa、角度 degree。

local config = {}

---------------------------------------------------------------------------
-- 岩性表
---------------------------------------------------------------------------
-- 欄位：
--   name        node 名稱後綴（rockmech:<name>）
--   description 顯示名稱
--   gamma       單位重 γ (kN/m³)
--   ucs         單軸抗壓強度 UCS (MPa)
--   tensile     張力強度 σt (MPa)
--   mi          Hoek-Brown 完整岩石常數 mi（rockmass.lua）
--   gsi         岩體品質的深度剖面 {top, bottom, depth}（rockmass.gsi_at）；預設 GSI 100（完整岩石）
--   color       著色（ColorString），用於材質
--   cracky      Luanti 挖掘群組等級（1 最硬、3 最軟）
--   rn, rt      落石撞擊此岩面時的法向／切向回彈係數
--   mu_roll     落石在此岩面上的滾動阻力係數（tan 滾動摩擦角）
--   ore         礦石名稱（config.ores）：方塊的 param2 1..255 是品位，不是 GSI
--   texture     （可選）方塊貼圖
--   break_height 掉落破碎特徵高度 h_ref (m)：落下 h 公尺後變碎石的機率
--               p = 1 − exp(−h / h_ref)，越硬越大
config.lithologies = {
	sandstone = {
		name = "sandstone", description = "Sandstone (砂岩)",
		gamma = 25.0, ucs = 60.0, tensile = 4.0, mi = 17,
		color = "#c9a46a", cracky = 3,
		rn = 0.35, rt = 0.85, mu_roll = 0.40, break_height = 4.0,
	},
	shale = {
		name = "shale", description = "Shale (頁岩)",
		gamma = 25.0, ucs = 30.0, tensile = 2.0, mi = 6,
		color = "#3c4048", cracky = 3,
		rn = 0.30, rt = 0.80, mu_roll = 0.50, break_height = 2.5,
	},
	granite = {
		name = "granite", description = "Granite (花崗岩)",
		gamma = 25.0, ucs = 180.0, tensile = 10.0, mi = 32,
		color = "#d2b4ac", cracky = 2,
		rn = 0.45, rt = 0.90, mu_roll = 0.35, break_height = 8.0,
	},
}

config.lithologies.coal = {
	name = "coal", description = "Coal (煤)", ore = "coal",
	gamma = 14.0, ucs = 15.0, tensile = 1.0, mi = 8, gsi = {top = 75},
	color = "#2c2c31", cracky = 3,
	texture = "default_stone.png^[colorize:#e0e0e0:200",
	rn = 0.25, rt = 0.75, mu_roll = 0.50, break_height = 2.0,
}

-- 礦石：每一列是一種礦石和它混合的廢石。param2 1..255 = 礦石佔的比例（品位），0 = 全是廢石。
--   lith    礦石的岩性；waste：混合的廢石是哪種岩性的碎石（同一格會合併，品位下降）
--   pure    純礦石的顏色；waste_color：廢石的顏色（未破碎的方塊用兩者之間的顏色）
--   label   顯示用；default：沒指定品位的方塊算多少（param2）
--   price   品位 100% 時每噸的售價；recovery：選礦回收率（破碎站，見 config.crush_income）
-- 碎石的外觀由 8 張遮罩決定：廢石貼圖上疊礦石貼圖，品位越高礦石的像素越多。加一種礦只要在這裡加一列
config.ores = {
	coal = {lith = "coal", waste = "shale", pure = "#141418", waste_color = "#6a6058",
		label = "煤", default = 191, price = 120, recovery = 0.9},
}

-- 經營模式的供應商（career.lua）：key 用在設定 rockmech_price_<key>；count：一次買幾個；
-- shop：哪一攤賣（vehicle 機械設備課長、blast 爆破主任、tools 工具室管理員）
config.shop = {
	{key = "pick", shop = "tools", item = "rockmech:pick", label = "挖礦鎬", price = 0},
	{key = "shovel", shop = "tools", item = "rockmech:shovel", label = "鏟子", price = 100},
	{key = "cart", shop = "vehicle", item = "rockmech:cart_item", label = "手推車", price = 500},
	{key = "suv", shop = "vehicle", item = "rockmech:suv_item", label = "休旅車", price = 3000},
	{key = "truck", shop = "vehicle", item = "rockmech:truck_item", label = "卡車", price = 10000},
	{key = "excavator", shop = "vehicle", item = "rockmech:excavator_item", label = "怪手", price = 15000},
	{key = "crusher", shop = "vehicle", item = "rockmech:crusher", label = "破碎站", price = 20000},
	{key = "crusher_big", shop = "vehicle", item = "rockmech:crusher_big", label = "大型破碎站", price = 300000},
	{key = "plant", shop = "vehicle", item = "rockmech:plant", label = "選礦場", price = 30000},
	{key = "belt", shop = "vehicle", item = "rockmech:belt", label = "輸送帶", price = 1000, count = 10},
	{key = "lowboy", shop = "vehicle", item = "rockmech:lowboy_item", label = "平板拖車", price = 40000},
	{key = "dozer", shop = "vehicle", item = "rockmech:dozer_item", label = "推土機", price = 35000},
	{key = "bulktruck", shop = "blast", item = "rockmech:bulktruck_item", label = "裝藥車", price = 40000},
	{key = "charger", shop = "blast", item = "rockmech:charger_item", label = "裝藥台車", price = 40000},
	{key = "corerig", shop = "blast", item = "rockmech:corerig_item", label = "岩芯鑽探車（60 m）", price = 45000},
	{key = "drillrig", shop = "blast", item = "rockmech:drillrig_item", label = "鑽機", price = 50000},
	{key = "jumbo", shop = "blast", item = "rockmech:jumbo_item", label = "鑽孔台車", price = 60000},
	{key = "haul", shop = "vehicle", item = "rockmech:haul_item", label = "礦卡", price = 150000},
	{key = "excavator_big", shop = "vehicle", item = "rockmech:excavator_big_item", label = "礦用怪手", price = 200000},
	{key = "loadout", shop = "vehicle", item = "rockmech:loadout", label = "裝車料斗（接輸送帶裝車）", price = 25000},
	-- 終極目標：買下時全服廣播（career.lua）
	{key = "miner", shop = "vehicle", item = "rockmech:miner_item", label = "連續採礦機", price = 1500000, final = true},
	{key = "operator", shop = "vehicle", item = "rockmech:operator", label = "怪手操作員（雇用另付日薪）", price = 0},
	{key = "breaker_kit", shop = "vehicle", item = "rockmech:breaker_kit", label = "油壓破碎錘（怪手改裝套件）", price = 20000},
	{key = "ahs_module", shop = "vehicle", item = "rockmech:ahs_module", label = "自動駕駛模組（卡車、礦卡）", price = 8000},
	{key = "radio", shop = "vehicle", item = "rockmech:radio", label = "對講機", price = 0},
	{key = "drill", shop = "blast", item = "rockmech:rock_drill", label = "鑿岩機", price = 500},
	{key = "detonator", shop = "blast", item = "rockmech:detonator", label = "起爆器", price = 500},
	{key = "emulsion", shop = "blast", item = "rockmech:emulsion", label = "乳膠炸藥", price = 500, count = 10},
	{key = "anfo", shop = "blast", item = "rockmech:anfo", label = "ANFO", price = 1000, count = 10},
	{key = "bolt", shop = "tools", item = "rockmech:rock_bolt", label = "岩栓", price = 300, count = 10},
	{key = "shotcrete", shop = "tools", item = "rockmech:shotcrete", label = "噴凝土", price = 800, count = 10},
	{key = "axe", shop = "tools", item = "default:axe_steel", label = "斧頭（砍樹）", price = 100},
	{key = "sawbench", shop = "tools", item = "rockmech:sawbench", label = "鋸木台（原木鋸成木柱、木板）", price = 800},
	{key = "workbench", shop = "tools", item = "rockmech:workbench", label = "木工桌（木牆板、樓梯、門…）", price = 300},
	{key = "rain_gauge", shop = "tools", item = "rockmech:rain_gauge", label = "氣象站（百葉箱，時雨量）", price = 500},
	{key = "survey_prism", shop = "tools", item = "rockmech:survey_prism", label = "監測稜鏡（岩面位移）", price = 500, count = 5},
	{key = "timber_post", shop = "tools", item = "rockmech:timber_post", label = "木柱（支撐、蓋房子）", price = 200, count = 10},
	{key = "timber_plank", shop = "tools", item = "rockmech:timber_plank", label = "木板", price = 100, count = 10},
	{key = "timber_slab", shop = "tools", item = "rockmech:timber_slab", label = "木板半格", price = 100, count = 10},
	{key = "drone", shop = "tools", item = "rockmech:drone_remote", label = "無人機", price = 2000},
	{key = "drone_cmd", shop = "tools", item = "rockmech:drone_cmd", label = "指揮無人機（無人機＋對講機）", price = 5000},
	{key = "xrf", shop = "tools", item = "rockmech:xrf", label = "XRF 分析儀（品位）", price = 5000},
	{key = "gsi_card", shop = "tools", item = "rockmech:gsi_card", label = "GSI 評估圖卡（岩體）", price = 1000},
	{key = "core_drill", shop = "tools", item = "rockmech:core_drill", label = "手持岩芯鑽機（10 m）", price = 3000},
	{key = "compass", shop = "tools", item = "rockmech:compass", label = "地質羅盤（力學）", price = 200},
	{key = "fieldbook", shop = "tools", item = "rockmech:fieldbook", label = "野帳本（判讀岩芯箱）", price = 10},
	{key = "locker", shop = "tools", item = "rockmech:locker", label = "置物箱（放小東西）", price = 200},
}

-- 引擎額定功率（kW，fuel.lua 算油耗）：沒列的車不耗油（手推車靠人推）
config.engine_kw = {suv = 150, truck = 300, haul = 1000, bulktruck = 250, lowboy = 400, dozer = 250,
	excavator = 120, excavator_big = 500, drillrig = 200, corerig = 100, jumbo = 150, charger = 100, miner = 500}

-- 破碎站的收入：噸數 ×（品位 × 回收率 × 價格 − 處理費）。ore = nil 是廢石，只付處理費
function config.crush_income(tons, grade, ore, fee)
	return tons * ((ore and grade * ore.recovery * ore.price or 0) - fee)
end

-- 註冊順序（固定，讓 content id / 測試結果可重現）
config.lithology_order = {"sandstone", "shale", "granite", "coal"}

-- 依深度分層：h = y0 - y，h < bottom 即屬於該層（由上往下排列）。
-- h < 0（高於 y0 的山丘）歸入第一層。
config.layers = {
	{lith = "sandstone", bottom = 20},
	{lith = "shale",     bottom = 60},
	{lith = "granite",   bottom = math.huge},
}

-- 區帶模式（rockmech_lith_mode = zones）：沿 x 方向每 zone_width 公尺換一種岩性，
-- 第 k 區（k = ⌊(x + W/2) / W⌋）用 zone_order[k mod 3 + 1]。
-- 預設：出生點附近（x −40..40）頁岩、東側花崗岩、西側砂岩，往外循環。
config.zone_order = {"shale", "granite", "sandstone"}

---------------------------------------------------------------------------
-- 節理組表
---------------------------------------------------------------------------
-- 欄位：
--   id          整數，參與雜湊（改了會改變延續性樣式）
--   name        顯示名稱
--   dip         傾角 ψ (deg, 0–90)
--   dipdir      傾向 (deg, 由北順時針 0–360)
--   spacing     間距 (m, ≥ 1)
--   persistence 延續性 (0–1)
--   phi         節理面摩擦角 φj (deg)
--   color       除錯顯示用顏色
--   offset      (可選) 平面組相位 (m)。未給時由世界種子決定。
config.joint_sets = {
	{id = 1, name = "J1", dip = 10, dipdir = 135, spacing = 4,
		persistence = 0.95, phi = 25, color = "#ff4040"},
	{id = 2, name = "J2", dip = 70, dipdir = 40, spacing = 3,
		persistence = 0.80, phi = 32, color = "#40c0ff"},
	{id = 3, name = "J3", dip = 80, dipdir = 300, spacing = 5,
		persistence = 0.70, phi = 30, color = "#ffd040"},
}

-- 設定的預設值（鍵名不含 "rockmech_" 前綴）
config.defaults = {
	surface_y = 0,        -- 地表高程 y0
	joint_lattice = 8,    -- 節理法向量對齊的整數格點密度 D（越大越接近輸入位態、材質變體越多）
	k0 = 0.5,             -- σh / σv
	replace_stone = true, -- 地圖生成時把 stone 換成本 mod 岩性
	strip_soil = false,   -- 地圖生成時移除土壤（露出岩盤）；建議只在個別世界的 rockmech.conf 開啟
	only_lithologies = false, -- 地圖生成時把其他天然實心方塊（礦石、凍土、冰、生態系岩石…）也換成岩性
	lith_mode = "layers", -- 岩性分布：layers（依深度分層）或 zones（沿 x 方向的區帶）
	zone_width = 80,      -- zones 模式的區帶寬度 (m)
}

-- 「土壤」判定：天然地層（is_ground_content）中 crumbly 群組的方塊，
-- 碎石（rockmech_rubble）除外。涵蓋泥土、帶草泥土、凍土、沙、礫石、黏土、雪。
function config.is_soil(name, groups, is_ground_content)
	groups = groups or {}
	if is_ground_content == false then return false end
	if (groups.rockmech_rubble or 0) > 0 then return false end
	return (groups.crumbly or 0) > 0
end

-- 軸差破壞（failure.lua）的預設值；設定鍵為 rockmech_failure_<key>
config.failure_defaults = {
	enabled = true,
	radius = 6,               -- 開挖影響範圍：玩家造成的改變（挖掘、放置、爆破）周圍的檢查半徑 (m)
	secondary_factor = 0.5,   -- 延伸影響範圍 = radius × 此值：崩落、滑出等物理造成的移除周圍再檢查的半徑
	window = 4,               -- 荷重擴散窗格半寬 w，窗格 (2w+1)² (m)
	gamma_other = 20,         -- 非岩性實心格（土、礦石等）的單位重 (kN/m³)
	overburden_scan = 64,     -- 柱狀荷重往上讀取的高度 (m)，超出部分假設連續到 y0
	initial_scan_max = 512,   -- 初始應力往上找地表的最大高度 (m)，超出部分假設連續到 y0
	strength_scale = 1.0,     -- （舊設定，改用 rockmech_model_scale）σci 額外乘上此值
	max_cascade = 5,          -- 連鎖重算輪數上限
	cascade_delay = 0.6,      -- 每輪間隔 (s)，讓剝落的岩塊先就位
	interval = 5,             -- 檢查最快幾秒一次 (s)：這段時間內的觸發合併成一批（主執行緒負擔），連鎖每輪也至少隔這麼久
	budget_ms = 5,            -- 單次檢查超過此時間的 3 倍就記 log
}

-- 節理材質（nodes.lua 的材質變體）；設定鍵為 rockmech_jointtex_<key>
-- 改動後需重新進入世界（材質在載入時產生）
config.jointtex_defaults = {
	enabled = true,           -- 地圖生成／轉換時依節理放置材質變體
	style = "plane",          -- plane：真實平面跡線（斜線）；edges：沿方塊邊緣＋節理面上色；
	                          -- mesh：不用方塊變體，跡線以區塊網格疊在岩面上（組數不限；jointmesh.lua）
	mesh_range = 3,           -- mesh：玩家周圍幾個區塊（16 m）內顯示
	mesh_width = 0.06,        -- mesh：跡線寬度 (m)
	mesh_overlay = false,     -- plane 模式下另外疊一層紅色網格跡線（檢查用）
	mesh_debug = false,       -- mesh：記錄地形改變到網格送達的延遲
	max_lines = 2,            -- plane：每格最多畫幾組節理
	plane_res = 32,           -- plane：跡線貼圖解析度（像素）
	plane_width = 1.5,        -- plane：跡線寬度（像素，以 plane_res 計）
	line_color = "#000000",   -- 節理跡線顏色
	line_alpha = 170,         -- 跡線不透明度 0..255
	line_width = 1,           -- 跡線寬度（像素，材質為 16×16）
	face_color = "#8a5a2a",   -- 節理面（沿節理挖開的面）上色
	face_ratio = 110,         -- 節理面上色強度 0..255
}

-- 掉落破碎；設定鍵為 rockmech_fallbreak_<key>
config.fallbreak_defaults = {
	enabled = true,           -- 完整岩石掉落後依落下高度有機率變成碎石
	break_height = 4.0,       -- 非岩性（如 default:stone）的破碎特徵高度 (m)
}

-- 穩定判定（stability.lua，與岩體是否相連）；設定鍵為 rockmech_stability_<key>
config.stability_defaults = {
	enabled = true,
	radius = 12,              -- 搜尋範圍半徑 (m)；碰到範圍邊界視為連回大岩體
	max_voxels = 2000,        -- 懸空群超過此格數保守視為穩定
	rigid = true,             -- 懸空群整塊（剛體）落下；false 則逐格落下
	rigid_max = 128,          -- 剛體落下的格數上限，超過改為逐格落下
	budget_ms = 5,            -- 單次判定超過此時間的 3 倍就記 log
}

-- 開挖周圍彈性應力場的原型（fem.lua、femstress.lua，只顯示）；設定鍵為 rockmech_fem_<key>
config.fem_defaults = {
	enabled = true,           -- 地質羅盤點一格時，背景解應力並回報
	drive = true,             -- 由應力解決定崩落：取代懸空頂板與軸差破壞（節理弱面、關鍵塊體、穩定判定照舊）
	radius = 12,              -- 解的範圍（以點的格為中心 ±radius 格）
	coarse = 2,               -- 子模型：粗網格元素邊長 (m)，格數與細網格相同（預設涵蓋 ±25 m），解出的位移當細網格的外緣；1 = 不用，外緣 Δu = 0。3 m 以上對不齊常見的洞高，FS 會隨求解框位置變動
	coarse_blend = 0.1,       -- 粗網格剪力項全積分的比例（其餘取格中心，避免一層元素太少時梁太硬）；1 = 全積分
	nu = 0.25,                -- 帕松比
	rubble_e = 0.1,           -- 滿格碎石的勁度 / 岩石的勁度（0 = 碎石沒有勁度）
	active_range = 64,        -- 離所有玩家超過此距離 (m) 的應力解與連鎖崩落先暫停，玩家回來才接著算（0 = 不限）
	tol = 0.001,              -- 共軛梯度法的相對殘差
	max_iter = 1500,          -- 最多迭代幾輪
}

-- 支護（support.lua、groundsupport.lua）：換算成臨空面上的等效圍壓 pᵢ；設定鍵為 rockmech_support_<key>
-- （和岩體強度一樣除以相似比 N）
config.support_defaults = {
	shotcrete_p = 0.01,       -- 噴凝土的等效支護壓力 p_sc (MPa)：比 3 m 間距的岩栓（約 0.022 MPa）弱，約等於 0.4 m 岩層
	-- 岩栓錨定力 T = min(握裹力 × 有效長度, 鋼材降伏)，長度 = 孔深；平均分給周圍 3×3 m² 的岩面（間距 s ≈ T/s²）。
	-- 關鍵塊體只算打進岩塊外那一段的長度
	bolt_grip = 200,          -- 握裹力 g (kN/m)：全長灌漿岩栓，約 1 m 就達到鋼材降伏
	bolt_yield = 360,         -- 鋼材降伏 T_y (kN)：約 32 mm 鋼棒（450 MPa）
	-- 木柱承載力 P = min(壓碎 σc·A, 尤拉挫屈 π²EI/L²)，平均分給柱頂周圍 3×3 m² 的頂板：
	-- 2 m 約 630 kN（壓碎）、4 m 約 480 kN、6 m 約 210 kN（挫屈）
	post_d = 0.2,             -- 木柱直徑 d (m)
	post_ucs = 20,            -- 木材順紋抗壓強度 σc (MPa)
	post_e = 10000,           -- 木材彈性模數 E (MPa)
	post_max_len = 6,         -- 木柱最長 (m)：放的時候往上長到碰到頂板，超過就只放 1 m（當建材）
	-- 應力解裡木柱的等效斷面積 A_eff (m²)：木柱那一格的勁度 = 岩石 × A_eff / 1 m²（假設木材與岩石的 E 同級，約 10 GPa）。
	-- 真實斷面（直徑 20 cm）只有 0.031 m²，太軟，對頂板幾乎沒幫助；假設性放大到 0.5 m²。越大分到的荷重越多、
	-- 越容易被壓斷（1.0 m² 時 9 m 跨度軸力就到承載力 80%）。承載力照真實直徑，不跟著變
	post_fem_area = 0.5,
}

-- TNT 爆破破碎（blast.lua）；設定鍵為 rockmech_blast_<key>
config.blast_defaults = {
	enabled = true,
	ucs_ref = 60,             -- 破碎半徑 = 爆炸半徑 × (ucs_ref / UCS)^ucs_exp
	ucs_exp = 0.167,          -- 強度指數：1/6 = 單位炸藥量 ∝ √UCS（花崗岩約頁岩的 2.4 倍）；1/3 = 單位炸藥量 ∝ UCS
	inner = 0.5,              -- 破碎半徑的這個比例以內炸飛，其餘原地變碎石
	-- 鑽孔爆破（drilling.lua）
	charge_radius = 2.0,      -- 一條乳膠炸藥的爆炸半徑 R0 (m)；n 條 R = R0·n^(1/3)（再依岩石強度縮放）
	max_cartridges = 4,       -- 一個鑽孔最多裝幾條
	hole_depth = 2,           -- 孔深 (m)：爆心在岩面往內這麼深（孔底）
	surface_factor = 0.3,     -- 貼面裝藥（沒有鑽孔、沒有約束）的半徑係數
	confine_factor = 0.75,    -- 夾制：鑽孔只有孔口一個自由面時的半徑係數
	free_face_k = 1.0,        -- 側向自由面加成：抵抗線 B < R 時再 × (1 + k·(1 − B/R))
	drill_time = 1.5,         -- 鑽一個孔的時間 (s)
	fuse_time = 4,            -- 點火後幾秒爆炸 (s)
	detonator_range = 30,     -- 起爆器引爆幾公尺內的裝藥
	detonator_delay = 5,      -- 起爆器倒數 (s)
	hole_interval = 0.1,      -- 起爆器各孔依序起爆的間隔（段發）(s)
	anfo_radius = 2.5,        -- ANFO 柱狀裝藥每 1.5 m 一段的爆炸半徑 (m)（一段約 7 kg，比一條乳膠炸藥多很多）
	anfo_stemming = 1.5,      -- ANFO 孔口填塞長度 (m)
	hand_max_depth = 4,       -- 手動鑿岩機（手持風鑽）對鑽孔繼續按住加深，最深幾公尺 (m)
}

-- 警戒裂紋（fsmask.lua）：1 < FS < max 的岩格加上裂紋；設定鍵為 rockmech_fswarn_<key>
config.fswarn_defaults = {
	max = 2.0,                -- FS 低於此值（且 > 1）就顯示裂紋
	sound_gain = 3.0,         -- 裂紋出現或變嚴重時破裂聲的音量（0 = 不播，字幕也不顯示）；定位音效隨距離衰減，所以大於 1
	sound_distance = 32,      -- 破裂聲聽得到的距離 (m)
	dig_min = 0.25,           -- 有裂紋的岩石比較好挖（接近破壞已有微裂、強度較低）：FS → 1 時挖的時間乘上這個，FS = max 時不變，中間線性
}

-- 關鍵塊體（keyblock.lua）；設定鍵為 rockmech_keyblock_<key>
-- 被節理面與臨空面完全圍住的岩塊，以重力判斷落下／平面滑動／楔形滑動（φj 同節理弱面，凝聚力另設）
config.keyblock_defaults = {
	enabled = true,
	max_cells = 500,          -- 岩塊超過此格數視為與岩體相連（不判定）
	c = 0,                    -- 岩塊邊界節理的凝聚力 (MPa)：圍出岩塊的是連續、張開的節理，通常取 0
	clamp = 0.5,              -- 應力夾持的釋放係數 λ（Unwedge 式）：接觸面夾持力 = λ·σn·A；0 = 只考慮重力
	mass_clamp = 0,           -- 整體滑動稜柱的 λ（預設 0：坡面附近的應力視為已釋放，同邊坡設計慣例）
	mass = true,              -- 整體滑動：坡腳露出的節理面（或一對）上方的整個岩體一起滑出
	mass_radius = 28,         -- 整體滑動的讀取範圍半徑 (m)；岩體碰到範圍邊界視為沒有被圍住
	mass_max = 8000,          -- 整體滑動的岩體格數上限
	mass_floods = 48,         -- 每次檢查最多擴展幾根稜柱
	mass_budget_ms = 40,      -- 單次檢查超過此時間就記 log
}

-- 只有開挖造成的惡化才破壞（collapse.lua）；設定鍵為 rockmech_induced_<key>
-- 生成的地形視為已平衡：比較開挖前後，只有「開挖前穩定、開挖後不穩定」才破壞
config.induced_defaults = {
	enabled = true,
	touch_max = 200,          -- 既有的不穩定懸空岩體被玩家直接挖到時，不超過此格數就掉落
}

-- 節理弱面滑動（failure.lua，Jaeger single plane of weakness）；設定鍵為 rockmech_weakness_<key>
-- 目前三組節理共用同一組 cj、φj
config.weakness_defaults = {
	enabled = true,
	c = 0.05,                 -- 節理凝聚力 cj (MPa)
	phi = 30,                 -- 節理摩擦角 φj (deg)
	daylight = true,          -- 運動學條件：節理須傾向臨空面（或下方臨空）才會滑出
	wedge = true,             -- 楔形：兩組節理都穿過的格，沿交線滑動（交線須朝臨空面露出）
	max_spacing = 100,        -- 只有間距 ≤ 此值 (m) 的組做逐格滑動（遍在節理）；較大的明確節理只由塊體力學處理
	lateral_limit = 20,       -- 側向限制 λ (deg)：傾向與臨空面外法向夾角 ≤ λ 才能平面滑動（Markland），凸角除外
}

-- 懸臂／頂板彎曲斷裂（overhang.lua）；設定鍵為 rockmech_overhang_<key>
config.overhang_defaults = {
	enabled = true,
	scale = 1.0,              -- （舊設定，改用 rockmech_model_scale）σt 額外乘上此值
	tensile_other = 2.0,      -- 非岩性鍵結格（土、礦石…）的張力強度 (MPa)
	radius = 16,              -- 檢查範圍半徑 (m)；懸空群碰到範圍邊界時保守地不處理
	max_voxels = 30000,       -- 懸空群超過此格數保守地不處理（以欄為單位搜尋，大空間的頂板也要能判定）
	joints = true,            -- 節理切過的介面不傳張力（根部斷面 t_eff；完全切開則分離成獨立的塊）
	-- Terzaghi 鬆弛區 H_p = k·(B + H_t) 的 k(GSI)：三個點之間線性內插，兩端取端點
	terzaghi_gsi_a = 85,      -- 完整岩體：GSI ≥ 此值 k = 0（沒有岩石荷重）
	terzaghi_gsi_b = 50,      -- 中度塊狀
	terzaghi_k_b = 0.35,
	terzaghi_gsi_c = 25,      -- 破碎
	terzaghi_k_c = 1.10,
}

-- 懸空頂板的剪力（overhang.lua，與彎曲同一段頂板）與荷重轉移（failure.compute_deposits）；設定鍵為 rockmech_shear_<key>
config.shear_defaults = {
	enabled = true,           -- 懸空頂板也檢查剪力
	k = 2,                    -- 抗剪強度 τ0 = k·σt（Griffith：k = 2）
	max_span = 32,            -- 頂板荷重往外找支撐處最多幾格 (m)
}

-- 安息角滑動（collapse.lua）；設定鍵為 rockmech_slope_<key>
config.slope_defaults = {
	enabled = true,           -- 碎石超過安息角會移動（完整岩石不受安息角影響）
	angle = 35,               -- 碎石安息角 (deg)
	rain_drop = 10,           -- 時雨量 rain_max 時，鬆土的安息角降低幾度（照時雨量比例；weather.lua，/rain 指令）
	rain_max = 100,           -- 時雨量的上限 (mm/h)：台灣颱風的量級。降雨弱化跟 時雨量 / rain_max 成正比
	rain_c_loss = 0.35,       -- 時雨量 rain_max 時，表土凝聚力降低的比例（自立高度 H_c 跟著降）
}

-- 落石翻滾（rockfall.lua）的預設值；設定鍵為 rockmech_rockfall_<key>
config.rockfall_defaults = {
	enabled = true,
	max_active = 64,          -- 同時翻滾的岩塊上限，超過時改用直接落下
	rn = 0.30,                -- 非岩性表面（土、碎石等）的法向回彈係數
	rt = 0.75,                -- 非岩性表面的切向回彈係數
	mu_roll = 0.55,           -- 非岩性表面的滾動阻力係數
	impact_speed = 2.0,       -- 法向速度超過此值 (m/s) 才算撞擊（否則視為貼地滾動）
	stop_speed = 0.4,         -- 貼地且速度低於此值 (m/s) 持續 0.5 s 即停止
	max_time = 20,            -- 最長翻滾時間 (s)
}

-- 岩體強度（rockmass.lua）；設定鍵為 rockmech_rockmass_<key>
-- 另有：rockmech_model_scale（相似比 N）、rockmech_gsi（所有岩性的 GSI 剖面）、
-- rockmech_gsi_<岩性>、rockmech_mi_<岩性>
config.rockmass_defaults = {
	d = 0,                    -- Hoek-Brown 擾動係數 D（0 = 未擾動，1 = 嚴重爆破損傷）
}

-- 解析 GSI 剖面 "top" 或 "top,bottom,depth"；空字串回傳 nil
function config.parse_gsi(s)
	if s == nil or s == "" then return nil end
	local v = {}
	for tok in tostring(s):gmatch("[^,%s]+") do
		local n = tonumber(tok)
		if not n then return nil, "不是數字: " .. tok end
		v[#v + 1] = n
	end
	if #v ~= 1 and #v ~= 3 then return nil, "需要 1 個（GSI）或 3 個（地表 GSI,深部 GSI,過渡深度）數字" end
	local function g(x) return math.max(1, math.min(100, x)) end
	if #v == 1 then return {top = g(v[1])} end
	return {top = g(v[1]), bottom = g(v[2]), depth = math.max(0, v[3])}
end

-- 節理組可由設定覆寫的槽位數（rockmech_joint_set_1 .. _N）
config.MAX_SET_OVERRIDES = 6   -- 第 4 組以後是新增的組（須連號）；方塊變體跡線只畫前幾組，mesh 模式全部都畫

---------------------------------------------------------------------------
-- 解析與驗證
---------------------------------------------------------------------------

local function copy(t)
	local r = {}
	for k, v in pairs(t) do
		r[k] = type(v) == "table" and copy(v) or v
	end
	return r
end
config.copy = copy

local function parse_bool(s)
	if s == nil then return nil end
	s = tostring(s):lower()
	if s == "true" or s == "1" or s == "yes" then return true end
	if s == "false" or s == "0" or s == "no" then return false end
	return nil
end

-- 解析 "dip,dipdir,spacing,persistence,phi"；空字串回傳 nil。
function config.parse_joint_set_string(s)
	if s == nil then return nil end
	s = tostring(s):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return nil end
	local vals = {}
	for tok in s:gmatch("[^,]+") do
		local v = tonumber((tok:gsub("%s", "")))
		if v == nil then
			return nil, "非數字欄位: '" .. tok .. "'"
		end
		vals[#vals + 1] = v
	end
	if #vals ~= 5 then
		return nil, "需要 5 個欄位 dip,dipdir,spacing,persistence,phi，實得 " .. #vals
	end
	return {dip = vals[1], dipdir = vals[2], spacing = vals[3],
		persistence = vals[4], phi = vals[5]}
end

-- 檢查並夾限一組節理參數；回傳警告訊息陣列。
function config.validate_joint_set(js)
	local warn = {}
	local function clamp(field, lo, hi)
		local v = js[field]
		if type(v) ~= "number" or v ~= v then
			warn[#warn + 1] = ("%s.%s 不是數字，改為 %s"):format(js.name, field, lo)
			js[field] = lo
		elseif v < lo or v > hi then
			local nv = math.min(hi, math.max(lo, v))
			warn[#warn + 1] = ("%s.%s=%s 超出 [%s,%s]，夾限為 %s")
				:format(js.name, field, v, lo, hi, nv)
			js[field] = nv
		end
	end
	clamp("dip", 0, 90)
	js.dipdir = (type(js.dipdir) == "number" and js.dipdir or 0) % 360
	-- spacing ≥ 1：保證相鄰兩格中心之間最多只穿過同一組的一個平面
	clamp("spacing", 1, 1e6)
	clamp("persistence", 0, 1)
	clamp("phi", 0, 89)
	return warn
end

-- 由設定讀取函式產生最終設定表。
-- get(key) 回傳字串或 nil（引擎內為 core.settings:get）。
-- 回傳 cfg, warnings
function config.load(get)
	get = get or function() return nil end
	local warnings = {}
	local cfg = {
		lithologies = copy(config.lithologies),
		lithology_order = copy(config.lithology_order),
		layers = copy(config.layers),
		ores = copy(config.ores),
		joint_sets = copy(config.joint_sets),
	}

	cfg.surface_y = tonumber(get("rockmech_surface_y")) or config.defaults.surface_y
	-- 煤層 rockmech_coal_seam = 傾角,傾向,真厚度,y0[,x0,z0]；露天坑 rockmech_open_pit = x0,z0,底半徑,深度,階高,階寬[,坡道坡度 %]
	local function numbers(key, count)
		local s = get(key)
		if not s or s == "" then return nil end
		local v = {}
		for tok in tostring(s):gmatch("[^,%s]+") do v[#v + 1] = tonumber(tok) end
		if #v < count then
			warnings[#warnings + 1] = key .. " 需要 " .. count .. " 個數字（忽略）"
			return nil
		end
		return v
	end
	local seam = numbers("rockmech_coal_seam", 4)
	if seam then
		local dip, dd = math.rad(seam[1]), math.rad(seam[2])
		cfg.coal_seam = {t = seam[3], y0 = seam[4], x0 = seam[5] or 0, z0 = seam[6] or 0,
			tan_dip = math.tan(dip), cos_dip = math.cos(dip), sin_dd = math.sin(dd), cos_dd = math.cos(dd)}
		-- 礦帶 rockmech_coal_seam_lanes = 寬度,kmin,kmax：沿 x 每 W 公尺一條礦帶（第 k 帶中心 x = k·W），
		-- 每帶一條一模一樣的煤層（帶內座標 x − k·W），只在自己的帶內；kmin..kmax 以外沒有煤
		local lanes = numbers("rockmech_coal_seam_lanes", 3)
		if lanes and lanes[1] > 0 then
			cfg.coal_seam.lane_w, cfg.coal_seam.lane_min, cfg.coal_seam.lane_max = lanes[1], lanes[2], lanes[3]
			-- 礦帶地形 rockmech_lane_terrain = 脊高,脊半寬,山丘高,山丘西界,山丘東界,走廊z,漸變長（m，x 是帶內座標）：
			-- 帶與帶交界一道山脊；山丘西界..東界之間是礦區的山丘（煤層從中間切過）；z < 走廊z 是相連的平地（沒有煤）
			local t = numbers("rockmech_lane_terrain", 7)
			if t then
				cfg.lane_terrain = {ridge_h = t[1], ridge_hw = t[2], hill_h = t[3], hill_lx0 = t[4], hill_lx1 = t[5],
					z0 = t[6], taper = math.max(1, t[7])}
				-- 煤層離帶的西邊界留幾公尺：隔壁帶的煤不會在交界上露出來
				cfg.coal_seam.lane_margin = 12
				cfg.coal_seam.z_min = t[6] - t[7] / 2
			end
		end
	end
	local pit = numbers("rockmech_open_pit", 6)
	if pit then
		cfg.open_pit = {x0 = pit[1], z0 = pit[2], R = pit[3], D = pit[4], H = pit[5], W = pit[6],
			G = math.max(1, pit[7] or 10) / 100}
	end
	-- 節理延續性：patch = 一片一片（片的大小 ≈ 間距，會切出完整的岩塊）；face = 舊版（每個格面各自判定）
	cfg.joint_persistence = get("rockmech_joint_persistence") == "face" and "face" or "patch"
	cfg.joint_lattice = math.max(2, math.min(16, math.floor(
		tonumber(get("rockmech_joint_lattice")) or config.defaults.joint_lattice)))
	cfg.k0 = tonumber(get("rockmech_k0")) or config.defaults.k0
	if cfg.k0 < 0 then
		warnings[#warnings + 1] = "rockmech_k0 < 0，改為 0"
		cfg.k0 = 0
	end
	-- 水平主應力：σH = K_H·σv + σH0、σh = K_h·σv + σh0，σH 方位由北順時針（度）。
	-- 未設定時 K_H = K_h = K0、σH0 = σh0 = 0（與只有 K0 時相同）
	cfg.KH = math.max(0, tonumber(get("rockmech_k_hmax")) or cfg.k0)
	cfg.Kh = math.max(0, tonumber(get("rockmech_k_hmin")) or cfg.k0)
	cfg.sH0 = math.max(0, tonumber(get("rockmech_sigma_hmax0")) or 0)
	cfg.sh0 = math.max(0, tonumber(get("rockmech_sigma_hmin0")) or 0)
	cfg.sH_azimuth = (tonumber(get("rockmech_sigma_hmax_azimuth")) or 0) % 360
	local rs = parse_bool(get("rockmech_replace_stone"))
	if rs == nil then rs = config.defaults.replace_stone end
	cfg.replace_stone = rs
	local ss = parse_bool(get("rockmech_strip_soil"))
	if ss == nil then ss = config.defaults.strip_soil end
	cfg.strip_soil = ss
	local ol = parse_bool(get("rockmech_only_lithologies"))
	if ol == nil then ol = config.defaults.only_lithologies end
	cfg.only_lithologies = ol
	-- 產生地圖時，比地表（surface_y）高 1 m 以上的天然岩石鋪 1–3 m 表土、種樹，山腳鋪漸薄的坡腳（mapgen.lua）
	local mt = parse_bool(get("rockmech_mapgen_topsoil"))
	cfg.mapgen_topsoil = mt ~= false
	-- 山坡露出岩面的面積比例（一片一片的露頭，stress.outcrop_factor）
	cfg.outcrop = math.max(0, math.min(0.9, tonumber(get("rockmech_outcrop")) or 0.2))
	local lm = get("rockmech_lith_mode")
	cfg.lith_mode = (lm == "zones" or lm == "layers") and lm or config.defaults.lith_mode
	cfg.zone_width = math.max(4, math.floor(tonumber(get("rockmech_zone_width")) or config.defaults.zone_width))
	cfg.zone_order = copy(config.zone_order)
	-- 區帶順序（rockmech_zone_order = "granite" 或 "granite,shale"）：只有一種時整個世界都是該岩性
	local zo = get("rockmech_zone_order")
	if zo and zo ~= "" then
		local list = {}
		for tok in zo:gmatch("[^,%s]+") do
			if config.lithologies[tok] then
				list[#list + 1] = tok
			else
				warnings[#warnings + 1] = "rockmech_zone_order: 沒有岩性 " .. tok .. "（忽略）"
			end
		end
		if #list > 0 then cfg.zone_order = list end
	end

	-- 讀取一組 rockmech_<prefix>_<key> 設定
	-- legacy：改名前的前綴（舊設定鍵仍讀得到，新鍵優先）
	local function load_section(prefix, defaults, legacy)
		local t = copy(defaults)
		for key, def in pairs(defaults) do
			local name = "rockmech_" .. prefix .. "_" .. key
			local raw = get(name)
			if (raw == nil or raw == "") and legacy then raw = get("rockmech_" .. legacy .. "_" .. key) end
			if type(def) == "boolean" then
				local b = parse_bool(raw)
				if b ~= nil then t[key] = b end
			elseif type(def) == "string" then
				if raw ~= nil and raw ~= "" then t[key] = raw end
			elseif raw ~= nil and raw ~= "" then
				local v = tonumber(raw)
				if v then
					t[key] = v
				else
					warnings[#warnings + 1] = name .. " 不是數字（忽略）"
				end
			end
		end
		return t
	end

	-- 軸差破壞
	local f = load_section("failure", config.failure_defaults)
	f.radius = math.max(1, math.floor(f.radius))
	f.window = math.max(1, math.floor(f.window))
	f.overburden_scan = math.max(0, math.floor(f.overburden_scan))
	f.secondary_factor = math.max(0, math.min(1, f.secondary_factor))
	f.initial_scan_max = math.max(16, math.floor(f.initial_scan_max))
	f.gamma_other = math.max(0, f.gamma_other)
	f.max_cascade = math.max(0, math.floor(f.max_cascade))
	if f.strength_scale <= 0 then
		warnings[#warnings + 1] = "rockmech_failure_strength_scale ≤ 0，改為 1"
		f.strength_scale = 1
	end
	cfg.failure = f

	-- 節理材質
	local jt = load_section("jointtex", config.jointtex_defaults)
	jt.line_alpha = math.max(0, math.min(255, math.floor(jt.line_alpha)))
	jt.face_ratio = math.max(0, math.min(255, math.floor(jt.face_ratio)))
	if jt.style ~= "plane" and jt.style ~= "edges" and jt.style ~= "mesh" then
		warnings[#warnings + 1] = "rockmech_jointtex_style 只能是 plane、edges 或 mesh，改用 plane"
		jt.style = "plane"
	end
	jt.mesh_range = math.max(1, math.min(6, math.floor(jt.mesh_range)))
	jt.mesh_width = math.max(0.01, math.min(0.5, jt.mesh_width))
	jt.max_lines = math.max(1, math.min(3, math.floor(jt.max_lines)))
	jt.plane_res = math.max(16, math.min(64, math.floor(jt.plane_res)))
	jt.plane_width = math.max(0.5, math.min(8, jt.plane_width))
	for _, k in ipairs({"line_color", "face_color"}) do
		if not jt[k]:match("^#%x%x%x%x%x%x$") then
			warnings[#warnings + 1] = "rockmech_jointtex_" .. k .. " 應為 #RRGGBB，改用預設"
			jt[k] = config.jointtex_defaults[k]
		end
	end
	cfg.jointtex = jt

	-- 掉落破碎
	cfg.fallbreak = load_section("fallbreak", config.fallbreak_defaults)
	cfg.fallbreak.break_height = math.max(0.01, cfg.fallbreak.break_height)

	-- 穩定判定
	cfg.stability = load_section("stability", config.stability_defaults, "support")
	cfg.stability.radius = math.max(2, math.floor(cfg.stability.radius))
	cfg.stability.max_voxels = math.max(1, math.floor(cfg.stability.max_voxels))
	cfg.stability.rigid_max = math.max(1, math.floor(cfg.stability.rigid_max))

	-- 開挖周圍的彈性應力場（原型）
	cfg.fem = load_section("fem", config.fem_defaults)
	cfg.fem.radius = math.max(4, math.min(32, math.floor(cfg.fem.radius)))
	cfg.fem.coarse = math.max(1, math.min(8, math.floor(cfg.fem.coarse)))
	cfg.fem.coarse_blend = math.max(0.01, math.min(1, cfg.fem.coarse_blend))
	cfg.fem.nu = math.max(0, math.min(0.45, cfg.fem.nu))
	cfg.fem.active_range = math.max(0, cfg.fem.active_range)

	-- 支護
	cfg.support = load_section("support", config.support_defaults)
	cfg.support.shotcrete_p = math.max(0, cfg.support.shotcrete_p)
	cfg.support.bolt_grip = math.max(0, cfg.support.bolt_grip)
	cfg.support.bolt_yield = math.max(0, cfg.support.bolt_yield)
	cfg.support.post_d = math.max(0, cfg.support.post_d)
	cfg.support.post_ucs = math.max(0, cfg.support.post_ucs)
	cfg.support.post_e = math.max(0, cfg.support.post_e)
	cfg.support.post_max_len = math.max(1, math.floor(cfg.support.post_max_len))
	cfg.support.post_fem_area = math.max(0.001, math.min(1, cfg.support.post_fem_area))

	-- 爆破破碎
	cfg.blast = load_section("blast", config.blast_defaults)
	cfg.blast.ucs_ref = math.max(0.1, cfg.blast.ucs_ref)
	cfg.blast.ucs_exp = math.max(0, math.min(1, cfg.blast.ucs_exp))
	cfg.blast.inner = math.max(0, math.min(1, cfg.blast.inner))

	-- 警戒裂紋
	cfg.fswarn = load_section("fswarn", config.fswarn_defaults)
	cfg.fswarn.max = math.max(1.01, math.min(5, cfg.fswarn.max))
	cfg.fswarn.sound_gain = math.max(0, cfg.fswarn.sound_gain)
	cfg.fswarn.sound_distance = math.max(1, cfg.fswarn.sound_distance)
	cfg.fswarn.dig_min = math.max(0.01, math.min(1, cfg.fswarn.dig_min))

	-- 關鍵塊體
	cfg.keyblock = load_section("keyblock", config.keyblock_defaults)
	cfg.keyblock.max_cells = math.max(1, math.floor(cfg.keyblock.max_cells))
	cfg.keyblock.c = math.max(0, cfg.keyblock.c)
	cfg.keyblock.clamp = math.max(0, math.min(2, cfg.keyblock.clamp))
	cfg.keyblock.mass_clamp = math.max(0, math.min(2, cfg.keyblock.mass_clamp))
	cfg.keyblock.mass_radius = math.max(8, math.min(64, math.floor(cfg.keyblock.mass_radius)))
	cfg.keyblock.mass_max = math.max(100, math.floor(cfg.keyblock.mass_max))
	cfg.keyblock.mass_floods = math.max(1, math.floor(cfg.keyblock.mass_floods))

	-- 只有開挖造成的惡化才破壞
	cfg.induced = load_section("induced", config.induced_defaults)

	-- 節理弱面滑動
	cfg.weakness = load_section("weakness", config.weakness_defaults)
	cfg.weakness.c = math.max(0, cfg.weakness.c)
	cfg.weakness.phi = math.max(0, math.min(89, cfg.weakness.phi))
	cfg.weakness.lateral_limit = math.max(0, math.min(90, cfg.weakness.lateral_limit))
	cfg.weakness.max_spacing = math.max(0, cfg.weakness.max_spacing)

	-- 懸臂／頂板斷裂
	cfg.overhang = load_section("overhang", config.overhang_defaults)
	cfg.overhang.scale = math.max(0.001, cfg.overhang.scale)
	cfg.overhang.radius = math.max(4, math.floor(cfg.overhang.radius))
	cfg.overhang.max_voxels = math.max(1, math.floor(cfg.overhang.max_voxels))

	-- 懸空頂板的剪力、荷重轉移
	cfg.shear = load_section("shear", config.shear_defaults)
	cfg.shear.k = math.max(0, cfg.shear.k)
	cfg.shear.max_span = math.max(1, math.floor(cfg.shear.max_span))

	-- 安息角滑動
	cfg.slope = load_section("slope", config.slope_defaults)
	cfg.slope.angle = math.min(89, math.max(1, cfg.slope.angle))

	-- 落石翻滾
	local rf = load_section("rockfall", config.rockfall_defaults)
	rf.max_active = math.max(0, math.floor(rf.max_active))
	for _, k in ipairs({"rn", "rt"}) do rf[k] = math.min(1, math.max(0, rf[k])) end
	rf.mu_roll = math.max(0, rf.mu_roll)
	cfg.rockfall = rf

	-- 岩體強度：相似比 N、擾動 D、各岩性的 GSI 剖面與 mi
	cfg.rubble_squeeze = math.max(0, tonumber(get("rockmech_rubble_squeeze")) or 0.125)
	cfg.vehicle_slide_mu = math.max(0, tonumber(get("rockmech_vehicle_slide_mu")) or 0.5)
	cfg.haul_max_grade = math.max(1, math.min(45, tonumber(get("rockmech_haul_max_grade")) or 17))   -- 礦卡最大爬坡角 (deg)
	cfg.rubble_sound_gain = math.max(0, tonumber(get("rockmech_rubble_sound_gain")) or 1)
	cfg.vehicle_sound_gain = math.max(0, tonumber(get("rockmech_vehicle_sound_gain")) or 1)
	cfg.shotcrete_speed = math.max(0.1, tonumber(get("rockmech_shotcrete_speed")) or 1.5)
	-- 經營模式（career.lua）
	cfg.career = get("rockmech_career") == "true" or get("rockmech_career") == true
	cfg.solo = get("rockmech_solo") == "true" or get("rockmech_solo") == true    -- 單機版（standalone/）：沒有老師功能
	cfg.career_start = math.max(0, tonumber(get("rockmech_career_start")) or 23000)
	-- 分組（team.lua）：組數（A, B, …）、各組營地沿 z 相隔幾公尺、名單檔（世界資料夾裡）、名單外的名稱能不能登入
	cfg.career_teams = math.max(1, math.min(26, math.floor(tonumber(get("rockmech_career_teams")) or 8)))
	cfg.career_site_spacing = math.max(60, tonumber(get("rockmech_career_site_spacing")) or 150)
	-- 營地（帳篷、破碎站、落腳點）離礦帶中心往東幾公尺：礦區在西半邊，營地放東邊一點
	cfg.career_camp_dx = tonumber(get("rockmech_career_camp_dx")) or 0
	-- 每日定時重開（restart.lua）："HH:MM"，空字串或沒設就不重開
	cfg.daily_restart = get("rockmech_daily_restart")
	cfg.drone_range = math.max(20, tonumber(get("rockmech_drone_range")) or 200)   -- 無人機最大飛行距離（離起飛點水平，m）
	if cfg.daily_restart == "" then cfg.daily_restart = nil end
	cfg.career_roster = get("rockmech_career_roster") or "students.csv"
	if cfg.career_roster == "" then cfg.career_roster = "students.csv" end
	cfg.career_roster_only = get("rockmech_career_roster_only") ~= "false" and get("rockmech_career_roster_only") ~= false
	cfg.hand_ore_time = math.max(0.1, tonumber(get("rockmech_hand_ore_time")) or 60)
	cfg.hand_rubble_time = math.max(0.1, tonumber(get("rockmech_hand_rubble_time")) or 4)
	cfg.pick_rock_time = math.max(0.1, tonumber(get("rockmech_pick_rock_time")) or 8)
	cfg.pick_rubble_time = math.max(0.1, tonumber(get("rockmech_pick_rubble_time")) or 2)
	cfg.shovel_time = math.max(0.1, tonumber(get("rockmech_shovel_time")) or 0.5)
	cfg.cart_blocks = math.max(1, math.floor(tonumber(get("rockmech_cart_blocks")) or 3))
	cfg.shop = copy(config.shop)
	for _, it in ipairs(cfg.shop) do
		it.price = math.max(0, tonumber(get("rockmech_price_" .. it.key)) or it.price)
	end
	-- 無人卡車綁定怪手（vehicle_ahs.lua）：車尾離怪手車身、倒車的距離、怪手移動多遠要重新停車、離路線起點多遠就不去
	cfg.ahs_tail_gap = math.max(0.6, tonumber(get("rockmech_ahs_tail_gap")) or 1.5)
	cfg.ahs_back_in = math.max(0.5, tonumber(get("rockmech_ahs_back_in")) or 3)
	cfg.ahs_follow = math.max(1, tonumber(get("rockmech_ahs_follow")) or 6)
	cfg.ahs_max_dist = math.max(10, tonumber(get("rockmech_ahs_max_dist")) or 60)
	-- 怪手操作員日薪（wages.lua）：每個交易日 $，按雇用時間比例、只在組員在線時計
	cfg.operator_wage = math.max(0, tonumber(get("rockmech_operator_wage")) or 3000)
	cfg.diesel_price = math.max(0, tonumber(get("rockmech_diesel_price")) or 50)   -- 柴油價（$/L，fuel.lua）
	-- 煤層帶不帶節理（預設不帶：節理組只在頁岩裡）
	cfg.coal_joints = parse_bool(get("rockmech_coal_joints")) == true
	cfg.crusher_rate = math.max(0.1, tonumber(get("rockmech_crusher_rate")) or 2)
	cfg.crusher_big_rate = math.max(0.1, tonumber(get("rockmech_crusher_big_rate")) or 10)   -- 大型破碎站 (t/s)
	cfg.crusher_fee = math.max(0, tonumber(get("rockmech_crusher_fee")) or 30)
	cfg.dump_fee = math.max(0, tonumber(get("rockmech_dump_fee")) or 0)            -- 破碎站切換成廢石場：每噸棄置費
	cfg.rubble_density = math.max(0.1, tonumber(get("rockmech_rubble_density")) or 2.5)   -- 計價用的碎石密度 (t/m³)
	-- 浮動礦價（crusher.lua）：交易日長度 (s，遊戲經過的時間)、每個交易日的波動（對數的標準差）、往基準價拉回的比例、
	-- 價格上下限（基準價的倍數）
	cfg.price_period = math.max(10, tonumber(get("rockmech_price_period")) or 1200)
	cfg.price_vol = math.max(0, tonumber(get("rockmech_price_vol")) or 0.08)
	cfg.price_revert = math.max(0, math.min(1, tonumber(get("rockmech_price_revert")) or 0.15))
	cfg.price_min = math.max(0.01, tonumber(get("rockmech_price_min")) or 0.5)
	cfg.price_max = math.max(cfg.price_min, tonumber(get("rockmech_price_max")) or 2)
	-- 選礦場（plant.lua）：處理能力 (t/s)、煤回收率、矸石混入率、每座儲料塔容量 (m³)、放料速度 (t/s)
	cfg.plant_rate = math.max(0.1, tonumber(get("rockmech_plant_rate")) or 3)
	cfg.plant_recovery = math.max(0, math.min(1, tonumber(get("rockmech_plant_recovery")) or 0.95))
	cfg.plant_misplaced = math.max(0, math.min(1, tonumber(get("rockmech_plant_misplaced")) or 0.10))
	cfg.plant_bin = math.max(1, tonumber(get("rockmech_plant_bin")) or 50)
	cfg.plant_load_rate = math.max(0.1, tonumber(get("rockmech_plant_load_rate")) or 4)
	cfg.plant_reach = math.max(1, tonumber(get("rockmech_plant_reach")) or 10)     -- 放料臂伸得到的水平距離 (m)
	-- 油壓破碎錘（vehicle_excavator.lua）：敲碎一格岩石的時間 = UCS × 這個 (s/MPa)。頁岩 30 MPa 約 1.5 秒、花崗岩 180 MPa 約 9 秒
	cfg.breaker_rate = math.max(0, tonumber(get("rockmech_breaker_s_per_mpa")) or 0.05)
	-- 表土（根系）的凝聚力 (kPa)：決定自立高度 H_c = 4c/γ·tan(45° + φ/2)（woodwork.lua）
	cfg.topsoil_c = math.max(0, tonumber(get("rockmech_topsoil_c")) or 5)
	-- 輸送帶（conveyor.lua）：運量 (t/s)、帶速 (m/s)、最大傾角 (deg，碎石在輸送帶上不往回滑的上限)
	cfg.conveyor_rate = math.max(0.1, tonumber(get("rockmech_conveyor_rate")) or 4)
	cfg.conveyor_speed = math.max(0.2, math.min(10, tonumber(get("rockmech_conveyor_speed")) or 2))
	cfg.conveyor_max_angle = math.max(0, math.min(45, tonumber(get("rockmech_conveyor_max_angle")) or 16))
	-- 交通壓實（vehicles.lua）：車子總重（含載重）多少噸以上才壓得實（排除手推車）、壓幾趟壓實、壓實後的摩擦角 (deg)
	cfg.compact_mass = math.max(0, tonumber(get("rockmech_compact_mass")) or 10)
	cfg.compact_passes = math.max(1, math.floor(tonumber(get("rockmech_compact_passes")) or 4))
	cfg.compact_phi = math.min(89, math.max(1, tonumber(get("rockmech_compact_phi")) or 75))
	cfg.model_scale = tonumber(get("rockmech_model_scale")) or 1
	if cfg.model_scale <= 0 then
		warnings[#warnings + 1] = "rockmech_model_scale ≤ 0，改為 1"
		cfg.model_scale = 1
	end
	cfg.rockmass = load_section("rockmass", config.rockmass_defaults)
	cfg.rockmass.d = math.max(0, math.min(1, cfg.rockmass.d))
	local gsi_all, gerr = config.parse_gsi(get("rockmech_gsi"))
	if gerr then warnings[#warnings + 1] = "rockmech_gsi: " .. gerr .. "（忽略）" end
	for key, lith in pairs(cfg.lithologies) do
		local prof, err = config.parse_gsi(get("rockmech_gsi_" .. key))
		if err then warnings[#warnings + 1] = "rockmech_gsi_" .. key .. ": " .. err .. "（忽略）" end
		lith.gsi = prof or gsi_all or lith.gsi or {top = 100}
		local mi = tonumber(get("rockmech_mi_" .. key))
		if mi and mi > 0 then lith.mi = mi end
	end

	-- 節理組覆寫
	for i = 1, config.MAX_SET_OVERRIDES do
		local key = "rockmech_joint_set_" .. i
		local o, err = config.parse_joint_set_string(get(key))
		if err then
			warnings[#warnings + 1] = key .. ": " .. err .. "（忽略）"
		elseif o then
			local js = cfg.joint_sets[i]
			if not js then
				js = {id = i, name = "J" .. i, color = "#ffffff"}
				cfg.joint_sets[i] = js
			end
			for k, v in pairs(o) do js[k] = v end
		end
	end
	-- 一組 persistence = 0 等同停用，保留在表中（羅盤仍會顯示其平面）

	for _, js in ipairs(cfg.joint_sets) do
		for _, w in ipairs(config.validate_joint_set(js)) do
			warnings[#warnings + 1] = w
		end
	end

	for _, layer in ipairs(cfg.layers) do
		if not cfg.lithologies[layer.lith] then
			warnings[#warnings + 1] = "分層引用了不存在的岩性: " .. tostring(layer.lith)
		end
	end

	return cfg, warnings
end

return config
