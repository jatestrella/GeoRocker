dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local keyblock = load_module("keyblock")

local AIR, ROCK = 0, 1
local GAMMA = 25
local TAN30 = math.tan(math.rad(30))

local function unit(x, y, z)
	local l = math.sqrt(x * x + y * y + z * z)
	return {x = x / l, y = y / l, z = z / l}
end
local function dipvec(dip, dipdir)
	local d, a = math.rad(dip), math.rad(dipdir)
	return {x = math.sin(a) * math.sin(d), y = math.cos(d), z = math.cos(a) * math.sin(d)}
end

-- 網格 [-R, R]³；solid(x,y,z) 決定岩石或空氣。節理以平面表示：planes = {{n, k, set}...}，
-- 平面切過兩格中心之間 ⇔ n·c − k 正負不同。
local R = 7
local function setup(solid, planes, sets)
	local g = {ox = -R, oy = -R, oz = -R, nx = 2 * R + 1, ny = 2 * R + 1, nz = 2 * R + 1, data = {},
		bonded_of = {[ROCK] = true}, solid_of = {[ROCK] = true}, lith_of = {[ROCK] = "rock"}}
	for z = -R, R do for y = -R, R do for x = -R, R do
		g.data[1 + (x + R) + (y + R) * g.nx + (z + R) * g.nx * g.ny] = solid(x, y, z) and ROCK or AIR
	end end end
	local p = {
		face_set = function(x, y, z, axis)
			local e = axis == 1 and {1, 0, 0} or axis == 2 and {0, 1, 0} or {0, 0, 1}
			for _, pl in ipairs(planes) do
				local n = pl.n
				local a = n.x * x + n.y * y + n.z * z - pl.k
				local b = n.x * (x + e[1]) + n.y * (y + e[2]) + n.z * (z + e[3]) - pl.k
				if (a > 0) ~= (b > 0) then return pl.set end
			end
			return nil
		end,
		joint_sets = sets, c = 0, tanphi = TAN30,
		lithologies = {rock = {gamma = GAMMA}}, max_cells = 500,
	}
	return g, p
end

