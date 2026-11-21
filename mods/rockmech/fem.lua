-- rockmech/fem.lua
-- 開挖周圍的彈性應力場（純函式，不依賴引擎；也載入背景執行緒，見 femstress.lua）。
--
-- ## 模型
-- 每個岩石格是一個邊長 1 m 的 8 節點六面體元素（線彈性、均質、等向），空氣沒有勁度。
-- 滿格的碎石是軟的元素（job.soft，勁度 = 岩石 × job.soft_e）：沒有現地應力、不加重力，反力只來自岩壁收斂壓它
-- （等於開挖前就在那裡，同回採區充填的簡化）。碎石只能頂、不能拉：job.plastic.rubble_phi 有給時，碎石格走塑性迭代
-- （c = 0、φ = 顆粒流的殘餘摩擦角，加上主應力的拉力截斷），不會靠拉力、剪力掛在岩壁上；重量另外當荷重給（femstress.lua）。
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
-- job.press（可選）= {格, 方向 k, p, ...}：支護。格往 k（1..6 = +x −x +y −y +z −z）那一面受壓力 p（kPa），指向岩體。
-- job.soft（可選）= {[格] = true}：其中 solid 為 true 的格是碎石，job.soft_e = 勁度比例（預設 0.1）。
--   [格] = 數字：這格是木柱（timber.lua），勁度比例就是這個數（一個網格裡只有一種木柱勁度）。
--   碎石和木柱都沒有現地應力、不加重力，反力只來自岩壁收斂壓它（等於開挖前就在那裡）。
-- job.soil（可選）= {[格] = true}：土（表土）。勁度比例 job.soil_e（沒有就用 job.soft_e），跟岩石一樣有現地應力、受重力
--   （job.soft 裡也要有這一格）。
-- job.gam（可選）= {[格] = γ}：這一格的單位重（沒有就用 job.gamma）。
-- ## 輸出
-- {sxx, syy, szz, sxy, syz, szx（總應力，kPa）, u, iters, res（相對殘差）, ms}

local fem = {}

local E = 1e6        -- kPa；應力與 E 無關，只影響 Δu 的尺度

-- 單位立方體 8 節點元素的 Ke（節點 a = i + 2j + 4k；K[a][b] = {3×3 列展開}）
-- blend（可選）：剪力項減積分。全積分的元素彎曲時有假的剪應變（剪力鎖定），一層元素太少時梁太硬；
-- 剪力項改取格中心，留 blend 比例的全積分防止沙漏模態。
-- 拉力截斷：應力（壓為正：xx, yy, zz, xy, yz, zx）的主應力有比 −tol 更拉的，就把拉的主應力設成 0、方向不變，
-- 回傳截斷後的 6 個分量；沒有拉力回傳 nil。3×3 對稱矩陣用 Jacobi 旋轉求特徵值
local function no_tension(a1, a2, a3, a4, a5, a6, tol)
	local m = {{a1, a4, a6}, {a4, a2, a5}, {a6, a5, a3}}
	local v = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
	for _ = 1, 12 do
		local off = m[1][2] * m[1][2] + m[1][3] * m[1][3] + m[2][3] * m[2][3]
		if off <= 1e-14 * (m[1][1] * m[1][1] + m[2][2] * m[2][2] + m[3][3] * m[3][3]) + 1e-20 then break end
		for p = 1, 2 do for q = p + 1, 3 do
			local apq = m[p][q]
			if apq ~= 0 then
				local th = (m[q][q] - m[p][p]) / (2 * apq)
				local t = (th >= 0 and 1 or -1) / (math.abs(th) + math.sqrt(th * th + 1))
				local c = 1 / math.sqrt(t * t + 1)
				local s = t * c
				for k = 1, 3 do
					local x, y = m[k][p], m[k][q]
					m[k][p], m[k][q] = c * x - s * y, s * x + c * y
				end
				for k = 1, 3 do
					local x, y = m[p][k], m[q][k]
					m[p][k], m[q][k] = c * x - s * y, s * x + c * y
				end
				for k = 1, 3 do
					local x, y = v[k][p], v[k][q]
					v[k][p], v[k][q] = c * x - s * y, s * x + c * y
				end
			end
		end end
	end
	local l1, l2, l3 = m[1][1], m[2][2], m[3][3]
	if l1 >= -tol and l2 >= -tol and l3 >= -tol then return nil end
	l1, l2, l3 = math.max(0, l1), math.max(0, l2), math.max(0, l3)
	local function cmp(i, j) return v[i][1] * l1 * v[j][1] + v[i][2] * l2 * v[j][2] + v[i][3] * l3 * v[j][3] end
	return cmp(1, 1), cmp(2, 2), cmp(3, 3), cmp(1, 2), cmp(2, 3), cmp(3, 1)
