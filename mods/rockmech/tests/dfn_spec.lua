dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local joints = load_module("joints")
local dfn = load_module("dfn")

local function sets_of(list, where, lith_at)
	for i, t in ipairs(list) do
		t.id = t.id or i
		t.name = t.name or ("J" .. i)
		t.persistence = t.persistence or 1
		t.phi = t.phi or 30
	end
	return joints.prepare(list, 4242, 8, "patch", {dfn = dfn, where = where, lith_at = lith_at})
end

describe("DFN 抽樣", function()
	it("截斷冪律 E[r²] 與抽樣平均相符", function()
		local s = 1
		local u = function() s = (s * 16807) % 2147483647; return s / 2147483647 end
		local n, sum = 20000, 0
		for _ = 1, n do local r = dfn.sample_r(u, 1, 15, 3.5); sum = sum + r * r end
		assert.near(dfn.E_r2(1, 15, 3.5), sum / n, 0.08 * dfn.E_r2(1, 15, 3.5))
	end)

	it("Fisher：平均 cosθ = coth κ − 1/κ", function()
		local s = 7
		local u = function() s = (s * 16807) % 2147483647; return s / 2147483647 end
		local n0 = joints.normal(40, 120)
		for _, k in ipairs({5, 30}) do
			local sum = 0
			for _ = 1, 5000 do
				local x, y, z = dfn.sample_fisher(u, n0, k)
				sum = sum + math.abs(x * n0.x + y * n0.y + z * n0.z)
			end
			local expect = (math.exp(2 * k) + 1) / (math.exp(2 * k) - 1) - 1 / k
			assert.near(expect, sum / 5000, 0.02)
		end
	end)
end)

