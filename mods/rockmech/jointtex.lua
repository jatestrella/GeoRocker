-- rockmech/jointtex.lua
-- 節理「平面跡線」材質（純函式，不依賴引擎）。
--
-- 每組節理是一族平行平面 n·p = (k − φ)·S。平面切過一個方塊時，在方塊各面上
-- 留下一條直線（跡線）。本模組：
--   1. cell_traces：判斷哪些節理平面切過某格、平面在格內的位置（量化成 Q 級）
--   2. face_line_pixels：產生某面、某組、某級的跡線圖（RGBA），由引擎端編成 PNG
--   3. 變體命名：每格最多 max_lines 條跡線，變體名稱由 (組, 級) 組成
--
-- 方塊局部座標 u ∈ [0,1]³（格中心 − 0.5 為原點）。平面在格內為 n·u = t，
-- t 介於 tmin = Σ min(0, n_i) 與 tmax = Σ max(0, n_i) 之間；級數 b 對應
-- t = tmin + (b + 0.5)/Q · (tmax − tmin)。
--
-- 延續性：只有當這個平面在此格的某個面上被判定為節理（joints.face_crossing
-- 的 k 相同且 r < P）時才畫；平面只擦過格角、沒有穿過任何面時，以
-- hash(seed, id, k, x, y, z, 7) < P 判定。這樣畫出來的跡線與力學用的節理面一致。

local jointtex = {}

local floor, abs, sqrt = math.floor, math.abs, math.sqrt

-- 每個面（tiles 順序 +Y, -Y, +X, -X, +Z, -Z）：
--   axis/val：此面的法向軸與局部座標值；right/up：貼圖右方與上方對應的局部軸與方向
-- 與 joints.TILE_EDGES 使用相同的方向假設（底面未經畫面確認）。
jointtex.FACES = {
	{axis = "y", val = 1, right = {"x", 1},  up = {"z", 1}},  -- +Y
	{axis = "y", val = 0, right = {"x", 1},  up = {"z", -1}}, -- -Y
	{axis = "x", val = 1, right = {"z", 1},  up = {"y", 1}},  -- +X
	{axis = "x", val = 0, right = {"z", -1}, up = {"y", 1}},  -- -X
	{axis = "z", val = 1, right = {"x", -1}, up = {"y", 1}},  -- +Z
	{axis = "z", val = 0, right = {"x", 1},  up = {"y", 1}},  -- -Z
}

local function t_range(js)
	local tmin, tmax = 0, 0
	for _, c in ipairs({js.nx, js.ny, js.nz}) do
		if c < 0 then tmin = tmin + c else tmax = tmax + c end
	end
	return tmin, tmax
end
jointtex.t_range = t_range

-- 平面 k 是否在此格「存在」（延續性），與 joints 的面判定一致
local function plane_present(joints, js, k, x, y, z)
	local touched = false
	local nb = {
		{x, y, z, 1}, {x - 1, y, z, 1}, {x, y, z, 2}, {x, y - 1, z, 2}, {x, y, z, 3}, {x, y, z - 1, 3},
	}
	for _, f in ipairs(nb) do
		local kk, r = joints.face_crossing(js, f[1], f[2], f[3], f[4])
		if kk == k then
			touched = true
			if r < js.persistence then return true end
		end
	end
	if touched then return false end
	return joints.hash01(js.seed, js.id, k, x, y, z, 7) < js.persistence
end

-- 回傳此格的跡線清單 {{set=i, bin=b}, ...}（依組號排序，最多 max_lines 條）
function jointtex.cell_traces(joints, sets, x, y, z, Q, max_lines)
	local out = {}
	for i = 1, #sets do
		if #out >= max_lines then break end
		local js = sets[i]
		local tmin, tmax = t_range(js)
		if tmax - tmin > 1e-9 then
			-- 格內平面座標 s = n·p/S + φ 的範圍（p 為格內任一點）
			local base = (js.nx * (x - 0.5) + js.ny * (y - 0.5) + js.nz * (z - 0.5)) * js.inv_s + js.phase
			local s_min = base + tmin * js.inv_s
			local s_max = base + tmax * js.inv_s
			local k = floor(s_max)
			if k > s_min and k < s_max and plane_present(joints, js, k, x, y, z) then
				local f = (k - s_min) / (s_max - s_min)
				local b = floor(f * Q)
				if b >= Q then b = Q - 1 end
				out[#out + 1] = {set = i, bin = b}
			end
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
		s = s .. LETTERS:sub(t.set, t.set) .. t.bin
	end
	return s
end

-- 所有可能的跡線組合（0..max_lines 條，組號遞增）
function jointtex.all_combos(nsets, Q, max_lines)
	local out = {{}}
	local function rec(start, cur)
		if #cur >= max_lines then return end
		for i = start, nsets do
			for b = 0, Q - 1 do
				local nxt = {}
				for _, t in ipairs(cur) do nxt[#nxt + 1] = t end
				nxt[#nxt + 1] = {set = i, bin = b}
				out[#out + 1] = nxt
				rec(i + 1, nxt)
			end
		end
	end
	rec(1, {})
	return out
end

-- 某面上的跡線圖：回傳長度 R*R 的 alpha 陣列（0..1，左上起、逐列）；
-- 平面與此面平行或沒有相交時回傳 nil。
-- width：線寬（像素）；以像素中心到直線的距離做反鋸齒。
function jointtex.face_line_alpha(js, face, bin, Q, R, width)
	local n = {x = js.nx, y = js.ny, z = js.nz}
	local tmin, tmax = t_range(js)
	local t = tmin + (bin + 0.5) / Q * (tmax - tmin)
	local ra, rs = face.right[1], face.right[2]
	local ua, us = face.up[1], face.up[2]
	-- 面內兩軸的法向分量（考慮方向）
	local na, nb = n[ra], n[ua]
	local g = sqrt(na * na + nb * nb)
	if g < 1e-6 then return nil end
	local fixed = n[face.axis] * face.val
	local alpha, any = {}, false
	local half = width / 2
	for j = 0, R - 1 do
		local v = 1 - (j + 0.5) / R          -- 貼圖上方 → 局部座標增加
		local cu = us > 0 and v or (1 - v)
		for i = 0, R - 1 do
			local s = (i + 0.5) / R
			local cr = rs > 0 and s or (1 - s)
			local val = na * cr + nb * cu + fixed
			local d = abs(val - t) / g * R     -- 到直線的距離（像素）
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
