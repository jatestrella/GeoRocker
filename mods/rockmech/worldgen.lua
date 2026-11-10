-- rockmech/worldgen.lua
-- 地圖產生器：新世界第一次啟動時（世界資料夾的 rockmech.conf 還沒有地質設定），擲一套地質寫進 rockmech.conf，
-- 每個新世界都不一樣（同一個種子同一套）。已經有地質設定的世界（上課伺服器、手寫的教學圖）完全不動。
-- 全域設定 rockmech_world_generator = false 可以關掉。
-- GeoRocker 開始畫面的「自訂煤礦」把滑桿（0–100）寫成 rockmech_gen_*，沒寫的就隨機：
--   gen_strata   single（圍岩夾一層煤）或 inter（砂頁岩煤互層）
--   gen_seams    煤層數 1–5（互層）
--   gen_outcrop  主煤層在出生點往上傾方向 20–55 m 露出地表（營地那片平地上，一進遊戲就找得到）；營地底下多深由距離和傾角決定
--   gen_dip      地層傾角 3–40°（傾向隨機；完全水平的煤層會整片貼在地表）
--   gen_thickvar 每層厚度沿層面的變化 0–60 %（薄的會尖滅）
--   gen_fold     褶皺振幅 0–25 m（波長 150–300 m，軸向大致沿走向）
--   gen_terrain  hills（丘陵）或 cuesta（單面山：順向坡＋陡崖，傾角大就是豬背嶺）
--   gen_relief   地形起伏 0–40 m（出生點附近 60 m 內是平地，給營地）
--   gen_ores     要哪幾種礦，逗號分開（coal、marble；舊的 gen_ore 只寫一種）。煤礦（預設）或大理岩（花蓮大南澳片岩，大理岩夾在黑色片岩裡）。
--                兩種以上：每種礦一個地質區，第一種在出生點那一區，隔著直立斷層（斷層帶是斷層角礫岩）往外排，
--                各區自己的柱狀圖、傾角、傾向（rockmech_strata_2…、rockmech_faults，見 config.lua）；節理組全圖共用（第 1 組照第 1 區）。
--                大理岩：single = 片岩裡一層厚大理岩（15–40 m），inter = 片岩、大理岩互層；傾角 20–70°（比煤陡）；
--                第 1 組節理是葉理（間距密、面平滑、有綠泥石雲母，Jr 1、Ja 2–4），世界設定 rockmech_ores = marble
-- 其他：節理第 1 組是層面（地層的平均位態），第 2、3 組陡傾、走向大致互相垂直，Jr、Ja 取 Q 法表格值；
-- 各岩性的 GSI；現地應力 K_Hmax、K_hmin、σHmax 方位。
-- 地質不直接顯示（要自己鑽岩心、量節理）；老師用 /rockmech_geology 查（單機版看不到，直接看世界資料夾的 rockmech.conf）。
-- init.lua 在讀設定之前呼叫 generate(world_conf)。

local M = {}

