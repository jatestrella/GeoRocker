-- tests/concrete_spec.lua：混凝土的強度發展、素混凝土牆的開裂彎矩
local root = debug.getinfo(1, "S").source:match("^@(.*[/\\])tests[/\\]") or "./"
local CC = dofile(root .. "concretecurve.lua")
local wb = dofile(root .. "wallbeam.lua")

-- 10 m 的 1 m 厚素混凝土牆（f_c 28 MPa），牆後土面在牆頂，前面挖 H m；c 10、φ 35°、γ 18、kh 15000
local function wall(H)
	local t = {n = 10, EI = CC.ei(28), soil = {}, props = {}}
	for i = 1, 10 do
		t.soil[#t.soil + 1] = wb.soil_spring(i, -1, 18 * (i - 0.5), 10, 35, 15000)
		if i > H then t.soil[#t.soil + 1] = wb.soil_spring(i, 1, 18 * (i - H - 0.5), 10, 35, 15000) end
	end
	return wb.solve(t)
end

describe("concretecurve 混凝土強度發展", function()
	it("ACI 209：1 天約 21 %、7 天約 70 %、28 天 100 %", function()
		assert.near(0.206, CC.ratio(1), 0.002)
		assert.near(0.70, CC.ratio(7), 0.01)
		assert.near(1.0, CC.ratio(28), 0.01)
		assert.near(0, CC.ratio(0), 1e-12)
		assert.is_true(CC.ratio(90) > CC.ratio(28))
	end)
	it("28 MPa：破裂模數約 3.3 MPa、E 約 25 GPa；1 m 厚的牆 M_cr 約 550 kN·m/m", function()
		assert.near(3.28, CC.fr(28), 0.01)
		assert.near(24870, CC.ec(28), 10)
		assert.near(547, CC.mcr(28), 2)
		assert.near(2.07e6, CC.ei(28), 1e4)
	end)
	it("素混凝土懸臂牆（10 m）：挖 3–6 m 彎矩遠小於開裂彎矩；挖 7 m 埋入只剩 3 m，形成機構", function()
		for H = 3, 6 do
			local r = wall(H)
			assert.is_true(r.ok and r.Mmax < CC.mcr(28) / 4)
		end
		assert.is_false(wall(7).ok)
	end)
end)
