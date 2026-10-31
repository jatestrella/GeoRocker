-- rockmech/fem.lua
-- 開挖周圍的彈性應力場（純函式，不依賴引擎；也載入背景執行緒，見 femstress.lua）。
--
-- ## 模型
-- 每個岩石格是一個邊長 1 m 的 8 節點六面體元素（線彈性、均質、等向），空氣與碎石沒有勁度。
-- 解的是「開挖造成的變化」：現地應力 σ0（每格給定）與重力在完整岩體裡平衡，開挖後臨空面上不平衡，
--   K·Δu = F_重力 − ∫Bᵀσ0 dV       （節點不平衡力只出現在臨空面）
--   σ = σ0 + D·B·Δu                 （每格中心）
-- 範圍外緣的節點 Δu = 0（遠場不受開挖影響），或用粗網格的解給定（solve_nested）。σ 與 E 無關，E 只是數值尺度。
-- 應力以「壓為正」進出本模組（kPa），內部的有限元素計算以「拉為正」。
--
-- ## 解法
-- Jacobi 前處理的共軛梯度法，不組整體矩陣：一個節點的 27 點模版只看它周圍 8 格哪幾格是岩石，
-- 共 256 種，算一次存起來（stencil）。
--
-- ## 輸入 job
-- {nx, ny, nz（格數）, solid（1 + x + y·nx + z·nx·ny → true/false）, sxx, syy, szz, sxz（σ0，kPa）,
--  gamma（kN/m³）, nu, tol, max_iter, u0（可選，上次的 Δu，當初始值；外緣節點的值就是給定的位移）}
-- 邊長 h 的元素：同一個單位立方體方程式，gamma 給 γ·h，解出來的 u 是 Δu / h。
-- ## 輸出
-- {sxx, syy, szz, sxy, syz, szx（總應力，kPa）, u, iters, res（相對殘差）, ms}

local fem = {}

local E = 1e6        -- kPa；應力與 E 無關，只影響 Δu 的尺度

-- 單位立方體 8 節點元素的 Ke（節點 a = i + 2j + 4k；K[a][b] = {3×3 列展開}）
local function element_stiffness(nu)
	local lam = E * nu / ((1 + nu) * (1 - 2 * nu))
	local mu = E / (2 * (1 + nu))
	local gp = {0.5 - 0.5 / math.sqrt(3), 0.5 + 0.5 / math.sqrt(3)}
	local K = {}
	for a = 0, 7 do
		K[a] = {}
		for b = 0, 7 do K[a][b] = {0, 0, 0, 0, 0, 0, 0, 0, 0} end
	end
	local function grad(a, x, y, z)
		local i, j, k = a % 2, math.floor(a / 2) % 2, math.floor(a / 4)
		local fx, dx = i == 1 and x or 1 - x, i == 1 and 1 or -1
		local fy, dy = j == 1 and y or 1 - y, j == 1 and 1 or -1
		local fz, dz = k == 1 and z or 1 - z, k == 1 and 1 or -1
		return {dx * fy * fz, fx * dy * fz, fx * fy * dz}
	end
	for _, x in ipairs(gp) do for _, y in ipairs(gp) do for _, z in ipairs(gp) do
		local g = {}
		for a = 0, 7 do g[a] = grad(a, x, y, z) end
		for a = 0, 7 do for b = 0, 7 do
			local dot = g[a][1] * g[b][1] + g[a][2] * g[b][2] + g[a][3] * g[b][3]
			local t = K[a][b]
			for p = 1, 3 do for q = 1, 3 do
				local v = lam * g[a][p] * g[b][q] + mu * g[a][q] * g[b][p]
				if p == q then v = v + mu * dot end
				t[(p - 1) * 3 + q] = t[(p - 1) * 3 + q] + v / 8
			end end
		end end
	end end end
	return K
end
fem.element_stiffness = element_stiffness

