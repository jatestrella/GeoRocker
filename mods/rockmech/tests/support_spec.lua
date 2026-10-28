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
		local sup = support.scan(g, IDS, {p_sc = 0.2, T = 100, L = 2.4, N = 2})
		assert.near(0.1, support.at(sup, gi(g, 1, 1, 0), 4), 1e-12)   -- 頂板的下面（−y）
		assert.near(0.1, support.at(sup, gi(g, 2, 0, 0), 2), 1e-12)   -- 牆的 −x 面
		assert.near(0, support.at(sup, gi(g, 0, 1, 0), 4), 1e-12)     -- 旁邊沒噴到
	end)

	it("岩栓：T 平均分給同一面 3×3 格 → 每面 T/9", function()
		local g = grid(function(x, y, z)
			if y >= 1 then return ROCK end
			return (x == 0 and y == 0 and z == 0) and BOLT or AIR
		end, function() return 0 end)   -- param2 0 → 指向 +y（打進頂板）
		local sup = support.scan(g, IDS, {p_sc = 0.2, T = 90, L = 2.4, N = 1})
		for _, c in ipairs({{0, 0}, {1, 1}, {-1, 0}, {0, -1}}) do
			assert.near(0.01, support.at(sup, gi(g, c[1], 1, c[2]), 4), 1e-12)
		end
		assert.near(0, support.at(sup, gi(g, 2, 1, 0), 4), 1e-12)
		assert.are.equal(1, #sup.bolts)
	end)

	it("沒有支護方塊 → nil", function()
		local g = grid(function(_, y) return y >= 1 and ROCK or AIR end)
		assert.is_nil(support.scan(g, IDS, {p_sc = 0.2, T = 100, L = 2.4}))
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
		g.support = support.scan(g, IDS, {p_sc = 0.2, T = 100, L = 2.4, N = 1})
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
		g.support = support.scan(g, IDS, {p_sc = 0.3, T = 100, L = 2.4, N = 1})
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
		assert.near(0, b.fs, 1e-12)
	end)

	it("岩栓錨進岩塊上方的岩體：FS = T / W", function()
		local g, p = roof(function(x, y, z) return (x == 0 and y == 0 and z == 0) and BOLT or AIR end,
			function() return 0 end)
		g.support = support.scan(g, IDS, {p_sc = 0.2, T = 500, L = 4, N = 1})
		local b = keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 0}})[1]
		assert.near(500 / W, b.fs, 1e-9)
	end)

	it("岩栓比岩塊短（錨固段沒出岩塊）：沒有效果", function()
		local g, p = roof(function(x, y, z) return (x == 0 and y == 0 and z == 0) and BOLT or AIR end,
			function() return 0 end)
		g.support = support.scan(g, IDS, {p_sc = 0.2, T = 500, L = 2, N = 1})
		local b = keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 0}})[1]
		assert.near(0, b.fs, 1e-12)
	end)

	it("噴凝土蓋住岩塊底面：FS = p_sc·A / W", function()
		local g, p = roof(function(x, y, z)
			return (y == 0 and math.abs(x) <= 1 and math.abs(z) <= 1) and LINING or AIR
		end)
		g.support = support.scan(g, IDS, {p_sc = 0.1, T = 100, L = 2.4, N = 1})
		local b = keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 0}})[1]
		assert.near(9 * 0.1 * 1000 / W, b.fs, 1e-9)
	end)
end)
