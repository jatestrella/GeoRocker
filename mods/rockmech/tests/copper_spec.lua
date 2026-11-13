dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local Cu = load_module("copper")
local mix = load_module("mix")
local config = load_module("config")

local M = config.ores.copper.metal

describe("copper 浮選", function()
	it("精礦品位固定、質量守恆", function()
		local pt, pcu, tt, tcu = Cu.float(100, 0.02, 0.25, 0.85, 0.001)
		assert.is_true(math.abs(pt + tt - 100) < 1e-9)
		assert.is_true(math.abs(pcu + tcu - 2) < 1e-9)
		assert.is_true(math.abs(pcu / pt - 0.25) < 1e-9)
		assert.is_true(pcu / 2 > 0.8 and pcu / 2 < 0.82)          -- 2% 進料回收率約 81%
	end)
	it("進料越貧回收率越低", function()
		assert.is_true(Cu.recovery(0.0024, 0.85, 0.001) < Cu.recovery(0.01, 0.85, 0.001))
		assert.is_true(Cu.recovery(0.0024, 0.85, 0.001) < 0.65)
	end)
	it("精礦倒回去：全部進精礦、品位不變、沒有尾礦", function()
		local pt, pcu, tt, tcu = Cu.float(10, 0.25, 0.25, 0.85, 0.001)
		assert.are.equal(10, pt); assert.are.equal(0, tt); assert.are.equal(0, tcu)
		assert.is_true(math.abs(pcu - 2.5) < 1e-9)
	end)
	it("尾礦重選：精礦幾乎沒有、幾乎全是尾礦", function()
		local pt, _, tt = Cu.float(100, 0.0024, 0.25, 0.85, 0.001)
		assert.is_true(pt < 1 and tt > 99)
	end)
	it("精礦品位高比較值錢（冶煉費按每噸精礦）", function()
		local v25 = Cu.conc_value(1, 0.25, 10500, M.tc)
		local v30 = Cu.conc_value(1, 0.30, 10500, M.tc)
		assert.is_true(v30 / 0.30 > v25 / 0.25)
	end)
	it("截止品位約 0.2–0.4% Cu", function()
		local c = Cu.cutoff(M, 10500, 0.85, 20)
		assert.is_true(c > 0.002 and c < 0.004)
		local v, tail = Cu.toll(1, c, M, 10500, 0.85, 20)
		assert.is_true(math.abs(v - tail * 20) < 1e-3)
	end)
end)

describe("同一族金屬碎石混合（按含銅量合併）", function()
	local R, ORE, CONC, TAIL = "rubble", "ore:copper", "ore:cu_conc", "ore:cu_tail"
	local fam = {[ORE] = {family = "copper", scale = 0.051, waste = R}, [CONC] = {family = "copper", scale = 0.51, waste = R},
		[TAIL] = {family = "copper", scale = 0.0102, waste = R}}
	local ctx = {
		mix_of = {rubble_copper = {a = ORE, b = R, ore = {}}, rubble_cu_conc = {a = CONC, b = R, ore = {}}, rubble_cu_tail = {a = TAIL, b = R, ore = {}}},
		pair = {[ORE] = {[R] = "rubble_copper"}, [CONC] = {[R] = "rubble_cu_conc"}, [TAIL] = {[R] = "rubble_cu_tail"}},
		rank = {[R] = 2, [ORE] = 3, [CONC] = 3, [TAIL] = 3},
		ore_rubble = {[ORE] = "rubble_copper", [CONC] = "rubble_cu_conc", [TAIL] = "rubble_cu_tail"},
		merge_family = function(parts) return Cu.merge_family(parts, fam) end,
	}
	local function cu_of(base, k, p2)
		local sc = base == "rubble_copper" and 0.051 or base == "rubble_cu_conc" and 0.51 or 0.0102
		return k * p2 / 255 * sc
	end
	it("精礦 + 原礦：銅不會消失", function()
		local p_conc = math.floor(0.25 / 0.51 * 255 + 0.5)        -- 25% 精礦
		local p_ore = math.floor(0.01 / 0.051 * 255 + 0.5)        -- 1% 原礦
		local b, p = mix.merge(ctx, "rubble_cu_conc", 4, p_conc, "rubble_copper", 4, p_ore)
		assert.are.equal("rubble_cu_conc", b)
		local before = cu_of("rubble_cu_conc", 4, p_conc) + cu_of("rubble_copper", 4, p_ore)
		assert.is_true(math.abs(cu_of(b, 8, p) - before) / before < 0.02)
	end)
	it("原礦 + 尾礦：還是原礦、含銅量按體積平均", function()
		local p_ore = math.floor(0.01 / 0.051 * 255 + 0.5)
		local p_tail = math.floor(0.002 / 0.0102 * 255 + 0.5)
		local b, p = mix.merge(ctx, "rubble_copper", 4, p_ore, "rubble_cu_tail", 4, p_tail)
		assert.are.equal("rubble_copper", b)
		local c = p / 255 * 0.051
		assert.is_true(math.abs(c - 0.006) < 0.0005)
	end)
	it("原礦混廢石：照體積稀釋", function()
		local p_ore = math.floor(0.02 / 0.051 * 255 + 0.5)
		local b, p = mix.merge(ctx, "rubble_copper", 4, p_ore, R, 4, 0)
		assert.are.equal("rubble_copper", b)
		assert.is_true(math.abs(p / 255 * 0.051 - 0.01) < 0.0005)
	end)
end)
