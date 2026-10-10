dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local joints = load_module("joints")

local EPS = 1e-12
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function len(a) return math.sqrt(dot(a, a)) end

local function one_set(t, seed)
	t.id = t.id or 1
	t.name = t.name or "T"
	t.phi = t.phi or 30
	return joints.prepare({t}, seed or 12345)
end

describe("joints 向量（Luanti: x=E, y=Up, z=N）", function()
	it("水平面法向朝上", function()
		local n = joints.normal(0, 123)
		assert.near(0, n.x, EPS); assert.near(1, n.y, EPS); assert.near(0, n.z, EPS)
	end)

	it("向東傾的直立面法向 = +x", function()
		local n = joints.normal(90, 90)
		assert.near(1, n.x, EPS); assert.near(0, n.y, EPS); assert.near(0, n.z, 1e-9)
	end)

	it("向北傾的直立面法向 = +z", function()
		local n = joints.normal(90, 0)
		assert.near(0, n.x, EPS); assert.near(0, n.y, EPS); assert.near(1, n.z, EPS)
	end)

	it("45°/180°（向南傾）", function()
		local n = joints.normal(45, 180)
		local h = math.sqrt(0.5)
		assert.near(0, n.x, 1e-9); assert.near(h, n.y, EPS); assert.near(-h, n.z, EPS)
		local d = joints.dip_vector(45, 180)
		-- 順傾向往下：向南（-z）且向下（-y）
		assert.near(0, d.x, 1e-9); assert.near(-h, d.y, EPS); assert.near(-h, d.z, EPS)
	end)

	it("法向、傾向向量、走向互相垂直且為單位向量", function()
		for dip = 0, 90, 15 do
			for dd = 0, 345, 15 do
				local n = joints.normal(dip, dd)
				local d = joints.dip_vector(dip, dd)
				local s = joints.strike_vector(dd)
				assert.near(1, len(n), 1e-12)
				assert.near(1, len(d), 1e-12)
				assert.near(1, len(s), 1e-12)
				assert.near(0, dot(n, d), 1e-12)
				assert.near(0, dot(n, s), 1e-12)
				assert.near(0, dot(d, s), 1e-12)
				assert.truthy(n.y >= -1e-12, "法向朝上")
				assert.truthy(d.y <= 1e-12, "傾向向量朝下")
			end
		end
	end)

	it("走向 = 傾向 - 90°（右手法則）", function()
		local s = joints.strike_vector(90) -- 向東傾 → 走向朝北
		assert.near(0, s.x, 1e-12); assert.near(1, s.z, 1e-12)
		s = joints.strike_vector(180)      -- 向南傾 → 走向朝東
		assert.near(1, s.x, 1e-12); assert.near(0, s.z, 1e-12)
	end)
end)

describe("joints 雜湊", function()
	it("決定性且落在 [0,1)", function()
		for i = -50, 50 do
			local a = joints.hash01(7, 1, i, i * 3, -i, 2 * i, 1)
			local b = joints.hash01(7, 1, i, i * 3, -i, 2 * i, 1)
			assert.are.equal(a, b)
			assert.truthy(a >= 0 and a < 1)
		end
	end)

	it("任一參數改變結果就改變", function()
		local base = joints.hash01(7, 1, 3, 10, 20, 30, 2)
		assert.truthy(base ~= joints.hash01(8, 1, 3, 10, 20, 30, 2))
		assert.truthy(base ~= joints.hash01(7, 2, 3, 10, 20, 30, 2))
		assert.truthy(base ~= joints.hash01(7, 1, 4, 10, 20, 30, 2))
		assert.truthy(base ~= joints.hash01(7, 1, 3, 11, 20, 30, 2))
		assert.truthy(base ~= joints.hash01(7, 1, 3, 10, 20, 30, 3))
	end)

	it("分佈大致均勻、鄰面不相關", function()
		local N, below, sum = 0, 0, 0
		local sxy, sx, sy, sxx, syy = 0, 0, 0, 0, 0
		for x = -60, 59 do
			for z = -40, 39 do
				local a = joints.hash01(99, 2, 5, x, 7, z, 1)
				local b = joints.hash01(99, 2, 5, x + 1, 7, z, 1)
				N = N + 1
				sum = sum + a
				if a < 0.7 then below = below + 1 end
				sx, sy = sx + a, sy + b
				sxx, syy, sxy = sxx + a * a, syy + b * b, sxy + a * b
			end
		end
		assert.near(0.5, sum / N, 0.01, "平均")
		assert.near(0.7, below / N, 0.015, "P(r<0.7)")
		local cov = sxy / N - (sx / N) * (sy / N)
		local corr = cov / math.sqrt((sxx / N - (sx / N) ^ 2) * (syy / N - (sy / N) ^ 2))
		assert.truthy(math.abs(corr) < 0.03, "鄰面相關係數 " .. corr)
	end)

	it("種子字串雜湊", function()
		assert.are.equal(joints.seed_from_string("12345"), joints.seed_from_string("12345"))
		assert.truthy(joints.seed_from_string("1") ~= joints.seed_from_string("2"))
		-- 超過 2^53 的 64-bit 種子仍可區分
		assert.truthy(joints.seed_from_string("18446744073709551614")
			~= joints.seed_from_string("18446744073709551615"))
	end)
end)