-- 一個節點周圍 8 格（位元 e = ex + 2ey + 4ez，該格在節點的 (ex−1, ey−1, ez−1) 位置）的組合 → 模版
-- {n, dx[], dy[], dz[], k[]（每鄰點 9 個）, d1, d2, d3（對角）}
local function make_stencil(Ke, mask)
	local sum = {}
	for e = 0, 7 do
		if math.floor(mask / 2 ^ e) % 2 == 1 then
			local ex, ey, ez = e % 2, math.floor(e / 2) % 2, math.floor(e / 4)
			local a = (1 - ex) + 2 * (1 - ey) + 4 * (1 - ez)   -- 這個節點是該格的第 a 個角
			local ai, aj, ak = 1 - ex, 1 - ey, 1 - ez
			for b = 0, 7 do
				local bi, bj, bk = b % 2, math.floor(b / 2) % 2, math.floor(b / 4)
				local key = (bi - ai + 1) + 3 * (bj - aj + 1) + 9 * (bk - ak + 1)
				local s = sum[key]
				if not s then s = {0, 0, 0, 0, 0, 0, 0, 0, 0}; sum[key] = s end
				for q = 1, 9 do s[q] = s[q] + Ke[a][b][q] end
			end
		end
	end
	local st = {n = 0, dx = {}, dy = {}, dz = {}, k = {}}
	for key = 0, 26 do
		local s = sum[key]
		if s then
			st.n = st.n + 1
			st.dx[st.n] = key % 3 - 1
			st.dy[st.n] = math.floor(key / 3) % 3 - 1
			st.dz[st.n] = math.floor(key / 9) - 1
			for q = 1, 9 do st.k[(st.n - 1) * 9 + q] = s[q] end
			if key == 13 then st.d1, st.d2, st.d3 = s[1], s[5], s[9] end
		end
	end
	return st
end
fem.make_stencil = make_stencil

-- 沿面相連、接到範圍外緣的岩石格。沒接到的岩塊沒有束制（K 奇異），不算勁度
local function anchored(job)
	local nx, ny, nz = job.nx, job.ny, job.nz
	local solid = job.solid
	local sy, sz = nx, nx * ny
	local out, stack, top = {}, {}, 0
	local function push(c)
		if solid[c] and not out[c] then
			out[c] = true
			top = top + 1
			stack[top] = c
		end
	end
	for z = 0, nz - 1 do for y = 0, ny - 1 do for x = 0, nx - 1 do
		if x == 0 or y == 0 or z == 0 or x == nx - 1 or y == ny - 1 or z == nz - 1 then
			push(1 + x + y * sy + z * sz)
		end
	end end end
	while top > 0 do
		local c = stack[top]
		top = top - 1
		local k = c - 1
		local x, y, z = k % nx, math.floor(k / sy) % ny, math.floor(k / sz)
		if x > 0 then push(c - 1) end
		if x < nx - 1 then push(c + 1) end
		if y > 0 then push(c - sy) end
		if y < ny - 1 then push(c + sy) end
		if z > 0 then push(c - sz) end
		if z < nz - 1 then push(c + sz) end
	end
	return out
end