describe("keyblock 關鍵塊體", function()
	-- 平面滑動：60° 傾向東（+x）的節理 A 在下，後方垂直節理 B（x = −1.5），兩側 C（z = ±1.5），
	-- 頂部水平節理 D（y = 2.5）；東側 x ≥ 3 是空氣（臨空面）
	local nA = dipvec(60, 90)
	local function plane_case(c)
		local planes = {
			{n = nA, k = 0.3, set = 1},
			{n = unit(1, 0, 0), k = -1.5, set = 2},
			{n = unit(0, 0, 1), k = 1.5, set = 3}, {n = unit(0, 0, 1), k = -1.5, set = 3},
			{n = unit(0, 1, 0), k = 2.5, set = 4},
		}
		local sets = {{n_eff = nA, name = "A"}, {n_eff = unit(1, 0, 0), name = "B"},
			{n_eff = unit(0, 0, 1), name = "C"}, {n_eff = unit(0, 1, 0), name = "D"}}
		local g, p = setup(function(x) return x <= 2 end, planes, sets)
		p.c = c or 0
		return g, p
	end

	it("平面滑動：c = 0 時 FS = tanφ / tanψ", function()
		local g, p = plane_case(0)
		local blocks = keyblock.find_blocks(g, p, {{x = 1, y = 1, z = 0}})
		assert.are.equal(1, #blocks)
		local b = blocks[1]
		assert.is_true(b.mode == "plane" or b.mode == "wedge")
		assert.near(TAN30 / math.tan(math.rad(60)), b.fs, 1e-9)
		assert.near(-math.sin(math.rad(60)), b.dir.y, 1e-9)   -- 順傾向往下
		assert.is_true(b.dir.x > 0)
		assert.near(#b.cells * GAMMA, b.W, 1e-9)
	end)

	it("平面滑動：加上凝聚力 FS = (W cosψ tanφ + c·A) / (W sinψ)", function()
		local g, p = plane_case(50)
		local b = keyblock.find_blocks(g, p, {{x = 1, y = 1, z = 0}})[1]
		local A
		for _, pl in ipairs(b.planes) do if pl.set == 1 then A = pl.area end end
		assert.is_true(A ~= nil)
		local W, s, c = b.W, math.sin(math.rad(60)), math.cos(math.rad(60))
		-- 兩側 C 面平行於滑動方向，也提供 c·A，所以 FS ≥ 只算底面的值
		assert.is_true(b.fs > TAN30 / math.tan(math.rad(60)))
		assert.is_true(b.fs >= (W * c * TAN30 + 50 * A) / (W * s) - 1e-9)
	end)

	it("楔形滑動：J2 60°/045 與 J3 60°/315 的交線朝北傾伏 50.8°", function()
		local n2, n3 = dipvec(60, 45), dipvec(60, 315)
		local planes = {
			{n = n2, k = 0.1, set = 1}, {n = n3, k = 0.1, set = 2},
			{n = unit(0, 1, 0), k = 2.5, set = 3},
		}
		local sets = {{n_eff = n2, name = "J2"}, {n_eff = n3, name = "J3"}, {n_eff = unit(0, 1, 0), name = "D"}}
		local g, p = setup(function(_, _, z) return z <= 2 end, planes, sets)
		local blocks = keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 1}})
		assert.are.equal(1, #blocks)
		local b = blocks[1]
		assert.are.equal("wedge", b.mode)
		local plunge = math.deg(math.asin(-b.dir.y))
		assert.near(50.8, plunge, 0.2)
		assert.is_true(b.dir.z > 0)
		-- 楔形係數 > 1：比同傾角的平面滑動穩定
		assert.is_true(b.fs > TAN30 / math.tan(math.rad(plunge)))
		assert.is_true(b.fs < 1)
	end)

	it("下方臨空、四周與頂部都被節理切開 → 落下；c = 0 時 FS = 0", function()
		local planes = {
			{n = unit(1, 0, 0), k = 1.5, set = 1}, {n = unit(1, 0, 0), k = -1.5, set = 1},
			{n = unit(0, 0, 1), k = 1.5, set = 2}, {n = unit(0, 0, 1), k = -1.5, set = 2},
			{n = unit(0, 1, 0), k = 2.5, set = 3},
		}
		local sets = {{n_eff = unit(1, 0, 0)}, {n_eff = unit(0, 0, 1)}, {n_eff = unit(0, 1, 0)}}
		local g, p = setup(function(_, y) return y >= 0 end, planes, sets)
		local b = keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 0}})[1]
		assert.are.equal("fall", b.mode)
		assert.are.equal(0, b.fs)
		-- 有凝聚力：垂直面提供 c·A
		p.c = 50
		local b2 = keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 0}})[1]
		local Avert = 4 * 3 * 3   -- 3×3 塊、高 3 格（y 0..2），四個側面各 3×3
		assert.near(50 * Avert / b2.W, b2.fs, 1e-9)
	end)

	it("有一面沒被節理切開（岩橋）→ 與岩體相連，不是獨立岩塊", function()
		local planes = {
			{n = unit(1, 0, 0), k = 1.5, set = 1}, {n = unit(1, 0, 0), k = -1.5, set = 1},
			{n = unit(0, 0, 1), k = 1.5, set = 2},   -- 少了 z = −1.5
			{n = unit(0, 1, 0), k = 2.5, set = 3},
		}
		local sets = {{n_eff = unit(1, 0, 0)}, {n_eff = unit(0, 0, 1)}, {n_eff = unit(0, 1, 0)}}
		local g, p = setup(function(_, y) return y >= 0 end, planes, sets)
		assert.are.equal(0, #keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 0}}))
		assert.are.equal(false, keyblock.block_at(g, p, 0, 1, 0))
	end)

	it("坐在水平節理上、側面臨空 → 卡住（FS = ∞）", function()
		local planes = {
			{n = unit(1, 0, 0), k = -1.5, set = 1},
			{n = unit(0, 0, 1), k = 1.5, set = 2}, {n = unit(0, 0, 1), k = -1.5, set = 2},
			{n = unit(0, 1, 0), k = 0.5, set = 3}, {n = unit(0, 1, 0), k = 2.5, set = 3},
		}
		local sets = {{n_eff = unit(1, 0, 0)}, {n_eff = unit(0, 0, 1)}, {n_eff = unit(0, 1, 0)}}
		local g, p = setup(function(x) return x <= 2 end, planes, sets)
		local b = keyblock.find_blocks(g, p, {{x = 0, y = 1, z = 0}})[1]
		assert.is_true(b ~= nil)
		assert.are.equal(math.huge, b.fs)
		assert.is_nil(b.mode)
	end)

	it("滑動位移：沿滑動方向移出、再落到底", function()
		local cells = {{x = 0, y = 1, z = 0}, {x = 0, y = 2, z = 0}}
		-- x ≤ 0、y ≤ 0 是岩石；x ≥ 1 一路空到 y = −5
		local function is_free(x, y) if x <= 0 then return y >= 1 end return y >= -5 end
		local off = keyblock.slide_offset(cells, unit(1, -1, 0), is_free)
		assert.is_true(off.x >= 1)
		assert.are.equal(-6, off.y)   -- 最低格 y=1 落到 y=−5
		-- 完全被擋住
		local stuck = keyblock.slide_offset(cells, unit(1, -1, 0), function() return false end)
		assert.are.equal(0, stuck.x); assert.are.equal(0, stuck.y)
	end)
end)

describe("keyblock 滑動路徑", function()
	it("斜向滑動：沿階梯一格一格移出（不會因為一步跨太大而被擋住）", function()
		-- 坡面：x + z ≤ 2·y 以下是岩石的階梯；方塊在 (0,1,0)，往 (+x,−y,+z) 滑
		local cells = {{x = 0, y = 1, z = 0}}
		local function is_free(x, y, z) return x + z > 2 * (y - 1) or y > 1 end
		local d = math.sqrt(0.35 ^ 2 * 2 + 0.87 ^ 2)
		local off = keyblock.slide_offset(cells, {x = 0.35 / d, y = -0.87 / d, z = 0.35 / d}, is_free, 6)
		assert.is_true(off.x + off.z >= 2)
		assert.is_true(off.y < 0)
	end)
end)