describe("joints 節理面判定", function()
	it("水平組：只有 y 方向的面會被切，且每 S 格一次", function()
		local sets = one_set({dip = 0, dipdir = 0, spacing = 4, persistence = 1, offset = 0})
		local js = sets[1]
		local hits = {}
		for y = -20, 19 do
			local ok, k = joints.face_is_joint_set(js, 5, y, -3, 2)
			if ok then hits[#hits + 1] = y end
			assert.is_nil((joints.face_crossing(js, 5, y, -3, 1)))
			assert.is_nil((joints.face_crossing(js, 5, y, -3, 3)))
		end
		assert.are.equal(10, #hits)
		-- offset=0：平面在 y = 4k，位於格中心上 → 歸給 (4k-1 | 4k) 之間的面
		for _, y in ipairs(hits) do
			assert.are.equal(3, y % 4)
		end
	end)

	it("相位 offset 移動平面位置", function()
		local sets = one_set({dip = 0, dipdir = 0, spacing = 4, persistence = 1, offset = 2.5})
		-- s = y/4 + 0.625；平面在 s 整數 → y = 4k - 2.5 → 介於 y=4k-3 與 4k-2 之間
		assert.truthy(joints.face_is_joint_set(sets[1], 0, 1, 0, 2))   -- y=1|2
		assert.falsy(joints.face_is_joint_set(sets[1], 0, 2, 0, 2))
		assert.truthy(joints.face_is_joint_set(sets[1], 0, -3, 0, 2))  -- y=-3|-2
	end)

	it("向東傾直立組只切 x 方向的面", function()
		local sets = one_set({dip = 90, dipdir = 90, spacing = 3, persistence = 1, offset = 0.5})
		local n = 0
		for x = 0, 29 do
			if joints.face_is_joint_set(sets[1], x, 0, 0, 1) then n = n + 1 end
			assert.is_nil((joints.face_crossing(sets[1], x, 4, 9, 2)))
			assert.is_nil((joints.face_crossing(sets[1], x, 4, 9, 3)))
		end
		assert.are.equal(10, n)
	end)

	it("斜交組：沿路徑累積的穿越數 = 平面座標差", function()
		local sets = one_set({dip = 55, dipdir = 30, spacing = 2.5, persistence = 1})
		local js = sets[1]
		-- 走一條 x→y→z 階梯路徑，n 的三個分量皆 > 0，s 單調遞增
		local x, y, z = 0, 0, 0
		local s0 = joints.plane_coord(js, x, y, z)
		local crossings = 0
		for step = 1, 60 do
			local axis = (step - 1) % 3 + 1
			if joints.face_crossing(js, x, y, z, axis) then crossings = crossings + 1 end
			local e = joints.AXIS[axis]
			x, y, z = x + e[1], y + e[2], z + e[3]
		end
		local s1 = joints.plane_coord(js, x, y, z)
		assert.are.equal(math.floor(s1) - math.floor(s0), crossings)
	end)

	it("平面編號 k 落在兩格中心之間", function()
		local sets = one_set({dip = 65, dipdir = 250, spacing = 3, persistence = 1})
		local js = sets[1]
		local checked = 0
		for x = -10, 10 do for y = -5, 5 do for axis = 1, 3 do
			local k = joints.face_crossing(js, x, y, 3, axis)
			if k then
				local e = joints.AXIS[axis]
				local s1 = joints.plane_coord(js, x, y, 3)
				local s2 = joints.plane_coord(js, x + e[1], y + e[2], 3 + e[3])
				assert.truthy(math.min(s1, s2) < k and k <= math.max(s1, s2))
				checked = checked + 1
			end
		end end end
		assert.truthy(checked > 50)
	end)

	it("延續性：P=0 無節理、P=1 全節理、中間值比例相符", function()
		local function frac(P)
			local sets = one_set({dip = 0, dipdir = 0, spacing = 1, persistence = P}, 4242)
			local hit, tot = 0, 0
			for x = -50, 49 do for z = -50, 49 do
				tot = tot + 1
				if joints.face_is_joint_set(sets[1], x, 0, z, 2) then hit = hit + 1 end
			end end
			return hit / tot
		end
		assert.are.equal(0, frac(0))
		assert.are.equal(1, frac(1))
		assert.near(0.6, frac(0.6), 0.02)
	end)

	it("同種子結果固定，不同種子延續性樣式不同、幾何相同", function()
		local def = {dip = 30, dipdir = 100, spacing = 2, persistence = 0.5, offset = 0.3}
		local a = one_set(def, 1)
		local a2 = one_set(def, 1)
		local b = one_set(def, 2)
		local same_geom, diff_pers = true, 0
		for x = 0, 20 do for y = 0, 20 do
			local ka, ra = joints.face_crossing(a[1], x, y, 0, 1)
			local ka2, ra2 = joints.face_crossing(a2[1], x, y, 0, 1)
			local kb, rb = joints.face_crossing(b[1], x, y, 0, 1)
			assert.are.equal(ka, ka2); assert.are.equal(ra, ra2)
			if ka ~= kb then same_geom = false end
			if ka and (ra < 0.5) ~= (rb < 0.5) then diff_pers = diff_pers + 1 end
		end end
		assert.is_true(same_geom)
		assert.truthy(diff_pers > 0)
	end)

	it("face_key：W 面 = 西鄰格的 E 面", function()
		local W = joints.FACES[2]
		local x, y, z, axis = joints.face_key(4, 5, 6, W)
		assert.are.same({3, 5, 6, 1}, {x, y, z, axis})
		local Dn = joints.FACES[4]
		x, y, z, axis = joints.face_key(4, 5, 6, Dn)
		assert.are.same({4, 4, 6, 2}, {x, y, z, axis})
	end)

	it("face_joint 回傳第一個成立的組；face_info 列出所有穿越", function()
		local sets = joints.prepare({
			{id = 1, name = "H", dip = 0, dipdir = 0, spacing = 2, persistence = 0, phi = 30, offset = 0},
			{id = 2, name = "H2", dip = 0, dipdir = 0, spacing = 2, persistence = 1, phi = 30, offset = 0},
		}, 1)
		assert.are.equal(2, joints.face_joint(sets, 0, 1, 0, 2))
		assert.is_nil(joints.face_joint(sets, 0, 0, 0, 2))
		local info = joints.face_info(sets, 0, 1, 0, 2)
		assert.are.equal(2, #info)
		assert.is_false(info[1].joint)
		assert.is_true(info[2].joint)
	end)

	it("未指定 offset 時相位由種子決定且在 [0,1)", function()
		local a = one_set({dip = 10, dipdir = 0, spacing = 3, persistence = 1}, 11)[1]
		local b = one_set({dip = 10, dipdir = 0, spacing = 3, persistence = 1}, 12)[1]
		assert.truthy(a.phase >= 0 and a.phase < 1)
		assert.truthy(a.phase ~= b.phase)
	end)
end)
