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
--   color       著色（ColorString），用於材質
--   cracky      Luanti 挖掘群組等級（1 最硬、3 最軟）
config.lithologies = {
	sandstone = {
		name = "sandstone", description = "Sandstone (砂岩)",
		gamma = 24.0, ucs = 60.0, tensile = 4.0,
		color = "#c9a46a", cracky = 3,
	},
	shale = {
		name = "shale", description = "Shale (頁岩)",
		gamma = 25.0, ucs = 30.0, tensile = 2.0,
		color = "#3c4048", cracky = 3,
	},
	granite = {
		name = "granite", description = "Granite (花崗岩)",
		gamma = 26.5, ucs = 180.0, tensile = 10.0,
		color = "#d2b4ac", cracky = 2,
	},
}

-- 註冊順序（固定，讓 content id / 測試結果可重現）
config.lithology_order = {"sandstone", "shale", "granite"}

-- 依深度分層：h = y0 - y，h < bottom 即屬於該層（由上往下排列）。
-- h < 0（高於 y0 的山丘）歸入第一層。
config.layers = {
	{lith = "sandstone", bottom = 20},
	{lith = "shale",     bottom = 60},
	{lith = "granite",   bottom = math.huge},
}

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
	k0 = 0.5,             -- σh / σv
	replace_stone = true, -- 地圖生成時把 stone 換成本 mod 岩性
}

-- 節理組可由設定覆寫的槽位數（rockmech_joint_set_1 .. _N）
config.MAX_SET_OVERRIDES = 3

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
		joint_sets = copy(config.joint_sets),
	}

	cfg.surface_y = tonumber(get("rockmech_surface_y")) or config.defaults.surface_y
	cfg.k0 = tonumber(get("rockmech_k0")) or config.defaults.k0
	if cfg.k0 < 0 then
		warnings[#warnings + 1] = "rockmech_k0 < 0，改為 0"
		cfg.k0 = 0
	end
	local rs = parse_bool(get("rockmech_replace_stone"))
	if rs == nil then rs = config.defaults.replace_stone end
	cfg.replace_stone = rs

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
