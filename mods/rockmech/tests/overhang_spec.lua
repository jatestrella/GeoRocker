dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local overhang = load_module("overhang")

local AIR, SS, SH, GR, GROUND = 0, 1, 2, 3, 4
local LITHS = {
	sandstone = {gamma = 24, tensile = 4},
	shale = {gamma = 25, tensile = 2},
	granite = {gamma = 26.5, tensile = 10},
}
local CODE = {s = SS, h = SH, g = GR, G = GROUND}

-- fn(x,y,z) → "s"/"h"/"g"（岩性）、"G"（地面：實心但不鍵結）或 nil（空氣）
-- 範圍 x ∈ [x0,x1], y ∈ [y0,y1], z ∈ [z0,z1]；req 為內縮一格（外圈當作範圍外）
local function grid(x0, x1, y0, y1, z0, z1, fn)
	local g = {
		ox = x0, oy = y0, oz = z0, nx = x1 - x0 + 1, ny = y1 - y0 + 1, nz = z1 - z0 + 1,
		data = {},
		bonded_of = {[SS] = true, [SH] = true, [GR] = true},
		solid_of = {[SS] = true, [SH] = true, [GR] = true, [GROUND] = true},
		lith_of = {[SS] = "sandstone", [SH] = "shale", [GR] = "granite"},
	}
	for z = z0, z1 do for y = y0, y1 do for x = x0, x1 do
		g.data[1 + (x - x0) + (y - y0) * g.nx + (z - z0) * g.nx * g.ny] = CODE[fn(x, y, z)] or AIR
	end end end
	g.req = {x1 = x0 + 1, x2 = x1 - 1, y1 = y0 + 1, y2 = y1 - 1, z1 = z0 + 1, z2 = z1 - 1}
	return g
end

local P = {lithologies = LITHS, scale = 1, max_voxels = 2000}

-- 地面 y ≤ 0（G），x=0 處一根立在地上的岩柱 y 1..8，從柱頂往 +x 伸出長 L、厚 t 的懸臂
local function cantilever(lith, L, t)
	return grid(-3, L + 3, -2, 12, -2, 2, function(x, y, z)
		if y <= 0 then return "G" end
		if z == 0 and x == 0 and y <= 8 then return lith end
		if z == 0 and x >= 1 and x <= L and y > 8 - t and y <= 8 then return lith end
	end)
end

describe("overhang 極限長度", function()
	it("L_max = √(σt·t/(3γ))", function()
		assert.near(math.sqrt(4000 / 72), overhang.lmax(4, 24, 1), 1e-9)   -- 砂岩 1 m：7.45
		assert.near(math.sqrt(2000 / 75), overhang.lmax(2, 25, 1), 1e-9)   -- 頁岩：5.16
		assert.near(math.sqrt(10000 / 79.5), overhang.lmax(10, 26.5, 1), 1e-9) -- 花崗岩：11.2
		assert.near(overhang.lmax(4, 24, 1) * math.sqrt(2), overhang.lmax(4, 24, 2), 1e-9)
	end)
end)

