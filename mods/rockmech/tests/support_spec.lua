dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local support = load_module("support")
local stress = load_module("stress")
local failure = load_module("failure", stress)
local keyblock = load_module("keyblock")

local AIR, ROCK, LINING, BOLT = 0, 1, 2, 3
local GAMMA = 25
local IDS = {lining = {[LINING] = true}, bolt = {[BOLT] = true}}

-- 網格 [-R, R]³：fn(x, y, z) 回傳 ROCK／AIR／LINING／BOLT；bolts 的 param2 由 p2fn 給
local R = 6
local function grid(fn, p2fn)
	local n = 2 * R + 1
	local g = {ox = -R, oy = -R, oz = -R, nx = n, ny = n, nz = n, data = {}, p2 = {},
		bonded_of = {[ROCK] = true}, solid_of = {[ROCK] = true}, weight_of = {[ROCK] = GAMMA},
		lith_of = {[ROCK] = "rock"}}
	for z = -R, R do for y = -R, R do for x = -R, R do
		local i = 1 + (x + R) + (y + R) * n + (z + R) * n * n
		g.data[i] = fn(x, y, z)
		g.p2[i] = p2fn and p2fn(x, y, z) or 0
	end end end
	return g
end
local function gi(g, x, y, z) return 1 + (x - g.ox) + (y - g.oy) * g.nx + (z - g.oz) * g.nx * g.ny end