end
fem.no_tension = no_tension

local function element_stiffness(nu, blend)
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
	local g0 = {}
	for a = 0, 7 do g0[a] = grad(a, 0.5, 0.5, 0.5) end
	local w = blend or 1
	-- 剪力項：S[p][q] = μ·g_a[q]·g_b[p]（p ≠ q）；μ·Σ_{r≠p} g_a[r]·g_b[r]（p = q）
	local function shear(ga, gb, p, q)
		if p ~= q then return mu * ga[q] * gb[p] end
		local v = 0
		for r = 1, 3 do
			if r ~= p then v = v + ga[r] * gb[r] end
		end
		return mu * v
	end
	for _, x in ipairs(gp) do for _, y in ipairs(gp) do for _, z in ipairs(gp) do
		local g = {}
		for a = 0, 7 do g[a] = grad(a, x, y, z) end
		for a = 0, 7 do for b = 0, 7 do
			local t = K[a][b]
			for p = 1, 3 do for q = 1, 3 do
				local v = lam * g[a][p] * g[b][q]
				if p == q then v = v + 2 * mu * g[a][p] * g[b][p] end
				v = v + w * shear(g[a], g[b], p, q) + (1 - w) * shear(g0[a], g0[b], p, q)
				t[(p - 1) * 3 + q] = t[(p - 1) * 3 + q] + v / 8
			end end
		end end
	end end end
	return K
end
fem.element_stiffness = element_stiffness

