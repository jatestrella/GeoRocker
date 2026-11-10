-- rockmech/dfn.lua
-- 離散裂隙網路（DFN, discrete fracture network）：每組節理是一群有限大小的圓盤（Baecher 模型）。
-- 純函式，不依賴引擎；結果只由世界種子決定，不需要存檔。
--
-- 每組節理的參數（config 的 joint_sets，rockmech_joint_dfn_i）：
--   dip, dipdir   平均位態（圓盤極點的平均方向）
--   kappa         Fisher 集中度 κ：越大位態越一致（κ ≈ 20 散開約 ±18°，κ ≈ 100 約 ±8°）
--   rmin, rmax    圓盤半徑的上下限 (m)
--   a             半徑的冪律指數：數量 ∝ r^−a（a 越大小裂隙越多）
--   spacing       平均間距 (m)：裂隙強度 P32 = 1 / spacing（每立方公尺的裂隙面積，m²/m³）
-- 範圍（可選，可以組合；都沒有 = 全圖）：
--   zone          只在第幾個地質區（opts.where(x, y, z) 回傳的編號）
--   lith          只在這些岩性裡（{sandstone = true, ...}；opts.lith_at(x, y, z) → 岩性名稱）。
--                 圓盤碰到別的岩層就停（層控節理）
--   box           只在這個範圍裡 {x1, y1, z1, x2, y2, z2}（含邊界）
--   同一個地方可以有好幾組各自的參數：例如同一種岩性，在兩個範圍各一組不同位態的節理
--   lith_p32      層控節理：各岩性的強度倍率 {sandstone = 0.7, shale = 1.5}（沒列的岩性 = 1）。
--                 每片圓盤屬於圓心所在的岩層，這一層的倍率決定留不留（P32 = 倍率 / spacing），
--                 而且碰到層面就停。同一組位態，薄而軟的岩層節理比較密
--
-- 產生：世界切成 C×C×C 的粗格（預設 16，對齊 mapblock）。每格、每組的圓盤數是 Poisson(λ)，
--   λ = P32 · C³ / (π·E[r²])；圓心均勻分布、極點 Fisher 抽樣、半徑冪律抽樣，亂數由 (種子, 組, 格) 決定。
--
-- 節理面判定（與舊的平面模型同一個定義）：格 p 與 p + e_axis 之間的面是節理
--   ⇔ 兩格中心連線穿過某個圓盤（交點離圓心 ≤ r），且兩格都在該組的地質區裡。
-- 每個粗格第一次查詢時把所有圓盤「點陣化」成面表（快取），之後查詢是 O(1)。

local dfn = {}

local floor, sqrt, abs, log, exp, cos, sin, pi = math.floor, math.sqrt, math.abs, math.log, math.exp, math.cos, math.sin, math.pi
local TWO32 = 4294967296

---------------------------------------------------------------------------
-- 亂數（由 joints.mix 串成的序列）
---------------------------------------------------------------------------
local function rng(mix, h)
	local s = h
	return function()
		s = mix((s + 0x9e3779b9) % TWO32)
		return (s + 0.5) / TWO32          -- (0, 1)
	end
end

local function poisson(u, lambda)
	if lambda <= 0 then return 0 end
	if lambda > 400 then          -- 常態近似
		local g = sqrt(-2 * log(u())) * cos(2 * pi * u())
		return math.max(0, floor(lambda + g * sqrt(lambda) + 0.5))
	end
	local L, k, p = exp(-lambda), 0, 1
	repeat k = k + 1; p = p * u() until p <= L
	return k - 1
end

-- 截斷冪律 f(r) ∝ r^−a，r ∈ [rmin, rmax]
local function E_r2(rmin, rmax, a)
	if rmax <= rmin then return rmin * rmin end
	local function I(p)            -- ∫ r^p dr
		if abs(p + 1) < 1e-9 then return log(rmax / rmin) end
		return (rmax ^ (p + 1) - rmin ^ (p + 1)) / (p + 1)
	end
	return I(2 - a) / I(-a)
