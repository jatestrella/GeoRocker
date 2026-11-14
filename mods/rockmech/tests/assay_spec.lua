dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
-- assay.lua 的純計算部分（合併、體積表、累加器、文字格式）。引擎的部分用假的 core
local mix = load_module("mix")

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

local saved_rm, saved_core = rockmech, core
rockmech = {mix = mix, mix_ctx = ctx, mix_of = ctx.mix_of, rubble_base = {}, lith_of_node = {}}
core = {register_chatcommand = function() end}
local A = load_module("assay")


local function vsum(c)
	local s = 0
	for k, v in pairs(c) do if A.is_v(k) then s = s + v end end
	return s
end

describe("assay 成分", function()
	it("兩種成分：跟原本的混合規則完全一樣，不記體積表", function()
		for _, case in ipairs({{"rubble_coal", 8, 200, R, 3, 0}, {"rubble_coal", 5, 40, "rubble_coal", 3, 120},
				{"colluvium", 4, 128, R, 4, 0}, {R, 8, 0, R, 2, 0}}) do
			local b0, p0 = mix.merge(ctx, (table.unpack or unpack)(case))
			local b, c = A.merge(case[1], case[2], case[3], case[4], case[5], case[6])
			assert.are.equal(b0, b)
			assert.are.equal(p0, c.g)
			assert.is_false(A.has_v(c))
		end
	end)

	it("三種成分：記下完整的體積表，總和 1，方塊照最大的兩種", function()
		-- 煤 50%＋碎石 50%（8 級），加 4 級花崗岩碎石
		local b, c = A.merge("rubble_coal", 8, 128, G, 4, 0)
		assert.is_true(A.has_v(c))
		assert.near(1, vsum(c), 1e-9)
		assert.near(4 / 12, c["v:" .. G], 1e-9)
		assert.near(8 * 128 / 255 / 12, c["v:" .. COAL], 1e-9)
		local b0, p0 = mix.compose(ctx, A.vol(nil, c, 1, {}))
		assert.are.equal(b0, b)
		assert.are.equal(p0, c.g)
	end)

	it("帶體積表的再混一般碎石：其他成分照比例稀釋，不會被併掉", function()
		local _, c = A.merge("rubble_coal", 8, 128, G, 4, 0)
		local coal = c["v:" .. COAL] * 12
		local _, c2 = A.merge("rubble_coal", 12, c, R, 6, 0)
		assert.near(coal / 18, c2["v:" .. COAL], 1e-9)
		assert.near(4 / 18, c2["v:" .. G], 1e-9)
		assert.near(1, vsum(c2), 1e-9)
	end)

	it("文字格式：體積表的鍵（含冒號）存得回來", function()
		local _, c = A.merge("rubble_coal", 8, 128, G, 4, 0)
		local d = A.decode(A.encode(c))
		assert.are.equal(c.g, d.g)
		assert.near(c["v:" .. COAL], d["v:" .. COAL], 1e-6)
		assert.near(c["v:" .. G], d["v:" .. G], 1e-6)
	end)

	it("累加器：沒有體積表的先放、帶體積表的後放，平均照體積加權", function()
		local base = "rubble_coal"
		local acc, lv, q = nil, 0, 0
		acc = A.acc_put(acc, base, lv, q, 200, 6); lv, q = lv + 6, q + 6 * 200
		assert.is_nil(acc)                                   -- 只有兩種成分：不用累加器
		local _, c = A.merge("rubble_coal", 8, 128, G, 4, 0)
		acc = A.acc_put(acc, base, lv, q, c, 12)
		local coal = 6 * 200 / 255 + 12 * c["v:" .. COAL]
		assert.near(coal, acc["v:" .. COAL], 1e-9)
		assert.near(4, acc["v:" .. G], 1e-9)
		assert.near(18, vsum(acc), 1e-9)
	end)

	it("slim：只剩兩種成分就拿掉體積表", function()
		local c = A.slim({g = 100, ["v:" .. COAL] = 0.4, ["v:" .. R] = 0.6})
		assert.is_false(A.has_v(c))
		c = A.slim({g = 100, ["v:" .. COAL] = 0.4, ["v:" .. R] = 0.5, ["v:" .. G] = 0.1})
		assert.is_true(A.has_v(c))
	end)
end)

rockmech, core = saved_rm, saved_core
