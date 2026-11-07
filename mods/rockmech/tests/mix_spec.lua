dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local mix = load_module("mix")

-- 跟 nodes.lua 一樣的成分和組合
local R, G, S, COAL = "rubble", "rubble_granite", "rubble_soil", "ore:coal"
local ORE = {label = "煤"}
local ctx = {
	mix_of = {
		rubble_coal = {a = COAL, b = R, ore = ORE},
		rubble_coal_granite = {a = COAL, b = G, ore = ORE},
		rubble_coal_soil = {a = COAL, b = S, ore = ORE},
		colluvium = {a = S, b = R},
		colluvium_granite = {a = S, b = G},
		rubble_mixed = {a = G, b = R},
	},
	pair = {
		[COAL] = {[R] = "rubble_coal", [G] = "rubble_coal_granite", [S] = "rubble_coal_soil"},
		[S] = {[R] = "colluvium", [G] = "colluvium_granite"},
		[G] = {[R] = "rubble_mixed"},
	},
	rank = {[R] = 2, [G] = 2, [S] = 1, [COAL] = 3},
	ore_rubble = {[COAL] = "rubble_coal"},
}
local function merge(...) return mix.merge(ctx, ...) end

describe("mix 混合碎石", function()
	it("同一種純碎石：還是那一種", function()
		local b, p = merge(S, 8, 0, S, 4, 0)
		assert.are.equal(S, b)
		assert.are.equal(0, p)
	end)

	it("碎石＋土 → 崩積土，param2 = 土的比例", function()
		local b, p = merge(R, 4, 0, S, 4, 0)
		assert.are.equal("colluvium", b)
		assert.are.equal(128, p)
		b, p = merge(R, 6, 0, S, 2, 0)
		assert.are.equal("colluvium", b)
		assert.are.equal(64, p)
	end)

	it("花崗岩＋一般碎石 → 混合碎石", function()
		local b, p = merge(R, 3, 0, G, 5, 0)
		assert.are.equal("rubble_mixed", b)
		assert.are.equal(159, p)
	end)

	it("崩積土再加碎石：照體積更新土的比例", function()
		local b, p = merge("colluvium", 4, 128, R, 4, 0)
		assert.are.equal("colluvium", b)
		assert.are.equal(64, p)
	end)

	it("煤＋土 → 煤混土，碎石那一點併進土（價值低的）", function()
		-- 煤 6 級品位 200：煤 4.7、碎石 1.3；加土 6 → 土 6、煤 4.7、碎石 1.3
		local b, p = merge("rubble_coal", 6, 200, S, 6, 0)
		assert.are.equal("rubble_coal_soil", b)
		assert.are.equal(100, p)
	end)

	it("崩積土＋高品位煤 → 煤＋碎石，最少的土併進碎石（品位被稀釋）", function()
		local b, p = merge("colluvium", 8, 128, "rubble_coal", 8, 242)
		assert.are.equal("rubble_coal", b)
		assert.are.equal(121, p)
	end)

	it("第三種成分只會稀釋品位，不會灌高", function()
		for _, k in ipairs({1, 2, 4, 8}) do
			local _, p = merge("rubble_coal", 8, 200, S, k, 0)
			assert.is_true(p <= 200)
		end
	end)

	it("比例到 0 變回純的那種", function()
		local b, p = merge("colluvium", 4, 0, R, 4, 0)
		assert.are.equal(R, b)
		assert.are.equal(0, p)
	end)

	it("純礦石：煤＋廢石那種，品位 255", function()
		local b, p = merge("rubble_coal", 4, 255, "rubble_coal", 4, 255)
		assert.are.equal("rubble_coal", b)
		assert.are.equal(255, p)
	end)

	it("體積守恆：拆開再合起來，各成分的總量不變", function()
		local v = mix.parts(ctx, "colluvium", 8, 128, mix.parts(ctx, R, 4, 0, {}))
		local tot = 0
		for _, x in pairs(v) do tot = tot + x end
		assert.are.equal(12, tot)
	end)
end)

describe("表土自立高度 H_c = 4c/γ·tan(45°+φ/2)", function()
	it("c = 5 kPa、γ = 20、φ = 35° → 約 1.92 m", function()
		local h = mix.standing_height(5, 20, 35)
		assert.is_true(math.abs(h - 1.921) < 0.01)
	end)
	it("凝聚力 0 → 自立高度 0（鬆土）", function()
		assert.are.equal(0, mix.standing_height(0, 20, 35))
	end)
	it("凝聚力加倍 → 自立高度加倍", function()
		assert.is_true(math.abs(mix.standing_height(10, 20, 35) - 2 * mix.standing_height(5, 20, 35)) < 1e-9)
	end)
end)
