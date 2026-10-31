dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local blast = load_module("blast")

describe("blast 爆破破碎範圍", function()
	it("強度縮放：砂岩 1 倍、頁岩較大、花崗岩較小", function()
		assert.near(1, blast.factor(60, 60), 1e-12)
		assert.near(2 ^ (1 / 3), blast.factor(30, 60, 1 / 3), 1e-12)   -- 頁岩 1.26
		assert.near((1 / 3) ^ (1 / 3), blast.factor(180, 60, 1 / 3), 1e-12) -- 花崗岩 0.69
		assert.near((1 / 3) ^ (1 / 6), blast.factor(180, 60), 1e-12)   -- 預設：花崗岩 0.83
	end)

	it("相鄰 TNT 一起引爆時半徑變大（同原版）", function()
		assert.are.equal(3, blast.effective_radius(3, 1))
		assert.are.equal(3, blast.effective_radius(3, 2)) -- ⌊3·1.26⌋
		assert.are.equal(6, blast.effective_radius(3, 8))
	end)

	it("分區：中心炸飛、外圍碎石、更外不受影響", function()
		-- 砂岩、R=3：r_out = 3、炸飛 ≤ 1.5
		assert.are.equal("eject", blast.zone(1, 3, 60, 60, 0.5))
		assert.are.equal("rubble", blast.zone(2.5, 3, 60, 60, 0.5))
		assert.is_nil(blast.zone(3.2, 3, 60, 60, 0.5))
		-- 同距離 3.2：頁岩（r_out 3.78）仍會破碎，花崗岩（2.08）在 2.5 就不受影響
		assert.are.equal("rubble", blast.zone(3.2, 3, 30, 60, 0.5, 1 / 3))
		assert.is_nil(blast.zone(2.5, 3, 180, 60, 0.5, 1 / 3))
	end)
end)