describe("overhang 懸臂", function()
	it("砂岩 1 m 厚：長 7 穩定、長 9 整段掉落", function()
		assert.are.equal(0, #overhang.find_failing(cantilever("s", 7, 1), P))
		local g = overhang.find_failing(cantilever("s", 9, 1), P)
		assert.are.equal(1, #g)
		assert.are.equal(9, #g[1].cells) -- 從根部整段斷開
	end)

	it("頁岩較弱：長 6 就掉；花崗岩較強：長 10 仍穩定", function()
		assert.are.equal(1, #overhang.find_failing(cantilever("h", 6, 1), P))
		assert.are.equal(0, #overhang.find_failing(cantilever("g", 10, 1), P))
	end)

	it("加厚可伸更長：砂岩長 9，厚 2 穩定", function()
		assert.are.equal(0, #overhang.find_failing(cantilever("s", 9, 2), P))
	end)

	it("強度縮放 0.25：L_max 減半，砂岩長 5 就掉", function()
		local p = {lithologies = LITHS, scale = 0.25, max_voxels = 2000}
		assert.are.equal(1, #overhang.find_failing(cantilever("s", 5, 1), p))
		assert.are.equal(0, #overhang.find_failing(cantilever("s", 3, 1), p))
	end)

	it("懸臂下方掛著的岩石跟著一起掉", function()
		local g = grid(-3, 13, -2, 12, -2, 2, function(x, y, z)
			if y <= 0 then return "G" end
			if z == 0 and x == 0 and y <= 8 then return "s" end
			if z == 0 and x >= 1 and x <= 9 and y == 8 then return "s" end
			if z == 0 and x == 9 and y >= 5 and y <= 7 then return "s" end -- 掛在尖端的岩柱
		end)
		local r = overhang.find_failing(g, P)
		assert.are.equal(1, #r)
		assert.are.equal(12, #r[1].cells)
	end)
end)

describe("overhang 頂板", function()
	-- 地面 y ≤ 0；兩道牆 x = 0、x = W+1（y 1..4）；頂板 y = 5..(4+t) 橫跨 x 0..W+1
	local function roof(lith, W, t)
		return grid(-3, W + 4, -2, 14, -2, 2, function(x, y, z)
			if y <= 0 then return "G" end
			if math.abs(z) > 0 then return nil end
			if (x == 0 or x == W + 1) and y <= 4 then return lith end
			if x >= 0 and x <= W + 1 and y >= 5 and y <= 4 + t then return lith end
		end)
	end

	it("跨度 = 兩倍懸臂長度：砂岩 1 m 厚，跨 14 穩定、跨 18 整片掉", function()
		assert.are.equal(0, #overhang.find_failing(roof("s", 14, 1), P))
		local r = overhang.find_failing(roof("s", 18, 1), P)
		assert.are.equal(1, #r)
		assert.are.equal(18, #r[1].cells)
	end)

	it("厚頂板（接到範圍頂端）跨 30 也穩定", function()
		local g = grid(-3, 34, -2, 14, -2, 2, function(x, y, z)
			if y <= 0 then return "G" end
			if math.abs(z) > 0 then return nil end
			if (x == 0 or x == 31) and y <= 4 then return "s" end
			if x >= 0 and x <= 31 and y >= 5 then return "s" end -- 一路到範圍頂端
		end)
		assert.are.equal(0, #overhang.find_failing(g, P))
	end)

	it("3 格寬隧道（厚岩體中）穩定", function()
		local g = grid(-6, 6, -2, 14, -6, 6, function(x, y, z)
			if y <= 0 then return "G" end
			if math.abs(x) <= 1 and y >= 1 and y <= 3 then return nil end
			return "s"
		end)
		assert.are.equal(0, #overhang.find_failing(g, P))
	end)
end)

describe("overhang 保守處理", function()
	it("群碰到範圍邊界：不處理", function()
		-- 懸臂一路伸到範圍外
		local g = grid(-3, 12, -2, 12, -2, 2, function(x, y, z)
			if y <= 0 then return "G" end
			if z == 0 and x == 0 and y <= 8 then return "s" end
			if z == 0 and x >= 1 and y == 8 then return "s" end
		end)
		assert.are.equal(0, #overhang.find_failing(g, P))
	end)

	it("群超過格數上限：不處理", function()
		local p = {lithologies = LITHS, scale = 1, max_voxels = 5}
		assert.are.equal(0, #overhang.find_failing(cantilever("s", 9, 1), p))
	end)

	it("坐在地面上的岩石 d = 0，不受影響", function()
		local g = grid(-3, 15, -2, 6, -3, 3, function(x, y, z)
			if y <= 0 then return "G" end
			if y == 1 then return "s" end -- 一大片平鋪在地上
		end)
		assert.are.equal(0, #overhang.find_failing(g, P))
	end)
end)

describe("overhang 局部版本與全範圍版本一致", function()
	-- 以所有鍵結格為起點時，局部版本應找出與全範圍版本相同的掉落格
	local function all_starts(g)
		local s = {}
		for i, c in ipairs(g.data) do
			if g.bonded_of[c] then
				local k = i - 1
				s[#s + 1] = {x = g.ox + k % g.nx, y = g.oy + math.floor(k / g.nx) % g.ny, z = g.oz + math.floor(k / (g.nx * g.ny))}
			end
		end
		return s
	end
	local function count(groups)
		local n = 0
		for _, gr in ipairs(groups) do n = n + #gr.cells end
		return n
	end
	local cases = {
		{"砂岩 L=7", function() return cantilever("s", 7, 1) end},
		{"砂岩 L=9", function() return cantilever("s", 9, 1) end},
		{"頁岩 L=6", function() return cantilever("h", 6, 1) end},
		{"花崗岩 L=10", function() return cantilever("g", 10, 1) end},
		{"砂岩 L=9 厚 2", function() return cantilever("s", 9, 2) end},
	}
	for _, c in ipairs(cases) do
		it(c[1], function()
			local g1 = c[2]()
			local g2 = c[2]()
			assert.are.equal(count(overhang.find_failing(g1, P)),
				count(overhang.find_failing_local(g2, P, all_starts(g2))))
		end)
	end

	it("只從移除位置附近出發也找得到（懸臂根部旁的起點）", function()
		local g = cantilever("s", 9, 1)
		local r = overhang.find_failing_local(g, P, {{x = 5, y = 8, z = 0}})
		assert.are.equal(1, #r)
		assert.are.equal(9, #r[1].cells)
	end)

	it("起點在厚岩體中：立即結束、不掉落", function()
		local g = grid(-6, 6, -2, 14, -6, 6, function(x, y, z)
			if y <= 0 then return "G" end
			if math.abs(x) <= 1 and y >= 1 and y <= 3 then return nil end
			return "s"
		end)
		local r, st = overhang.find_failing_local(g, P, {{x = 0, y = 4, z = 0}, {x = 2, y = 2, z = 0}})
		assert.are.equal(0, #r)
	end)
end)

describe("overhang 懸臂安全係數", function()
	it("FS = σt/(3γd²/t) = (L_max/d)²；整段取最小（尖端）", function()
		local g = cantilever("h", 4, 1)
		local lm = overhang.lmax(2, 25, 1)
		local tip = overhang.cell_state(g, P, 4, 8, 0)
		assert.are.equal(4, tip.d)
		assert.are.equal(1, tip.t)
		assert.near((lm / 4) ^ 2, tip.fs, 1e-9)
		assert.near(3 * 25 * 16 / 1 / 1000, tip.sigma_b, 1e-12)
		assert.near(2 / tip.sigma_b, tip.fs, 1e-9)
		local root = overhang.cell_state(g, P, 1, 8, 0)
		assert.are.equal(1, root.d)
		assert.near(lm ^ 2, root.fs, 1e-9)
		assert.near(tip.fs, root.group_fs, 1e-12)
		assert.are.equal(4, root.crit.x)
	end)

	it("岩柱本身（坐在地面上）：有支撐", function()
		local st = overhang.cell_state(cantilever("h", 4, 1), P, 0, 5, 0)
		assert.is_true(st.supported)
	end)

	it("非岩石格：nil", function()
		assert.is_nil(overhang.cell_state(cantilever("h", 4, 1), P, 2, 3, 0))
	end)

	it("整段 FS < 1 ⇔ 局部判定會斷（各岩性、長度、厚度）", function()
		for _, lith in ipairs({"s", "h", "g"}) do
			for _, t in ipairs({1, 2}) do
				for L = 2, 14 do
					local g = cantilever(lith, L, t)
					local st = overhang.cell_state(g, P, 1, 8, 0)
					local groups = overhang.find_failing_local(g, P, {{x = 1, y = 8, z = 0}})
					assert.are.equal(#groups > 0, st.group_fs < 1,
						("lith=%s t=%d L=%d fs=%.3f"):format(lith, t, L, st.group_fs))
				end
			end
		end
	end)
end)

describe("overhang 懸空群碰到範圍邊界", function()
	it("梁伸出範圍外：標示 edge（FS 可能高估）；完整在範圍內：不標示", function()
		local inside = overhang.cell_state(cantilever("g", 6, 1), P, 3, 8, 0)
		assert.is_false(inside.edge)
		-- 同一根梁，但網格只讀到 x = 5（req 內縮一格 → x ≤ 4），梁在範圍邊界被截斷
		local g = cantilever("g", 6, 1)
		g.req.x2 = 4
		local cut = overhang.cell_state(g, P, 3, 8, 0)
		assert.is_true(cut.edge)
		assert.is_true(cut.group_fs > inside.group_fs)
	end)
end)

describe("overhang 節理切過根部斷面", function()
	-- 指定被節理切過的面：key = "x,y,z,axis"（face_jointed 的參數）
	local function with_joints(faces)
		local set = {}
		for _, k in ipairs(faces) do set[k] = true end
		local p = {}
		for k, v in pairs(P) do p[k] = v end
		p.face_jointed = function(x, y, z, axis) return set[x .. "," .. y .. "," .. z .. "," .. axis] or false end
		return p
	end
	local function fell(groups, x, y, z)
		for _, gr in ipairs(groups) do
			for _, c in ipairs(gr.cells) do
				if c.x == x and c.y == y and c.z == z then return true end
			end
		end
		return false
	end

	it("1 m 厚的短梁：根部被節理切斷 → 張力為 0，整段掉落", function()
		local g = cantilever("g", 2, 1)
		assert.are.equal(0, #overhang.find_failing_local(g, P, {{x = 1, y = 8, z = 0}}))
		local pj = with_joints({"0,8,0,1"})   -- x=0 與 x=1 之間的面
		local groups = overhang.find_failing_local(g, pj, {{x = 1, y = 8, z = 0}})
		assert.are.equal(1, #groups)
		assert.is_true(fell(groups, 2, 8, 0))
		local st = overhang.cell_state(g, pj, 1, 8, 0)
		assert.is_nil(st.d)
		assert.are.equal(0, st.group_fs)
	end)

	it("2 m 厚的梁：根部一半被切 → L_max × 1/2", function()
		-- 頁岩 t=2：L_max = 7.30；切一半 → 3.65，L=4 會斷、L=3 不會
		local pj = with_joints({"0,8,0,1"})
		local st = overhang.cell_state(cantilever("h", 4, 2), pj, 1, 8, 0)
		assert.near(0.5, st.rho, 1e-12)
		assert.near((overhang.lmax(2, 25, 2) * 0.5 / 4) ^ 2, st.group_fs, 1e-9)
		assert.are.equal(1, #overhang.find_failing_local(cantilever("h", 4, 2), pj, {{x = 1, y = 8, z = 0}}))
		assert.are.equal(0, #overhang.find_failing_local(cantilever("h", 3, 2), pj, {{x = 1, y = 8, z = 0}}))
		assert.are.equal(0, #overhang.find_failing_local(cantilever("h", 4, 2), P, {{x = 1, y = 8, z = 0}}))
		-- σb = 3γ·t·d²/t_eff²
		local tip = overhang.cell_state(cantilever("h", 4, 2), pj, 4, 8, 0)
		assert.near(3 * 25 * 2 * 16 / 1 / 1000, tip.sigma_b, 1e-12)
	end)

	it("梁中間被節理切斷：外側那段被切離而掉落，內側保留", function()
		local g = cantilever("g", 4, 1)
		local pj = with_joints({"2,8,0,1"})   -- x=2 與 x=3 之間
		local groups = overhang.find_failing_local(g, pj, {{x = 1, y = 8, z = 0}})
		assert.are.equal(1, #groups)
		assert.is_true(fell(groups, 3, 8, 0))
		assert.is_true(fell(groups, 4, 8, 0))
		assert.is_false(fell(groups, 1, 8, 0))
		assert.is_false(fell(groups, 2, 8, 0))
		local inner = overhang.cell_state(g, pj, 2, 8, 0)
		assert.is_true(inner.group_fs > 1)
		assert.are.equal(0, overhang.cell_state(g, pj, 3, 8, 0).group_fs)
	end)
end)

describe("overhang 被節理切離的相鄰塊", function()
	it("從梁內側那格查詢：回報外側被切離、會掉落的格數", function()
		local set = {["2,8,0,1"] = true}
		local p = {}
		for k, v in pairs(P) do p[k] = v end
		p.face_jointed = function(x, y, z, axis) return set[x .. "," .. y .. "," .. z .. "," .. axis] or false end
		local st = overhang.cell_state(cantilever("g", 4, 1), p, 1, 8, 0)
		assert.are.equal(2, st.cut_cells)
		assert.is_true(st.group_fs > 1)
		assert.are.equal(0, overhang.cell_state(cantilever("g", 4, 1), P, 1, 8, 0).cut_cells)
	end)

	it("支撐岩柱只在垂直方向超出範圍：不標示 edge", function()
		local g = cantilever("g", 3, 1)
		g.req.y1 = 5   -- 岩柱往下超出範圍
		local st = overhang.cell_state(g, P, 1, 8, 0)
		assert.is_false(st.edge)
	end)
end)