function fem.solve(job)
	local t_start = os.clock()
	local nx, ny, nz = job.nx, job.ny, job.nz
	local solid = anchored(job)
	local Nx, Ny, Nz = nx + 1, ny + 1, nz + 1
	local sy, sz = Nx, Nx * Ny
	local nn = Nx * Ny * Nz
	local nu = job.nu or 0.25
	local Ke = element_stiffness(nu)
	local lam = E * nu / ((1 + nu) * (1 - 2 * nu))
	local mu = E / (2 * (1 + nu))

	local function is_solid(x, y, z)
		if x < 0 or y < 0 or z < 0 or x >= nx or y >= ny or z >= nz then return false end
		return solid[1 + x + y * nx + z * nx * ny]
	end

	-- 模版（用到才算），這次網格的節點索引位移
	local stencils, offs = {}, {}
	local active, masks = {}, {}
	local na = 0
	for z = 1, Nz - 2 do for y = 1, Ny - 2 do for x = 1, Nx - 2 do
		local m = 0
		for e = 0, 7 do
			local ex, ey, ez = e % 2, math.floor(e / 2) % 2, math.floor(e / 4)
			if is_solid(x + ex - 1, y + ey - 1, z + ez - 1) then m = m + 2 ^ e end
		end
		if m > 0 then
			na = na + 1
			active[na] = x + y * sy + z * sz
			masks[na] = m
			if not stencils[m] then
				local st = make_stencil(Ke, m)
				stencils[m] = st
				local o = {}
				for s = 1, st.n do o[s] = (st.dx[s] + st.dy[s] * sy + st.dz[s] * sz) * 3 end
				offs[m] = o
			end
		end
	end end end

	local ndof = nn * 3
	local f, r, z_, p, q, u = {}, {}, {}, {}, {}, job.u0 or {}
	for i = 1, ndof do f[i] = 0; r[i] = 0; z_[i] = 0; p[i] = 0; q[i] = 0 end
	if not job.u0 then for i = 1, ndof do u[i] = 0 end end

	-- 節點不平衡力：F = F_重力 − ∫Bᵀσ0 dV。常應力元素的 ∫∂N/∂x dV = ±1/4，以「拉為正」
	local gam = job.gamma or 25
	local cs = {}   -- 8 個角：節點位移（索引）與 ∂N/∂x（格中心，同時也是 ∫ 的值）
	for a = 0, 7 do
		local i, j, k = a % 2, math.floor(a / 2) % 2, math.floor(a / 4)
		cs[a + 1] = {i, j, k, (i * 2 - 1) / 4, (j * 2 - 1) / 4, (k * 2 - 1) / 4}
	end
	for cz = 0, nz - 1 do for cy = 0, ny - 1 do for cx = 0, nx - 1 do
		local c = 1 + cx + cy * nx + cz * nx * ny
		if solid[c] then
			local txx, tyy, tzz, txz = -job.sxx[c], -job.syy[c], -job.szz[c], -job.sxz[c]
			for a = 1, 8 do
				local cr = cs[a]
				local n3 = ((cx + cr[1]) + (cy + cr[2]) * sy + (cz + cr[3]) * sz) * 3
				local gx, gy, gz = cr[4], cr[5], cr[6]
				f[n3 + 1] = f[n3 + 1] - (txx * gx + txz * gz)
				f[n3 + 2] = f[n3 + 2] - (tyy * gy) - gam / 8
				f[n3 + 3] = f[n3 + 3] - (txz * gx + tzz * gz)
			end
		end
	end end end

	local function matvec(x, y)
		for i = 1, na do
			local idx, m = active[i] * 3, masks[i]
			local st, o = stencils[m], offs[m]
			local k = st.k
			local a, b, c = 0, 0, 0
			local kp = 0
			for s = 1, st.n do
				local j = idx + o[s]
				local u1, u2, u3 = x[j + 1], x[j + 2], x[j + 3]
				a = a + k[kp + 1] * u1 + k[kp + 2] * u2 + k[kp + 3] * u3
				b = b + k[kp + 4] * u1 + k[kp + 5] * u2 + k[kp + 6] * u3
				c = c + k[kp + 7] * u1 + k[kp + 8] * u2 + k[kp + 9] * u3
				kp = kp + 9
			end
			y[idx + 1], y[idx + 2], y[idx + 3] = a, b, c
		end
	end

	-- r = f − K·u（只有自由節點）
	matvec(u, q)
	local rz, r0, ri = 0, 0, 0
	for i = 1, na do
		local idx, m = active[i] * 3, masks[i]
		local st = stencils[m]
		for d = 1, 3 do
			local j = idx + d
			local v = f[j] - q[j]
			r[j] = v
			local zv = v / (d == 1 and st.d1 or d == 2 and st.d2 or st.d3)
			z_[j] = zv
			p[j] = zv
			rz = rz + v * zv
			r0 = r0 + f[j] * f[j]
			ri = ri + v * v
		end
	end
	r0 = math.sqrt(math.max(r0, ri))     -- 只有外緣給定位移時 f = 0
	local tol, max_iter = job.tol or 1e-3, job.max_iter or 1500
	local iters, rel = 0, 0
	if r0 > 0 then
		repeat
			iters = iters + 1
			matvec(p, q)
			local pq = 0
			for i = 1, na do
				local j = active[i] * 3
				pq = pq + p[j + 1] * q[j + 1] + p[j + 2] * q[j + 2] + p[j + 3] * q[j + 3]
			end
			if pq <= 0 then break end
			local alpha = rz / pq
			local rr, rz2 = 0, 0
			for i = 1, na do
				local idx = active[i] * 3
				local st = stencils[masks[i]]
				local d1, d2, d3 = st.d1, st.d2, st.d3
				local j1, j2, j3 = idx + 1, idx + 2, idx + 3
				u[j1] = u[j1] + alpha * p[j1]
				u[j2] = u[j2] + alpha * p[j2]
				u[j3] = u[j3] + alpha * p[j3]
				local r1, r2, r3 = r[j1] - alpha * q[j1], r[j2] - alpha * q[j2], r[j3] - alpha * q[j3]
				r[j1], r[j2], r[j3] = r1, r2, r3
				rr = rr + r1 * r1 + r2 * r2 + r3 * r3
				local z1, z2, z3 = r1 / d1, r2 / d2, r3 / d3
				z_[j1], z_[j2], z_[j3] = z1, z2, z3
				rz2 = rz2 + r1 * z1 + r2 * z2 + r3 * z3
			end
			rel = math.sqrt(rr) / r0
			local beta = rz2 / rz
			rz = rz2
			for i = 1, na do
				local idx = active[i] * 3
				local j1, j2, j3 = idx + 1, idx + 2, idx + 3
				p[j1] = z_[j1] + beta * p[j1]
				p[j2] = z_[j2] + beta * p[j2]
				p[j3] = z_[j3] + beta * p[j3]
			end
		until rel < tol or iters >= max_iter
	end

	-- 每格中心的總應力（壓為正）
	local out = {sxx = {}, syy = {}, szz = {}, sxy = {}, syz = {}, szx = {}, u = u, iters = iters, res = rel}
	local ncell = nx * ny * nz
	for c = 1, ncell do
		out.sxx[c], out.syy[c], out.szz[c], out.sxy[c], out.syz[c], out.szx[c] = 0, 0, 0, 0, 0, 0
	end
	for cz = 0, nz - 1 do for cy = 0, ny - 1 do for cx = 0, nx - 1 do
		local c = 1 + cx + cy * nx + cz * nx * ny
		if solid[c] then
			local exx, eyy, ezz, gxy, gyz, gzx = 0, 0, 0, 0, 0, 0
			for a = 1, 8 do
				local cr = cs[a]
				local n3 = ((cx + cr[1]) + (cy + cr[2]) * sy + (cz + cr[3]) * sz) * 3
				local gx, gy, gz = cr[4], cr[5], cr[6]
				local ux, uy, uz = u[n3 + 1], u[n3 + 2], u[n3 + 3]
				exx = exx + gx * ux
				eyy = eyy + gy * uy
				ezz = ezz + gz * uz
				gxy = gxy + gy * ux + gx * uy
				gyz = gyz + gz * uy + gy * uz
				gzx = gzx + gx * uz + gz * ux
			end
			local tr = lam * (exx + eyy + ezz)
			out.sxx[c] = job.sxx[c] - (tr + 2 * mu * exx)
			out.syy[c] = job.syy[c] - (tr + 2 * mu * eyy)
			out.szz[c] = job.szz[c] - (tr + 2 * mu * ezz)
			out.sxy[c] = -mu * gxy
			out.syz[c] = -mu * gyz
			out.szx[c] = job.sxz[c] - mu * gzx
		end
	end end end
	out.ms = (os.clock() - t_start) * 1000
	return out
