-- rockmech/failure.lua
-- 軸差破壞（純函式，不依賴引擎；可搬到 core.handle_async）。
-- 載入方式：local failure = loadfile(".../failure.lua")(stress)
--
-- ## 模型（暫定，待力學檢查）
-- 1. 柱狀累積荷重（沿用 physics_core 的柱狀累計）：
--      L(格) = Σ γk·1m，由該格（含）往上累加，遇到非承載格（空氣等）即停。
--      網格頂端仍為實心時，假設往上連續到 y0：再加 γ·max(0, y0-1-ytop)。
--      完整岩體中 L = γ·(y0 - y) = γh，與 stress.lua 一致。
-- 2. 開口頂板荷重：空氣格的 R = 其上方第一段實心柱的 L（露天則為 0）。
--      這是開口原本要承擔、必須轉給周圍實心格的重量。
-- 3. 荷重擴散（水平窗格 (2w+1)²，同一高程）：
--      σy = Σ窗格(實心格取 L、空氣格取 R) / 窗格內實心格數
--    → 平地：σy = γh；坡趾：分攤後方高柱 → 集中；礦柱：分攤頂板 → 集中。
-- 4. 圍壓：σh = K0·(該格自身的 L)。x 或 z 向任一側臨空時，該方向正應力 = 0；
--    下方臨空（頂板／懸垂）時 σy = 0。上方臨空不歸零（階梯狀坡面上
--    σy 代表沿坡面方向的壓應力）。
--    → 陡坡：臨空格後方的柱很高，擴散後 σy 大；緩坡：後方柱逐階變矮，σy 小。
-- 5. 判定（只對臨空岩格）：
--      params.rock（rockmass.new 的查詢器）：Hoek-Brown 岩體強度 q ≥ q_f(σ3) = σci·(mb·σ3/σci + s)^a
--      （GSI 取該格 param2，或依岩性的深度剖面；強度已除以相似比 N）
--      沒有 params.rock：q = σ1 − σ3 ≥ UCS × strength_scale
-- 6. 弱面（Jaeger single plane of weakness）：穿過此格的每組節理面（法向 n）
--      σn = n·σ·n、τ = |σ·n − σn·n|，τ ≥ cj + σn·tan φj → 沿節理滑動。
--    運動學（daylight）：節理須傾向某個側向臨空面（向上法向的水平分量指向
--    該面外側），或下方臨空（頂板／懸垂，任何節理都可釋放）。只有上方臨空不算。
--    params.weakness = {c (MPa), tanphi, daylight}；params.joint_sets = 節理組陣列
--    （每組需有 n_eff = 向上單位法向，與 name）；params.joints_at(x,y,z, sets) 回傳
--    sets 中穿過此格的組。params.detail = true 時不做前置篩選（顯示用）。
--    params.axial == false 時不做軸差判定（只做弱面）。
--
-- ## 網格格式（與 VoxelManip / VoxelArea 相同的扁平陣列）
-- grid = {
--   data = {content id...},          -- 索引 1 + lx + ly·nx + lz·nx·ny
--   ox, oy, oz, nx, ny, nz,          -- data[1] 的世界座標與尺寸
--   solid_of  = {[cid] = true},      -- 提供側向圍壓（walkable，含未載入的 ignore）
--   weight_of = {[cid] = γ},         -- 承載荷重的格與其單位重 (kN/m³)；nil = 不承載
--   lith_of   = {[cid] = "shale"},   -- 本 mod 岩性（只有這些會被評估）
--   p2        = {param2...},          -- （可選）與 data 同索引；岩性格的 param2 1..100 = 該格的 GSI
-- }
-- 網格外：側向視為實心（保守），荷重窗格不計入。
--
-- params = {surface_y, k0, lithologies, window, strength_scale}

local stress = ...
assert(type(stress) == "table", "failure.lua 需以 loadfile(path)(stress) 載入")

local failure = {}

