dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local config = load_module("config")

local function getter(t)
	return function(k) return t[k] end
end

describe("config 區帶順序與第 4 組以後的節理", function()
	it("rockmech_zone_order 只有花崗岩；第 4、5 組新增", function()
		local set = {
			rockmech_zone_order = "granite",
			rockmech_joint_set_4 = "80,225,6,0.8,30",
			rockmech_joint_set_5 = "40,200,8,0.6,30",
		}
		local cfg, w = config.load(function(k) return set[k] end)
		assert.are.equal(0, #w)
		assert.are.equal(1, #cfg.zone_order)
		assert.are.equal("granite", cfg.zone_order[1])
		assert.are.equal(5, #cfg.joint_sets)
		assert.are.equal(225, cfg.joint_sets[4].dipdir)
		assert.are.equal("J5", cfg.joint_sets[5].name)
	end)
	it("不存在的岩性給警告", function()
		local _, w = config.load(function(k) return k == "rockmech_zone_order" and "basalt" or nil end)
		assert.are.equal(1, #w)
	end)
end)

describe("config.load", function()
	it("無設定時使用預設值", function()
		local cfg, warn = config.load(getter({}))
		assert.are.equal(0, cfg.surface_y)
		assert.are.equal(0.5, cfg.k0)
		assert.is_true(cfg.replace_stone)
		assert.are.equal(4, #cfg.lithology_order)
		assert.are.equal(3, #cfg.joint_sets)
		assert.are.equal(0, #warn)
	end)

	it("設定覆寫 y0、K0、replace_stone", function()
		local cfg = config.load(getter({
			rockmech_surface_y = "25", rockmech_k0 = "1.2", rockmech_replace_stone = "false",
		}))
		assert.are.equal(25, cfg.surface_y)
		assert.are.equal(1.2, cfg.k0)
		assert.is_false(cfg.replace_stone)
	end)

	it("節理組字串覆寫", function()
		local cfg = config.load(getter({rockmech_joint_set_2 = " 45, 270, 2.5, 0.6, 28 "}))
		local js = cfg.joint_sets[2]
		assert.are.equal(45, js.dip)
		assert.are.equal(270, js.dipdir)
		assert.are.equal(2.5, js.spacing)
		assert.are.equal(0.6, js.persistence)
		assert.are.equal(28, js.phi)
		assert.are.equal(2, js.id) -- id 保留
	end)

	it("錯誤的節理字串被忽略並發出警告", function()
		local cfg, warn = config.load(getter({rockmech_joint_set_1 = "10,abc,3,0.5,30"}))
		assert.are.equal(config.joint_sets[1].dipdir, cfg.joint_sets[1].dipdir)
		assert.are.equal(1, #warn)
		local _, warn2 = config.load(getter({rockmech_joint_set_1 = "10,20,3"}))
		assert.are.equal(1, #warn2)
	end)

	it("夾限不合理的值", function()
		local cfg, warn = config.load(getter({rockmech_joint_set_1 = "95,-30,0.5,1.5,30"}))
		local js = cfg.joint_sets[1]
		assert.are.equal(90, js.dip)
		assert.are.equal(330, js.dipdir)
		assert.are.equal(1, js.spacing)
		assert.are.equal(1, js.persistence)
		assert.are.equal(3, #warn)
	end)

	it("碎石安息角：預設 35°，可設定並夾限", function()
		assert.are.equal(35, config.load(getter({})).slope.angle)
		assert.are.equal(38, config.load(getter({rockmech_slope_angle = "38"})).slope.angle)
		assert.are.equal(89, config.load(getter({rockmech_slope_angle = "120"})).slope.angle)
		assert.is_false(config.load(getter({rockmech_slope_enabled = "false"})).slope.enabled)
	end)

	it("不修改原始表", function()
		local before = config.joint_sets[1].dip
		local cfg = config.load(getter({rockmech_joint_set_1 = "33,20,3,0.5,30"}))
		assert.are.equal(33, cfg.joint_sets[1].dip)
		assert.are.equal(before, config.joint_sets[1].dip)
	end)

	it("岩性欄位完整", function()
		for _, key in ipairs(config.lithology_order) do
			local l = config.lithologies[key]
			assert.is_not_nil(l, key)
			assert.truthy(l.gamma > 0 and l.ucs > 0 and l.tensile > 0, key)
			assert.truthy(type(l.color) == "string", key)
		end
	end)
end)

describe("經營模式", function()
	it("預設關閉；鎬子免費、推車便宜，價格可用設定覆寫，推車比人多載", function()
		local cfg = config.load(getter({}))
		assert.is_true(not cfg.career)
		assert.is_true(cfg.cart_blocks > 1)
		local price = {}
		for _, it in ipairs(cfg.shop) do price[it.key] = it.price end
		assert.are.equal(0, price.pick)
		assert.is_true(price.cart < price.truck)
		local c2 = config.load(getter({rockmech_career = "true", rockmech_price_haul = "123"}))
		assert.is_true(c2.career)
		for _, it in ipairs(c2.shop) do if it.key == "haul" then assert.are.equal(123, it.price) end end
	end)
end)

describe("config.crush_income", function()
	it("收入 = 噸數 ×（品位 × 回收率 × 價格 − 處理費），廢石只付處理費，低於截止品位就賠錢", function()
		local coal = config.ores.coal
		assert.near(72 * (0.75 * 0.9 * 120 - 30), config.crush_income(72, 0.75, coal, 30), 1e-9)
		assert.near(-720, config.crush_income(24, 0, nil, 30), 1e-9)
		assert.is_true(config.crush_income(1, 0.2, coal, 30) < 0)
		assert.is_true(config.crush_income(1, 0.3, coal, 30) > 0)
	end)
end)

describe("config.is_soil", function()
	it("crumbly 天然地層為土壤；碎石、岩石、非天然方塊不是", function()
		assert.is_true(config.is_soil("default:dirt", {crumbly = 3, soil = 1}, true))
		assert.is_true(config.is_soil("default:sand", {crumbly = 3, falling_node = 1, sand = 1}, nil))
		assert.is_false(config.is_soil("rockmech:rubble", {crumbly = 2, cracky = 3, rockmech_rubble = 1}, true))
		assert.is_false(config.is_soil("rockmech:shale", {cracky = 3, stone = 1}, true))
		assert.is_false(config.is_soil("x:placed", {crumbly = 3}, false))
	end)
	it("rockmech_strip_soil 預設關閉、可由設定開啟", function()
		assert.is_false(config.load(function() return nil end).strip_soil)
		assert.is_true(config.load(function(k) return k == "rockmech_strip_soil" and "true" or nil end).strip_soil)
	end)
end)