describe("support 支護壓力", function()
	it("噴凝土：這格相鄰的每個岩面都得到 p_sc（除以 N）", function()
		-- 頂板 y ≥ 1，牆 x ≥ 2；噴凝土在牆角 (1, 0, 0)
		local g = grid(function(x, y, z)
			if y >= 1 or x >= 2 then return ROCK end
			return (x == 1 and y == 0 and z == 0) and LINING or AIR
		end)
		local sup = support.scan(g, IDS, {p_sc = 0.2, grip = 50, yield = 200, L = 2, N = 2})
		assert.near(0.1, support.at(sup, gi(g, 1, 1, 0), 4), 1e-12)   -- 頂板的下面（−y）
		assert.near(0.1, support.at(sup, gi(g, 2, 0, 0), 2), 1e-12)   -- 牆的 −x 面
		assert.near(0, support.at(sup, gi(g, 0, 1, 0), 4), 1e-12)     -- 旁邊沒噴到
	end)

	it("岩栓：T 平均分給同一面 3×3 格 → 每面 T/9", function()
		local g = grid(function(x, y, z)
			if y >= 1 then return ROCK end
			return (x == 0 and y == 0 and z == 0) and BOLT or AIR
		end, function() return 0 end)   -- param2 0 → 指向 +y（打進頂板）
		local sup = support.scan(g, IDS, {p_sc = 0.2, grip = 45, yield = 1000, L = 2, N = 1})
		for _, c in ipairs({{0, 0}, {1, 1}, {-1, 0}, {0, -1}}) do
			assert.near(0.01, support.at(sup, gi(g, c[1], 1, c[2]), 4), 1e-12)
		end
		assert.near(0, support.at(sup, gi(g, 2, 1, 0), 4), 1e-12)
		assert.are.equal(1, #sup.bolts)
	end)

	it("噴凝土岩栓：同一格同時是兩種，孔口那一面 = p_sc + T/9", function()
		local SPRAYED = 4
		local ids = {lining = {[LINING] = true, [SPRAYED] = true}, bolt = {[BOLT] = true, [SPRAYED] = true}}
		local g = grid(function(x, y, z)
			if y >= 1 then return ROCK end
			return (x == 0 and y == 0 and z == 0) and SPRAYED or AIR
		end, function() return 0 end)
		local sup = support.scan(g, ids, {p_sc = 0.01, grip = 200, yield = 360, L = 4, N = 1})
		assert.near(0.01 + 0.04, support.at(sup, gi(g, 0, 1, 0), 4), 1e-12)
		assert.near(0.04, support.at(sup, gi(g, 1, 1, 0), 4), 1e-12)     -- 旁邊只有岩栓分到的
		assert.are.equal(1, #sup.bolts)
	end)

	it("沒有支護方塊 → nil", function()
		local g = grid(function(_, y) return y >= 1 and ROCK or AIR end)
		assert.is_nil(support.scan(g, IDS, {p_sc = 0.2, grip = 50, L = 2}))
	end)
end)

describe("support 等效圍壓（failure.cell_state）", function()
	local P = {surface_y = 20, k0 = 0.5, window = 2, lithologies = {rock = {gamma = GAMMA, ucs = 30}}}
	it("頂板：σy = 頂板的支護壓力", function()
		local g = grid(function(x, y, z)
			if y >= 1 then return ROCK end
			return (x == 0 and y == 0 and z == 0) and LINING or AIR
		end)
		local bare = failure.cell_state(g, 0, 1, 0, P)
		assert.near(0, bare.sy, 1e-12)
		g.support = support.scan(g, IDS, {p_sc = 0.2, grip = 50, L = 2, N = 1})
		local st = failure.cell_state(g, 0, 1, 0, P)
		assert.near(0.2, st.sy, 1e-12)
		assert.near(0.2, st.p_support, 1e-12)
		assert.is_true(st.s3 > bare.s3)
	end)

	it("側牆：σx = 牆面的支護壓力", function()
		local g = grid(function(x, y, z)
			if x >= 1 then return ROCK end
			return (x == 0 and y == 0 and z == 0) and LINING or AIR
		end)
		g.support = support.scan(g, IDS, {p_sc = 0.3, grip = 50, L = 2, N = 1})
		local st = failure.cell_state(g, 1, 0, 0, P)
		assert.near(0.3, st.sx, 1e-12)
	end)
end)

describe("support 關鍵塊體", function()
	-- 頂板上被節理圍住的岩塊：x、z ∈ [−1, 1]、y ∈ [1, 2]（18 格），下方 y ≤ 0 是空氣、c = 0 → 落下 FS = 0
	local function roof(extra, p2fn)
		local g = grid(function(x, y, z)
			if y >= 1 then return ROCK end
			return extra and extra(x, y, z) or AIR
		end, p2fn)
		g.bonded_of = {[ROCK] = true}
		local p = {
			face_set = function(x, y, z, axis)
				if axis == 1 and (x == -2 or x == 1) and y <= 2 then return 1 end
				if axis == 3 and (z == -2 or z == 1) and y <= 2 then return 3 end
				if axis == 2 and y == 2 then return 2 end
				return nil
			end,
			joint_sets = {{n_eff = {x = 1, y = 0, z = 0}, name = "V1"}, {n_eff = {x = 0, y = 1, z = 0}, name = "H"}, {n_eff = {x = 0, y = 0, z = 1}, name = "V2"}},
			c = 0, tanphi = math.tan(math.rad(30)), lithologies = {rock = {gamma = GAMMA}}, max_cells = 500,
		}
		return g, p
	end
	local W = 18 * GAMMA

	it("沒有支護：落下 FS = 0", function()
		local g, p = roof()
		local b = keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 0}})[1]
		assert.are.equal(18, #b.cells)
		assert.are.equal("fall", b.mode)
		assert.near(0, b.fs, 2e-3)
	end)

	it("岩栓打進岩塊外 2 m：FS = g·2 / W", function()
		local g, p = roof(function(x, y, z) return (x == 0 and y == 0 and z == 0) and BOLT or AIR end,
			function() return 0 end)
		g.support = support.scan(g, IDS, {p_sc = 0.2, grip = 250, yield = 1000, N = 1, bolt_len = function() return 4 end})
		local b = keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 0}})[1]
		assert.near(500 / W, b.fs, 2e-3)
	end)

	it("岩栓比岩塊短（錨固段沒出岩塊）：沒有效果", function()
		local g, p = roof(function(x, y, z) return (x == 0 and y == 0 and z == 0) and BOLT or AIR end,
			function() return 0 end)
		g.support = support.scan(g, IDS, {p_sc = 0.2, grip = 250, L = 2, N = 1})
		local b = keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 0}})[1]
		assert.near(0, b.fs, 2e-3)
	end)

	it("岩栓打進岩塊外的長度越長越好，上限是鋼材降伏", function()
		local function fs(L)
			local g, p = roof(function(x, y, z) return (x == 0 and y == 0 and z == 0) and BOLT or AIR end,
				function() return 0 end)
			g.support = support.scan(g, IDS, {p_sc = 0, grip = 50, yield = 150, N = 1, bolt_len = function() return L end})
			return keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 0}})[1].fs
		end
		assert.near(50 / W, fs(3), 1e-9)            -- 岩塊厚 2 m：打出去 1 m
		assert.near(100 / W, fs(4), 1e-9)
		assert.near(150 / W, fs(6), 1e-9)           -- g·4 = 200 > T_y = 150
	end)

	it("噴凝土蓋住岩塊底面：FS = p_sc·A / W", function()
		local g, p = roof(function(x, y, z)
			return (y == 0 and math.abs(x) <= 1 and math.abs(z) <= 1) and LINING or AIR
		end)
		g.support = support.scan(g, IDS, {p_sc = 0.1, grip = 50, L = 2, N = 1})
		local b = keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 0}})[1]
		assert.near(9 * 0.1 * 1000 / W, b.fs, 2e-3)
	end)