local function index(g, x, y, z)
	local lx, ly, lz = x - g.ox, y - g.oy, z - g.oz
	if lx < 0 or ly < 0 or lz < 0 or lx >= g.nx or ly >= g.ny or lz >= g.nz then
		return nil
	end
	return 1 + lx + ly * g.nx + lz * g.nx * g.ny
end
failure.index = index

local function is_solid(g, x, y, z)
	local i = index(g, x, y, z)
	if not i then return true end
	return g.solid_of[g.data[i]] == true
end
failure.is_solid = is_solid

-- 計算柱狀荷重 L 與頂板荷重 R（kPa），存成「緊湊陣列」：
-- 只存需要評估的範圍（g.req 的欄 × 高度帶），上方只做累加不儲存。
-- 緊湊索引：c = 1 + (x−cx) + (y−cy)·cW + (z−cz)·cW·cH（世界座標）
-- 依序預先填滿，讓陣列使用 Lua 表的陣列部分（從中間寫入會落到雜湊部分，慢很多）。
function failure.compute_loads(g, p)
	local nx, ny, nz = g.nx, g.ny, g.nz
	local data, weight_of = g.data, g.weight_of
	local ytop = g.oy + ny - 1
	local extra = math.max(0, p.surface_y - 1 - ytop) -- 網格上方假設的岩層厚度
	-- 需要的範圍（網格局部座標）；沒有 g.req 時為整個網格
	local x1, x2, z1, z2, y1, y2 = 0, nx - 1, 0, nz - 1, 0, ny - 1
	if g.req then
		x1 = math.max(0, g.req.x1 - g.ox); x2 = math.min(nx - 1, g.req.x2 - g.ox)
		z1 = math.max(0, g.req.z1 - g.oz); z2 = math.min(nz - 1, g.req.z2 - g.oz)
		y1 = math.max(0, g.req.y1 - g.oy); y2 = math.min(ny - 1, (g.req.y2 or ytop) - g.oy)
	end
	local cW, cH, cD = x2 - x1 + 1, y2 - y1 + 1, z2 - z1 + 1
	local L, R = {}, {}
	for c = 1, cW * cH * cD do
		L[c] = 0
		R[c] = 0
	end
	local cs = cW * cH
	for lz = z1, z2 do
		for lx = x1, x2 do
			local i = 1 + lx + (ny - 1) * nx + lz * nx * ny
			local w = weight_of[data[i]]
			local lv = w and w * (1 + extra) or 0
			local rv = 0
			local c0 = 1 + (lx - x1) + (lz - z1) * cs -- 本欄在緊湊陣列的底（ly = y1）
			if ny - 1 <= y2 then
				L[c0 + (ny - 1 - y1) * cW] = lv
				R[c0 + (ny - 1 - y1) * cW] = rv
			end
			for ly = ny - 2, y1, -1 do
				i = i - nx
				w = weight_of[data[i]]
				if w then
					lv, rv = w + lv, 0
				else
					rv = lv > 0 and lv or rv
					lv = 0
				end
				if ly <= y2 then
					local c = c0 + (ly - y1) * cW
					L[c] = lv
					R[c] = rv
				end
			end
		end
	end
	g.L, g.R = L, R
	g.cx, g.cy, g.cz = g.ox + x1, g.oy + y1, g.oz + z1
	g.cW, g.cH, g.cD = cW, cH, cD
	return L, R
end

-- 緊湊陣列索引（不在範圍內回傳 nil）
local function cindex(g, x, y, z)
	local lx, ly, lz = x - g.cx, y - g.cy, z - g.cz
	if lx < 0 or ly < 0 or lz < 0 or lx >= g.cW or ly >= g.cH or lz >= g.cD then
		return nil
	end
	return 1 + lx + ly * g.cW + lz * g.cW * g.cH
end
failure.cindex = cindex

