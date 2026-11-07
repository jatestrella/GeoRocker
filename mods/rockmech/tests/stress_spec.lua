dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local config = load_module("config")
local stress = load_module("stress")

describe("stress", function()
	it("深度 h = y0 - y", function()
		assert.are.equal(100, stress.depth(-100, 0))
		assert.are.equal(90, stress.depth(-80, 10))
		assert.are.equal(-5, stress.depth(5, 0))
	end)

	it("σv = γh（kN/m³·m → MPa）", function()
		assert.near(2.5, stress.sigma_v(25, 100), 1e-12)
		assert.near(26.5, stress.sigma_v(26.5, 1000), 1e-9)
		assert.are.equal(0, stress.sigma_v(25, 0))
		assert.are.equal(0, stress.sigma_v(25, -10)) -- 高於地表
	end)

	it("σh = K0·σv", function()
		assert.near(1.25, stress.sigma_h(2.5, 0.5), 1e-12)
		assert.near(5.0, stress.sigma_h(2.5, 2.0), 1e-12)
	end)

	it("分層邊界", function()
		local layers = config.layers
		assert.are.equal("sandstone", stress.layer_at_depth(layers, -30))
		assert.are.equal("sandstone", stress.layer_at_depth(layers, 0))
		assert.are.equal("sandstone", stress.layer_at_depth(layers, 19.9))
		assert.are.equal("shale", stress.layer_at_depth(layers, 20))
		assert.are.equal("shale", stress.layer_at_depth(layers, 59))
		assert.are.equal("granite", stress.layer_at_depth(layers, 60))
		assert.are.equal("granite", stress.layer_at_depth(layers, 1e6))
	end)

	it("initial() 綜合", function()
		local cfg = config.load(function(k)
			return ({rockmech_surface_y = "10", rockmech_k0 = "0.8"})[k]
		end)
		local s = stress.initial(cfg, {gamma = 25}, -90)
		assert.are.equal(100, s.h)
		assert.near(2.5, s.sv, 1e-12)
		assert.near(2.0, s.sh, 1e-12)
	end)

	it("layer_table 與 layer_at_depth 一致", function()
		local cfg = config.load()
		local t = stress.layer_table(cfg, -80, 5)
		for y = -80, 5 do
			assert.are.equal(stress.layer_at_depth(cfg.layers, -y), t[y])
		end
	end)
end)

describe("stress 區帶模式", function()
	local cfg = config.load(function(k)
		return ({rockmech_lith_mode = "zones", rockmech_zone_width = "80"})[k]
	end)
	it("出生點附近頁岩、東側花崗岩、西側砂岩，往外循環", function()
		assert.are.equal("shale", stress.lith_key_at(cfg, 0, -50))
		assert.are.equal("shale", stress.lith_key_at(cfg, 39, 100))
		assert.are.equal("granite", stress.lith_key_at(cfg, 40, 0))
		assert.are.equal("granite", stress.lith_key_at(cfg, 119, 0))
		assert.are.equal("sandstone", stress.lith_key_at(cfg, 120, 0))
		assert.are.equal("sandstone", stress.lith_key_at(cfg, -41, 0))
		assert.are.equal("sandstone", stress.lith_key_at(cfg, -120, 0))
		assert.are.equal("granite", stress.lith_key_at(cfg, -121, 0))
	end)
	it("與深度無關", function()
		for y = -200, 200, 37 do assert.are.equal("shale", stress.lith_key_at(cfg, 5, y)) end
	end)
	it("預設仍為依深度分層", function()
		local c = config.load()
		assert.are.equal("layers", c.lith_mode)
		assert.are.equal("sandstone", stress.lith_key_at(c, 999, -5))
		assert.are.equal("granite", stress.lith_key_at(c, 999, -100))
	end)
end)

describe("stress 水平主應力", function()
	it("方位換算：θ=0 σH 南北向、θ=90 東西向、θ=45 有剪應力", function()
		local xx, zz, xz = stress.h_tensor(3, 1, 0)
		assert.near(1, xx, 1e-12); assert.near(3, zz, 1e-12); assert.near(0, xz, 1e-12)
		xx, zz, xz = stress.h_tensor(3, 1, 90)
		assert.near(3, xx, 1e-12); assert.near(1, zz, 1e-12); assert.near(0, xz, 1e-12)
		xx, zz, xz = stress.h_tensor(3, 1, 45)
		assert.near(2, xx, 1e-12); assert.near(2, zz, 1e-12); assert.near(1, xz, 1e-12)
	end)
	it("主應力還原 σH、σh", function()
		for _, th in ipairs({0, 30, 45, 120, 300}) do
			local xx, zz, xz = stress.h_tensor(5, 2, th)
			local s1, s3, a, b = stress.principal(xx, 3, zz, xz)
			assert.near(5, a, 1e-9); assert.near(2, b, 1e-9)
			assert.near(5, s1, 1e-9); assert.near(2, s3, 1e-9)
		end
	end)
	it("構造應力項與 K 值；未設定時 = K0", function()
		local c = config.load(function(k) return ({rockmech_k_hmax = "1.5", rockmech_k_hmin = "0.8",
			rockmech_sigma_hmax0 = "2", rockmech_sigma_hmax_azimuth = "90"})[k] end)
		local sH, sh = stress.horizontal(c, 10)
		assert.near(17, sH, 1e-12); assert.near(8, sh, 1e-12)
		assert.are.same({0, 0}, {stress.horizontal(c, 0)})
		local d = config.load()
		assert.are.equal(d.k0, d.KH); assert.are.equal(d.k0, d.Kh)
	end)
end)

