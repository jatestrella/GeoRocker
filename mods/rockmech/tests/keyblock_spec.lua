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
