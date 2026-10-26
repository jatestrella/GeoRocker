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

describe("overhang 水平節理面（不傳張力）", function()
	local function with_faces(keys)
		local set = {}
		for _, k in ipairs(keys) do set[k] = true end
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

	it("只靠上方吊著、上方的面被節理切過 → 掉落（梁本身不受影響）", function()
		-- 花崗岩短梁 x=1..3、y=8，x=2 下方吊一格 (2,7,0)
		local g = grid(-3, 6, -2, 12, -2, 2, function(x, y, z)
			if y <= 0 then return "G" end
			if z == 0 and x == 0 and y <= 8 then return "g" end
			if z == 0 and x >= 1 and x <= 3 and y == 8 then return "g" end
			if z == 0 and x == 2 and y == 7 then return "g" end
		end)
		assert.are.equal(0, #overhang.find_failing_local(g, P, {{x = 2, y = 7, z = 0}}))
		local pj = with_faces({"2,7,0,2"})   -- (2,7) 與 (2,8) 之間
		local groups = overhang.find_failing_local(g, pj, {{x = 2, y = 7, z = 0}})
		assert.is_true(fell(groups, 2, 7, 0))
		assert.is_false(fell(groups, 2, 8, 0))
		assert.are.equal(0, overhang.cell_state(g, pj, 2, 7, 0).group_fs)
	end)

	it("頂板（兩側都連著岩體）不用懸臂判定：被層面切開的薄層也不會因懸臂斷", function()
		-- 頁岩：兩根岩柱 x=0、x=16（y 1..8），中間 y=6..8 的頂板（跨度 15 m）；y=6 與 y=7 之間是層面
		local g = grid(-3, 19, -2, 12, -2, 2, function(x, y, z)
			if y <= 0 then return "G" end
			if z == 0 and (x == 0 or x == 16) and y <= 8 then return "h" end
			if z == 0 and x >= 1 and x <= 15 and y >= 6 and y <= 8 then return "h" end
		end)
		local keys = {}
		for x = 1, 15 do keys[#keys + 1] = x .. ",6,0,2" end
		local pj = with_faces(keys)
		local starts = {{x = 8, y = 6, z = 0}, {x = 8, y = 7, z = 0}}
		assert.are.equal(0, #overhang.find_failing_local(g, P, starts))   -- 沒有層面：t=3 撐得住
		local groups = overhang.find_failing_local(g, pj, starts)
		assert.is_false(fell(groups, 8, 6, 0))
		assert.is_false(fell(groups, 8, 7, 0))
		local st = overhang.cell_state(g, pj, 8, 6, 0)
		assert.is_true(st.beam and st.beam.roof)
		assert.are.equal(15, st.beam.span)
	end)

	it("只有一側連著岩體的仍是懸臂", function()
		local g = grid(-3, 19, -2, 12, -2, 2, function(x, y, z)
			if y <= 0 then return "G" end
			if z == 0 and x == 0 and y <= 8 then return "h" end
			if z == 0 and x >= 1 and x <= 9 and y == 8 then return "h" end
		end)
		local st = overhang.cell_state(g, P, 9, 8, 0)
		assert.is_nil(st.beam)
		assert.near((overhang.lmax(2, 25, 1) / 9) ^ 2, st.fs, 1e-9)
	end)

	it("12 m 跨度的 1 m 薄層頂板：不當懸臂（FS ∞）", function()
		local g = grid(-3, 16, -2, 12, -2, 2, function(x, y, z)
			if y <= 0 then return "G" end
			if z == 0 and (x == 0 or x == 13) and y <= 8 then return "h" end
			if z == 0 and x >= 1 and x <= 12 and y == 8 then return "h" end
		end)
		local st = overhang.cell_state(g, P, 6, 8, 0)
		assert.is_true(st.beam ~= nil and st.beam.roof)
		assert.are.equal(12, st.beam.span)
		assert.are.equal(math.huge, st.fs)
		assert.are.equal(0, #overhang.find_failing_local(g, P, {{x = 6, y = 8, z = 0}}))
	end)

	it("坐在節理面上的岩柱（下段有支撐）仍算有支撐", function()
		local g = cantilever("h", 3, 1)
		local pj = with_faces({"0,4,0,2"})   -- 岩柱中間 y=4/5 之間被切
		assert.is_true(overhang.cell_state(g, pj, 0, 6, 0).supported)
		assert.are.equal(0, #overhang.find_failing_local(g, pj, {{x = 1, y = 8, z = 0}}))
	end)
end)

describe("overhang 懸空段列表（顯示用）", function()
	it("列出懸臂段與其最小 FS（與 cell_state 一致）", function()
		local g = cantilever("h", 4, 1)
		local segs = overhang.scan_segments(g, P, {{x = 2, y = 8, z = 0}, {x = 4, y = 8, z = 0}})
		assert.are.equal(1, #segs)
		assert.are.equal(4, #segs[1].cells)
		assert.near(overhang.cell_state(g, P, 1, 8, 0).group_fs, segs[1].fs, 1e-12)
	end)
end)

describe("overhang 層疊荷重（Obert & Duvall 疊層梁）", function()
	local function layered(t_low, t_up)
		-- 頁岩：岩柱 x=0（y 1..8）；下層 y 從 8−t_up−t_low+1 起、厚 t_low；上層在其上、厚 t_up；都伸出 x=1..4
		local top = 8
		local up_bot = top - t_up + 1
		local low_bot = up_bot - t_low
		local g = grid(-3, 8, -2, 12, -2, 2, function(x, y, z)
			if y <= 0 then return "G" end
			if z == 0 and x == 0 and y <= top then return "h" end
			if z == 0 and x >= 1 and x <= 4 and y >= low_bot and y <= top then return "h" end
		end)
		local set = {}
		for x = 1, 4 do set[x .. "," .. (up_bot - 1) .. ",0,2"] = true end   -- 上下層之間的層面
		local p = {}
		for k, v in pairs(P) do p[k] = v end
		p.face_jointed = function(x, y, z, axis) return set[x .. "," .. y .. "," .. z .. "," .. axis] or false end
		return g, p, low_bot, up_bot
	end
	local function fell(groups, x, y)
		for _, gr in ipairs(groups) do
			for _, c in ipairs(gr.cells) do if c.x == x and c.y == y and c.z == 0 then return true end end
		end
		return false
	end

	it("薄下層（t=1）＋厚上層（t=2）：上層較勁、自己分離，不壓在下層上（m = 1·3/9 < 1）", function()
		local g, p, low_bot, up_bot = layered(1, 2)
		local low = overhang.cell_state(g, p, 4, low_bot, 0)
		assert.near((overhang.lmax(2, 25, 1) / 4) ^ 2, low.group_fs, 1e-9)
		local upc = overhang.cell_state(g, p, 4, up_bot, 0)
		assert.are.equal(0, upc.d)
		assert.are.equal(math.huge, upc.fs)
		assert.are.equal(0, #overhang.find_failing_local(g, p, {{x = 4, y = low_bot, z = 0}, {x = 4, y = up_bot, z = 0}}))
	end)

	it("厚下層（t=3）承擔薄上層（t=1）：q₁/γt₁ = 9·4/28，下層 FS ÷ 1.286 ≥ 1 → 都不斷", function()
		local g, p, low_bot, up_bot = layered(3, 1)
		local low = overhang.cell_state(g, p, 4, low_bot, 0)
		assert.near((overhang.lmax(2, 25, 3) / 4) ^ 2 / (9 * 4 / 28), low.group_fs, 1e-9)
		assert.are.equal(0, #overhang.find_failing_local(g, p, {{x = 4, y = low_bot, z = 0}, {x = 4, y = up_bot, z = 0}}))
	end)
end)

describe("overhang 取最有利的根部", function()
	it("最近的根部被節理切掉大半時，改走較遠但完整的根部", function()
		-- 岩柱 x = 0、z −1..1；板 x 1..6、z −1..1、y 6..8（厚 3）
		local g = grid(-3, 9, -2, 12, -3, 3, function(x, y, z)
			if y <= 0 then return "G" end
			if x == 0 and z >= -1 and z <= 1 and y <= 8 then return "s" end
			if x >= 1 and x <= 6 and z >= -1 and z <= 1 and y >= 6 and y <= 8 then return "s" end
		end)
		local p = {lithologies = LITHS, scale = 1, max_voxels = 2000}
		-- (1, y, −1) 的根部斷面 y = 7、8 被節理切過：只剩 1/3 完整
		local set = {["0,7,-1,1"] = true, ["0,8,-1,1"] = true}
		p.face_jointed = function(x, y, z, axis) return set[x .. "," .. y .. "," .. z .. "," .. axis] or false end
		local st = overhang.cell_state(g, p, 1, 7, -1)
		-- 直接根部：d 1、rho 1/3 → (L/3)²；經 (1, 0) 的完整根部：d 2、rho 1 → (L/2)²，較有利
		assert.are.equal(2, st.d)
		assert.near(1, st.rho, 1e-12)
		assert.near((st.lmax / 2) ^ 2, st.fs, 1e-9)
	end)
end)
