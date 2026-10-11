dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local stress = load_module("stress")
local failure = load_module("failure", stress)

local AIR, ROCK = 0, 1
local GAMMA = 25

-- 建立 x∈[x0,x1], y∈[y0,y1], z∈[z0,z1] 的網格；fn(x,y,z) 回傳 true = 岩石
local function make_grid(x0, x1, y0, y1, z0, z1, fn)
	local g = {
		ox = x0, oy = y0, oz = z0,
		nx = x1 - x0 + 1, ny = y1 - y0 + 1, nz = z1 - z0 + 1,
		data = {},
		solid_of = {[ROCK] = true},
		weight_of = {[ROCK] = GAMMA},
		lith_of = {[ROCK] = "rock"},
	}
	for z = z0, z1 do for y = y0, y1 do for x = x0, x1 do
		g.data[failure.index(g, x, y, z)] = fn(x, y, z) and ROCK or AIR
	end end end
	return g
end

local function params(scale)
	return {
		surface_y = 0, k0 = 0.5, window = 4, strength_scale = scale or 1,
		lithologies = {rock = {gamma = GAMMA, ucs = 30}},
	}
end

-- 2D 剖面（沿 x），z 方向寬 9 格、地形一致
local function profile_grid(height_at, ybot, ytop)
	return make_grid(-20, 20, ybot, ytop, -4, 4, function(x, y)
		return y < height_at(x)
	end)
end

describe("failure 柱狀荷重", function()
	it("完整岩體（網格頂端仍為岩石）σ = γh", function()
		local g = make_grid(-5, 5, -20, -1, -5, 5, function() return true end)
		local st = failure.cell_state(g, 0, -8, 0, params())
		assert.near(GAMMA * 8 / 1000, st.sv0, 1e-12)
		assert.near(GAMMA * 8 / 1000, st.sv, 1e-12)
		assert.is_false(st.exposed)
	end)

	it("平地：累積到地表空氣為止，與 γh 一致", function()
		local g = make_grid(-5, 5, -20, 10, -5, 5, function(_, y) return y < 0 end)
		local st = failure.cell_state(g, 0, -8, 0, params())
		assert.near(GAMMA * 8 / 1000, st.sv0, 1e-12)
		assert.near(1, st.factor, 1e-12)
	end)

	it("開口頂板荷重 R 轉給兩側（礦柱集中）", function()
		-- 地下 y=-20..-18 開挖成房間，只留 x=0 的礦柱（z 向全寬）
		local g = make_grid(-6, 6, -30, -1, -6, 6, function(x, y)
			if y >= -20 and y <= -18 and x ~= 0 then return false end
			return true
		end)
		local st = failure.cell_state(g, 0, -19, 0, params())
		-- 窗格 9×9：礦柱 9 格（自身柱 19 m）+ 72 個開口格（頂板厚 17 m）
		-- σy = γ(9·19 + 72·17)/9 → 集中係數 = 155/19
		assert.near(GAMMA * (9 * 19 + 72 * 17) / 9 / 1000, st.sv, 1e-9)
		assert.near(155 / 19, st.factor, 1e-9)
		assert.is_true(st.exposed_x)
		assert.near(0, st.sx, 1e-12)
	end)

	it("頂板格（下方臨空）σy = 0", function()
		local g = make_grid(-6, 6, -30, -1, -6, 6, function(_, y) return not (y >= -20 and y <= -18) end)
		local st = failure.cell_state(g, 0, -17, 0, params())
		assert.is_true(st.exposed_down)
		assert.are.equal(0, st.sy)
	end)
end)