-- 一個節點周圍 8 格（位元 e = ex + 2ey + 4ez，該格在節點的 (ex−1, ey−1, ez−1) 位置）的組合 → 模版
-- {n, dx[], dy[], dz[], k[]（每鄰點 9 個）, d1, d2, d3（對角）}
-- soft（可選）：mask 裡哪幾格是軟的元素，勁度乘 ratio；post（可選）：哪幾格是木柱，勁度乘 pratio
-- 一般形式：elems[e] = {w（勁度比例）, Ke（該格的元素勁度）}，沒有就是空格
local function stencil_of(elems)
	local sum = {}
	for e = 0, 7 do
		local el = elems[e]
		if el then
			local w, Ke = el[1], el[2]
			local ex, ey, ez = e % 2, math.floor(e / 2) % 2, math.floor(e / 4)
			local a = (1 - ex) + 2 * (1 - ey) + 4 * (1 - ez)   -- 這個節點是該格的第 a 個角
			local ai, aj, ak = 1 - ex, 1 - ey, 1 - ez
			for b = 0, 7 do
				local bi, bj, bk = b % 2, math.floor(b / 2) % 2, math.floor(b / 4)
				local key = (bi - ai + 1) + 3 * (bj - aj + 1) + 9 * (bk - ak + 1)
				local s = sum[key]
				if not s then s = {0, 0, 0, 0, 0, 0, 0, 0, 0}; sum[key] = s end
				for q = 1, 9 do s[q] = s[q] + w * Ke[a][b][q] end
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
local function make_stencil(Ke, mask, soft, ratio, post, pratio, soilm, sratio)
	local elems = {}
	for e = 0, 7 do
		if math.floor(mask / 2 ^ e) % 2 == 1 then
			local w = post and math.floor(post / 2 ^ e) % 2 == 1 and pratio
				or soilm and math.floor(soilm / 2 ^ e) % 2 == 1 and sratio
				or soft and math.floor(soft / 2 ^ e) % 2 == 1 and ratio or 1
			elems[e] = {w, Ke}
		end
	end
	return stencil_of(elems)
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
	local Ke = element_stiffness(nu, job.blend)
	local lam = E * nu / ((1 + nu) * (1 - 2 * nu))
	local mu = E / (2 * (1 + nu))
	local soft, ratio = job.soft or {}, job.soft_e or 0.1
	local soil, sratio = job.soil or {}, job.soil_e or ratio
	local function w_of(c)    -- 這格的勁度比例（木柱、板樁、H 型鋼各自的數字）
		if soil[c] then return sratio end
		local s = soft[c]
		if not s then return 1 end
		return type(s) == "number" and s or ratio
	end
	-- 彎曲構件（job.bend[格]，鋼板樁）：一層 1 m 的元素彎曲，全積分會剪力鎖定（彎矩被假的剪應力吃掉、梁太硬），
	-- 改用剪力項減積分的元素（job.bend_blend，同粗網格的 coarse_blend）
	local bend = job.bend or {}
	local Ke_bend
	-- 材料編號：(勁度比例, 彎曲構件) → 1..63，模版用 8 格的編號組成的數字當鍵
	-- （以前只分 岩石／碎石／土／木柱 四類，木柱類共用一個勁度比例：板樁、H 型鋼、鋼支保在同一解裡會被當成同一個勁度）
	local mat_ids, mat_list, cell_mat = {}, {}, {}
	local function mat_of(c)
		local id = cell_mat[c]
		if id then return id end
		local w, b = w_of(c), bend[c] and true or false
		local k = w .. "|" .. tostring(b)
		id = mat_ids[k]
		if not id then
			id = #mat_list + 1
			assert(id < 64, "fem: too many materials")
			mat_ids[k] = id
			if b and not Ke_bend then Ke_bend = element_stiffness(nu, job.bend_blend or 0.1) end
			mat_list[id] = {w, b and Ke_bend or Ke}
		end
		cell_mat[c] = id
		return id
	end

	local function is_solid(x, y, z)
		if x < 0 or y < 0 or z < 0 or x >= nx or y >= ny or z >= nz then return false end
		return solid[1 + x + y * nx + z * nx * ny]
	end

	-- 模版（用到才算），這次網格的節點索引位移
	local stencils, offs = {}, {}
	local active, masks = {}, {}
	local na = 0
	for z = 1, Nz - 2 do for y = 1, Ny - 2 do for x = 1, Nx - 2 do
		local key, ids = 0, nil
		for e = 0, 7 do
			local ex, ey, ez = e % 2, math.floor(e / 2) % 2, math.floor(e / 4)
			local cx, cy, cz = x + ex - 1, y + ey - 1, z + ez - 1
			if is_solid(cx, cy, cz) then
				local id = mat_of(1 + cx + cy * nx + cz * nx * ny)
				key = key + id * 64 ^ e
				ids = ids or {}
				ids[e] = id
			end
		end
		if key > 0 then
			na = na + 1
			active[na] = x + y * sy + z * sz
			masks[na] = key
			if not stencils[key] then
				local elems = {}
				for e, id in pairs(ids) do elems[e] = mat_list[id] end
				local st = stencil_of(elems)
				stencils[key] = st
				local o = {}
				for s = 1, st.n do o[s] = (st.dx[s] + st.dy[s] * sy + st.dz[s] * sz) * 3 end
				offs[key] = o
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
		if solid[c] and (not soft[c] or (job.soil and job.soil[c])) then
			local txx, tyy, tzz, txz = -job.sxx[c], -job.syy[c], -job.szz[c], -job.sxz[c]
			local g8 = (job.gam and job.gam[c] or gam) / 8
			for a = 1, 8 do
				local cr = cs[a]
				local n3 = ((cx + cr[1]) + (cy + cr[2]) * sy + (cz + cr[3]) * sz) * 3
				local gx, gy, gz = cr[4], cr[5], cr[6]
				f[n3 + 1] = f[n3 + 1] - (txx * gx + txz * gz)
				f[n3 + 2] = f[n3 + 2] - (tyy * gy) - g8
				f[n3 + 3] = f[n3 + 3] - (txz * gx + tzz * gz)
			end
		end
	end end end

	-- 支護：面上的壓力平均分給面的 4 個節點，方向指向岩體
	local press = job.press
	if press then
		for i = 1, #press, 3 do
			local c, k, pr = press[i], press[i + 1], press[i + 2]
			if solid[c] then
				local r = c - 1
				local cx, cy, cz = r % nx, math.floor(r / nx) % ny, math.floor(r / (nx * ny))
				local axis, side = math.ceil(k / 2), k % 2      -- side 1：往正方向的面
				for a = 1, 8 do
					local cr = cs[a]
					if cr[axis] == side then
						local n3 = ((cx + cr[1]) + (cy + cr[2]) * sy + (cz + cr[3]) * sz) * 3
						f[n3 + axis] = f[n3 + axis] + (side == 1 and -pr or pr) / 4
					end
				end
			end
		end
	end

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

	-- 共軛梯度：解 K·u = fv（u 就地更新，從目前的 u 出發）。回傳 迭代次數, 相對殘差
	local tol = job.tol or 1e-3
	local function pcg(fv, max_iter)
	-- r = f − K·u（只有自由節點）
	matvec(u, q)
	local rz, r0, ri = 0, 0, 0
	for i = 1, na do
		local idx, m = active[i] * 3, masks[i]
		local st = stencils[m]
		for d = 1, 3 do
			local j = idx + d
			local v = fv[j] - q[j]
			r[j] = v
			local zv = v / (d == 1 and st.d1 or d == 2 and st.d2 or st.d3)
			z_[j] = zv
			p[j] = zv
			rz = rz + v * zv
			r0 = r0 + fv[j] * fv[j]
			ri = ri + v * v
		end
	end
	r0 = math.sqrt(math.max(r0, ri))     -- 只有外緣給定位移時 f = 0
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
	return iters, rel
	end
	local iters, rel = pcg(f, job.max_iter or 1500)

	-- 土的塑性（job.plastic = {c（kPa）, phi（°）, iters（迭代上限）}，job.soil 的格）：初始應力法
	-- （Smith & Griffiths 的黏塑性迭代，勁度矩陣不變）。每一輪算土格中心的應力，超出破壞面的部分拉回破壞面，
	-- 拉回的量累積成「塑性應力」P（壓為正），當成多出來的初始應力加進外力，從上一輪的位移再解一次。
	-- 破壞面：Drucker-Prager，配 Mohr-Coulomb 的平面應變（√J2 ≤ α·I1 + k，α = tanφ / √(9 + 12 tan²φ)、k = 3c / √(…)，I1 = 3p）：
	-- 靜止土壓 K0 = 1 − sinφ 的狀態在面內；錐頂 p = −k/α 就是張力上限（c·cot φ 的同級）。偏應力照比例縮回錐面（徑向回映），
	-- 超過錐頂就整個拉到錐頂（土不能再受拉）。
	-- 結果：牆後的土到了強度上限就維持在上限推牆（主動土壓）、被擠的土最多頂到被動土壓。
	-- 迭代上限到了還有格子在超出（res.flow：超出的比例）→ 形成機構、還在流動（femstress.lua 拿來判定破壞）
	-- 滿格碎石（job.soft 是 true、不是土）：同一個迴圈，c = 0、φ = plastic.rubble_phi（顆粒流的殘餘摩擦角），
	-- 再加上拉力截斷：主應力是拉的就設成 0（碎石只能頂、不能拉，哪個方向都一樣）
	local P, flow, piters = nil, nil, 0
	local plastic = job.plastic
	local rub = {}
	if plastic and plastic.rubble_phi then
		for c, s in pairs(soft) do
			if s == true and not soil[c] and solid[c] then rub[c] = true end
		end
	end
	if plastic and ((job.soil and next(job.soil)) or next(rub)) then
		local function dp(phi, c)
			local tp = math.tan(math.rad(phi))
			local den = math.sqrt(9 + 12 * tp * tp)
			return 3 * tp / den, 3 * c / den     -- alpha 已乘 3：√J2 ≤ α_I1·I1 + k = (3α_I1)·p + k
		end
		local alpha_s, kc_s = dp(plastic.phi or 30, plastic.c or 0)
		local alpha_r = plastic.rubble_phi and dp(plastic.rubble_phi, 0)
		-- 應變軟化：降伏過的土格（有塑性應力 P）凝聚力降到殘餘值 c_res × c（膠結破壞），φ 不變
		local kres_s = kc_s * math.max(0, math.min(1, plastic.c_res or 1))
		local cells = {}
		for c in pairs(job.soil or {}) do if solid[c] then cells[#cells + 1] = c end end
		for c in pairs(rub) do cells[#cells + 1] = c end
		table.sort(cells)
		P = {}
		local fv = {}
		local function cell_strain(c)
			local k = c - 1
			local cx, cy, cz = k % nx, math.floor(k / nx) % ny, math.floor(k / (nx * ny))
			local exx, eyy, ezz, gxy, gyz, gzx = 0, 0, 0, 0, 0, 0
			for a = 1, 8 do
				local cr = cs[a]
				local n3 = ((cx + cr[1]) + (cy + cr[2]) * sy + (cz + cr[3]) * sz) * 3
				local gx, gy, gz = cr[4], cr[5], cr[6]
				local ux, uy, uz = u[n3 + 1], u[n3 + 2], u[n3 + 3]
				exx = exx + gx * ux; eyy = eyy + gy * uy; ezz = ezz + gz * uz
				gxy = gxy + gy * ux + gx * uy; gyz = gyz + gz * uy + gy * uz; gzx = gzx + gx * uz + gz * ux
			end
			return cx, cy, cz, exx, eyy, ezz, gxy, gyz, gzx
		end
		-- 土照舊迭代 plastic.iters 輪（到上限還在流動 = 破壞，femstress.lua 的判定）；之後只剩碎石沒收斂的話，
		-- 只對碎石繼續到 plastic.rubble_iters 輪（碎石的拉力截斷收斂得慢，土格的塑性應力不再動）
		local soil_iters = plastic.iters or 15
		local total = math.max(soil_iters, next(rub) and (plastic.rubble_iters or soil_iters) or 0)
		for it = 1, total do
			piters = it
			local over = {}
			local any = false
			local soil_phase = it <= soil_iters
			for _, c in ipairs(cells) do
				if not soil_phase and not rub[c] then goto next_cell end
				do
				local _, _, _, exx, eyy, ezz, gxy, gyz, gzx = cell_strain(c)
				local w = w_of(c)
				local tr = w * lam * (exx + eyy + ezz)
				local pc = P[c]
				local s1 = job.sxx[c] - (tr + 2 * w * mu * exx) + (pc and pc[1] or 0)
				local s2 = job.syy[c] - (tr + 2 * w * mu * eyy) + (pc and pc[2] or 0)
				local s3 = job.szz[c] - (tr + 2 * w * mu * ezz) + (pc and pc[3] or 0)
				local s4 = -w * mu * gxy + (pc and pc[4] or 0)
				local s5 = -w * mu * gyz + (pc and pc[5] or 0)
				local s6 = job.sxz[c] - w * mu * gzx + (pc and pc[6] or 0)
				local pm = (s1 + s2 + s3) / 3
				local d1, d2, d3 = s1 - pm, s2 - pm, s3 - pm
				local sq = math.sqrt(0.5 * (d1 * d1 + d2 * d2 + d3 * d3) + s4 * s4 + s5 * s5 + s6 * s6)
				local isr = rub[c]
				local alpha, kc = alpha_s, kc_s
				local kk = pc and kres_s or kc_s
				if isr then alpha, kc, kk = alpha_r, 0, 0 end
				local lim = alpha * pm + kk
				local scale = alpha * math.abs(pm) + kc + 0.1
				local r1, r2, r3, r4, r5, r6
				local excess = 0
				if sq > lim + 0.01 * scale then
					if lim <= 0 then
						local pa = alpha > 1e-9 and -kk / alpha or 0      -- 錐頂（張力上限）
						r1, r2, r3, r4, r5, r6 = pa, pa, pa, 0, 0, 0
					else
						local fr = lim / sq
						r1, r2, r3 = pm + d1 * fr, pm + d2 * fr, pm + d3 * fr
						r4, r5, r6 = s4 * fr, s5 * fr, s6 * fr
					end
					excess = (sq - math.max(lim, 0)) / scale
				end
				if isr then          -- 碎石：拉力截斷（主應力 < 0 → 0）
					local t1, t2, t3, t4, t5, t6 = no_tension(r1 or s1, r2 or s2, r3 or s3, r4 or s4, r5 or s5, r6 or s6, 0.5)
					if t1 then
						r1, r2, r3, r4, r5, r6 = t1, t2, t3, t4, t5, t6
						if excess == 0 then excess = 0.01 end
					end
				end
				if r1 then
					if not pc then pc = {0, 0, 0, 0, 0, 0}; P[c] = pc end
					pc[1], pc[2], pc[3] = pc[1] - (s1 - r1), pc[2] - (s2 - r2), pc[3] - (s3 - r3)
					pc[4], pc[5], pc[6] = pc[4] - (s4 - r4), pc[5] - (s5 - r5), pc[6] - (s6 - r6)
					over[c] = excess
					any = true
				end
				end
				::next_cell::
			end
			if soil_phase then flow = over end
			if not any then
				if soil_phase then flow = nil end
				break
			end
			-- 外力 = 原本的 + 塑性應力當初始應力（σ0 在 f 裡是 +σ0·∂N/∂x，同一個寫法）
			for i = 1, ndof do fv[i] = f[i] end
			for c, pc in pairs(P) do
				local k = c - 1
				local cx, cy, cz = k % nx, math.floor(k / nx) % ny, math.floor(k / (nx * ny))
				for a = 1, 8 do
					local cr = cs[a]
					local n3 = ((cx + cr[1]) + (cy + cr[2]) * sy + (cz + cr[3]) * sz) * 3
					local gx, gy, gz = cr[4], cr[5], cr[6]
					fv[n3 + 1] = fv[n3 + 1] + pc[1] * gx + pc[4] * gy + pc[6] * gz
					fv[n3 + 2] = fv[n3 + 2] + pc[4] * gx + pc[2] * gy + pc[5] * gz
					fv[n3 + 3] = fv[n3 + 3] + pc[6] * gx + pc[5] * gy + pc[3] * gz
				end
			end
			local it2, rel2 = pcg(fv, plastic.pcg_iter or 300)
			iters, rel = iters + it2, rel2
		end
	end

	-- 每格中心的總應力（壓為正）。job.lean：只回傳位移 u（背景執行緒用：少傳 6 個陣列回主執行緒，
	-- 主執行緒用到哪一格再算，見 fem.lazy_stress）。P：土的塑性應力（有才有），flow：迭代上限到了還在流動的土格
	if job.lean then
		return {u = u, iters = iters, res = rel, ms = (os.clock() - t_start) * 1000, P = P, flow = flow, piters = piters}
	end
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
			local w = w_of(c)
			local tr = w * lam * (exx + eyy + ezz)
			out.sxx[c] = job.sxx[c] - (tr + 2 * w * mu * exx)
			out.syy[c] = job.syy[c] - (tr + 2 * w * mu * eyy)
			out.szz[c] = job.szz[c] - (tr + 2 * w * mu * ezz)
			out.sxy[c] = -w * mu * gxy
			out.syz[c] = -w * mu * gyz
			out.szx[c] = job.sxz[c] - w * mu * gzx
			local pc = P and P[c]
			if pc then
				out.sxx[c], out.syy[c], out.szz[c] = out.sxx[c] + pc[1], out.syy[c] + pc[2], out.szz[c] + pc[3]
				out.sxy[c], out.syz[c], out.szx[c] = out.sxy[c] + pc[4], out.syz[c] + pc[5], out.szx[c] + pc[6]
			end
		end
	end end end
	out.P, out.flow, out.piters = P, flow, piters
	out.ms = (os.clock() - t_start) * 1000
	return out
end

-- 子模型：先解粗網格（job.coarse，元素邊長 h，原點比細網格的原點多 ox, oy, oz 公尺），
-- 把它的位移內插到細網格外緣當邊界條件，再解細網格。範圍比開口小時也看得到整個開口。
-- 粗網格的空節點（周圍 8 格都不是岩石）沒有解，不參與內插。
-- res.hot：粗網格上拉力最大的頂板格（最多 16 個，{x, y, z, σ1, σ3}，kPa），細網格範圍外的頂板也看得到。
-- 天然地形（開挖前）的工作：job.nat = {solid, soft, soil, gam, sxx, syy, szz, sxz}，其他照 job
function fem.natural_job(job)
	local n = job.nat
	if not n then return nil end
	return {nx = job.nx, ny = job.ny, nz = job.nz, solid = n.solid, soft = n.soft, soil = n.soil, gam = n.gam,
		sxx = n.sxx, syy = n.syy, szz = n.szz, sxz = n.sxz, gamma = job.gamma, nu = job.nu, tol = job.tol,
		max_iter = job.max_iter, soft_e = job.soft_e, soil_e = job.soil_e, blend = job.blend, u0 = n.u0, press = n.press,
		plastic = job.plastic,
		coarse = job.coarse}     -- 外緣用同一個粗網格的解：兩個解只差在局部的開挖（外緣不同的話，陡的谷地兩個解差很多）
end

-- job.nat 有給：另外解一次天然地形（外緣跟現況一樣用粗網格的解），放在 res.nat。用來分辨「開挖造成的破壞」和天然就有的應力集中
local solve_nested_inner
function fem.solve_nested(job)
	fem.unpack_s0(job)
	local nj = fem.natural_job(job)
	local nres = nj and solve_nested_inner(nj)
	local res = solve_nested_inner(job)
	if nres then
		res.nat = nres
		res.ms = res.ms + nres.ms
	end
	return res
end
solve_nested_inner = function(job)
	local cj = job.coarse
	if not cj then return fem.solve(job) end
	local cres = fem.solve(cj)
	local hot = {}
	local cn, cn2 = cj.nx, cj.nx * cj.ny
	for z = 4, cj.nz - 5 do for y = 2, cj.ny - 3 do for x = 4, cj.nx - 5 do     -- 外圈 Δu = 0，應力是假的
		local c = 1 + x + y * cn + z * cn2
		if cj.solid[c] and not cj.solid[c - cn] and not (cj.soft and cj.soft[c]) then
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
fem.solve_sub = function(job) return solve_nested_inner(fem.unpack_s0(job)) end      -- 只解這一個（有粗網格就先解粗網格）

-- 對稱 3×3 應力張量的主應力（壓為正）：回傳 σ1 ≥ σ2 ≥ σ3
-- 臨空面的邊界條件：法向應力 = 支護壓力 p、面上的剪應力 = 0（一階元素外插到面上不滿足，
-- 會差一個應力梯度，看起來像垂直岩面的拉力）。s = {sxx, syy, szz, sxy, syz, szx}，axis 1..3 = 面的法向
function fem.free_face(s, axis, p)
	s[axis] = p
	if axis == 1 then s[4], s[6] = 0, 0
	elseif axis == 2 then s[4], s[5] = 0, 0
	else s[5], s[6] = 0, 0 end
	return s
end

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
	-- 只平均同一類的格：岩石（1）或土（2）；碎石、木柱（0）不算
	local function cls(c)
		if job.soil and job.soil[c] then return 2 end
		return (job.soft and job.soft[c]) and 0 or 1
	end
	local k0 = cls(1 + x + y * nx + z * nx * ny)
	if k0 == 0 then k0 = 1 end
	for dz = -r, r do for dy = -r, r do for dx = -r, r do
		local cx, cy, cz = x + dx, y + dy, z + dz
		if cx >= 0 and cy >= 0 and cz >= 0 and cx < nx and cy < ny and cz < nz then
			local c = 1 + cx + cy * nx + cz * nx * ny
			if solid[c] and cls(c) == k0 then
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
	local sf = job.soft and job.soft[c]
	local w = job.soil and job.soil[c] and (job.soil_e or job.soft_e or 0.1)
		or not sf and 1 or type(sf) == "number" and sf or (job.soft_e or 0.1)      -- 勁度比例（土、碎石較軟）
	lam, mu = w * lam, w * mu
	local tr = lam * (exx + eyy + ezz)
	local pc = res.P and res.P[c]       -- 土的塑性應力（fem.solve 的 job.plastic）
	if pc then
		return job.sxx[c] - (tr + 2 * mu * exx) + pc[1], job.syy[c] - (tr + 2 * mu * eyy) + pc[2],
			job.szz[c] - (tr + 2 * mu * ezz) + pc[3], -mu * gxy + pc[4], -mu * gyz + pc[5], job.sxz[c] - mu * gzx + pc[6]
	end
	return job.sxx[c] - (tr + 2 * mu * exx), job.syy[c] - (tr + 2 * mu * eyy), job.szz[c] - (tr + 2 * mu * ezz),
		-mu * gxy, -mu * gyz, job.sxz[c] - mu * gzx
end

-- 傳到背景執行緒的工作只帶 σyy（= σv），σxx、σzz、σxz 在背景照同一個公式算回來（少傳 3 個陣列）。
-- job.s0p = {KH, Kh, sH0, sh0（MPa）, az（σH 方位，度）, k0s（土的 K0）}：
--   job.soil 的格：σxx = σzz = K0·σv、σxz = 0；其他格：femstress.lua 的 in_situ（σv ≤ 0 → 全部 0，開挖過的格、碎石本來就是 0）
function fem.pack_s0(job, p)
	local t = {}
	for k, v in pairs(job) do t[k] = v end
	t.sxx, t.szz, t.sxz, t.s0p = nil, nil, nil, p
	return t
end
function fem.unpack_s0(job)
	if not job or not job.s0p or job.sxx then return job end
	local p = job.s0p
	local th = math.rad(p.az or 0)
	local s2, c2, sc = math.sin(th) ^ 2, math.cos(th) ^ 2, math.sin(th) * math.cos(th)
	local syy, soil = job.syy, job.soil or {}
	local sxx, szz, sxz = {}, {}, {}
	for c = 1, job.nx * job.ny * job.nz do
		local sv = syy[c] or 0
		if soil[c] then
			sxx[c], szz[c], sxz[c] = p.k0s * sv, p.k0s * sv, 0
		elseif sv <= 0 then
			sxx[c], szz[c], sxz[c] = 0, 0, 0
		else
			local svm = sv / 1000
			local sH, sh = (p.KH * svm + p.sH0) * 1000, (p.Kh * svm + p.sh0) * 1000
			sxx[c] = s2 * sH + c2 * sh
			szz[c] = c2 * sH + s2 * sh
			sxz[c] = (sH - sh) * sc
		end
	end
	job.sxx, job.szz, job.sxz = sxx, szz, sxz
	if job.coarse then fem.unpack_s0(job.coarse) end
	return job
end

-- 只有位移的結果（job.lean）：補上 sxx … szx 六個表，用到哪一格才從 u 算那一格的格中心應力（跟 fem.solve 一樣），算過的記住。
-- 不是岩石（job.solid）的格是 0
local SKEYS = {"sxx", "syy", "szz", "sxy", "syz", "szx"}
function fem.lazy_stress(job, res)
	if not res or res.sxx then return res end
	local nx, ny = job.nx, job.ny
	local tabs = {}
	local function fill(c)
		local v1, v2, v3, v4, v5, v6 = 0, 0, 0, 0, 0, 0
		if job.solid[c] then
			local k = c - 1
			local x, y, z = k % nx, math.floor(k / nx) % ny, math.floor(k / (nx * ny))
			v1, v2, v3, v4, v5, v6 = fem.point_stress(job, res, x, y, z, 0.5, 0.5, 0.5)
		end
		rawset(tabs[1], c, v1); rawset(tabs[2], c, v2); rawset(tabs[3], c, v3)
		rawset(tabs[4], c, v4); rawset(tabs[5], c, v5); rawset(tabs[6], c, v6)
	end
	for i, key in ipairs(SKEYS) do
		local t = setmetatable({}, {__index = function(t, c)
			if type(c) ~= "number" then return nil end
			fill(c)
			return rawget(t, c)
		end})
		tabs[i] = t
		res[key] = t
	end
	return res
end

-- 背景執行緒（core.register_async_dofile）裡用 core.rockmech_fem 取得
if core then core.rockmech_fem = fem end

return fem