describe("DFN 節理面", function()
	it("水平組：每立方公尺的水平節理面數 ≈ P32 = 1/間距", function()
		local S = sets_of({{dip = 0, dipdir = 0, spacing = 3, kappa = 1e5, rmin = 1, rmax = 8, a = 3.5}})
		local n, V = 0, 0
		for x = 0, 47 do for y = 0, 31 do for z = 0, 47 do
			V = V + 1
			if joints.face_joint(S, x, y, z, 2) then n = n + 1 end
		end end end
		assert.near(1 / 3, n / V, 0.06)
	end)

	it("同一個種子結果一樣；face 與 face_all 一致", function()
		local spec = {{dip = 60, dipdir = 30, spacing = 2, kappa = 20, rmin = 1, rmax = 6, a = 3.5},
			{dip = 80, dipdir = 140, spacing = 3, kappa = 20, rmin = 1, rmax = 6, a = 3.5}}
		local A, B = sets_of(spec), sets_of({
			{dip = 60, dipdir = 30, spacing = 2, kappa = 20, rmin = 1, rmax = 6, a = 3.5},
			{dip = 80, dipdir = 140, spacing = 3, kappa = 20, rmin = 1, rmax = 6, a = 3.5}})
		local hits = 0
		for x = -10, 10 do for y = -5, 5 do for z = -10, 10 do for ax = 1, 3 do
			local a = joints.face_joint(A, x, y, z, ax)
			assert.are.equal(a, joints.face_joint(B, x, y, z, ax))
			local all = A.dfn:face_all(x, y, z, ax)
			assert.are.equal(a ~= nil, #all > 0)
			if a then hits = hits + 1; assert.are.equal(all[1].set, a) end
		end end end end
		assert.truthy(hits > 100)
	end)

	it("位態離散：κ 小的組，圓盤極點散開", function()
		local S = sets_of({{dip = 45, dipdir = 90, spacing = 2, kappa = 10, rmin = 1, rmax = 4, a = 3}})
		local n0, lo, cnt = S[1].n, 1, 0
		for _, d in ipairs(S.dfn:generated(0, 0, 0)) do
			local c = d.nx * n0.x + d.ny * n0.y + d.nz * n0.z
			if c < lo then lo = c end
			cnt = cnt + 1
		end
		assert.truthy(cnt > 20)
		assert.truthy(lo < math.cos(math.rad(25)))
	end)

	it("地質區：第 1 區的組不會出現在第 2 區", function()
		local where = function(x) return x < 0 and 1 or 2 end
		local S = sets_of({{dip = 70, dipdir = 0, spacing = 2, kappa = 30, rmin = 1, rmax = 10, a = 3, zone = 1},
			{dip = 30, dipdir = 200, spacing = 2, kappa = 30, rmin = 1, rmax = 10, a = 3, zone = 2}}, where)
		local cnt = {0, 0}
		for x = -20, 19 do for y = 0, 10 do for z = 0, 20 do for ax = 1, 3 do
			local i = joints.face_joint(S, x, y, z, ax)
			if i then
				cnt[i] = cnt[i] + 1
				local e = ax == 1 and 1 or 0
				assert.are.equal(i, where(x + e) == where(x) and where(x) or -1)
			end
		end end end end
		assert.truthy(cnt[1] > 50 and cnt[2] > 50)
	end)

	it("掃描線 P10：順著平行組的法線 ≈ 1/間距", function()
		local S = sets_of({{dip = 0, dipdir = 0, spacing = 2, kappa = 1e5, rmin = 4, rmax = 30, a = 3}})
		local sum = 0
		for i = 0, 9 do sum = sum + S.dfn:p10({x = i * 7, y = 0, z = i * 3}, {x = 0, y = 1, z = 0}, 60) end
		assert.near(0.5, sum / 10, 0.12)
	end)

	it("岩面跡線：節理面旁的格子看得到跡線", function()
		local S = sets_of({{dip = 50, dipdir = 70, spacing = 2, kappa = 30, rmin = 1.5, rmax = 8, a = 3.5}})
		local n = 0
		for x = 0, 15 do for y = 0, 15 do
			n = n + #S.dfn:face_traces(x, y, 0, 3, -1)
		end end
		assert.truthy(n > 20)
	end)

	it("岩性範圍：砂岩、頁岩各一組，圓盤碰到層面就停", function()
		local lith_at = function(x, y) return y >= 0 and "sandstone" or "shale" end
		local S = sets_of({{dip = 80, dipdir = 0, spacing = 2, kappa = 30, rmin = 1, rmax = 10, a = 3, lith = {sandstone = true}},
			{dip = 80, dipdir = 90, spacing = 2, kappa = 30, rmin = 1, rmax = 10, a = 3, lith = {shale = true}}}, nil, lith_at)
		local cnt = {0, 0}
		for x = 0, 20 do for y = -10, 9 do for z = 0, 20 do for ax = 1, 3 do
			local i = joints.face_joint(S, x, y, z, ax)
			if i then
				cnt[i] = cnt[i] + 1
				local y2 = ax == 2 and y + 1 or y
				assert.are.equal(i == 1 and "sandstone" or "shale", lith_at(x, y))
				assert.are.equal(lith_at(x, y), lith_at(x, y2))     -- 不跨過層面
			end
		end end end end
		assert.truthy(cnt[1] > 50 and cnt[2] > 50)
	end)

	it("方塊範圍：同一種岩體，兩個範圍各一組不同位態", function()
		local S = sets_of({{dip = 20, dipdir = 0, spacing = 2, kappa = 50, rmin = 1, rmax = 8, a = 3, box = {-40, -20, -20, -1, 20, 20}},
			{dip = 70, dipdir = 180, spacing = 2, kappa = 50, rmin = 1, rmax = 8, a = 3, box = {0, -20, -20, 40, 20, 20}}})
		local cnt = {0, 0}
		for x = -30, 29 do for y = -5, 5 do for z = -5, 5 do for ax = 1, 3 do
			local i = joints.face_joint(S, x, y, z, ax)
			if i then
				cnt[i] = cnt[i] + 1
				local x2 = ax == 1 and x + 1 or x
				assert.are.equal(i, x < 0 and 1 or 2)
				assert.are.equal(x < 0, x2 < 0)
			end
		end end end end
		assert.truthy(cnt[1] > 50 and cnt[2] > 50)
		-- 範圍外的粗格不產生這一組
		for _, d in ipairs(S.dfn:generated(10, 0, 0)) do assert.are.equal(nil, d.set == 1 and d or nil) end
	end)

	it("層控節理：頁岩裡比砂岩密，而且不跨過層面", function()
		local lith_at = function(x, y) return y >= 0 and "sandstone" or "shale" end
		local S = sets_of({{dip = 85, dipdir = 30, spacing = 3, kappa = 40, rmin = 1, rmax = 8, a = 3.5,
			lith_p32 = {sandstone = 0.5, shale = 2}}}, nil, lith_at)
		local n = {sandstone = 0, shale = 0}
		for x = 0, 47 do for y = -12, 11 do for z = 0, 47 do for ax = 1, 3 do
			if joints.face_joint(S, x, y, z, ax) then
				local y2 = ax == 2 and y + 1 or y
				assert.are.equal(lith_at(x, y), lith_at(x, y2))
				n[lith_at(x, y)] = n[lith_at(x, y)] + 1
			end
		end end end end
		local ratio = n.shale / n.sandstone
		assert.truthy(ratio > 2.5 and ratio < 6, "shale/sandstone = " .. ratio)
	end)
end)
