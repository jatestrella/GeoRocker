-- rockmech/jointtex.lua
-- 節理「平面跡線」材質（純函式，不依賴引擎）。
--
-- 節理平面已對齊整數格點（joints.prepare）：m·p + o = L·k，m 為整數向量。
-- 方塊局部座標 u ∈ [0,1]³（原點在格中心 − 0.5）。平面在格內為 m·u = t，
--   t = L·k − o − m·c + ½Σm_i（c 為格中心，整數）
-- 所以 2t 一定是整數，且奇偶性固定（同 Σm_i）。t 只可能是有限幾個值：
--   tmin < t < tmax，tmin = Σ min(0, m_i)，tmax = Σ max(0, m_i)
-- 每個值稱為一「級」(level)。相鄰兩格看到的是同一個精確平面，
-- 因此跡線在方塊之間完美連接（不需要量化）。
--
-- 延續性：只有當這個平面在此格的某個面上被判定為節理（joints.face_crossing
-- 的 k 相同且 r < P）時才畫；平面只擦過格角、沒有穿過任何面時，以
-- hash(seed, id, k, x, y, z, 7) < P 判定。畫出來的跡線與力學用的節理面一致。

local jointtex = {}

local floor, abs, sqrt = math.floor, math.abs, math.sqrt

-- 每個面（tiles 順序 +Y, -Y, +X, -X, +Z, -Z）：
--   axis/val：此面的法向軸與局部座標值；right/up：貼圖右方與上方對應的局部軸與方向
-- 已用 /rockmech_orient 在遊戲中確認 6 面方向皆正確。
jointtex.FACES = {
	{ax = "y", val = 1, right = {"x", 1},  up = {"z", 1}},  -- +Y
	{ax = "y", val = 0, right = {"x", 1},  up = {"z", -1}}, -- -Y
	{ax = "x", val = 1, right = {"z", 1},  up = {"y", 1}},  -- +X
	{ax = "x", val = 0, right = {"z", -1}, up = {"y", 1}},  -- -X
	{ax = "z", val = 1, right = {"x", -1}, up = {"y", 1}},  -- +Z
	{ax = "z", val = 0, right = {"x", 1},  up = {"y", 1}},  -- -Z
}

local function mvec(js)
	return {x = js.mx, y = js.my, z = js.mz}
end

-- 2·tmin、2·tmax 與第一級的 2t（每組固定，快取在 js 上）
local function level_info(js)
	if js._lo then return js._lo, js._hi, js._first end
	local tmin, tmax, sum = 0, 0, 0
	for _, c in ipairs({js.mx, js.my, js.mz}) do
		if c < 0 then tmin = tmin + c else tmax = tmax + c end
		sum = sum + c
	end
	js._lo, js._hi = 2 * tmin, 2 * tmax
	js._first = 2 * tmin + ((sum % 2 == 0) and 2 or 1)
	js._sum = sum
	return js._lo, js._hi, js._first
end

-- 此組的級數
function jointtex.levels(js)
	local lo, hi, first = level_info(js)
	if first >= hi then return 0 end
	return floor((hi - 1 - first) / 2) + 1
end

-- 平面 k 是否在此格「存在」（延續性），與 joints 的面判定一致。
-- 熱路徑：先用整數運算判斷 6 個面是否被平面 k 切過，只對被切過的面算雜湊。
-- 面 (fx,fy,fz | axis) 被平面 k 切過 ⇔ k = max(⌊a1/L⌋, ⌊a2/L⌋) 且兩者不同，
-- 其中 a1 = m·f + o、a2 = a1 + m_axis。
local function crosses_k(a1, a2, L, k)
	local k1, k2 = (a1 - a1 % L) / L, (a2 - a2 % L) / L
	if k1 == k2 then return false end
	return (k1 > k2 and k1 or k2) == k
end

