-- rockmech/wallbeam.lua
-- 擋土壁的彈性支承梁法（土壤反力係數法，台灣深開挖設計常用的 TORSA、RIDO 同一類；純函式，不依賴引擎）。
--
-- 一欄鋼板樁 = 一根薄梁（每公尺寬，EI），節點在每一格的中心、間距 1 m，兩端自由。
-- 每個節點兩側（板的法向 ±）可以有：
--   土的彈簧：土壓 p = p0 + kh·δ，夾在 [pa, pp]（主動、被動土壓），δ = 板往那一側的土推進去的位移。
--     p0 = 靜止土壓 K0·σv；pa = Ka·σv − 2c√Ka（≥ 0）；pp = Kp·σv + 2c√Kp。
--   支撐（H 型鋼）：只受壓的彈簧 k（kN/m，每公尺寬；圍令把一支的勁度分攤到它負責的寬度）。
-- 位移 w 取板法向的座標軸正向為正。土在 s 側（s = ±1）：δ = s·w，作用在板上的力 = −s·p。
-- 彈簧有三種狀態（彈性、主動、被動），反覆「照狀態組勁度 → 解 → 更新狀態」到狀態不變。
--
-- 輸入 t = {n（節點數）, EI（kN·m²/m）, soil = {{i, s, p0, pa, pp, k}, ...}, props = {{i, s, k}, ...}}
-- 回傳 {w = {}, M = {}（節點彎矩，kN·m/m）, Mmax, prop = {}（各支撐的力，kN/m）, ok（收斂、沒有形成機構）, iters}

local wb = {}

-- 解 A·x = b（稠密、部分選主元的高斯消去；n 很小）
local function gauss(A, b, n)
	for k = 1, n do
		local piv, best = k, math.abs(A[k][k])
		for i = k + 1, n do
			if math.abs(A[i][k]) > best then piv, best = i, math.abs(A[i][k]) end
		end
		if best < 1e-12 then return nil end
		A[k], A[piv] = A[piv], A[k]
		b[k], b[piv] = b[piv], b[k]
		for i = k + 1, n do
			local f = A[i][k] / A[k][k]
			if f ~= 0 then
				local Ai, Ak = A[i], A[k]
				for j = k, n do Ai[j] = Ai[j] - f * Ak[j] end
				b[i] = b[i] - f * b[k]
			end
		end
	end
	local x = {}
	for i = n, 1, -1 do
		local s = b[i]
		for j = i + 1, n do s = s - A[i][j] * x[j] end
		x[i] = s / A[i][i]
	end
	return x
end

-- 一根梁元素（長 1 m）的勁度，自由度 (w_i, θ_i, w_j, θ_j)
local KE = {{12, 6, -12, 6}, {6, 4, -6, 2}, {-12, -6, 12, -6}, {6, 2, -6, 4}}

-- 彈簧的狀態：0 彈性、1 主動（p = pa）、2 被動（p = pp）
local function soil_state(sp, w)
	local p = sp[3] + sp[6] * sp[2] * w
	if p < sp[4] then return 1 elseif p > sp[5] then return 2 end
	return 0
end

function wb.solve(t)
	local n, EI = t.n, t.EI
	local N = 2 * n
	local soil, props = t.soil or {}, t.props or {}
	local st, pon = {}, {}
	for k = 1, #soil do st[k] = 0 end
	for k = 1, #props do pon[k] = true end
	local w, x
	local iters, ok = 0, false
	local WMAX = t.wmax or 0.5          -- 超過這個位移（m）當成形成機構（埋入不夠、整片倒）
	for it = 1, 60 do
		iters = it
		local A, b = {}, {}
		for i = 1, N do
			A[i] = {}
			for j = 1, N do A[i][j] = 0 end
			b[i] = 0
		end
		for e = 1, n - 1 do
			local d = {2 * e - 1, 2 * e, 2 * e + 1, 2 * e + 2}
			for r = 1, 4 do for c = 1, 4 do A[d[r]][d[c]] = A[d[r]][d[c]] + EI * KE[r][c] end end
		end
		-- 很小的接地彈簧：沒有任何支承時矩陣不奇異（位移會很大 → 判成機構）
		for i = 1, n do A[2 * i - 1][2 * i - 1] = A[2 * i - 1][2 * i - 1] + EI * 1e-7 end
		for k, sp in ipairs(soil) do
			local r, s = 2 * sp[1] - 1, sp[2]
			if st[k] == 0 then
				A[r][r] = A[r][r] + sp[6]
				b[r] = b[r] - s * sp[3]
			else
				b[r] = b[r] - s * (st[k] == 1 and sp[4] or sp[5])
			end
		end
		for k, pr in ipairs(props) do
			if pon[k] then
				local r = 2 * pr[1] - 1
				A[r][r] = A[r][r] + pr[3]
			end
		end
		x = gauss(A, b, N)
		if not x then break end
		w = {}
		local big = false
		for i = 1, n do
			w[i] = x[2 * i - 1]
			if math.abs(w[i]) > WMAX then big = true end
		end
		if big then break end
		local changed = false
		for k, sp in ipairs(soil) do
			local ns = soil_state(sp, w[sp[1]])
			if ns ~= st[k] then st[k] = ns; changed = true end
		end
		for k, pr in ipairs(props) do
			local on = pr[2] * w[pr[1]] > 0
			if on ~= pon[k] then pon[k] = on; changed = true end
		end
		if not changed then ok = true; break end
	end
	local out = {w = w, ok = ok, iters = iters, M = {}, Mmax = 0, prop = {}}
	if not (ok and x) then return out end
	-- 節點彎矩：元素端力（兩端各取一次，取大的）
	for i = 1, n do out.M[i] = 0 end
	for e = 1, n - 1 do
		local d = {x[2 * e - 1], x[2 * e], x[2 * e + 1], x[2 * e + 2]}
		local f = {}
		for r = 1, 4 do
			local v = 0
			for c = 1, 4 do v = v + EI * KE[r][c] * d[c] end
			f[r] = v
		end
		if math.abs(f[2]) > math.abs(out.M[e]) then out.M[e] = f[2] end
		if math.abs(f[4]) > math.abs(out.M[e + 1]) then out.M[e + 1] = -f[4] end
	end
	for i = 1, n do out.Mmax = math.max(out.Mmax, math.abs(out.M[i])) end
	for k, pr in ipairs(props) do
		local dlt = pr[2] * w[pr[1]]
		out.prop[k] = dlt > 0 and pr[3] * dlt or 0
	end
	-- 每個土彈簧最後的土壓（kPa）：應力解把它當成板旁邊那格土受的面壓
	out.p = {}
	for k, sp in ipairs(soil) do
		out.p[k] = math.min(sp[5], math.max(sp[4], sp[3] + sp[6] * sp[2] * w[sp[1]]))
	end
	return out
end

-- 土壓係數（朗肯）
function wb.coeffs(phi_deg)
	local s = math.sin(math.rad(phi_deg))
	return 1 - s, (1 - s) / (1 + s), (1 + s) / (1 - s)      -- K0, Ka, Kp
end

-- 一個土彈簧：σv（kPa）、c（kPa）、φ（°）、kh（kN/m³ × 1 m² = kN/m）
function wb.soil_spring(i, s, sv, c, phi, kh)
	local K0, Ka, Kp = wb.coeffs(phi)
	local pa = math.max(0, Ka * sv - 2 * c * math.sqrt(Ka))
	local pp = Kp * sv + 2 * c * math.sqrt(Kp)
	local p0 = math.min(pp, math.max(pa, K0 * sv))
	return {i, s, p0, pa, pp, kh}
end

return wb
