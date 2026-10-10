dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local rf = load_module("rockfall")

local function v(x, y, z) return {x = x, y = y, z = z} end

describe("rockfall 坡面法向", function()
	it("平地法向朝上", function()
		local n = rf.surface_normal(5, 5, 5, 5, 5)
		assert.near(0, n.x, 1e-12); assert.near(1, n.y, 1e-12); assert.near(0, n.z, 1e-12)
	end)

	it("往 +x 升高的 45° 坡，法向指向 -x 上方", function()
		local n = rf.surface_normal(0, -1, 1, 0, 0)
		local h = math.sqrt(0.5)
		assert.near(-h, n.x, 1e-12); assert.near(h, n.y, 1e-12); assert.near(0, n.z, 1e-12)
		assert.near(math.rad(45), rf.slope_angle(n), 1e-12)
	end)

	it("缺值以中心高度代替", function()
		local n = rf.surface_normal(0, nil, 2, nil, nil)
		-- hx = (2 - 0)/2 = 1
		local h = math.sqrt(0.5)
		assert.near(-h, n.x, 1e-12); assert.near(h, n.y, 1e-12)
	end)
end)

describe("rockfall 撞擊", function()
	it("垂直落在平地：vn' = -Rn·vn", function()
		local out, vn = rf.impact(v(0, -10, 0), v(0, 1, 0), 0.4, 0.8)
		assert.near(10, vn, 1e-12)
		assert.near(4, out.y, 1e-12)
		assert.near(0, out.x, 1e-12)
	end)

	it("斜向撞擊：切向乘 Rt、法向反彈乘 Rn", function()
		local out, vn, vt = rf.impact(v(6, -8, 0), v(0, 1, 0), 0.5, 0.9)
		assert.near(8, vn, 1e-12)
		assert.near(5.4, out.x, 1e-12)
		assert.near(4, out.y, 1e-12)
		assert.near(5.4, vt.x, 1e-12)
		assert.near(10.8, rf.roll_rate(vt, 0.5), 1e-12)
	end)

	it("落在 45° 坡上：反彈方向偏向下坡", function()
		local h = math.sqrt(0.5)
		local out = rf.impact(v(0, -10, 0), v(-h, h, 0), 0.4, 0.8)
		assert.truthy(out.x < 0, "應往 -x（下坡）")
		-- 法向分量 = Rn·|vn|
		assert.near(0.4 * 10 * h, rf.dot(out, v(-h, h, 0)), 1e-9)
	end)

	it("能量不增加（Rn, Rt ≤ 1）", function()
		local n = rf.normalize(v(0.3, 1, -0.2))
		local vin = v(3, -7, 2)
		local out = rf.impact(vin, n, 1, 1)
		assert.near(rf.len(vin), rf.len(out), 1e-9)
		out = rf.impact(vin, n, 0.4, 0.8)
		assert.truthy(rf.len(out) < rf.len(vin))
	end)
end)

describe("rockfall 貼地滾動", function()
	local h = math.sqrt(0.5)
	local n45 = v(-h, h, 0) -- 往 +x 升高，下坡為 -x

	it("平地上只有阻力、方向與速度相反", function()
		local a = rf.contact_accel(v(2, 0, 0), v(0, 1, 0), 0.5, 10)
		assert.near(-5, a.x, 1e-12); assert.near(0, a.z, 1e-12)
	end)

	it("平地靜止：不動", function()
		local a = rf.contact_accel(v(0, 0, 0), v(0, 1, 0), 0.5, 10)
		assert.near(0, rf.len(a), 1e-12)
	end)

	it("45° 坡靜止：μ < tan45 會往下坡加速，μ ≥ tan45 不動", function()
		local a = rf.contact_accel(v(0, 0, 0), n45, 0.5, 10)
		assert.truthy(a.x < 0, "應往 -x 下坡")
		a = rf.contact_accel(v(0, 0, 0), n45, 1.0, 10)
		assert.near(0, rf.len(a), 1e-9)
	end)

	it("45° 坡無阻力：水平加速度 = g·sinθ·cosθ", function()
		local a = rf.contact_accel(v(0, 0, 0), n45, 0, 10)
		assert.near(-5, a.x, 1e-9)
		assert.near(0, a.y, 1e-12)
	end)

	it("往上坡滾時減速比平地快", function()
		local up = rf.contact_accel(v(1, 0, 0), n45, 0.3, 10)
		local flat = rf.contact_accel(v(1, 0, 0), v(0, 1, 0), 0.3, 10)
		assert.truthy(up.x < flat.x)
	end)
end)

-- 複製自 Luanti 5.15.1 builtin/common/vector.lua 的 vector.rotate
-- （文件註明與 ObjectRef:set_rotation 一致），用來檢查外觀旋轉方向。
local function engine_rotate(p, rot)
	local sp, sy, sr = math.sin(-rot.x), math.sin(-rot.y), math.sin(-rot.z)
	local cp, cy, cr = math.cos(rot.x), math.cos(rot.y), math.cos(rot.z)
	local m = {
		{sy * sp * sr + cy * cr, sy * sp * cr - cy * sr, sy * cp},
		{cp * sr, cp * cr, -sp},
		{cy * sp * sr - sy * cr, cy * sp * cr + sy * sr, cy * cp},
	}
	return {
		x = m[1][1] * p.x + m[1][2] * p.y + m[1][3] * p.z,
		y = m[2][1] * p.x + m[2][2] * p.y + m[2][3] * p.z,
		z = m[3][1] * p.x + m[3][2] * p.y + m[3][3] * p.z,
	}
end

describe("rockfall 外觀", function()
	it("向前滾：頂部往速度方向倒（各方向）", function()
		for _, vel in ipairs({v(0, 0, 1), v(0, 0, -1), v(1, 0, 0), v(-1, 0, 0), v(1, 0, 1)}) do
			local yaw = rf.heading_yaw(vel)
			-- 未滾動時，本地前方 (0,0,1) 應指向速度方向
			local fw = engine_rotate(v(0, 0, 1), rf.roll_rotation(0, yaw))
			local dir = rf.normalize(vel)
			assert.near(1, rf.dot(fw, dir), 1e-9)
			-- 滾動一小角度後，頂部 (0,1,0) 應往速度方向移動
			local top = engine_rotate(v(0, 1, 0), rf.roll_rotation(0.3, yaw))
			assert.truthy(rf.dot(top, dir) > 0.25,
				("速度 (%g,%g,%g) 時頂部往後倒"):format(vel.x, vel.y, vel.z))
		end
	end)

	it("heading_yaw：+z 為 0、-x 為 +90°", function()
		assert.near(0, rf.heading_yaw(v(0, 0, 1)), 1e-12)
		assert.near(math.pi / 2, rf.heading_yaw(v(-1, 0, 0)), 1e-12)
		assert.is_nil(rf.heading_yaw(v(0, -3, 0)))
	end)
end)

describe("rockfall 掉落破碎機率", function()
	it("h ≤ 0.5 不破碎", function()
		assert.are.equal(0, rf.break_probability(0, 4))
		assert.are.equal(0, rf.break_probability(0.5, 4))
	end)
	it("p = 1 − exp(−h/h_ref)，隨高度遞增、越硬越低", function()
		assert.near(1 - math.exp(-1), rf.break_probability(4, 4), 1e-12)
		assert.truthy(rf.break_probability(10, 4) > rf.break_probability(2, 4))
		assert.truthy(rf.break_probability(5, 8) < rf.break_probability(5, 2.5))
		assert.truthy(rf.break_probability(1000, 4) <= 1)
	end)
end)