describe("failure 邊坡：越陡越容易破壞", function()
	-- 坡腳在 x=0，左側高、右側低；地表 y<0 以下為岩石
	local function slope(H, drop_per_col)
		return function(x)
			if x >= 0 then return -H end                 -- 坡腳前的平台
			return math.min(0, -H + drop_per_col * (-x)) -- 往左升高到坡頂 y=0
		end
	end

	local function toe_state(H, d, scale)
		local g = profile_grid(slope(H, d), -H - 10, 10)
		-- 坡腳臨空格：x=-1、平台面上方一格
		return failure.cell_state(g, -1, -H, 0, params(scale))
	end

	it("直立坡：坡腳 σy ≈ γH", function()
		local st = toe_state(12, 100, 1)
		assert.is_true(st.exposed_x)
		assert.near(GAMMA * 12 / 1000, st.sv, 1e-9)
		assert.near(st.sv, st.q, 1e-12)
	end)

	it("同高度下，越陡 q 越大", function()
		local q = {}
		for _, d in ipairs({1, 2, 3, 6, 100}) do
			q[#q + 1] = toe_state(12, d, 1).q
		end
		for i = 2, #q do
			assert.truthy(q[i] >= q[i - 1], ("q 未隨坡度遞增: %s"):format(table.concat(q, ", ")))
		end
		assert.truthy(q[#q] > 2 * q[1])
	end)

	it("直立坡越高 q 越大", function()
		assert.truthy(toe_state(20, 100, 1).q > toe_state(8, 100, 1).q)
	end)

	it("強度門檻：直立坡超過臨界高度才破壞", function()
		-- 強度 = 30 × 0.01 = 0.3 MPa → 臨界高度 0.3 / 0.025 = 12 m
		assert.is_false(toe_state(10, 100, 0.01).fails)
		assert.is_true(toe_state(14, 100, 0.01).fails)
		-- 45° 緩坡同樣 14 m 高不破壞
		assert.is_false(toe_state(14, 1, 0.01).fails)
	end)

	it("evaluate 回傳破壞格由上往下排序", function()
		local g = profile_grid(slope(20, 100), -30, 10)
		local failed, stats = failure.evaluate(g, params(0.01), -1, -15, 0, 8)
		assert.truthy(stats.failed > 0)
		assert.truthy(stats.evaluated >= stats.failed)
		for i = 2, #failed do
			assert.truthy(failed[i - 1].y >= failed[i].y)
		end
	end)
end)

describe("failure 水平主應力與集中", function()
	local function hp(KH, Kh, az, scale)
		local p = params(scale)
		p.KH, p.Kh, p.sH_azimuth = KH, Kh, az
		return p
	end

	it("完整岩體：σxx、σzz 依方位等於 K_H·σv、K_h·σv", function()
		local g = make_grid(-6, 6, -30, -1, -6, 6, function() return true end)
		local st = failure.cell_state(g, 0, -15, 0, hp(2, 1, 90))
		assert.near(2 * st.sv0, st.sx, 1e-9)
		assert.near(1 * st.sv0, st.sz, 1e-9)
		st = failure.cell_state(g, 0, -15, 0, hp(2, 1, 0))
		assert.near(1 * st.sv0, st.sx, 1e-9)
		assert.near(2 * st.sv0, st.sz, 1e-9)
	end)

	-- 沿 z 方向的隧道（3×3 斷面），頂板格 (0, -17, 0)
	local function tunnel()
		return make_grid(-8, 8, -40, -1, -8, 8, function(x, y)
			return not (math.abs(x) <= 1 and y >= -20 and y <= -18)
		end)
	end

	it("隧道頂板：σxx 受開口截斷而集中，σzz 幾乎不變", function()
		local st = failure.cell_state(tunnel(), 0, -17, 0, hp(1, 1, 0))
		assert.is_true(st.exposed_down)
		assert.truthy(st.fx > 1.2, "fx = " .. st.fx)
		assert.truthy(st.fx > st.fz, ("fx %.2f fz %.2f"):format(st.fx, st.fz))
		assert.are.equal(0, st.sy)
	end)

	it("σH 垂直隧道軸（東西向）時頂板比平行時危險", function()
		local across = failure.cell_state(tunnel(), 0, -17, 0, hp(2, 0.5, 90))
		local along = failure.cell_state(tunnel(), 0, -17, 0, hp(2, 0.5, 0))
		assert.truthy(across.q > along.q, ("%.3f vs %.3f"):format(across.q, along.q))
	end)

	it("側壁：法向（x）正應力與剪應力為 0", function()
		local st = failure.cell_state(tunnel(), 2, -19, 0, hp(2, 0.5, 45))
		assert.is_true(st.exposed_x)
		assert.are.equal(0, st.sx)
		assert.are.equal(0, st.sxz)
	end)

	it("地表附近的露天空氣不會被當成開口（不集中）", function()
		local g = make_grid(-6, 6, -20, 10, -6, 6, function(_, y) return y < 0 end)
		local st = failure.cell_state(g, 0, -2, 0, hp(1, 1, 0))
		assert.truthy(st.fx < 1.01 and st.fz < 1.01, ("fx %.3f fz %.3f"):format(st.fx, st.fz))
	end)
end)

describe("failure 節理弱面（Jaeger）", function()
	local function nvec(dip, dipdir)
		local d, a = math.rad(dip), math.rad(dipdir)
		return {x = math.sin(a) * math.sin(d), y = math.cos(d), z = math.cos(a) * math.sin(d)}
	end

	it("單軸垂直應力：σn = σv·cos²ψ、τ = σv·sinψ·cosψ", function()
		local n = nvec(60, 90)
		local sn, tau = failure.plane_stress(0, 1, 0, 0, n)
		assert.near(math.cos(math.rad(60)) ^ 2, sn, 1e-12)
		assert.near(math.sin(math.rad(60)) * math.cos(math.rad(60)), tau, 1e-12)
	end)

	it("等向應力：τ = 0，FS = ∞", function()
		local sn, tau = failure.plane_stress(2, 2, 2, 0, nvec(45, 30))
		assert.near(2, sn, 1e-12)
		assert.near(0, tau, 1e-9)
		assert.are.equal(math.huge, failure.plane_fs(sn, tau, 0, 0.5))
	end)

	it("cj = 0 時：傾角 > φj 才滑（tanψ 與 tanφ 比較）", function()
		local tanphi = math.tan(math.rad(30))
		local sn, tau = failure.plane_stress(0, 1, 0, 0, nvec(35, 0))
		assert.is_true(failure.plane_fs(sn, tau, 0, tanphi) < 1)
		sn, tau = failure.plane_stress(0, 1, 0, 0, nvec(25, 0))
		assert.is_true(failure.plane_fs(sn, tau, 0, tanphi) > 1)
		-- FS = tanφ / tanψ
		sn, tau = failure.plane_stress(0, 1, 0, 0, nvec(50, 0))
		assert.near(tanphi / math.tan(math.rad(50)), failure.plane_fs(sn, tau, 0, tanphi), 1e-12)
	end)

	it("剪應力 σxz 也計入", function()
		local n = {x = math.sqrt(0.5), y = 0, z = math.sqrt(0.5)}
		local sn, tau = failure.plane_stress(1, 0, 1, 0.5, n)
		assert.near(1.5, sn, 1e-12)
		assert.near(0, tau, 1e-12)
	end)

	it("運動學：傾向臨空面才能滑出；下方臨空任何方向都可", function()
		local east = nvec(60, 90)   -- 傾向東 → 向上法向指向 +x
		assert.is_true(failure.daylights(east, true, false, false, false, false))
		assert.is_false(failure.daylights(east, false, true, false, false, false))
		assert.is_false(failure.daylights(east, false, false, true, true, false))
		assert.is_true(failure.daylights(east, false, false, false, false, true))
		assert.is_false(failure.daylights(nvec(0, 0), true, true, true, true, false))
	end)

	-- 東側是 8 m 高的直立坡面（x ≥ 1 為空氣），坡頂 y = 0
	local function cliff()
		return make_grid(-12, 6, -20, 6, -4, 4, function(x, y) return x <= 0 and y < 0 end)
	end
	local function wparams(js_list, c, phi)
		local p = params()
		p.weakness = {c = c, tanphi = math.tan(math.rad(phi)), daylight = true}
		p.joint_sets = js_list
		p.detail = true
		p.joints_at = function(_, _, _, sets) return sets end
		return p
	end

	it("坡面格：傾向坡外的陡節理滑動，傾向坡內的不滑", function()
		local g = cliff()
		local out = {name = "J", n_eff = nvec(60, 90)}
		local into = {name = "K", n_eff = nvec(60, 270)}
		local st = failure.cell_state(g, 0, -6, 0, wparams({out}, 0, 30))
		assert.is_true(st.fails_slip)
		assert.are.equal(out, st.slip_set)
		assert.is_true(st.fails)
		st = failure.cell_state(g, 0, -6, 0, wparams({into}, 0, 30))
		assert.is_false(st.fails_slip)
		assert.is_nil(st.slip_set)
	end)

	it("凝聚力足夠時不滑；完整岩塊（無節理）不做弱面判定", function()
		local g = cliff()
		local out = {name = "J", n_eff = nvec(60, 90)}
		local st = failure.cell_state(g, 0, -6, 0, wparams({out}, 10, 30))
		assert.is_false(st.fails_slip)
		assert.is_true(st.fs_joint > 1)
		st = failure.cell_state(g, 0, -6, 0, wparams({}, 0, 30))
		assert.are.equal(0, st.n_joints)
		assert.are.equal(math.huge, st.fs_joint)
		assert.is_false(st.fails)
	end)

	it("未臨空的格子不會沿節理滑", function()
		local g = cliff()
		local st = failure.cell_state(g, -5, -6, 0, wparams({{name = "J", n_eff = nvec(60, 90)}}, 0, 30))
		assert.is_false(st.exposed)
		assert.is_false(st.fails_slip)
	end)

	it("axial = false：只做弱面判定", function()
		local g = cliff()
		local p = wparams({}, 0, 30)
		p.axial = false
		p.strength_scale = 1e-6
		local st = failure.cell_state(g, 0, -6, 0, p)
		assert.is_false(st.fails_axial)
		assert.is_false(st.fails)
	end)
end)

describe("failure 節理弱面前置篩選", function()
	it("篩選與不篩選的結果相同（坡面各高度、各方位節理）", function()
		local g = make_grid(-12, 6, -20, 6, -4, 4, function(x, y) return x <= 0 and y < 0 end)
		local sets = {}
		for _, dd in ipairs({0, 90, 180, 270, 45}) do
			for _, dip in ipairs({40, 60, 80}) do
				local d, a = math.rad(dip), math.rad(dd)
				sets[#sets + 1] = {name = dip .. "/" .. dd,
					n_eff = {x = math.sin(a) * math.sin(d), y = math.cos(d), z = math.cos(a) * math.sin(d)}}
			end
		end
		for _, c in ipairs({0, 0.05, 0.2}) do
			local base = params()
			base.weakness = {c = c, tanphi = math.tan(math.rad(30)), daylight = true}
			base.joint_sets = sets
			base.joints_at = function(_, _, _, s) return s end
			for y = -19, -1 do
				local a = failure.cell_state(g, 0, y, 0, base)
				base.detail = true
				local b = failure.cell_state(g, 0, y, 0, base)
				base.detail = nil
				assert.are.equal(b.fails_slip, a.fails_slip)
				if a.fails_slip then assert.near(b.fs_joint, a.fs_joint, 1e-12) end
			end
		end
	end)
end)

describe("failure 範圍內最小 FS", function()
	it("找到坡面上最小的節理 FS 與軸差 FS", function()
		local g = make_grid(-12, 6, -20, 6, -4, 4, function(x, y) return x <= 0 and y < 0 end)
		local d, a = math.rad(60), math.rad(90)
		local js = {name = "J", n_eff = {x = math.sin(a) * math.sin(d), y = math.cos(d), z = math.cos(a) * math.sin(d)}}
		local p = params()
		p.weakness = {c = 0, tanphi = math.tan(math.rad(30)), daylight = true}
		p.joint_sets = {js}
		p.detail = true
		p.joints_at = function(_, _, _, s) return s end
		local box = {{x = -3, y = -10, z = -2}, {x = 0, y = -1, z = 2}}
		local m = failure.min_fs_in_box(g, p, box)
		assert.is_true(m.exposed > 0)
		assert.are.equal(js, m.joint.set)
		assert.are.equal(0, m.joint.x)
		-- 逐格確認是最小值
		for z = -2, 2 do for y = -10, -1 do
			local st = failure.cell_state(g, 0, y, z, p)
			assert.is_true(st.fs_joint >= m.joint.fs - 1e-12)
			assert.is_true(st.fs_axial >= m.axial.fs - 1e-12)
		end end
		assert.near(math.tan(math.rad(30)) / math.tan(math.rad(60)), m.joint.fs, 1e-9)
	end)
end)
