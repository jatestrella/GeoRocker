dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local R = load_module("railline")

describe("鐵路線形 railline", function()
	local pts = R.parse("-345,480;-345,300;-340,100;-330,-100;-335,-280;-350,-480")
	-- 起伏的地面：兩座 20 m 的丘
	local function ground(x, z) return 20 * math.exp(-((z - 200) / 40) ^ 2) + 15 * math.exp(-((z + 250) / 50) ^ 2) end
	local L = R.build(pts, ground, {grade = 0.015, load_z = 0, flat = 60, win = 120, hold = 400})

	it("控制點解析、每一排 z 都有中線", function()
		assert.are.equal(6, #pts)
		for z = -480, 480 do assert.is_true(L.rows[z] ~= nil) end
		assert.is_true(math.abs(L.rows[300].xc + 345) < 0.01)
		assert.is_true(math.abs(L.rows[-100].xc + 330) < 0.01)
	end)

	it("中線上的橫距是 0，往 +x 為正", function()
		local row = L.rows[50]
		local d = R.lateral(L, row.xc, 50)
		assert.is_true(math.abs(d) < 1e-9)
		assert.is_true(R.lateral(L, row.xc + 3, 50) > 2.9)
		assert.is_nil(R.lateral(L, 0, 600))
	end)

	it("縱斷面：坡度不超過 1.5%，裝車點前後是平的", function()
		for i = 2, L.n do assert.is_true(math.abs(L.y[i] - L.y[i - 1]) <= 0.015 + 1e-9) end
		local s0 = R.s_of_z(L, 0)
		for _, z in ipairs({50, 0, -50}) do
			assert.is_true(math.abs(L.rows[z].y - L.y_load) < 1e-9)
		end
		assert.is_true(math.abs(s0 - L.s_load) < 1.5)
	end)

	it("往南走時 yaw 朝 −z（約 ±π）", function()
		local _, _, _, yaw = L:at(L.s_load)
		assert.is_true(math.abs(math.abs(yaw) - math.pi) < 0.2)
	end)
end)
