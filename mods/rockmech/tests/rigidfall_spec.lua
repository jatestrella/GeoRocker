dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local rigid = load_module("rigidfall")

-- solid 為一組 "x,y,z" 鍵；另外 y ≤ floor_y 全部實心
local function world(floor_y, extra)
	local set = {}
	for _, p in ipairs(extra or {}) do set[rigid.key(p[1], p[2], p[3])] = true end
	return function(x, y, z)
		return y <= floor_y or set[rigid.key(x, y, z)] == true
	end
end

local function column(x, z, y1, y2)
	local t = {}
	for y = y1, y2 do t[#t + 1] = {x = x, y = y, z = z} end
	return t
end

describe("rigidfall 落下距離", function()
	it("懸空柱整根落到地面", function()
		-- 地面 y ≤ 0，柱 y 4..8 → 落 3 格（底落到 y=1）
		assert.are.equal(3, rigid.drop_distance(column(0, 0, 4, 8), world(0)))
	end)

	it("L 形：取各欄最小落差", function()
		-- 柱 (0, 5..8) 加上往 +x 伸出的一格 (1, 8)；(1, 6) 有障礙物
		local cells = column(0, 0, 5, 8)
		cells[#cells + 1] = {x = 1, y = 8, z = 0}
		-- (0,*)：落到 y=1 → 4；(1,8)：下方 (1,7) 空、(1,6) 實心 → 1
		assert.are.equal(1, rigid.drop_distance(cells, world(0, {{1, 6, 0}})))
	end)

	it("U 形中間夾著障礙物：被卡住", function()
		-- 兩隻腳 (−1, 3..6)、(1, 3..6)，橫梁 (−1..1, 7)；腳中間 (0, 5) 有障礙
		local cells = {}
		for _, c in ipairs(column(-1, 0, 3, 6)) do cells[#cells + 1] = c end
		for _, c in ipairs(column(1, 0, 3, 6)) do cells[#cells + 1] = c end
		for x = -1, 1 do cells[#cells + 1] = {x = x, y = 7, z = 0} end
		-- 腳底落到 y=1 需 2；橫梁中間 (0,7) 往下 (0,6) 空、(0,5) 實心 → 1
		assert.are.equal(1, rigid.drop_distance(cells, world(0, {{0, 5, 0}})))
		-- 沒有障礙時由腳決定
		assert.are.equal(2, rigid.drop_distance(cells, world(0)))
	end)

	it("群內上下有空隙：空隙不構成限制", function()
		-- (0,8) 與 (0,4) 屬於同一群（經由 (1,4..8) 相連），中間 (0,5..7) 為空
		local cells = {{x = 0, y = 8, z = 0}, {x = 0, y = 4, z = 0}}
		for _, c in ipairs(column(1, 0, 4, 8)) do cells[#cells + 1] = c end
		assert.are.equal(3, rigid.drop_distance(cells, world(0)))
	end)

	it("下方很深找不到支撐：回傳 nil", function()
		assert.is_nil(rigid.drop_distance(column(0, 0, 200, 202), world(-1000), 64))
	end)

	it("已經貼著實心格：0", function()
		assert.are.equal(0, rigid.drop_distance(column(0, 0, 1, 3), world(0)))
	end)
end)
