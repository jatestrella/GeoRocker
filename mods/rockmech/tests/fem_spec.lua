dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local fem = load_module("fem")

-- 網格 n³、solid(x, y, z)；σ0 依深度（壓為正），頂面 y = ny 是地表
local GAMMA = 25
local function job(nx, ny, nz, solidf, top, K)
	local j = {nx = nx, ny = ny, nz = nz, solid = {}, sxx = {}, syy = {}, szz = {}, sxz = {}, gamma = GAMMA, tol = 1e-6, max_iter = 4000}
	for z = 0, nz - 1 do for y = 0, ny - 1 do for x = 0, nx - 1 do
		local c = 1 + x + y * nx + z * nx * ny
		local sv = GAMMA * (top + 0.5 - y)
		j.solid[c] = solidf(x, y, z)
		j.syy[c] = sv
		j.sxx[c], j.szz[c], j.sxz[c] = (K or 1) * sv, (K or 1) * sv, 0
	end end end
	return j
end

-- 粗網格：把 solidf 每 h³ 一格，過半是岩石算實心；頂層 ktop
local function coarsen(nx, ny, nz, h, solidf, ktop, ox, oy, oz)
	local cx, cy, cz = math.floor(nx / h), math.floor(ny / h), math.floor(nz / h)
	local c = job(cx, cy, cz, function(x, y, z)
		local n = 0
		for dz = 0, h - 1 do for dy = 0, h - 1 do for dx = 0, h - 1 do
			if solidf(h * x + dx, h * y + dy, h * z + dz) then n = n + 1 end
		end end end
		return 2 * n > h * h * h
	end, ktop)
	for k = 1, cx * cy * cz do
		local y = math.floor((k - 1) / cx) % cy
		local sv = h * GAMMA * (ktop - y + 0.5)
		c.syy[k], c.sxx[k], c.szz[k] = sv, sv, sv
	end
	c.gamma, c.h, c.ox, c.oy, c.oz = h * GAMMA, h, ox, oy, oz
	return c
end