local function pick(r, t) return t[r:next(1, #t)] end
local function range(r, a, b) return a + (b - a) * r:next(0, 10000) / 10000 end
local function round(v, step) step = step or 1; return math.floor(v / step + 0.5) * step end

-- 每種礦的地質：柱狀圖（由上往下，回傳主礦層頂離柱狀圖頂面的真厚度、主礦層是第幾層）、傾角範圍、第 1 組節理（層面或葉理）。
-- 加一種礦：在這裡加一列（config.lua 的 ores、lithologies 也要有）
M.RECIPES = {
	coal = {
		dip = function(f) return math.max(3, round(40 * f)) end,
		column = function(r, mode, nseam, add, sum, range, count)
			local main_top, main_i
			if mode == "single" then
				local host = pick(r, {"shale", "sandstone"})      -- 圍岩夾一層煤
				add(host, 40)
				main_top = sum()
				add("coal", range(r, 4, 12))
				main_i = count()
				add(host, 250)
				return main_top, main_i
			end
			-- 沉積旋迴：砂岩 → 頁岩 →（煤）→ 頁岩；主煤層是其中一層，比較厚
			local main = r:next(1, nseam)
			local function cycle(coal_t)
				add("sandstone", range(r, 4, 12))
				add("shale", range(r, 1, 4))
				if coal_t then add("coal", coal_t) end
				add("shale", range(r, 1, 3))
			end
			cycle(nil)                               -- 最上面一個沒有煤的旋迴
			for k = 1, nseam do
				if k > 1 and r:next(1, 3) == 1 then cycle(nil) end      -- 偶爾夾一個沒有煤的旋迴
				if k == main then
					add("sandstone", range(r, 4, 12)); add("shale", range(r, 1, 4))
					main_top = sum()
					add("coal", range(r, 5, 10)); main_i = count()
					add("shale", range(r, 1, 3))
				else
					cycle(range(r, 0.5, 2.5))
				end
			end
			while sum() < main_top + 250 do cycle(nil) end
			return main_top, main_i
		end,
		joint1 = function(r, dip, dipdir, round, range, pick)
			return ("%d,%d,%g,0.7,1.5,3"):format(dip, dipdir, round(range(r, 2, 5), 0.5))
		end,
	},
	marble = {
		dip = function(f) return round(20 + 50 * f) end,
		host_only = true,      -- 圍岩只有片岩
		column = function(r, mode, nseam, add, sum, range, count)
			local main_top, main_i
			if mode == "single" then
				add("schist", 40)
				main_top = sum()
				add("marble", range(r, 15, 40))
				main_i = count()
				add("schist", 250)
				return main_top, main_i
			end
			-- 片岩、大理岩互層：主礦層比較厚，其他幾層薄的大理岩夾在片岩裡
			local main = r:next(1, nseam)
			add("schist", range(r, 6, 15))
			for k = 1, nseam do
				if k == main then
					main_top = sum()
					add("marble", range(r, 12, 30)); main_i = count()
				else
					add("marble", range(r, 2, 8))
				end
				add("schist", range(r, 4, 15))
			end
			while sum() < main_top + 250 do add("schist", 20) end
			return main_top, main_i
		end,
		joint1 = function(r, dip, dipdir, round, range, pick)
			return ("%d,%d,%g,0.9,1,%d"):format(dip, dipdir, round(range(r, 1, 2), 0.5), pick(r, {2, 3, 4}))
		end,
	},
}

function M.generate(world_conf)
	if world_conf:has("rockmech_joint_lattice") or world_conf:has("rockmech_zone_order") or world_conf:has("rockmech_generated") then
		return false
	end
	if not core.settings:get_bool("rockmech_world_generator", true) then return false end
	local seed_str = core.get_mapgen_setting("seed") or ""
	if seed_str == "" then seed_str = tostring(os.time()) end
	local seed = (tonumber(seed_str) or os.time()) % 2147483647
	local r = PcgRandom(math.floor(seed))
	-- 滑桿 0..1；沒設定就隨機
	local function frac(k)
		local v = tonumber(world_conf:get("rockmech_gen_" .. k) or "")
		if v then return math.max(0, math.min(100, v)) / 100 end
		return r:next(0, 1000) / 1000
	end
	local function choice(k, t)
		local v = world_conf:get("rockmech_gen_" .. k)
		for _, c in ipairs(t) do if c == v then return v end end
		return pick(r, t)
	end

	-- 礦種：rockmech_gen_ores = coal,marble（開始畫面勾選的，逗號分開）；舊的 rockmech_gen_ore 只有一種。
	-- 每種礦一個地質區（各自的柱狀圖、傾角、傾向），第一種在出生點那一區，其他的隔著直立斷層往外排
	local ores, seen = {}, {}
	for k in (world_conf:get("rockmech_gen_ores") or world_conf:get("rockmech_gen_ore") or "coal"):gmatch("[%w_]+") do
		if M.RECIPES[k] and not seen[k] then ores[#ores + 1] = k; seen[k] = true end
	end
	if #ores == 0 then ores[1] = "coal" end
	local mode = choice("strata", {"single", "inter"})
	local terrain = choice("terrain", {"hills", "cuesta"})
	local dist = round(20 + 35 * frac("outcrop"))
	local var = round(0.6 * frac("thickvar"), 0.01)
	local foldA = round(25 * frac("fold"))
	local relief = round(40 * frac("relief"))
	local nseam = mode == "single" and 1 or (1 + math.floor(4 * frac("seams") + 0.5))
	local varScale = r:next(60, 140)
	-- 斷層：法線方位隨機；第 1 條離出生點 90–140 m（營地、第 1 區的露頭都在這之內），之後每條再往外 150–250 m
	local faz = r:next(0, 359)
	local fnx, fnz = math.sin(math.rad(faz)), math.cos(math.rad(faz))
	local faults, fd = {}, 0
	for k = 2, #ores do
		fd = fd + (k == 2 and r:next(90, 140) or r:next(150, 250))
		faults[#faults + 1] = {d = fd, w = r:next(6, 14)}
	end

	local set = function(k, v) world_conf:set("rockmech_" .. k, tostring(v)) end
	local logs = {}
	local main_dip, main_dipdir
	for k, ore in ipairs(ores) do
		local R = M.RECIPES[ore]
		local beds = {}
		local function add(lith, t)
			local last = beds[#beds]
			if last and last[1] == lith then last[2] = last[2] + round(t, 0.5)      -- 同一種岩性相鄰：併成一層
			else beds[#beds + 1] = {lith, round(t, 0.5)} end
		end
		local function sum() local d = 0 for _, b in ipairs(beds) do d = d + b[2] end return d end
		local main_top, main_i = R.column(r, mode, nseam, add, sum, range, function() return #beds end)
		local dip = R.dip(frac("dip"))
		local dipdir = r:next(0, 359)
		if k == 1 then main_dip, main_dipdir = dip, dipdir end
		-- 主礦層的頂在 P 點露出地表（y = 0）：第 1 區在出生點往上傾方向 dist m，其他區在斷層外 25–50 m
		local cosd, tand = math.cos(math.rad(dip)), math.tan(math.rad(dip))
		local sdd, cdd = math.sin(math.rad(dipdir)), math.cos(math.rad(dipdir))
		local foldL, foldAz = r:next(150, 300), (dipdir + 90 + r:next(-20, 20)) % 360
		local St = {beds = {}, var = var > 0 and {f = math.min(0.95, var), scale = varScale} or nil}
		for i, b in ipairs(beds) do St.beds[i] = {lith = b[1], t = b[2]} end
		local function fold_at(x, z)
			if foldA <= 0 then return 0 end
			local az = math.rad(foldAz)
			return foldA * math.sin(2 * math.pi * (x * math.cos(az) - z * math.sin(az)) / foldL)
		end
		local function top_at(x, z) return main_i > 1 and rockmech.stress.strata_column(St, x, z)[main_i - 1] or 0 end
		local px, pz
		if k == 1 then px, pz = -dist * sdd, -dist * cdd
		else
			local f = faults[k - 1]
			local o = f.d + f.w / 2 + r:next(25, 50)
			px, pz = o * fnx, o * fnz
		end
		-- 頂面高程 ref_y(P) = y0 − tan·(P·傾向) + fold(P)；主礦層頂 = ref_y(P) − top(P)/cos = 0
		local y0 = top_at(px, pz) / cosd + tand * (px * sdd + pz * cdd) - fold_at(px, pz)
		local parts = {}
		for _, b in ipairs(beds) do parts[#parts + 1] = ("%s:%g"):format(b[1], b[2]) end
		local sfx = k == 1 and "" or ("_" .. k)
		set("strata" .. sfx, table.concat(parts, ","))
		set("strata_attitude" .. sfx, ("%d,%d,%g"):format(dip, dipdir, round(y0, 0.1)))
		if foldA > 0 then set("strata_fold" .. sfx, ("%d,%d,%d"):format(foldA, foldL, foldAz)) end
		if var > 0 then set("strata_var" .. sfx, ("%g,%d"):format(var, varScale)) end
		if k == 1 then
			set("zone_order", (mode == "single" or R.host_only) and beds[1][1] or "shale")
			set("joint_set_1", R.joint1(r, dip, dipdir, round, range, pick))      -- 第 1 組：第 1 區的層面（大理岩是片岩的葉理）
			local depth = math.floor(-(y0 + fold_at(0, 0) - top_at(0, 0) / cosd) + 0.5)
			logs[#logs + 1] = ("%s %s %d 層、傾角 %d°/%03d°、露頭 %d m 外、營地底下 %d m"):format(ore, mode, nseam, dip, dipdir, dist, depth)
		else
			logs[#logs + 1] = ("斷層 %d m 外（帶寬 %d m）→ %s 傾角 %d°/%03d°"):format(faults[k - 1].d, faults[k - 1].w, ore, dip, dipdir)
		end
	end

	local d2 = r:next(0, 359)
	local d3 = (d2 + 90 + r:next(-15, 15)) % 360
	local function sp() return round(range(r, 2, 5), 0.5) end
	local function jr() return pick(r, {1, 1.5, 2, 3}) end
	local function ja() return pick(r, {1, 2, 3, 4}) end
	local kH = round(range(r, 1.0, 2.0), 0.1)
	local kh = math.min(kH, round(range(r, 0.6, 1.0), 0.1))
	local az = r:next(0, 179)

	set("generated", seed_str)
	set("strip_soil", "true")
	set("only_lithologies", "true")
	set("lith_mode", "zones")
	set("zone_width", 100000)
	if #faults > 0 then
		local fp = {tostring(faz)}
		for _, f in ipairs(faults) do fp[#fp + 1] = ("%d:%d"):format(f.d, f.w) end
		set("faults", table.concat(fp, ","))
		set("gsi_breccia", round(range(r, 10, 25)))
	end
	if relief > 0 then set("terrain", ("%s,%d,%d"):format(terrain, relief, terrain == "cuesta" and 120 or 60)) end
	set("gsi_sandstone", round(range(r, 45, 70)))
	set("gsi_shale", round(range(r, 35, 60)))
	set("gsi_coal", round(range(r, 30, 50)))
	if seen.marble then
		set("gsi_marble", round(range(r, 50, 75)))
		set("gsi_schist", round(range(r, 30, 55)))
	end
	set("ores", table.concat(ores, ","))
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
	set("career", "true")
	set("solo", "true")            -- 個人遊戲
	set("teacher", "false")        -- 不是教學地圖：沒有老師示範區、分組、防爆、名牌（config.lua 的 cfg.teacher）
	world_conf:write()
	-- 引擎的地形：平地（起伏由 rockmech_terrain 自己造），沒有湖、海、洞穴
	local mg = {mg_name = "flat", mg_flags = "nocaves, nodungeons, light, nodecorations, nobiomes, noores",
		mgflat_spflags = "nolakes, nohills, nocaverns", mgflat_ground_level = "0", water_level = "-31000"}
	for k, v in pairs(mg) do core.set_mapgen_setting(k, v, true) end
	core.log("action", ("[rockmech] 地圖產生器：種子 %s → %s；褶皺 %d m、厚度變化 %d%%、%s %d m"):format(
		seed_str, table.concat(logs, "；"), foldA, math.floor(var * 100 + 0.5), terrain, relief))
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
			local out = {}
			if g("strata") ~= "-" then
				-- 柱狀圖：列到最後一層礦再多兩層，礦層用 [ ] 標出來。多個地質區：每區一段，中間是斷層
				local seen, gsi = {}, {}
				local function name(k) local L = rockmech.cfg.lithologies[k]; return L and S(L.description) or k end
				local faults = {}
				for d, w in g("faults"):gmatch("(%-?[%d.]+):([%d.]+)") do faults[#faults + 1] = {d, w} end
				for k = 1, #faults + 1 do
					local sfx = k == 1 and "" or ("_" .. k)
					if g("strata" .. sfx) == "-" then break end
					if k > 1 then
						out[#out + 1] = S("Fault @1 m out (normal @2°), fault zone @3 m of @4", faults[k - 1][1], g("faults"):match("^[^,]+"), faults[k - 1][2], name("breccia"))
						if not seen.breccia then seen.breccia = true; gsi[#gsi + 1] = name("breccia") .. " " .. g("gsi_breccia") end
					end
					local col, last_coal = {}, 0
					for lith, t in g("strata" .. sfx):gmatch("([%a_]+):([%d.]+)") do
						local L = rockmech.cfg.lithologies[lith]
						local is_ore = L and L.ore
						col[#col + 1] = is_ore and ("[" .. t .. " m " .. name(lith) .. "]") or (t .. " m " .. name(lith))
						if is_ore then last_coal = #col end
						if not seen[lith] then seen[lith] = true; gsi[#gsi + 1] = name(lith) .. " " .. g("gsi_" .. lith) end
					end
					for i = #col, last_coal + 3, -1 do col[i] = nil end
					out[#out + 1] = S("Strata (top down): @1", table.concat(col, ", ") .. " …")
					out[#out + 1] = S("Attitude dip/dip direction, top at (0,0): @1", g("strata_attitude" .. sfx))
				end
				out[#out + 1] = "GSI  " .. table.concat(gsi, "  ")
				out[#out + 1] = S("Fold amplitude,wavelength,axis: @1   thickness variation,scale: @2   terrain: @3", g("strata_fold"), g("strata_var"), g("terrain"))
			end
			if g("strata") == "-" then
				local lith = g("zone_order")
				local key = lith:match("^[^,]+")
				local L = rockmech.cfg.lithologies[key]
				out[#out + 1] = S("Host rock: @1", L and S(L.description) or lith) .. "  GSI " .. g("gsi_" .. key)
			end
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