-- 荷重擴散後的垂直應力 σy (MPa)。回傳 σy, 窗格總荷重 (kPa·格), 實心格數
function failure.spread_load(g, x, y, z, w)
	local L, R, weight_of, data = g.L, g.R, g.weight_of, g.data
	local total, n = 0, 0
	-- 快速路徑：窗格完全在緊湊範圍內時，兩個陣列同步以索引步進
	local cx, cy, cz = x - g.cx, y - g.cy, z - g.cz
	if cx - w >= 0 and cz - w >= 0 and cx + w < g.cW and cz + w < g.cD and cy >= 0 and cy < g.cH then
		local nx, gs = g.nx, g.nx * g.ny
		local cW, cs = g.cW, g.cW * g.cH
		local grow = 1 + (x - w - g.ox) + (y - g.oy) * nx + (z - w - g.oz) * gs
		local crow = 1 + (cx - w) + cy * cW + (cz - w) * cs
		local span = 2 * w
		for _ = 0, span do
			local i, c = grow, crow
			for _ = 0, span do
				if weight_of[data[i]] then
					total = total + L[c]
					n = n + 1
				else
					total = total + R[c]
				end
				i, c = i + 1, c + 1
			end
			grow, crow = grow + gs, crow + cs
		end
	else
		for dz = -w, w do
			for dx = -w, w do
				local i = index(g, x + dx, y, z + dz)
				local c = cindex(g, x + dx, y, z + dz)
				if i and c then
					if weight_of[data[i]] then
						total = total + L[c]
						n = n + 1
					else
						total = total + R[c]
					end
				end
			end
		end
	end
	if n == 0 then return 0, total, 0 end
	return total / n / 1000, total, n
end

-- 截面窗格加總（水平應力集中用）：
-- plane = "yz"（σxx 沿 x 傳遞，截面為 y-z 平面）或 "xy"（σzz，截面為 x-y 平面）。
-- 回傳 開口部分的 Σv（MPa，開口取頂板荷重 R）與其中 v > 0 的格數，
--      實心部分的 Σv（岩石取柱狀荷重 L）與其中 v > 0 的格數。
-- 露天空氣 R = 0，不計入開口（不會在地表附近造成假的集中）。
local function plane_sums(g, x, y, z, w, plane)
	local L, R, weight_of, data = g.L, g.R, g.weight_of, g.data
	local So, No, Ss, Ns = 0, 0, 0, 0
	local cx, cy, cz = x - g.cx, y - g.cy, z - g.cz
	local nx, gs = g.nx, g.nx * g.ny
	local cW, cs = g.cW, g.cW * g.cH
	local inside
	if plane == "yz" then
		inside = cz - w >= 0 and cz + w < g.cD and cy - w >= 0 and cy + w < g.cH and cx >= 0 and cx < g.cW
	else
		inside = cx - w >= 0 and cx + w < g.cW and cy - w >= 0 and cy + w < g.cH and cz >= 0 and cz < g.cD
	end
	if inside then
		-- 外層 y、內層 z（yz）或 x（xy）
		local gi_step, ci_step, go, co
		if plane == "yz" then
			gi_step, ci_step = gs, cs
			go = 1 + (x - g.ox) + (y - w - g.oy) * nx + (z - w - g.oz) * gs
			co = 1 + cx + (cy - w) * cW + (cz - w) * cs
		else
			gi_step, ci_step = 1, 1
			go = 1 + (x - w - g.ox) + (y - w - g.oy) * nx + (z - g.oz) * gs
			co = 1 + (cx - w) + (cy - w) * cW + cz * cs
		end
		local span = 2 * w
		for _ = 0, span do
			local i, c = go, co
			for _ = 0, span do
				if weight_of[data[i]] then
					local v = L[c]
					if v > 0 then Ss = Ss + v; Ns = Ns + 1 end
				else
					local v = R[c]
					if v > 0 then So = So + v; No = No + 1 end
				end
				i, c = i + gi_step, c + ci_step
			end
			go, co = go + nx, co + cW
		end
	else
		for dy = -w, w do
			for da = -w, w do
				local xx, zz = x, z
				if plane == "yz" then zz = z + da else xx = x + da end
				local i = index(g, xx, y + dy, zz)
				local c = failure.cindex(g, xx, y + dy, zz)
				if i and c then
					if weight_of[data[i]] then
						local v = L[c]
						if v > 0 then Ss = Ss + v; Ns = Ns + 1 end
					else
						local v = R[c]
						if v > 0 then So = So + v; No = No + 1 end
					end
				end
			end
		end
	end
	return So / 1000, No, Ss / 1000, Ns