describe("fem 子模型", function()
	it("沒有開挖：粗網格與細網格的 Δu 都是 0", function()
		local all = function(_, y) return y < 18 end
		local j = job(9, 9, 9, function() return true end, 8)
		j.coarse = coarsen(27, 27, 27, 3, all, 5, -9, -9, -9)
		for k = 1, #j.syy do
			local y = math.floor((k - 1) / 9) % 9
			local sv = GAMMA * (17 - (y + 9) + 0.5)
			j.syy[k], j.sxx[k], j.szz[k] = sv, sv, sv
		end
		j.coarse.ox, j.coarse.oy, j.coarse.oz = -9, -9, -9
		local res = fem.solve_nested(j)
		local m = 0
		for k = 1, #res.u do m = math.max(m, math.abs(res.u[k])) end
		assert.is_true(m < 1e-6)
	end)

	it("res.hot：頂板拉力最大的地方在開口跨中，細網格範圍外也找得到", function()
		local function solidf(x, y, z)
			if y > 17 then return false end
			return not (x >= 3 and x <= 32 and z >= 3 and z <= 32 and y >= 6 and y <= 8)
		end
		local c = coarsen(36, 21, 36, 3, solidf, 5, -3, -6, -3)
		c.tol = 1e-4
		local j = job(5, 5, 5, function(x, y, z) return solidf(x + 3, y + 6, z + 3) end, 11)
		j.coarse = c
		local res = fem.solve_nested(j)
		assert.is_true(#res.hot > 0 and #res.hot <= 16)
		local p = res.hot[1]
		assert.is_true(p[1] >= 3 and p[1] <= 8 and p[3] >= 3 and p[3] <= 8)
		assert.is_true(p[2] == 3)
	end)

	it("支護 press：頂板受向上的壓力，下緣正應力接近 p，頂板往下的位移變小", function()
		local function room()
			return job(21, 21, 21, function(x, y, z) return not (x >= 6 and x <= 14 and z >= 6 and z <= 14 and y >= 6 and y <= 8) end, 40, 1)
		end
		local bare = room()
		local r0 = fem.solve(bare)
		local j = room()
		j.press = {}
		for x = 6, 14 do for z = 6, 14 do
			local m = #j.press
			j.press[m + 1], j.press[m + 2], j.press[m + 3] = 1 + x + 9 * 21 + z * 441, 4, 200
		end end
		local r1 = fem.solve(j)
		local _, s0 = fem.point_stress(bare, r0, 10, 9, 10, 0.5, 0, 0.5)
		local _, s1 = fem.point_stress(j, r1, 10, 9, 10, 0.5, 0, 0.5)
		assert.near(200, s1 - s0, 30)
		local n = (10 + 9 * 22 + 10 * 484) * 3 + 2
		assert.is_true(r1.u[n] > r0.u[n])
	end)

	it("剪力減積分：Ke 仍對稱，剛體平移沒有力，同一根梁比全積分軟", function()
		local K = fem.element_stiffness(0.25, 0.1)
		for a = 0, 7 do
			for p = 1, 3 do for q = 1, 3 do
				local sum = 0
				for b = 0, 7 do
					assert.near(K[a][b][(p - 1) * 3 + q], K[b][a][(q - 1) * 3 + p], 1e-6)
					sum = sum + K[a][b][(p - 1) * 3 + q]
				end
				assert.near(0, sum, 1e-6)
			end end
		end
		local function beam(blend)
			local j = job(11, 7, 3, function(x, y) return y == 3 or x == 0 or x == 10 end, 6)
			j.blend, j.tol = blend, 1e-6
			return fem.solve(j).u[(5 + 3 * 12 + 1 * 12 * 8) * 3 + 2]
		end
		assert.is_true(math.abs(beam(0.1)) > math.abs(beam(nil)))
	end)

	it("沒接到外緣的岩塊不算勁度：不會發散", function()
		local j = job(11, 11, 11, function(x, y, z)
			if x >= 4 and x <= 6 and y >= 4 and y <= 6 and z >= 4 and z <= 6 then return x == 5 and y == 5 and z == 5 end
			return y <= 8
		end, 8)
		local res = fem.solve(j)
		assert.is_true(res.iters < 500)
		local m = 0
		for k = 1, #res.u do m = math.max(m, math.abs(res.u[k])) end
		assert.is_true(m < 1)
	end)

	it("開口比細網格範圍大：外緣用粗網格的解比 Δu = 0 接近大範圍的解", function()
		local N, NY, TOP = 33, 27, 23
		local function solidf(x, y, z)
			if y > TOP then return false end
			return not (x >= 6 and x <= 26 and z >= 6 and z <= 26 and y >= 12 and y <= 14)
		end
		local big = job(N, NY, N, solidf, TOP)
		big.tol = 1e-4
		local rb = fem.solve(big)
		local bx, by, bz = 12, 10, 12        -- 9 格的 box，水平範圍整個在開口裡
		local function box()
			local j = job(9, 9, 9, function(x, y, z) return solidf(x + bx, y + by, z + bz) end, TOP - by)
			j.tol = 1e-4
			return j
		end
		local function sxx(j, r, x, y, z) return (fem.point_stress(j, r, x, y, z, 0.5, 0, 0.5)) end
		local truth = sxx(big, rb, 16, 15, 16)
		local j1 = box()
		local e1 = math.abs(sxx(j1, fem.solve(j1), 4, 5, 4) - truth)
		local j2 = box()
		j2.coarse = coarsen(N, NY, N, 3, solidf, 7, -bx, -by, -bz)
		local e2 = math.abs(sxx(j2, fem.solve_nested(j2), 4, 5, 4) - truth)
		assert.is_true(e2 < 0.5 * e1)
	end)
end)

describe("fem 彈性應力場", function()
	it("主應力：對角張量、純剪", function()
		local a, b, c = fem.principal(3, 1, 2, 0, 0, 0)
		assert.near(3, a, 1e-9); assert.near(2, b, 1e-9); assert.near(1, c, 1e-9)
		a, b, c = fem.principal(0, 0, 0, 5, 0, 0)
		assert.near(5, a, 1e-9); assert.near(0, b, 1e-9); assert.near(-5, c, 1e-9)
	end)

	it("Ke：對稱、剛體平移沒有力", function()
		local K = fem.element_stiffness(0.25)
		for a = 0, 7 do
			local sum = {0, 0, 0, 0, 0, 0, 0, 0, 0}
			for b = 0, 7 do for q = 1, 9 do
				sum[q] = sum[q] + K[a][b][q]
				local p = math.floor((q - 1) / 3)
				local r = (q - 1) % 3
				assert.near(K[a][b][q], K[b][a][r * 3 + p + 1], 1e-6)
			end end
			for q = 1, 9 do assert.near(0, sum[q], 1e-6) end
		end
	end)

	it("沒有開挖：現地應力與重力平衡，應力不變", function()
		local j = job(6, 6, 6, function() return true end, 5.5 + 0.0, 0.5)
		local r = fem.solve(j)
		local c = 1 + 3 + 3 * 6 + 3 * 36
		assert.near(j.syy[c], r.syy[c], 1e-6)
		assert.near(j.sxx[c], r.sxx[c], 1e-6)
	end)

	it("開挖後洞壁的法向應力接近 0、環向應力集中", function()
		-- 長隧道（沿 z）斷面 3×3 格，K = 1；中段斷面取值，範圍 ±12 格
		local n = 25
		local nzz = 15
		local function hole(x, y) return x >= 11 and x <= 13 and y >= 11 and y <= 13 end
		local j = job(n, n, nzz, function(x, y) return not hole(x, y) end, 60, 1)
		local r = fem.solve(j)
		assert.is_true(r.res < 1e-5)
		local z = 7
		local c = function(x, y) return 1 + x + y * n + z * n * n end
		local sv = GAMMA * 60
		-- 頂板正上方：豎向應力大幅釋放（洞壁法向），水平（環向）應力集中
		local roof = c(12, 14)
		assert.is_true(r.syy[roof] < 0.45 * j.syy[roof])
		assert.is_true(r.sxx[roof] > 1.1 * j.sxx[roof])
		-- 遠離開挖：回到現地應力
		local far = c(3, 3)
		assert.near(j.syy[far], r.syy[far], 0.1 * j.syy[far])
		-- 平衡：通過隧道中心那個水平斷面的總豎向力不變
		local sum0, sum1 = 0, 0
		for zz = 0, nzz - 1 do for x = 0, n - 1 do
			local cc = 1 + x + 12 * n + zz * n * n
			sum0 = sum0 + j.syy[cc]
			if j.solid[cc] then sum1 = sum1 + r.syy[cc] end
		end end
		assert.near(sum0, sum1, 0.15 * sum0)
		assert.is_true(sv > 0)
	end)

	it("初始值：用上次的解再解，迭代次數大幅減少", function()
		local n = 15
		local function s1(x, y, z) return not (x >= 6 and x <= 8 and y >= 6 and y <= 8 and z >= 4) end
		local a = job(n, n, n, s1, 30, 1)
		local ra = fem.solve(a)
		local b = job(n, n, n, s1, 30, 1)
		b.u0 = ra.u
		local rb = fem.solve(b)
		assert.is_true(rb.iters <= 2)
		assert.is_true(ra.iters > 10)
	end)

	it("臨空面的邊界條件：法向應力 = 支護壓力，面上的剪應力 = 0，面內應力不變", function()
		local s = fem.free_face({1240, -47, 314, -5, -3, 1}, 2, 0)
		assert.near(1240, s[1], 1e-12); assert.near(0, s[2], 1e-12); assert.near(314, s[3], 1e-12)
		assert.near(0, s[4], 1e-12); assert.near(0, s[5], 1e-12); assert.near(1, s[6], 1e-12)
		local s1, _, s3 = fem.principal(s[1], s[2], s[3], s[4], s[5], s[6])
		assert.near(1240, s1, 0.01); assert.near(0, s3, 0.01)
		local w = fem.free_face({-50, 900, 300, 120, 2, 7}, 1, 40)    -- 側牆，40 kPa 的支護
		assert.near(40, w[1], 1e-12); assert.near(0, w[4], 1e-12); assert.near(0, w[6], 1e-12)
		assert.near(2, w[5], 1e-12)
	end)

	it("碎石填滿開口：壓力往岩壁回推，頂板下陷變小，碎石本身受壓", function()
		local n = 21
		local function room(x, y, z) return x >= 8 and x <= 12 and y >= 8 and y <= 11 and z >= 8 and z <= 12 end
		local empty = job(n, n, n, function(x, y, z) return not room(x, y, z) end, 40, 1)
		local filled = job(n, n, n, function() return true end, 40, 1)
		filled.soft = {}
		for z = 0, n - 1 do for y = 0, n - 1 do for x = 0, n - 1 do
			if room(x, y, z) then
				local c = 1 + x + y * n + z * n * n
				filled.soft[c] = true
				filled.syy[c], filled.sxx[c], filled.szz[c] = 0, 0, 0
			end
		end end end
		filled.soft_e = 0.1
		local r0, r1 = fem.solve(empty), fem.solve(filled)
		local c = 1 + 10 + 10 * n + 10 * n * n
		assert.is_true(r1.syy[c] > 0 and r1.sxx[c] > 0 and r1.szz[c] > 0)   -- 三向受壓
		local Nx = n + 1
		local node = (10 + 12 * Nx + 10 * Nx * Nx) * 3 + 2                  -- 頂板中央的節點 uy
		assert.is_true(math.abs(r1.u[node]) < math.abs(r0.u[node]))
		-- 頂板第一格的 σyy：沒有碎石時接近 0，有碎石時等於碎石頂上來的反力
		local roof = 1 + 10 + 12 * n + 10 * n * n
		assert.is_true(r1.syy[roof] > r0.syy[roof])
	end)

	it("沒有碎石格時，給不給 soft 結果都一樣", function()
		local n = 11
		local function s1(x, y, z) return not (x >= 4 and x <= 6 and y >= 4 and y <= 6 and z >= 4 and z <= 6) end
		local a, b = job(n, n, n, s1, 20, 1), job(n, n, n, s1, 20, 1)
		b.soft, b.soft_e = {}, 0.1
		local ra, rb = fem.solve(a), fem.solve(b)
		for k = 1, #ra.syy do assert.near(ra.syy[k], rb.syy[k], 1e-9) end
	end)
end)
