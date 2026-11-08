dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local A = load_module("airflow")

-- 隧道：沿 x 的 4×4 斷面，格子 x = 0..n-1（每格 4×4×8 = 128 m³），只有前後兩面通（16 m²）
local function tunnel(n, portal_sky)
	return {
		vol = function(x, y, z) return (y == 0 and z == 0 and x >= 0 and x < n) and 128 or 0 end,
		sky = function(x) return (portal_sky and x == 0) and 1 or 0 end,
		face = function(x, y, z, d)
			if y ~= 0 or z ~= 0 then return 0 end
			local nx = x + A.DIRS[d][1]
			if A.DIRS[d][2] ~= 0 or A.DIRS[d][3] ~= 0 or nx < 0 or nx >= n then return 0 end
			return 16
		end,
	}
end
-- 開放空間：到處都是空氣（每格 512 m³、每面 64 m²），sky：看得到天空的比例
local function open(sky)
	return {vol = function() return 512 end, sky = function() return sky end, face = function() return 64 end}
end
local function total(state) local m = 0; for _, c in pairs(state.cells) do m = m + c.m end; return m end
local function ppm(state, x, y, z) local c = state.cells[A.key(x, y, z)]; return c and A.ppm(c) or 0 end

describe("airflow 空氣品質", function()
	it("校準：每 kW 給 0.06 m³/s 新鮮風量時，滿載柴油引擎的濃度是 25 ppm", function()
		local kw = 120
		local co_rate = A.diesel_m3(A.BSFC * kw / 3600)         -- 滿載每秒放出的廢氣（m³/s）
		assert.near(25, co_rate / (A.DILUTION * kw) * 1e6, 1e-9)
	end)

	it("封閉的隧道：只擴散，氣體總量不變", function()
		local s, g = A.new(), tunnel(10)
		A.emit(s, g, 9, 0, 0, 0.5)
		for _ = 1, 200 do A.step(s, g, 1) end
		assert.near(0.5, total(s), 5e-4)       -- 擴散最前緣淡到 < 1 ppm 的格子不追蹤，會漏一點點
		assert.is_true(ppm(s, 8, 0, 0) > 0)       -- 有往隔壁擴散
		assert.is_true(ppm(s, 9, 0, 0) > ppm(s, 5, 0, 0))
	end)

	it("同樣的炮煙：開放空間很快淡掉，隧道工作面還是很濃", function()
		local so, go = A.new(), open(1)
		local st, gt = A.new(), tunnel(12, true)
		A.emit(so, go, 0, 0, 0, 0.5)
		A.emit(st, gt, 11, 0, 0, 0.5)
		for _ = 1, 120 do A.step(so, go, 1); A.step(st, gt, 1) end
		assert.is_true(ppm(so, 0, 0, 0) < 5)
		assert.is_true(ppm(st, 11, 0, 0) > 200)
	end)

	it("風機：沿著隧道推空氣，工作面的炮煙幾分鐘內清乾淨", function()
		local s, g = A.new(), tunnel(12, true)
		local path = {}
		for x = 0, 11 do path[#path + 1] = {x, 0, 0} end
		A.emit(s, g, 11, 0, 0, 0.5)
		local fans = {{path = path, q = 10}}
		local removed = 0
		for _ = 1, 300 do removed = removed + A.step(s, g, 1, fans) end
		assert.is_true(ppm(s, 11, 0, 0) < A.LIMIT_PPM)
		assert.is_true(removed > 0.4)             -- 大部分是從風管抽走的
	end)

	it("工作面有柴油機具：風量照 0.06 m³/s/kW 給，穩定後工作面約 25 ppm", function()
		local s, g = A.new(), tunnel(6, true)
		local kw, q = 120, 0.06 * 120
		local path = {}
		for x = 0, 5 do path[#path + 1] = {x, 0, 0} end
		local rate = A.diesel_m3(A.BSFC * kw / 3600)
		for _ = 1, 1200 do
			A.emit(s, g, 5, 0, 0, rate)
			A.step(s, g, 1, {{path = path, q = q}})
		end
		local c = ppm(s, 5, 0, 0)
		assert.is_true(c > 20 and c < 30)
	end)

	it("沒有空氣的格子放不進去", function()
		local s, g = A.new(), tunnel(3)
		assert.is_false(A.emit(s, g, 0, 5, 0, 1))
		assert.is_true(A.emit(s, g, 0, 0, 0, 1))
	end)
end)