end
dfn.E_r2 = E_r2

local function sample_r(u, rmin, rmax, a)
	if rmax <= rmin then return rmin end
	local v = u()
	if abs(a - 1) < 1e-9 then return rmin * (rmax / rmin) ^ v end
	local b = 1 - a
	local lo, hi = rmin ^ b, rmax ^ b
	return (lo + v * (hi - lo)) ^ (1 / b)
end
dfn.sample_r = sample_r

-- Fisher 分布：以 n0 為平均極點、集中度 κ
local function sample_fisher(u, n0, kappa)
	if not kappa or kappa >= 1e4 then return n0.x, n0.y, n0.z end
	local v1, v2 = u(), u()
	-- cos θ = 1 + ln(v + (1 − v)·e^(−2κ)) / κ（κ → 0 是均勻分布）
	local w = kappa < 1e-6 and 2 * v1 - 1 or 1 + log(v1 + (1 - v1) * exp(-2 * kappa)) / kappa
	if w > 1 then w = 1 elseif w < -1 then w = -1 end
	local ph = 2 * pi * v2
	-- 與 n0 垂直的正交基底
	local ax, ay, az = n0.x, n0.y, n0.z
	local e1x, e1y, e1z
	if abs(ay) < 0.9 then e1x, e1y, e1z = az, 0, -ax      -- n0 × (0,1,0)
	else e1x, e1y, e1z = 0, -az, ay end                    -- n0 × (1,0,0)
	local l = sqrt(e1x * e1x + e1y * e1y + e1z * e1z)
	e1x, e1y, e1z = e1x / l, e1y / l, e1z / l
	local e2x, e2y, e2z = ay * e1z - az * e1y, az * e1x - ax * e1z, ax * e1y - ay * e1x
	local s = sqrt(1 - w * w)
	local c1, c2 = s * cos(ph), s * sin(ph)
	local nx, ny, nz = w * ax + c1 * e1x + c2 * e2x, w * ay + c1 * e1y + c2 * e2y, w * az + c1 * e1z + c2 * e2z
	if ny < 0 then nx, ny, nz = -nx, -ny, -nz end           -- 極點朝上
	return nx, ny, nz
end
dfn.sample_fisher = sample_fisher

---------------------------------------------------------------------------
-- DFN 物件
---------------------------------------------------------------------------
-- sets：joints.prepare 之後的組（需要 id、n、spacing、kappa、rmin、rmax、a、zone）
-- opts：{cell = 16, mix = joints.mix, hash = joints.hash, where = function(x, y, z) → 區號或 nil,
--        lith_at = function(x, y, z) → 岩性名稱, cache = 96}
function dfn.new(sets, seed, opts)
	opts = opts or {}
	local C = opts.cell or 16
	local D = {sets = sets, seed = seed, C = C, where = opts.where, lith_at = opts.lith_at, mix = opts.mix, hash = opts.hash,
		cache = opts.cache or 96, nid = 0}
	local rmax = 0
	for i, js in ipairs(sets) do
		js.rmin = math.max(0.5, js.rmin or 1)
		js.rmax = math.max(js.rmin, js.rmax or 10)
		js.a = js.a or 3.5
		js.P32 = 1 / math.max(0.05, js.spacing or 3)
		js.lambda = js.P32 * C * C * C / (pi * E_r2(js.rmin, js.rmax, js.a))
		if js.rmax > rmax then rmax = js.rmax end
		js.reach = math.ceil((js.rmax + 1) / C)
		-- 層控：先照最大的倍率產生，再依圓心岩層的倍率篩掉
		js.p32max = 1
		if js.lith_p32 and opts.lith_at then
			for _, m in pairs(js.lith_p32) do if m > js.p32max then js.p32max = m end end
		end
		-- 這一組有沒有範圍限制（沒有對應查詢函式的條件不算）
		js.ranged = (js.box ~= nil) or (js.zone ~= nil and opts.where ~= nil)
			or ((js.lith ~= nil or js.lith_p32 ~= nil) and opts.lith_at ~= nil)
	end
	D.rmax = rmax
	D.reach = math.ceil((rmax + 1) / C)
	-- 兩代快取：新的一代滿了就把舊的丟掉
	local function cache2(limit)
		local cur, old, n = {}, {}, 0
		return function(key, make)
			local v = cur[key]
			if v then return v end
			v = old[key] or make()
			cur[key] = v
			n = n + 1
			if n >= limit then old, cur, n = cur, {}, 0 end
			return v
		end
	end
	D.gen_cache = cache2(D.cache * 32)      -- 一個粗格、一組一筆
	D.touch_cache = cache2(D.cache)
	D.face_cache = cache2(D.cache)
	return setmetatable(D, {__index = dfn})