end

-- 子模型：先解粗網格（job.coarse，元素邊長 h，原點比細網格的原點多 ox, oy, oz 公尺），
-- 把它的位移內插到細網格外緣當邊界條件，再解細網格。範圍比開口小時也看得到整個開口。
-- 粗網格的空節點（周圍 8 格都不是岩石）沒有解，不參與內插。
-- res.hot：粗網格上拉力最大的頂板格（最多 16 個，{x, y, z, σ1, σ3}，kPa），細網格範圍外的頂板也看得到。
function fem.solve_nested(job)
	local cj = job.coarse
	if not cj then return fem.solve(job) end
	local cres = fem.solve(cj)
	local hot = {}
	local cn, cn2 = cj.nx, cj.nx * cj.ny
	for z = 4, cj.nz - 5 do for y = 2, cj.ny - 3 do for x = 4, cj.nx - 5 do     -- 外圈 Δu = 0，應力是假的
		local c = 1 + x + y * cn + z * cn2
		if cj.solid[c] and not cj.solid[c - cn] then
			local t = {fem.point_stress(cj, cres, x, y, z, 0.5, 0, 0.5)}
			local s1, _, s3 = fem.principal(t[1], t[2], t[3], t[4], t[5], t[6])
			if s3 < 0 then hot[#hot + 1] = {x, y, z, s1, s3} end
		end
	end end end
	table.sort(hot, function(p, q) return p[5] < q[5] end)
	for i = #hot, 17, -1 do hot[i] = nil end
	local h = cj.h
	local Nx, Ny, Nz = job.nx + 1, job.ny + 1, job.nz + 1
	local cNx, cNy, cNz = cj.nx + 1, cj.ny + 1, cj.nz + 1
	local csy, csz = cNx, cNx * cNy
	local csolid, cu = cj.solid, cres.u
	local function cell(x, y, z)
		if x < 0 or y < 0 or z < 0 or x >= cj.nx or y >= cj.ny or z >= cj.nz then return false end
		return csolid[1 + x + y * cj.nx + z * cj.nx * cj.ny]
	end
	local function has_rock(i, j, k)
		for e = 0, 7 do
			if cell(i - e % 2, j - math.floor(e / 2) % 2, k - math.floor(e / 4)) then return true end
		end
		return false
	end
	local u = job.u0
	if not u then
		u = {}
		for i = 1, Nx * Ny * Nz * 3 do u[i] = 0 end
	end
	local sy, sz = Nx, Nx * Ny
	for z = 0, Nz - 1 do for y = 0, Ny - 1 do for x = 0, Nx - 1 do
		if x == 0 or y == 0 or z == 0 or x == Nx - 1 or y == Ny - 1 or z == Nz - 1 then
			local gx, gy, gz = (x - cj.ox) / h, (y - cj.oy) / h, (z - cj.oz) / h
			local i0 = math.max(0, math.min(cNx - 2, math.floor(gx)))
			local j0 = math.max(0, math.min(cNy - 2, math.floor(gy)))
			local k0 = math.max(0, math.min(cNz - 2, math.floor(gz)))
			local fx, fy, fz = gx - i0, gy - j0, gz - k0
			local a, b, c, w = 0, 0, 0, 0
			for e = 0, 7 do
				local ei, ej, ek = e % 2, math.floor(e / 2) % 2, math.floor(e / 4)
				local i, j, k = i0 + ei, j0 + ej, k0 + ek
				if has_rock(i, j, k) then
					local wt = (ei == 1 and fx or 1 - fx) * (ej == 1 and fy or 1 - fy) * (ek == 1 and fz or 1 - fz)
					local n3 = (i + j * csy + k * csz) * 3
					a, b, c, w = a + wt * cu[n3 + 1], b + wt * cu[n3 + 2], c + wt * cu[n3 + 3], w + wt
				end
			end
			local n3 = (x + y * sy + z * sz) * 3
			local m = w > 1e-9 and h / w or 0
			u[n3 + 1], u[n3 + 2], u[n3 + 3] = a * m, b * m, c * m
		end
	end end end
	job.u0 = u
	local res = fem.solve(job)
	res.cu, res.citers, res.hot = cu, cres.iters, hot
	res.ms = res.ms + cres.ms
	return res
end

-- 對稱 3×3 應力張量的主應力（壓為正）：回傳 σ1 ≥ σ2 ≥ σ3
function fem.principal(sxx, syy, szz, sxy, syz, szx)
	local q = (sxx + syy + szz) / 3
	local p1 = sxy * sxy + syz * syz + szx * szx
	local a, b, c = sxx - q, syy - q, szz - q
	local p2 = a * a + b * b + c * c + 2 * p1
	if p2 <= 1e-18 then return q, q, q end
	local p = math.sqrt(p2 / 6)
	local det = a * (b * c - syz * syz) - sxy * (sxy * c - syz * szx) + szx * (sxy * syz - b * szx)
	local rr = det / (2 * p * p * p)
	rr = math.max(-1, math.min(1, rr))
	local phi = math.acos(rr) / 3
	local s1 = q + 2 * p * math.cos(phi)
	local s3 = q + 2 * p * math.cos(phi + 2 * math.pi / 3)
	return s1, 3 * q - s1 - s3, s3
end

-- 格 (x, y, z) 的應力取周圍 r 格內岩石格的平均（消掉方塊角點的應力奇異）。回傳主應力 σ1, σ2, σ3 (kPa) 或 nil
function fem.cell_principal(job, res, x, y, z, r)
	local nx, ny, nz = job.nx, job.ny, job.nz
	local solid = job.solid
	local sum = {0, 0, 0, 0, 0, 0}
	local n = 0
	for dz = -r, r do for dy = -r, r do for dx = -r, r do
		local cx, cy, cz = x + dx, y + dy, z + dz
		if cx >= 0 and cy >= 0 and cz >= 0 and cx < nx and cy < ny and cz < nz then
			local c = 1 + cx + cy * nx + cz * nx * ny
			if solid[c] then
				n = n + 1
				sum[1] = sum[1] + res.sxx[c]
				sum[2] = sum[2] + res.syy[c]
				sum[3] = sum[3] + res.szz[c]
				sum[4] = sum[4] + res.sxy[c]
				sum[5] = sum[5] + res.syz[c]
				sum[6] = sum[6] + res.szx[c]
			end
		end
	end end end
	if n == 0 then return nil end
	return fem.principal(sum[1] / n, sum[2] / n, sum[3] / n, sum[4] / n, sum[5] / n, sum[6] / n)
end

-- 格 (x, y, z) 內一點（xi, eta, zeta ∈ 0..1）的總應力（壓為正，kPa）：回傳 sxx, syy, szz, sxy, syz, szx。
-- 格中心看不到一格厚的梁的彎曲，取臨空面上的點才有
function fem.point_stress(job, res, x, y, z, xi, eta, zeta)
	local nx, ny = job.nx, job.ny
	local sy, sz = nx + 1, (nx + 1) * (ny + 1)
	local nu = job.nu or 0.25
	local lam = E * nu / ((1 + nu) * (1 - 2 * nu))
	local mu = E / (2 * (1 + nu))
	local u = res.u
	local exx, eyy, ezz, gxy, gyz, gzx = 0, 0, 0, 0, 0, 0
	for a = 0, 7 do
		local i, j, k = a % 2, math.floor(a / 2) % 2, math.floor(a / 4)
		local fx, dx = i == 1 and xi or 1 - xi, i == 1 and 1 or -1
		local fy, dy = j == 1 and eta or 1 - eta, j == 1 and 1 or -1
		local fz, dz = k == 1 and zeta or 1 - zeta, k == 1 and 1 or -1
		local gx, gy, gz = dx * fy * fz, fx * dy * fz, fx * fy * dz
		local n3 = ((x + i) + (y + j) * sy + (z + k) * sz) * 3
		local ux, uy, uz = u[n3 + 1], u[n3 + 2], u[n3 + 3]
		exx = exx + gx * ux
		eyy = eyy + gy * uy
		ezz = ezz + gz * uz
		gxy = gxy + gy * ux + gx * uy
		gyz = gyz + gz * uy + gy * uz
		gzx = gzx + gx * uz + gz * ux
	end
	local c = 1 + x + y * nx + z * nx * ny
	local tr = lam * (exx + eyy + ezz)
	return job.sxx[c] - (tr + 2 * mu * exx), job.syy[c] - (tr + 2 * mu * eyy), job.szz[c] - (tr + 2 * mu * ezz),
		-mu * gxy, -mu * gyz, job.sxz[c] - mu * gzx
end

-- 背景執行緒（core.register_async_dofile）裡用 core.rockmech_fem 取得
if core then core.rockmech_fem = fem end

return fem
