dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local config = load_module("config")
local stress = load_module("stress")

describe("stress", function()
	it("深度 h = y0 - y", function()
		assert.are.equal(100, stress.depth(-100, 0))
		assert.are.equal(90, stress.depth(-80, 10))
		assert.are.equal(-5, stress.depth(5, 0))
	end)

	it("σv = γh（kN/m³·m → MPa）", function()
		assert.near(2.5, stress.sigma_v(25, 100), 1e-12)
		assert.near(26.5, stress.sigma_v(26.5, 1000), 1e-9)
		assert.are.equal(0, stress.sigma_v(25, 0))
		assert.are.equal(0, stress.sigma_v(25, -10)) -- 高於地表
	end)

	it("σh = K0·σv", function()
		assert.near(1.25, stress.sigma_h(2.5, 0.5), 1e-12)
		assert.near(5.0, stress.sigma_h(2.5, 2.0), 1e-12)
	end)

	it("分層邊界", function()
		local layers = config.layers
		assert.are.equal("sandstone", stress.layer_at_depth(layers, -30))
		assert.are.equal("sandstone", stress.layer_at_depth(layers, 0))
		assert.are.equal("sandstone", stress.layer_at_depth(layers, 19.9))
		assert.are.equal("shale", stress.layer_at_depth(layers, 20))
		assert.are.equal("shale", stress.layer_at_depth(layers, 59))
		assert.are.equal("granite", stress.layer_at_depth(layers, 60))
		assert.are.equal("granite", stress.layer_at_depth(layers, 1e6))
	end)

	it("initial() 綜合", function()
		local cfg = config.load(function(k)
			return ({rockmech_surface_y = "10", rockmech_k0 = "0.8"})[k]
		end)
		local s = stress.initial(cfg, {gamma = 25}, -90)
		assert.are.equal(100, s.h)
		assert.near(2.5, s.sv, 1e-12)
		assert.near(2.0, s.sh, 1e-12)
	end)

	it("layer_table 與 layer_at_depth 一致", function()
		local cfg = config.load()
		local t = stress.layer_table(cfg, -80, 5)
		for y = -80, 5 do
			assert.are.equal(stress.layer_at_depth(cfg.layers, -y), t[y])
		end
	end)
end)