end
failure.plane_sums = plane_sums

-- 單格應力狀態。非本 mod 岩性回傳 nil。
function failure.cell_state(g, x, y, z, p)
	local i = index(g, x, y, z)
	if not i then return nil end
	local key = g.lith_of[g.data[i]]
	local lith = key and p.lithologies[key]
	if not lith then return nil end
	if not g.L then failure.compute_loads(g, p) end

	local ci = cindex(g, x, y, z)
	local sv0 = (ci and g.L[ci] or 0) / 1000   -- 自身柱狀荷重 (MPa)
	local sh = stress.sigma_h(sv0, p.k0)        -- 舊欄位（K0·σv），供顯示
	local sv = failure.spread_load(g, x, y, z, p.window)

	-- 水平應力：遠場 σH、σh（依自身柱狀荷重）換到 x、z。
	-- 集中係數 = 截面上「全部應承受的遠場力」/「實心格承受的遠場力」
	--          = 1 + F_開口 / F_實心（開口的遠場力以頂板荷重換算）
	local th = math.rad(p.sH_azimuth or 0)
	local s2, c2, sc = math.sin(th) ^ 2, math.cos(th) ^ 2, math.sin(th) * math.cos(th)
	local KH, Kh = p.KH or p.k0, p.Kh or p.k0
	local sH0, sh0 = p.sH0 or 0, p.sh0 or 0
	local kx = s2 * KH + c2 * Kh          -- σxx 的 K
	local kz = c2 * KH + s2 * Kh          -- σzz 的 K
	local tx = s2 * sH0 + c2 * sh0        -- σxx 的構造項
	local tz = c2 * sH0 + s2 * sh0
	local Sox, Nox, Ssx, Nsx = plane_sums(g, x, y, z, p.window, "yz")
	local Soz, Noz, Ssz, Nsz = plane_sums(g, x, y, z, p.window, "xy")
	local Fsx, Fsz = kx * Ssx + tx * Nsx, kz * Ssz + tz * Nsz
	local fx = Fsx > 0 and (1 + (kx * Sox + tx * Nox) / Fsx) or 1
	local fz = Fsz > 0 and (1 + (kz * Soz + tz * Noz) / Fsz) or 1
	local sH_own, sh_own = stress.horizontal({KH = KH, Kh = Kh, sH0 = sH0, sh0 = sh0}, sv0)
	local sxx_c = (s2 * sH_own + c2 * sh_own) * fx
	local szz_c = (c2 * sH_own + s2 * sh_own) * fz
	local sxz = (sH_own - sh_own) * sc

	local ex_p, ex_n = not is_solid(g, x + 1, y, z), not is_solid(g, x - 1, y, z)
	local ez_p, ez_n = not is_solid(g, x, y, z + 1), not is_solid(g, x, y, z - 1)
	local ex, ez = ex_p or ex_n, ez_p or ez_n
	local e_up = not is_solid(g, x, y + 1, z)
	local e_down = not is_solid(g, x, y - 1, z)

	-- 自由面：法向正應力與剪應力為 0。
	-- 下方臨空（頂板／懸垂）：σy = 0。上方臨空（地表／階梯狀坡面）不歸零：
	-- 擴散荷重代表沿坡面方向的壓應力。
	local sx = ex and 0 or sxx_c
	local sy = e_down and 0 or sv
	local sz = ez and 0 or szz_c
	if ex or ez then sxz = 0 end

	local s1, s3 = stress.principal(sx, sy, sz, sxz)
	local q = s1 - s3
	local strength, rm
	if p.rock then
		rm = p.rock.at(key, y, g.p2 and g.p2[i])
		strength = p.rock.q_fail(rm, s3)
	else
		strength = lith.ucs * (p.strength_scale or 1)
	end
	local exposed = ex or ez or e_up or e_down

	-- 弱面滑動
	local fs_joint, slip_set, slip_sn, slip_tau = math.huge, nil, nil, nil
	local n_joints
	local wk = p.weakness
	-- 前置篩選（p.detail 時不篩，供顯示用）：
	--   τ ≤ (σ1 − σ3)/2，所以 FS ≥ 2cj/q：2cj > q·fs_cut（預設 1）時不可能低於 fs_cut；未臨空也不可能滑
	--   運動學不成立的組不必判斷平面是否穿過此格
	if wk and p.joints_at and (p.detail or (exposed and 2 * wk.c <= q * (p.fs_cut or 1))) then
		local cands = p.joint_sets
		if wk.daylight and not p.detail then
			cands = {}
			for k = 1, #p.joint_sets do
				local js = p.joint_sets[k]
				if failure.daylights(js.n_eff, ex_p, ex_n, ez_p, ez_n, e_down) then cands[#cands + 1] = js end
			end
		end
		local list = #cands > 0 and p.joints_at(x, y, z, cands) or {}
		if p.detail then n_joints = #list end
		for k = 1, #list do
			local js = list[k]
			if not wk.daylight or failure.daylights(js.n_eff, ex_p, ex_n, ez_p, ez_n, e_down) then
				local sn, tau = failure.plane_stress(sx, sy, sz, sxz, js.n_eff)
				local f = failure.plane_fs(sn, tau, wk.c, wk.tanphi)
				if f < fs_joint then
					fs_joint, slip_set, slip_sn, slip_tau = f, js, sn, tau
				end
			end
		end
	end
	local axial = p.axial ~= false
	local fs_axial = q > 0 and strength / q or math.huge
	local fails_axial = axial and exposed and q >= strength
	local fails_slip = exposed and fs_joint <= 1
	local fs = axial and fs_axial or math.huge
	if fs_joint < fs then fs = fs_joint end

	return {
		lith = key, h = stress.depth(y, p.surface_y),
		sv0 = sv0, sv = sv, sh = sh,
		factor = sv0 > 0 and sv / sv0 or 1,
		sx = sx, sy = sy, sz = sz, sxz = sxz, s1 = s1, s3 = s3, q = q,
		sH_far = sH_own, sh_far = sh_own, fx = fx, fz = fz,
		strength = strength, rm = rm, fs = fs, fs_axial = fs_axial, fs_joint = fs_joint,
		slip_set = slip_set, slip_sn = slip_sn, slip_tau = slip_tau, n_joints = n_joints,
		fails_axial = fails_axial, fails_slip = fails_slip,
		exposed_x = ex, exposed_z = ez, exposed_up = e_up, exposed_down = e_down,
		exposed = exposed,
		fails = fails_axial or fails_slip,
	}
end

-- 節理面上的正應力與剪應力（壓為正）。應力張量只有 σxx、σyy、σzz、σxz。
function failure.plane_stress(sx, sy, sz, sxz, n)
	local tx = sx * n.x + sxz * n.z
	local ty = sy * n.y
	local tz = sxz * n.x + sz * n.z
	local sn = tx * n.x + ty * n.y + tz * n.z
	local t2 = tx * tx + ty * ty + tz * tz - sn * sn
	return sn, t2 > 0 and math.sqrt(t2) or 0
end

-- 弱面安全係數 (cj + σn·tanφj) / τ（τ = 0 時為 ∞；σn < 0 時摩擦項取 0）
function failure.plane_fs(sn, tau, c, tanphi)
	if tau <= 0 then return math.huge end
	return (c + math.max(0, sn) * tanphi) / tau
end

-- 運動學：節理（向上法向 n）能否往臨空面釋放
-- ex_p/ex_n：+x/−x 側臨空；ez_p/ez_n：+z/−z 側臨空；e_down：下方臨空
function failure.daylights(n, ex_p, ex_n, ez_p, ez_n, e_down)
	if e_down then return true end
	local eps = 1e-9
	return (ex_p and n.x > eps) or (ex_n and n.x < -eps)
		or (ez_p and n.z > eps) or (ez_n and n.z < -eps) or false
end

-- 是否有任一面臨空（便宜的前置篩選）
local function is_exposed(g, x, y, z)
	return not is_solid(g, x + 1, y, z) or not is_solid(g, x - 1, y, z)
		or not is_solid(g, x, y + 1, z) or not is_solid(g, x, y - 1, z)
		or not is_solid(g, x, y, z + 1) or not is_solid(g, x, y, z - 1)
end
failure.is_exposed = is_exposed

-- 評估 boxes 內所有臨空岩格（boxes = {{minp, maxp}, ...}，世界座標，含邊界）。
-- 重疊的盒子只評估一次。
-- 回傳 failed = {{x=,y=,z=, state=}...}（由上往下）, stats
-- stats = {evaluated, failed, min_fs, min_fs_pos, min_fs_state}
function failure.evaluate_boxes(g, p, boxes)
	if not g.L then failure.compute_loads(g, p) end
	local failed = {}
	local stats = {evaluated = 0, failed = 0, min_fs = math.huge}
	local seen = {}
	local lith_of, data = g.lith_of, g.data
	for _, b in ipairs(boxes) do
		local a, c = b[1], b[2]
		for z = a.z, c.z do
			for y = a.y, c.y do
				for x = a.x, c.x do
					local i = index(g, x, y, z)
					if i and not seen[i] and lith_of[data[i]] then
						seen[i] = true
						if is_exposed(g, x, y, z) then
							local st = failure.cell_state(g, x, y, z, p)
							stats.evaluated = stats.evaluated + 1
							if st.fs < stats.min_fs then
								stats.min_fs = st.fs
								stats.min_fs_pos = {x = x, y = y, z = z}
								stats.min_fs_state = st
							end
							if st.fails then
								failed[#failed + 1] = {x = x, y = y, z = z, state = st}
							end
						end
					end
				end
			end
		end
	end
	table.sort(failed, function(u, v)
		if u.y ~= v.y then return u.y > v.y end
		if u.x ~= v.x then return u.x < v.x end
		return u.z < v.z
	end)
	stats.failed = #failed
	return failed, stats
end

-- box = {minp, maxp} 內臨空岩格的最小安全係數（顯示用，p 建議 detail = true）。
-- 回傳 {joint = {fs, x, y, z, set} 或 nil, axial = {fs, x, y, z} 或 nil, exposed = 臨空格數}
function failure.min_fs_in_box(g, p, box)
	if not g.L then failure.compute_loads(g, p) end
	local out = {exposed = 0}
	local lith_of, data = g.lith_of, g.data
	local a, c = box[1], box[2]
	for z = a.z, c.z do
		for y = a.y, c.y do
			for x = a.x, c.x do
				local i = index(g, x, y, z)
				if i and lith_of[data[i]] and is_exposed(g, x, y, z) then
					out.exposed = out.exposed + 1
					local st = failure.cell_state(g, x, y, z, p)
					if st.slip_set and (not out.joint or st.fs_joint < out.joint.fs) then
						out.joint = {fs = st.fs_joint, x = x, y = y, z = z, set = st.slip_set}
					end
					if p.axial ~= false and (not out.axial or st.fs_axial < out.axial.fs) then
						out.axial = {fs = st.fs_axial, x = x, y = y, z = z}
					end
				end
			end
		end
	end
	return out
end

-- 以 (cx,cy,cz) 為中心、半邊長 r 的立方體評估
function failure.evaluate(g, p, cx, cy, cz, r)
	return failure.evaluate_boxes(g, p, {{
		{x = cx - r, y = cy - r, z = cz - r}, {x = cx + r, y = cy + r, z = cz + r},
	}})
end

return failure