end

local function key3(x, y, z) return x .. "," .. y .. "," .. z end

-- 粗格 (cx, cy, cz) 裡產生的圓盤（圓心在這一格），所有組
function dfn:generated(cx, cy, cz)
	local out = {}
	for i = 1, #self.sets do
		for _, d in ipairs(self:generated_set(cx, cy, cz, i)) do out[#out + 1] = d end
	end
	return out
end

-- 粗格 (cx, cy, cz) 裡第 i 組的圓盤
function dfn:generated_set(cx, cy, cz, i)
	return self.gen_cache(key3(cx, cy, cz) .. "," .. i, function()
		local C, out = self.C, {}
		local x0, y0, z0 = cx * C - 0.5, cy * C - 0.5, cz * C - 0.5
		local where, lith_at = self.where, self.lith_at
		local js = self.sets[i]
		do
			local skip = false
			local B = js.box
			if B then
				local e = js.rmax + 1
				skip = x0 + C + e < B[1] or x0 - e > B[4] or y0 + C + e < B[2] or y0 - e > B[5]
					or z0 + C + e < B[3] or z0 - e > B[6]
			end
			if not skip and js.zone and where then
				-- 外擴 rmax 的盒子 8 個角都在同一個別的區 → 這一組在這裡不會有任何節理面
				local e, first, same = js.rmax + 1, nil, true
				for _, px in ipairs({x0 - e, x0 + C + e}) do for _, pz in ipairs({z0 - e, z0 + C + e}) do
					local w = where(px, y0, pz)
					if w == nil then same = false end
					if first == nil then first = w elseif w ~= first then same = false end
				end end
				skip = same and first ~= js.zone
			end
			if not skip then
				local u = rng(self.mix, self.hash(self.seed, js.id, cx, cy, cz, 0xD15C))
				local bound = js.lith_p32 and lith_at
				local n = poisson(u, js.lambda * js.p32max)
				for k = 1, n do
					local px, py, pz = x0 + u() * C, y0 + u() * C, z0 + u() * C
					local nx, ny, nz = sample_fisher(u, js.n, js.kappa)
					local r = sample_r(u, js.rmin, js.rmax, js.a)
					local keep, li = true, nil
					if bound then
						li = lith_at(floor(px + 0.5), floor(py + 0.5), floor(pz + 0.5))
						keep = u() * js.p32max < (js.lith_p32[li] or 1)
					end
					if keep then
						out[#out + 1] = {x = px, y = py, z = pz, nx = nx, ny = ny, nz = nz,
							d = nx * px + ny * py + nz * pz, r = r, set = i, ranged = js.ranged, lith = li,
							id = self.hash(cx, cy, cz, i, k) % 100000}
					end
				end
			end
		end
		return out
	end)
end

-- 會碰到粗格 (cx, cy, cz) 的圓盤（盒子外擴 1 格：面的另一側、方塊的半格）
function dfn:touching(cx, cy, cz)
	return self.touch_cache(key3(cx, cy, cz), function()
		local C, out = self.C, {}
		local bx0, by0, bz0 = cx * C - 1, cy * C - 1, cz * C - 1
		local bx1, by1, bz1 = bx0 + C + 1, by0 + C + 1, bz0 + C + 1
		for i, js in ipairs(self.sets) do
		local R = js.reach
		for gx = cx - R, cx + R do for gy = cy - R, cy + R do for gz = cz - R, cz + R do
			for _, d in ipairs(self:generated_set(gx, gy, gz, i)) do
				-- 圓心到盒子的距離 ≤ r
				local dx = d.x < bx0 and bx0 - d.x or (d.x > bx1 and d.x - bx1 or 0)
				local dy = d.y < by0 and by0 - d.y or (d.y > by1 and d.y - by1 or 0)
				local dz = d.z < bz0 and bz0 - d.z or (d.z > bz1 and d.z - bz1 or 0)
				if dx * dx + dy * dy + dz * dz <= d.r * d.r then
					-- 平面穿過盒子
					local cxm, cym, czm = (bx0 + bx1) / 2, (by0 + by1) / 2, (bz0 + bz1) / 2
					local h = (C + 2) / 2
					local f = d.nx * cxm + d.ny * cym + d.nz * czm - d.d
					if abs(f) <= h * (abs(d.nx) + abs(d.ny) + abs(d.nz)) then out[#out + 1] = d end
				end
			end
		end end end
		end
		return out
	end)
end

local OTHER = {{2, 3}, {1, 3}, {1, 2}}

-- 圓盤 d 是否切過格 p 與 p + e_axis 之間的面（兩格中心連線與圓盤的交點離圓心 ≤ r，且兩格都在 d 的區裡）
function dfn:crosses(d, x, y, z, axis)
	local p = {x, y, z}
	local n = {d.nx, d.ny, d.nz}
	local na = n[axis]
	if abs(na) < 1e-9 then return false end
	local u, v = OTHER[axis][1], OTHER[axis][2]
	local t = (d.d - n[u] * p[u] - n[v] * p[v]) / na
	if floor(t) ~= p[axis] then return false end
	local q = {x, y, z}
	q[axis] = t
	local dx, dy, dz = q[1] - d.x, q[2] - d.y, q[3] - d.z
	if dx * dx + dy * dy + dz * dz > d.r * d.r then return false end
	if d.ranged then
		local e = {0, 0, 0}
		e[axis] = 1
		local js = self.sets[d.set]
		if not self:inside(js, x, y, z, nil, d) or not self:inside(js, x + e[1], y + e[2], z + e[3], nil, d) then return false end
	end
	return true
end

-- 格 (x, y, z) 在不在 js 的範圍裡（d：層控圓盤還要在同一層）。info(x, y, z) → 區號、岩性（可選，給快取用）
function dfn:inside(js, x, y, z, info, d)
	local B = js.box
	if B and (x < B[1] or x > B[4] or y < B[2] or y > B[5] or z < B[3] or z > B[6]) then return false end
	local dl = d and d.lith
	local need_l = self.lith_at and (js.lith or dl)
	if (js.zone and self.where) or need_l then
		local zn, li
		if info then zn, li = info(x, y, z)
		else
			zn = js.zone and self.where and self.where(x, y, z)
			li = need_l and self.lith_at(x, y, z)
		end
		if js.zone and self.where and zn ~= js.zone then return false end
		if js.lith and self.lith_at and not js.lith[li] then return false end
		if dl and li ~= dl then return false end
	end
	return true
end

-- 每格的區號、岩性快取（一次點陣化或畫一個區塊用）
function dfn:info_cache()
	local zc, lc = {}, {}
	local where, lith_at = self.where, self.lith_at
	return function(x, y, z)
		local k = x .. "," .. y .. "," .. z
		local zn, li = zc[k], lc[k]
		if zn == nil then zn = where and where(x, y, z) or false; zc[k] = zn end
		if li == nil then li = lith_at and lith_at(x, y, z) or false; lc[k] = li end
		return zn, li
	end
end

-- 粗格的面表：face[局部索引] = 圓盤（同一個面有幾組時取組號最小的）
function dfn:face_map(cx, cy, cz)
	return self.face_cache(key3(cx, cy, cz), function()
		local C, sets = self.C, self.sets
		local base = {cx * C, cy * C, cz * C}
		local faces = {}
		local info = self:info_cache()
		for _, d in ipairs(self:touching(cx, cy, cz)) do
			local n = {d.nx, d.ny, d.nz}
			local c = {d.x, d.y, d.z}
			for axis = 1, 3 do
				local na = n[axis]
				if abs(na) > 1e-9 then
					local u, v = OTHER[axis][1], OTHER[axis][2]
					local eu, ev = d.r * sqrt(math.max(0, 1 - n[u] * n[u])), d.r * sqrt(math.max(0, 1 - n[v] * n[v]))
					local u0 = math.max(base[u], math.ceil(c[u] - eu))
					local u1 = math.min(base[u] + C - 1, floor(c[u] + eu))
					local v0 = math.max(base[v], math.ceil(c[v] - ev))
					local v1 = math.min(base[v] + C - 1, floor(c[v] + ev))
					local a0, a1 = base[axis], base[axis] + C - 1
					local r2 = d.r * d.r
					for pu = u0, u1 do
						local du = pu - c[u]
						for pv = v0, v1 do
							local t = (d.d - n[u] * pu - n[v] * pv) / na
							local pa = floor(t)
							if pa >= a0 and pa <= a1 then
								local dv, da = pv - c[v], t - c[axis]
								if du * du + dv * dv + da * da <= r2 then
									local p = {0, 0, 0}
									p[axis], p[u], p[v] = pa, pu, pv
									local ok = true
									if d.ranged then
										local js = sets[d.set]
										local q = {p[1], p[2], p[3]}
										q[axis] = q[axis] + 1
										ok = self:inside(js, p[1], p[2], p[3], info, d) and self:inside(js, q[1], q[2], q[3], info, d)
									end
									if ok then
										local li = (((p[1] - base[1]) * C + (p[2] - base[2])) * C + (p[3] - base[3])) * 3 + axis
										local old = faces[li]
										if not old or old.set > d.set then faces[li] = d end
									end
								end
							end
						end
					end
				end
			end
		end
		return faces
	end)
end

-- 格 (x, y, z) 與 (x, y, z) + e_axis 之間的面：切過的圓盤（組號最小的）或 nil
function dfn:face(x, y, z, axis)
	local C = self.C
	local cx, cy, cz = floor(x / C), floor(y / C), floor(z / C)
	local fm = self:face_map(cx, cy, cz)
	return fm[(((x - cx * C) * C + (y - cy * C)) * C + (z - cz * C)) * 3 + axis]
end

-- 同一個面上所有切過的圓盤（除錯工具用）
function dfn:face_all(x, y, z, axis)
	local C, out = self.C, {}
	for _, d in ipairs(self:touching(floor(x / C), floor(y / C), floor(z / C))) do
		if self:crosses(d, x, y, z, axis) then out[#out + 1] = d end
	end
	table.sort(out, function(a, b) return a.set < b.set end)
	return out
end

-- 格 (x, y, z) 的 6 個面之一（axis 軸、sg = ±1 那一面，邊長 1 的正方形）上的跡線：
-- 回傳 {{u1, v1, u2, v2, disc}, ...}（面內座標，相對格中心，u、v 是 OTHER[axis] 那兩軸）
-- info：dfn:info_cache() 的結果（畫一整個區塊時共用，可省略）
function dfn:face_traces(x, y, z, axis, sg, info)
	local C, out = self.C, {}
	local c = {x, y, z}
	local u, v = OTHER[axis][1], OTHER[axis][2]
	local fc = {x, y, z}
	fc[axis] = fc[axis] + 0.5 * sg
	local corners = {{-0.5, -0.5}, {0.5, -0.5}, {0.5, 0.5}, {-0.5, 0.5}}
	for _, d in ipairs(self:touching(floor(x / C), floor(y / C), floor(z / C))) do
		local n = {d.nx, d.ny, d.nz}
		local f0 = n[1] * fc[1] + n[2] * fc[2] + n[3] * fc[3] - d.d
		if abs(f0) < 0.5 * (abs(n[u]) + abs(n[v])) and (not d.ranged or self:inside(self.sets[d.set], x, y, z, info, d)) then
			local ex, ey, ez = fc[1] - d.x, fc[2] - d.y, fc[3] - d.z
			local rr = d.r + 0.71
			if ex * ex + ey * ey + ez * ez <= rr * rr then
				local pts = {}
				for ci = 1, 4 do
					local cj = ci % 4 + 1
					local a, b = corners[ci], corners[cj]
					local fa = f0 + n[u] * a[1] + n[v] * a[2]
					local fb = f0 + n[u] * b[1] + n[v] * b[2]
					if (fa < 0) ~= (fb < 0) then
						local t = fa / (fa - fb)
						pts[#pts + 1] = {a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t}
					end
				end
				if #pts >= 2 then
					-- 線段剪到圓盤裡：|A + t(B − A) − 圓心|² ≤ r²
					local A, B = pts[1], pts[2]
					local function w3(q) local p = {fc[1], fc[2], fc[3]}; p[u] = p[u] + q[1]; p[v] = p[v] + q[2]; return p end
					local PA, PB = w3(A), w3(B)
					local Dx, Dy, Dz = PB[1] - PA[1], PB[2] - PA[2], PB[3] - PA[3]
					local Fx, Fy, Fz = PA[1] - d.x, PA[2] - d.y, PA[3] - d.z
					local qa = Dx * Dx + Dy * Dy + Dz * Dz
					local qb = 2 * (Fx * Dx + Fy * Dy + Fz * Dz)
					local qc = Fx * Fx + Fy * Fy + Fz * Fz - d.r * d.r
					local disc = qb * qb - 4 * qa * qc
					if qa > 1e-12 and disc > 0 then
						local s = sqrt(disc)
						local t1 = math.max(0, (-qb - s) / (2 * qa))
						local t2 = math.min(1, (-qb + s) / (2 * qa))
						if t2 - t1 > 1e-4 then
							out[#out + 1] = {A[1] + (B[1] - A[1]) * t1, A[2] + (B[2] - A[2]) * t1,
								A[1] + (B[1] - A[1]) * t2, A[2] + (B[2] - A[2]) * t2, d}
						end
					end
				end
			end
		end
	end
	return out
end

-- 掃描線量測：從 p 沿單位向量 dir 走 len 公尺，經過的節理面數 / len = P10（每公尺幾條）
function dfn:p10(p, dir, len)
	local hits, seen = 0, {}
	local steps = floor(len * 4)
	local lx, ly, lz = floor(p.x + 0.5), floor(p.y + 0.5), floor(p.z + 0.5)
	for i = 1, steps do
		local t = i / 4
		local x, y, z = floor(p.x + dir.x * t + 0.5), floor(p.y + dir.y * t + 0.5), floor(p.z + dir.z * t + 0.5)
		for axis, dd in ipairs({x - lx, y - ly, z - lz}) do
			if dd ~= 0 then
				local q = {lx, ly, lz}
				if dd < 0 then q[axis] = q[axis] - 1 end
				local d = self:face(q[1], q[2], q[3], axis)
				if d and not seen[d] then seen[d] = true; hits = hits + 1 end
				if axis == 1 then lx = lx + dd elseif axis == 2 then ly = ly + dd else lz = lz + dd end
			end
		end
	end
	return hits / len
end

return dfn
