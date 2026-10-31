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
end)
