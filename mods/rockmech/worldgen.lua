-- rockmech/worldgen.lua
-- 地圖產生器：主選單新開的世界第一次啟動時（世界資料夾還沒有 rockmech.conf），擲一套地質寫進 rockmech.conf，
-- 每個新世界都不一樣。已經有 rockmech.conf 的世界（上課伺服器、手寫的教學圖）完全不動。
-- 全域設定 rockmech_world_generator = false 可以關掉（新世界就照全域預設）。
-- 地形也換成上課的圖那一套（平地加緩丘、沒有湖和洞穴），主選單選什麼地形產生器都一樣。
-- 擲的東西（範圍限制在教學上合理、挖得到煤的區間）：
--   圍岩：頁岩或砂岩（煤系是沉積岩，不擲花崗岩），GSI 40–65
--   煤層：傾角 10–35°、傾向任意、真厚度 4–12 m、出生點底下 8–25 m 深（往上傾的方向會露頭）
--   節理：第 1 組是層理（跟煤層同位態），第 2、3 組陡傾（60–85°）、走向大致互相垂直；間距 2–5 m；Jr、Ja 取 Q 法表格值
--   現地應力：K_Hmax 1.0–2.0、K_hmin 0.6–1.0（不超過 K_Hmax）、σHmax 方位 0–179°
-- 地質不直接顯示（學生要自己鑽岩心、量節理）；老師用 /rockmech_geology 查（rockmech 權限）。
-- init.lua 在讀設定之前呼叫 generate(world_conf)。

local M = {}

local function pick(r, t) return t[r:next(1, #t)] end
local function range(r, a, b) return a + (b - a) * r:next(0, 10000) / 10000 end
local function round(v, step) step = step or 1; return math.floor(v / step + 0.5) * step end

function M.generate(world_conf)
	if world_conf:has("rockmech_joint_lattice") or world_conf:has("rockmech_zone_order") or world_conf:has("rockmech_generated") then
		return false
	end
	local on = core.settings:get_bool("rockmech_world_generator", true)
	if not on then return false end
	local seed_str = core.get_mapgen_setting("seed") or ""
	if seed_str == "" then seed_str = tostring(os.time()) end
	local seed = (tonumber(seed_str) or os.time()) % 2147483647        -- 世界種子很大（存成字串），取餘數給亂數
	local r = PcgRandom(math.floor(seed))

	local lith = pick(r, {"shale", "sandstone"})
	local gsi = round(range(r, 40, 65))
	local dip = round(range(r, 10, 35))
	local dipdir = r:next(0, 359)
	local thick = round(range(r, 4, 12))
	local depth = round(range(r, 8, 25))
	local d2 = r:next(0, 359)
	local d3 = (d2 + 90 + r:next(-15, 15)) % 360
	local function sp() return round(range(r, 2, 5), 0.5) end
	local function jr() return pick(r, {1, 1.5, 2, 3}) end
	local function ja() return pick(r, {1, 2, 3, 4}) end
	local kH = round(range(r, 1.0, 2.0), 0.1)
	local kh = math.min(kH, round(range(r, 0.6, 1.0), 0.1))
	local az = r:next(0, 179)

	local set = function(k, v) world_conf:set("rockmech_" .. k, tostring(v)) end
	set("generated", seed_str)
	set("strip_soil", "true")
	set("only_lithologies", "true")
	set("lith_mode", "zones")
	set("zone_width", 100000)
	set("zone_order", lith)
	set("gsi_" .. lith, gsi)
	-- 第 1 組：層理（跟煤層同位態，煤質軟、填充物多）；第 2、3 組：陡傾的節理
	set("joint_set_1", ("%d,%d,%g,0.7,1.5,3"):format(dip, dipdir, sp()))
	set("joint_set_2", ("%d,%d,%g,0.7,%g,%g"):format(r:next(60, 85), d2, sp(), jr(), ja()))
	set("joint_set_3", ("%d,%d,%g,0.7,%g,%g"):format(r:next(60, 85), d3, sp(), jr(), ja()))
	set("joint_persistence", "patch")
	set("jointtex_style", "mesh")
	set("surface_y", 0)
	set("joint_lattice", 8)
	set("k_hmax", kH)
	set("k_hmin", kh)
	set("sigma_hmax_azimuth", az)
	set("model_scale", 1)
	set("weakness_c", 0)
	set("weakness_max_spacing", 1.5)
	set("coal_seam", ("%d,%d,%d,%d"):format(dip, dipdir, thick, -depth))
	set("career", "true")
	world_conf:write()
	-- 地形照上課的圖：平地加緩丘，沒有湖、海、洞穴（主選單選的地形產生器換掉；只有新世界第一次載入時改得動）
	local mg = {mg_name = "flat", mg_flags = "nocaves, nodungeons, light, nodecorations, nobiomes, noores",
		mgflat_spflags = "nolakes, hills, nocaverns", mgflat_ground_level = "0", mgflat_hill_threshold = "0.35",
		mgflat_hill_steepness = "64", water_level = "-31000"}
	for k, v in pairs(mg) do core.set_mapgen_setting(k, v, true) end
	core.log("action", ("[rockmech] 地圖產生器：種子 %s → %s GSI %d、煤層 %d°/%03d° 厚 %d m 深 %d m"):format(
		seed_str, lith, gsi, dip, dipdir, thick, depth))
	return true
end

-- 老師查這個世界的地質（rockmech 權限）
function M.register_command()
	local S = rockmech.S
	core.register_chatcommand("rockmech_geology", {
		description = S("Show this world's geology (teacher)"),
		privs = {rockmech = true},
		func = function()
			-- 直接讀這個世界的 rockmech.conf（產生器寫的，或手寫的）
			local w = Settings(core.get_worldpath() .. "/rockmech.conf")
			local function g(k) local v = w:get("rockmech_" .. k); return v and v ~= "" and v or "-" end
			local lith = g("zone_order")
			local key = lith:match("^[^,]+")
			local L = rockmech.cfg.lithologies[key]
			local out = {S("Host rock: @1", L and S(L.description) or lith) .. "  GSI " .. g("gsi_" .. key)}
			local cs = g("coal_seam")
			local dip, dd, t, y0 = cs:match("^([%d.]+),([%d.]+),([%d.]+),(%-?[%d.]+)")
			if dip then out[#out + 1] = S("Coal seam: dip @1°, dip direction @2°, thickness @3 m, @4 m below spawn", dip, dd, t, tostring(-tonumber(y0))) end
			for i = 1, 3 do out[#out + 1] = ("J%d  %s"):format(i, g("joint_set_" .. i)) .. "  (dip,dipdir,spacing,persistence,Jr,Ja)" end
			out[#out + 1] = ("K_Hmax %s  K_hmin %s  σHmax %s°"):format(g("k_hmax"), g("k_hmin"), g("sigma_hmax_azimuth"))
			if g("generated") ~= "-" then out[#out + 1] = S("Generated from seed @1", g("generated")) end
			return true, table.concat(out, "\n")
		end,
	})
end

return M