describe("stress 開挖前上覆荷重", function()
	it("連續岩層：σv = Σγ、h = 厚度", function()
		local col = {}
		for k = 1, 10 do col[k] = 25 end
		local sv, h = stress.overburden(col, 20, 25)
		assert.near(0.25, sv, 1e-12)
		assert.are.equal(10, h)
	end)
	it("中間的隧道視為原本是岩石（以 gamma_fill 補）", function()
		local col = {}
		for k = 1, 10 do col[k] = 25 end
		col[3], col[4], col[5] = nil, nil, nil
		local sv, h = stress.overburden(col, 10, 24)
		assert.near((7 * 25 + 3 * 24) / 1000, sv, 1e-12)
		assert.are.equal(10, h)
	end)
	it("上方全是空氣：0", function()
		local sv, h = stress.overburden({}, 30, 25)
		assert.are.equal(0, sv); assert.are.equal(0, h)
	end)
	it("不同岩層的單位重分別計入", function()
		local col = {26.5, 26.5, 25, 25, 24}
		local sv = stress.overburden(col, 5, 25)
		assert.near((2 * 26.5 + 2 * 25 + 24) / 1000, sv, 1e-12)
	end)
end)

describe("stress 上覆荷重外插", function()
	it("掃描範圍外仍是岩石：加上 extra 公尺（以 gamma_fill 計）", function()
		local col = {25, nil, 25}
		local sv, h = stress.overburden(col, 4, 24, 10)
		assert.near((25 + 24 + 25 + 24 + 10 * 24) / 1000, sv, 1e-12)
		assert.are.equal(14, h)
	end)
	it("initial_from 與 initial 對同一 σv 給出相同的水平應力", function()
		local cfg = {surface_y = 0, k0 = 0.5, KH = 1.5, Kh = 0.8, sH0 = 0, sh0 = 0, sH_azimuth = 90}
		local a = stress.initial(cfg, {gamma = 25}, -40)
		local b = stress.initial_from(cfg, a.sv, a.h)
		for _, k in ipairs({"sv", "sh", "sH", "shmin", "sxx", "szz", "sxz"}) do
			assert.near(a[k], b[k], 1e-12)
		end
	end)

	local function seam(dip, dd, t, y0)
		local a, b = math.rad(dip), math.rad(dd)
		return {t = t, y0 = y0, x0 = 0, z0 = 0, tan_dip = math.tan(a), cos_dip = math.cos(a),
			sin_dd = math.sin(b), cos_dd = math.cos(b)}
	end

	it("煤層：往傾向變深，真厚度 t", function()
		local s = seam(30, 90, 15, -30)
		assert.near(0, stress.seam_offset(s, 0, -30, 0), 1e-9)
		assert.is_true(stress.in_seam(s, 0, -30, 0))
		assert.is_true(stress.in_seam(s, 100, -30 - 100 * math.tan(math.rad(30)), 500))   -- 中面往東變深，南北不變
		assert.is_false(stress.in_seam(s, 100, -30, 0))
		-- 鉛直厚度 = t / cos(dip)
		local v = 15 / math.cos(math.rad(30))
		assert.is_true(stress.in_seam(s, 0, -30 + v / 2 - 0.01, 0))
		assert.is_false(stress.in_seam(s, 0, -30 + v / 2 + 0.01, 0))
	end)

	it("煤層品位：中央比頂底板好，1..255", function()
		local s = seam(30, 90, 15, -30)
		local v = 7 / math.cos(math.rad(30))
		local mid, edge = stress.seam_grade(s, 0, -30, 0), stress.seam_grade(s, 0, -30 + v, 0)
		assert.is_true(mid > edge + 50)
		assert.is_true(mid >= 1 and mid <= 255 and edge >= 1)
	end)

	it("露天坑：坑底平、階是水平的，坡道切過各階，到地表結束", function()
		local p = {x0 = 0, z0 = 0, R = 30, D = 40, H = 8, W = 12, G = 0.1}
		assert.near(-40, stress.pit_surface(p, 0, 10, 0), 1e-9)
		assert.near(-40, stress.pit_surface(p, 0, 31, 0), 1e-9)              -- 坡道起點
		assert.near(-32, stress.pit_surface(p, 0, -33, 0), 1e-9)             -- 第 1 階（對面，沒有坡道）
		assert.near(-8, stress.pit_surface(p, 0, -70, 0), 1e-9)              -- 第 4 階
		assert.is_nil(stress.pit_surface(p, 0, -100, 0))                     -- 階頂之外是地表
		local rc = 30 * math.exp(1.35 * 0.1 * math.pi / 2)                   -- 轉 1/4 圈的坡道中線
		assert.near(-40 + (rc - 30) / 1.35, stress.pit_surface(p, 0, 0, 37), 1e-9)
		assert.is_nil(stress.pit_surface(p, 0, 300, 0))
		-- 開得出去：從坑底沿著相鄰格走，每步高差 ≤ 1 m，要走得到地面；路程不能再是兩公里
		local function ground(x, z)
			local g = stress.pit_surface(p, 0, x, z)
			return g and math.floor(g) or 0
		end
		local seen, queue, head, out = {["0,0"] = true}, {{0, 0, 0}}, 1, nil
		while queue[head] and not out do
			local c = queue[head]
			head = head + 1
			for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
				local x, z = c[1] + d[1], c[2] + d[2]
				local k = x .. "," .. z
				if not seen[k] and math.abs(x) <= 120 and math.abs(z) <= 120
					and math.abs(ground(x, z) - ground(c[1], c[2])) <= 1 then
					seen[k] = true
					queue[#queue + 1] = {x, z, c[3] + 1}
					if not stress.pit_surface(p, 0, x, z) and x * x + z * z > 78 * 78 then out = c[3] + 1 end
				end
			end
		end
		assert.is_true(out ~= nil, "開不出坑")
		assert.is_true(out < 700, "路程 " .. tostring(out))
	end)
end)

describe("stress 天然表土（mapgen 和應力解共用）", function()
	local cfg = {outcrop = 0}      -- 沒有礦帶地形、沒有露頭
	local function none() return 0 end
	it("礦石露頭、地表以下不鋪", function()
		assert.are.equal(0, stress.natural_soil(cfg, 10, 10, 5, none, true))
		assert.are.equal(0, stress.natural_soil(cfg, 10, 10, -1, none, false))
	end)
	it("平地 0.25–0.75 m（2–6 級），山坡 1–3 m（8–24 級，樹那一欄另計）", function()
		for x = 0, 60, 7 do
			local t = stress.natural_soil(cfg, x, 3, 0, none, false)
			assert.is_true(t >= 2 and t <= 6)
			if not stress.tree_at(x, 3) then
				local h = stress.natural_soil(cfg, x, 3, 5, none, false)
				assert.is_true(h >= 8 and h <= 24)
			end
		end
	end)
	it("山腳的坡腳：離山坡 1 格 1 m、4 格 2/8 m（不比平地薄）", function()
		local function hill_west(x, z) return x <= 0 and 5 or 0 end
		assert.are.equal(8, stress.natural_soil(cfg, 1, 7, 0, hill_west, false))
		assert.is_true(stress.natural_soil(cfg, 4, 7, 0, hill_west, false) >= 2)
		assert.are.equal(stress.natural_soil(cfg, 9, 7, 0, none, false), stress.natural_soil(cfg, 9, 7, 0, hill_west, false))
	end)
	it("種樹的位置：間距 6 m 的格點附近，不會相鄰", function()
		local n = 0
		for x = -40, 40 do for z = -40, 40 do
			if stress.tree_at(x, z) then
				n = n + 1
				assert.is_nil(stress.tree_at(x + 1, z))
				assert.is_nil(stress.tree_at(x, z + 1))
			end
		end end
		assert.is_true(n > 50 and n < 200)
	end)
	it("露頭 20%：山坡大約兩成不鋪土，一片一片（相鄰的格大多一樣）", function()
		local c2 = {outcrop = 0.2}
		local bare, n, same, pairs_ = 0, 0, 0, 0
		for x = -150, 150, 3 do for z = -150, 150, 3 do
			n = n + 1
			local f = stress.outcrop_factor(c2, x, z)
			if f == 0 then bare = bare + 1 end
			if (f == 0) == (stress.outcrop_factor(c2, x + 1, z) == 0) then same = same + 1 end
			pairs_ = pairs_ + 1
		end end
		assert.is_true(bare / n > 0.15 and bare / n < 0.25)
		assert.is_true(same / pairs_ > 0.9)
		-- 露頭的山坡不鋪土、也不種樹
		for x = -60, 60 do for z = -60, 60 do
			if stress.outcrop_factor(c2, x, z) == 0 then
				assert.are.equal(0, stress.natural_soil(c2, x, z, 5, none, false))
			end
		end end
	end)
	it("露頭 0：沒有露頭", function()
		for x = -60, 60, 5 do assert.are.equal(1, stress.outcrop_factor({outcrop = 0}, x, 7)) end
	end)
	it("樹那一欄的山坡表土取整格、至少 2 m", function()
		for x = -40, 40 do for z = -40, 40 do
			if stress.tree_at(x, z) then
				local t = stress.natural_soil(cfg, x, z, 5, none, false)
				assert.is_true(t >= 16 and t % 8 == 0)
			end
		end end
	end)
end)