describe("keyblock 滑到平地就停", function()
	it("離開坡面落到平地後不會繼續水平滑動", function()
		-- y ≤ 0 是平地；方塊從 (0,5,0) 往北下方滑
		local cells = {{x = 0, y = 5, z = 0}}
		local off = keyblock.slide_offset(cells, {x = 0, y = -0.78, z = 0.62}, function(_, y) return y >= 1 end, 16)
		assert.are.equal(-4, off.y)
		assert.is_true(off.z <= 2)
	end)
end)

describe("keyblock 整體滑動（大型楔形／平面）", function()
	local joints = load_module("joints")
	-- 正北、正東傾向 60° 的貫通節理（間距 4 m）
	local sets = joints.prepare({
		{id = 2, name = "J2", dip = 60, dipdir = 0, spacing = 4, persistence = 1, phi = 30, offset = 0},
		{id = 3, name = "J3", dip = 60, dipdir = 90, spacing = 4, persistence = 1, phi = 30, offset = 0},
	}, 1, 8, "patch")
	local RR = 20
	local function grid(solid)
		local g = {ox = -RR, oy = -RR, oz = -RR, nx = 2 * RR + 1, ny = 2 * RR + 1, nz = 2 * RR + 1, data = {},
			bonded_of = {[ROCK] = true}, solid_of = {[ROCK] = true}, lith_of = {[ROCK] = "rock"}}
		for z = -RR, RR do for y = -RR, RR do for x = -RR, RR do
			g.data[1 + (x + RR) + (y + RR) * g.nx + (z + RR) * g.nx * g.ny] = solid(x, y, z) and ROCK or AIR
		end end end
		local p = {face_set = function(x, y, z, axis) return joints.face_joint(sets, x, y, z, axis) end,
			joint_sets = sets, c = 0, tanphi = TAN30, lithologies = {rock = {gamma = GAMMA}},
			max_mass = 20000}
		return g, p
	end

	-- 岩角的稜線（x = 0、z = 0）上的臨空格
	local edge = {}
	for y = -13, 0 do edge[#edge + 1] = {x = 0, y = y, z = 0} end

	it("凸出的岩角（東、北兩面臨空）：J2∩J3 上方整團沿交線滑出", function()
		local g, p = grid(function(x, y, z) return x <= 0 and z <= 0 and y <= 0 or y <= -14 end)
		local masses = keyblock.find_masses(g, p, edge)
		assert.is_true(#masses >= 1)
		local m = masses[1]
		assert.are.equal("wedge", m.mode)
		assert.is_true(m.fs < 1)
		assert.is_true(#m.cells > 50)
		assert.is_true(m.dir.x > 0 and m.dir.z > 0)   -- 交線朝東北
	end)

	it("筆直的北向長壁：交線（045°）斜向露出，稜柱照樣滑出", function()
		local g, p = grid(function(x, y, z) return z <= 0 and y <= 0 or y <= -14 end)
		local masses = keyblock.find_masses(g, p, edge)
		assert.is_true(#masses >= 1)
		assert.are.equal("wedge", masses[1].mode)
	end)

	it("南向的牆：交線往牆裡（坡腳前方是岩體），不滑", function()
		local g, p = grid(function(x, y, z) return z >= 0 and y <= 0 or y <= -14 end)
		local starts = {}
		for y = -13, 0 do starts[#starts + 1] = {x = 0, y = y, z = 0} end
		local masses = keyblock.find_masses(g, p, starts)
		assert.are.equal(0, #masses)
		-- �Y�}�U�誺����]���_�I�]��u�¤U�S�X�]����G�U���O�|������^
		local g2, p2 = grid(function(x, y, z) return z >= 0 and y <= 0 or y <= -14 end)
		assert.are.equal(0, #keyblock.find_masses(g2, p2, {{x = 0, y = -14, z = -1}}))
	end)

	it("岩橋：bridge_c 未設定時有岩橋就不判定", function()
		local sets2 = joints.prepare({
			{id = 2, name = "J2", dip = 60, dipdir = 0, spacing = 4, persistence = 0.5, phi = 30, offset = 0},
			{id = 3, name = "J3", dip = 60, dipdir = 90, spacing = 4, persistence = 0.5, phi = 30, offset = 0},
		}, 7, 8, "patch")
		local g, p = grid(function(x, y, z) return x <= 0 and z <= 0 and y <= 0 or y <= -14 end)
		p.joint_sets = sets2
		p.face_set = function(x, y, z, axis) return joints.face_joint(sets2, x, y, z, axis) end
		local masses = keyblock.find_masses(g, p, edge)
		assert.are.equal(0, #masses)
		-- 岩橋強度很低 → 照樣滑
		p.bridge_c = 1
		assert.is_true(#keyblock.find_masses(g, p, edge) >= 1)
	end)
end)