end)

describe("support 頂板：往上托抵銷自重", function()
	local overhang = load_module("overhang")
	local SH = 1
	-- 地面 y ≤ 0、x = 0 的岩柱 y 1..8，柱頂往 +x 伸出長 L、厚 t 的頁岩懸臂（σt 2 MPa、γ 25）
	local function cantilever(L, t)
		local x0, x1, y0, y1, z0, z1 = -3, L + 3, -2, 12, -2, 2
		local g = {ox = x0, oy = y0, oz = z0, nx = x1 - x0 + 1, ny = y1 - y0 + 1, nz = z1 - z0 + 1, data = {},
			bonded_of = {[SH] = true}, solid_of = {[SH] = true, [9] = true}, lith_of = {[SH] = "shale"}}
		for z = z0, z1 do for y = y0, y1 do for x = x0, x1 do
			local v = AIR
			if y <= 0 then v = 9
			elseif z == 0 and x == 0 and y <= 8 then v = SH
			elseif z == 0 and x >= 1 and x <= L and y > 8 - t and y <= 8 then v = SH end
			g.data[1 + (x - x0) + (y - y0) * g.nx + (z - z0) * g.nx * g.ny] = v
		end end end
		g.req = {x1 = x0 + 1, x2 = x1 - 1, y1 = y0 + 1, y2 = y1 - 1, z1 = z0 + 1, z2 = z1 - 1}
		return g
	end
	local OP = {lithologies = {shale = {gamma = 25, tensile = 2}}, scale = 1, max_voxels = 2000}
	-- 懸臂每一欄底面（−y）的支護：sc（噴凝土）、bolt（岩栓攤到的）MPa
	local function under(g, L, t, sc, bolt)
		local sup = {face = {}, sc = {}, bolts = {}}
		for x = 1, L do
			local i = gi(g, x, 8 - t + 1, 0)
			sup.face[i * 8 + 4] = sc + bolt
			if sc > 0 then sup.sc[i * 8 + 4] = sc end
		end
		g.support = sup
	end

	it("懸臂：FS × γt/(γt − pᵢ)", function()
		local g = cantilever(6, 1)
		local bare = overhang.cell_state(g, OP, 6, 8, 0).fs
		assert.is_true(bare < 1)
		under(g, 6, 1, 0.02, 0)            -- 20 kPa，γt = 25 kPa → × 5
		assert.near(bare * 5, overhang.cell_state(g, OP, 6, 8, 0).fs, 2e-3)
	end)

	it("懸臂：pᵢ ≥ γt 整欄被托住", function()
		local g = cantilever(6, 1)
		under(g, 6, 1, 0.03, 0)
		assert.are.equal(math.huge, overhang.cell_state(g, OP, 6, 8, 0).fs)
		assert.are.equal(0, #(overhang.find_failing_local(g, OP, {{x = 6, y = 8, z = 0}})))
	end)

	it("Terzaghi：h = min(t, k·(B + H_t))，B = 2·HR、H_t = 淨高", function()
		local g = cantilever(2, 6)                  -- 6 m 厚、伸出 2 m、底下淨高 2 m
		local s1 = overhang.cell_state(g, OP, 1, 8, 0)
		local s2 = overhang.cell_state(g, OP, 2, 8, 0)
		assert.near(2, s2.hr, 1e-12)
		assert.near(2, s2.ht, 1e-12)
		assert.near(0.35, s2.k, 1e-12)              -- GSI 不明取 50
		assert.near(2.1, s1.h, 1e-9)                -- 0.35 × (4 + 2)，整段共用
		assert.near(2.1, s2.h, 1e-9)
		-- FS = (L_max·ρ/HR)² × t/h
		assert.near((s2.lmax / 2) ^ 2 * 6 / 2.1, s2.fs, 2e-3)
	end)

	it("Terzaghi：k 依 GSI；完整岩體 k = 0 沒有荷重", function()
		local function with_gsi(v)
			local p = {}
			for k, x in pairs(OP) do p[k] = x end
			p.gsi_at = function() return v end
			return p
		end
		local g = cantilever(2, 6)
		assert.are.equal(math.huge, overhang.cell_state(g, with_gsi(90), 2, 8, 0).fs)
		local poor = overhang.cell_state(g, with_gsi(25), 2, 8, 0)
		assert.near(1.1, poor.k, 1e-12)
		assert.near(6, poor.h, 1e-9)                -- 1.1 × 6 = 6.6 > t = 6
		assert.near((poor.lmax / 2) ^ 2, poor.fs, 2e-3)
	end)

	it("k(GSI) 內插，兩端取端點", function()
		assert.near(0, overhang.terzaghi_k(100), 1e-12)
		assert.near(0, overhang.terzaghi_k(85), 1e-12)
		assert.near(0.175, overhang.terzaghi_k(67.5), 1e-12)
		assert.near(0.35, overhang.terzaghi_k(50), 1e-12)
		assert.near(0.725, overhang.terzaghi_k(37.5), 1e-12)
		assert.near(1.1, overhang.terzaghi_k(25), 1e-12)
		assert.near(1.1, overhang.terzaghi_k(10), 1e-12)
		assert.near(0.35, overhang.terzaghi_k(nil), 1e-12)
		assert.near(0.5, overhang.terzaghi_k(60, {{80, 0}, {40, 1}}), 1e-12)
	end)

	it("岩栓錨定力 = min(握裹力 × 長度, 鋼材降伏)", function()
		for _, c in ipairs({{2, 100}, {3, 150}, {4, 200}, {6, 200}}) do
			local g = grid(function(x, y, z)
				if y >= 1 then return ROCK end
				return (x == 0 and y == 0 and z == 0) and BOLT or AIR
			end, function() return 0 end)
			local sup = support.scan(g, IDS, {p_sc = 0, grip = 50, yield = 200, N = 1, bolt_len = function() return c[1] end})
			assert.near(c[2] / 9 / 1000, support.at(sup, gi(g, 0, 1, 0), 4), 1e-9)
		end
	end)

	it("被挖斷的岩栓：有效長度只算到斷點", function()
		local g = grid(function(x, y, z)
			if y >= 1 and not (x == 0 and y == 3 and z == 0) then return ROCK end
			return (x == 0 and y == 0 and z == 0) and BOLT or AIR
		end, function() return 0 end)
		local sup = support.scan(g, IDS, {p_sc = 0, grip = 45, yield = 1000, N = 1, bolt_len = function() return 5 end})
		assert.near(90 / 9 / 1000, support.at(sup, gi(g, 0, 1, 0), 4), 1e-9)   -- y = 1、2 → 2 m
		assert.are.equal(1, #sup.bolts[1].path)
	end)

	it("噴凝土與岩栓都讓 FS 上升", function()
		local g = cantilever(2, 6)                  -- h = 2.1 m、γh = 52.5 kPa
		local bare = overhang.cell_state(g, OP, 2, 8, 0).fs
		under(g, 2, 6, 0, 0.03)                     -- 30 kPa
		assert.near(bare * 52.5 / 22.5, overhang.cell_state(g, OP, 2, 8, 0).fs, 2e-3)
		under(g, 2, 6, 0.03, 0)
		assert.near(bare * 52.5 / 22.5, overhang.cell_state(g, OP, 2, 8, 0).fs, 2e-3)
		under(g, 2, 6, 0, 0.06)                     -- 60 kPa ≥ 52.5 → 托住
		assert.are.equal(math.huge, overhang.cell_state(g, OP, 2, 8, 0).fs)
	end)

	it("支護只減少那一欄的荷重，效果靠均分擴散到整段", function()
		local g = cantilever(4, 1)                  -- 4 m² 懸空、γh = 25 kPa
		local bare = overhang.cell_state(g, OP, 4, 8, 0)
		local sup = {face = {}, sc = {}, bolts = {}}
		sup.face[gi(g, 2, 8, 0) * 8 + 4] = 0.04     -- 只有一欄 40 kPa → 整段平均 10 kPa
		g.support = sup
		local tip = overhang.cell_state(g, OP, 4, 8, 0)
		assert.near(10, tip.p_sup, 1e-9)            -- 顯示：平均 10 kPa
		assert.is_true(tip.fs > bare.fs)            -- 沒打到的尖端也受益
		assert.is_true(tip.group_fs > bare.group_fs)
	end)

	it("同一段頂板也檢查剪力：FS = k·σt·t_eff / (q·HR)，取彎曲與剪力較小者", function()
		local g = cantilever(1, 7)                  -- 7 m 厚、伸出 1 m、淨高 1 m：t > 6·HR，剪力控制
		local p = {}
		for k, v in pairs(OP) do p[k] = v end
		local bend = overhang.cell_state(g, OP, 1, 8, 0)
		assert.is_nil(bend.fs_shear)
		p.shear_k = 2
		local st = overhang.cell_state(g, p, 1, 8, 0)
		local h = 0.35 * (2 + 1)
		assert.near(h, st.h, 1e-9)
		assert.near(2 * 2000 * 7 / (25 * h * 1), st.fs_shear, 1e-2)
		assert.near(st.fs_shear, st.fs, 2e-3)
		assert.is_true(st.fs < bend.fs)
		-- FS_剪/FS_彎 = 6·HR/t_eff
		assert.near(6 * 1 / 7, st.fs_shear / bend.fs, 1e-4)
		-- 支護對兩者同比例：q = γh − pᵢ
		under(g, 1, 7, 0.01, 0)
		local gh = 25 * h
		assert.near(st.fs * gh / (gh - 10), overhang.cell_state(g, p, 1, 8, 0).fs, 2e-3)
	end)

	it("一般跨度由彎曲控制", function()
		local g = cantilever(4, 2)
		local p = {}
		for k, v in pairs(OP) do p[k] = v end
		local a = overhang.cell_state(g, OP, 1, 8, 0)
		p.shear_k = 2
		local b = overhang.cell_state(g, p, 1, 8, 0)    -- 根部那欄碰到支撐，有剪力
		assert.near(a.group_fs, b.group_fs, 2e-3)
		assert.is_true(b.fs_shear > b.group_fs)
	end)
end)
