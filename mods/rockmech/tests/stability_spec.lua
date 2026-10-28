dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local stability = load_module("stability")

local AIR, ROCK, RUBBLE = 0, 1, 2

-- fn(x,y,z) 回傳 "r"（岩石）、"b"（碎石）或 nil（空氣）；網格 x,z ∈ [-r, r]，y ∈ [y0, y1]
local function make_grid(r, y0, y1, fn)
	local g = {
		ox = -r, oy = y0, oz = -r, nx = 2 * r + 1, ny = y1 - y0 + 1, nz = 2 * r + 1,
		data = {},
		bonded_of = {[ROCK] = true},
		solid_of = {[ROCK] = true, [RUBBLE] = true},
	}
	local i = 1
	for z = -r, r do for y = y0, y1 do for x = -r, r do
		local c = fn(x, y, z)
		g.data[1 + (x + r) + (y - y0) * g.nx + (z + r) * g.nx * g.ny] =
			c == "r" and ROCK or (c == "b" and RUBBLE or AIR)
		i = i + 1
	end end end
	return g
end

local function nb6(p)
	return {
		{x = p.x + 1, y = p.y, z = p.z}, {x = p.x - 1, y = p.y, z = p.z},
		{x = p.x, y = p.y + 1, z = p.z}, {x = p.x, y = p.y - 1, z = p.z},
		{x = p.x, y = p.y, z = p.z + 1}, {x = p.x, y = p.y, z = p.z - 1},
	}
end

describe("stability 懸空判定", function()
	it("獨立柱底部挖空：整根懸空", function()
		-- 地面 y ≤ 0（碰到網格底部），柱 x=z=0、y 2..6，y=1 被挖掉
		local g = make_grid(6, -4, 12, function(x, y, z)
			if y <= 0 then return "r" end
			if x == 0 and z == 0 and y >= 2 and y <= 6 then return "r" end
		end)
		local comps = stability.find_detached(g, nb6({x = 0, y = 1, z = 0}))
		assert.are.equal(1, #comps)
		assert.are.equal(5, #comps[1].cells)
		assert.are.equal(2, comps[1].cells[1].y) -- 由低到高
		assert.are.equal(6, comps[1].cells[5].y)
	end)

	it("柱子立在地面上：有支撐", function()
		local g = make_grid(6, -4, 12, function(x, y, z)
			if y <= 0 then return "r" end
			if x == 0 and z == 0 and y >= 1 and y <= 6 then return "r" end
		end)
		local comps = stability.find_detached(g, nb6({x = 1, y = 3, z = 0}))
		assert.are.equal(0, #comps)
	end)

	it("隧道頂板：連回大岩體，不掉", function()
		local g = make_grid(8, -8, 8, function(x, y, z)
			if math.abs(x) <= 1 and y >= 0 and y <= 2 then return nil end -- 沿 z 的隧道
			return "r"
		end)
		local comps, stats = stability.find_detached(g, nb6({x = 0, y = 2, z = 0}))
		assert.are.equal(0, #comps)
		assert.truthy(stats.visited < 60, "應很快往下找到邊界，實際展開 " .. stats.visited)
	end)

	it("懸臂（側邊連著岩壁）：不掉", function()
		local g = make_grid(6, -4, 12, function(x, y, z)
			if y <= 0 then return "r" end
			if x <= -3 and y <= 8 then return "r" end              -- 岩壁
			if x > -3 and x <= 1 and z == 0 and y == 6 then return "r" end -- 從牆伸出的懸臂
		end)
		local comps = stability.find_detached(g, nb6({x = 1, y = 5, z = 0}))
		assert.are.equal(0, #comps)
	end)

	it("坐在碎石堆上：有支撐", function()
		local g = make_grid(6, -4, 12, function(x, y, z)
			if y <= 0 then return "r" end
			if x == 0 and z == 0 and y == 1 then return "b" end
			if x == 0 and z == 0 and y >= 2 and y <= 6 then return "r" end
		end)
		local comps = stability.find_detached(g, {{x = 0, y = 4, z = 0}})
		assert.are.equal(0, #comps)
	end)

	it("懸空但超過體素上限：保守視為穩定", function()
		local g = make_grid(6, -4, 12, function(x, y, z)
			if y <= 0 then return "r" end
			if math.abs(x) <= 3 and math.abs(z) <= 3 and y >= 3 and y <= 6 then return "r" end
		end)
		assert.are.equal(1, #stability.find_detached(g, {{x = 0, y = 4, z = 0}}, 1000))
		assert.are.equal(0, #stability.find_detached(g, {{x = 0, y = 4, z = 0}}, 100))
	end)

	it("多個起點屬於同一群只回報一次", function()
		local g = make_grid(6, -4, 12, function(x, y, z)
			if y <= 0 then return "r" end
			if math.abs(x) <= 1 and z == 0 and y >= 3 and y <= 4 then return "r" end
		end)
		local comps, stats = stability.find_detached(g, {
			{x = -1, y = 3, z = 0}, {x = 1, y = 4, z = 0}, {x = 0, y = 3, z = 0},
		})
		assert.are.equal(1, #comps)
		assert.are.equal(6, #comps[1].cells)
		assert.are.equal(1, stats.searches)
	end)

	it("兩個分開的懸空群各自回報", function()
		local g = make_grid(6, -4, 12, function(x, y, z)
			if y <= 0 then return "r" end
			if (x == -3 or x == 3) and z == 0 and y >= 3 and y <= 4 then return "r" end
		end)
		local comps = stability.find_detached(g, {{x = -3, y = 3, z = 0}, {x = 3, y = 4, z = 0}})
		assert.are.equal(2, #comps)
	end)

	it("起點是空氣或碎石：略過", function()
		local g = make_grid(4, -2, 6, function(x, y, z)
			if y <= 0 then return "r" end
			if x == 0 and z == 0 and y == 1 then return "b" end
		end)
		local comps, stats = stability.find_detached(g, {{x = 0, y = 1, z = 0}, {x = 0, y = 3, z = 0}})
		assert.are.equal(0, #comps)
		assert.are.equal(0, stats.searches)
	end)
end)
