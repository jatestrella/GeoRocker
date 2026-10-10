dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local config = load_module("config")

local function getter(t)
	return function(k) return t[k] end
end

describe("config.load", function()
	it("無設定時使用預設值", function()
		local cfg, warn = config.load(getter({}))
		assert.are.equal(0, cfg.surface_y)
		assert.are.equal(0.5, cfg.k0)
		assert.is_true(cfg.replace_stone)
		assert.are.equal(3, #cfg.lithology_order)
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
