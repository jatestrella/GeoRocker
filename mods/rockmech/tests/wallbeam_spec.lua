-- tests/wallbeam_spec.lua：擋土壁的彈性支承梁法
local wb = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])tests[/\\]") or "./") .. "wallbeam.lua")

local EI = 2e8 * 1.68e-4          -- SP-III
-- 9 m 的板樁，牆後土面在樁頂，前面挖 H m；c、φ 35°、γ 18、kh 15000
local function wall(H, c, prop_i, kprop)
	local t = {n = 9, EI = EI, soil = {}, props = {}}
	for i = 1, 9 do
		t.soil[#t.soil + 1] = wb.soil_spring(i, -1, 18 * (i - 0.5), c, 35, 15000)
		if i > H then t.soil[#t.soil + 1] = wb.soil_spring(i, 1, 18 * (i - H - 0.5), c, 35, 15000) end
	end
	if prop_i then t.props[1] = {prop_i, 1, kprop} end
	return wb.solve(t)
end

describe("wallbeam 彈性支承梁法", function()
	it("土壓係數：K0 = 1 − sinφ、Ka·Kp = 1", function()
		local K0, Ka, Kp = wb.coeffs(30)
		assert.near(0.5, K0, 1e-9)
		assert.near(1 / 3, Ka, 1e-9)
		assert.near(1, Ka * Kp, 1e-9)
	end)
	it("沒有開挖：兩側靜止土壓平衡，不動、沒有彎矩", function()
		local r = wall(0, 10)
		assert.is_true(r.ok)
		assert.is_true(r.Mmax < 1e-6)
	end)
	it("懸臂：越挖越深彎矩越大；6 m（c 10 kPa）約同自由端支撐法的量級", function()
		local m3, m5, m6 = wall(3, 10).Mmax, wall(5, 10).Mmax, wall(6, 10)
		assert.is_true(m3 < m5 and m5 < m6.Mmax)
		assert.is_true(m6.ok)
		assert.is_true(m6.Mmax > 40 and m6.Mmax < 120)
	end)
	it("砂土（c = 0）挖 6 m、只埋 3 m：撐不住（形成機構）", function()
		assert.is_false(wall(6, 0).ok)
	end)
	it("加一層支撐：彎矩變小、支撐受壓", function()
		local k = 2 * 2e8 * 1.184e-2 / 6 / 3
		local free, prop = wall(6, 10), wall(6, 10, 2, k)
		assert.is_true(prop.ok)
		assert.is_true(prop.Mmax < free.Mmax)
		assert.is_true(prop.prop[1] > 0)
	end)
end)