local function plane_present(joints, js, k, x, y, z)
	local L, P = js.L, js.persistence
	local mx, my, mz = js.mx, js.my, js.mz
	local a = mx * x + my * y + mz * z + js.o -- 本格中心
	local hash = joints.face_hash01
	local touched = false
	-- +x 面（本格 → 東鄰）與 −x 面（西鄰 → 本格）
	if crosses_k(a, a + mx, L, k) then
		touched = true
		if hash(js, k, x, y, z, 1) < P then return true end
	end
	if crosses_k(a - mx, a, L, k) then
		touched = true
		if hash(js, k, x - 1, y, z, 1) < P then return true end
	end
	if crosses_k(a, a + my, L, k) then
		touched = true
		if hash(js, k, x, y, z, 2) < P then return true end
	end
	if crosses_k(a - my, a, L, k) then
		touched = true
		if hash(js, k, x, y - 1, z, 2) < P then return true end
	end
	if crosses_k(a, a + mz, L, k) then
		touched = true
		if hash(js, k, x, y, z, 3) < P then return true end
	end
	if crosses_k(a - mz, a, L, k) then
		touched = true
		if hash(js, k, x, y, z - 1, 3) < P then return true end
	end
	if touched then return false end
	return joints.face_hash01(js, k, x, y, z, 7) < P
end

jointtex.plane_present = plane_present

-- 回傳此格的跡線清單 {{set=i, level=j}, ...}（依組號排序，最多 max_lines 條）
function jointtex.cell_traces(joints, sets, x, y, z, max_lines)
	local out = {}
	for i = 1, #sets do
		if #out >= max_lines then break end
		local js = sets[i]
		local lo, hi, first = level_info(js)
		local sum = js._sum
		local mc = js.mx * x + js.my * y + js.mz * z
		-- 2t(k) = 2Lk − 2o − 2m·c + Σm，需 lo < 2t < hi
		local base = -2 * js.o - 2 * mc + sum
		local twoL = 2 * js.L
		-- 最小的 k 使 2Lk + base > lo
		local A = lo - base
		local k = (A - A % twoL) / twoL + 1
		local t2 = twoL * k + base
		if t2 < hi and plane_present(joints, js, k, x, y, z) then
			out[#out + 1] = {set = i, level = (t2 - first) / 2}
		end
	end
	return out
end

-- 變體名稱後綴：組 1,2,3… 以 a,b,c… 表示，接級數。例：{} → ""、{1/3} → "_pa3"
local LETTERS = "abcdefghij"
function jointtex.suffix(traces)
	if #traces == 0 then return "" end
	local s = "_p"
	for _, t in ipairs(traces) do
		s = s .. LETTERS:sub(t.set, t.set) .. t.level
	end
	return s
end

-- 所有可能的跡線組合（0..max_lines 條，組號遞增）。levels[i] 為第 i 組的級數
function jointtex.all_combos(levels, max_lines)
	local out = {{}}
	local function rec(start, cur)
		if #cur >= max_lines then return end
		for i = start, #levels do
			for j = 0, levels[i] - 1 do
				local nxt = {}
				for _, t in ipairs(cur) do nxt[#nxt + 1] = t end
				nxt[#nxt + 1] = {set = i, level = j}
				out[#out + 1] = nxt
				rec(i + 1, nxt)
			end
		end
	end
	rec(1, {})
	return out
end

-- 某面上的跡線圖：回傳長度 R*R 的 alpha 陣列（0..1，左上起、逐列）；
-- 平面與此面平行或沒有相交時回傳 nil。width：線寬（像素），反鋸齒。
function jointtex.face_line_alpha(js, face, level, R, width)
	local m = mvec(js)
	local _, _, first = level_info(js)
	local t = (first + 2 * level) / 2
	local ra, rs = face.right[1], face.right[2]
	local ua, us = face.up[1], face.up[2]
	local na, nb = m[ra], m[ua]
	local g = sqrt(na * na + nb * nb)
	if g < 1e-9 then return nil end
	local fixed = m[face.ax] * face.val
	local alpha, any = {}, false
	local half = width / 2
	for j = 0, R - 1 do
		local v = 1 - (j + 0.5) / R
		local cu = us > 0 and v or (1 - v)
		for i = 0, R - 1 do
			local s = (i + 0.5) / R
			local cr = rs > 0 and s or (1 - s)
			local d = abs(na * cr + nb * cu + fixed - t) / g * R
			local a = half + 0.5 - d
			if a > 1 then a = 1 elseif a < 0 then a = 0 end
			if a > 0 then any = true end
			alpha[j * R + i + 1] = a
		end
	end
	if not any then return nil end
	return alpha
end

return jointtex
