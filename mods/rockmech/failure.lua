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
-- 5. 判定：q = σ1 − σ3 ≥ UCS × strength_scale → 破壞（只對臨空岩格）。
--
-- ## 網格格式（與 VoxelManip / VoxelArea 相同的扁平陣列）
-- grid = {
--   data = {content id...},          -- 索引 1 + lx + ly·nx + lz·nx·ny
--   ox, oy, oz, nx, ny, nz,          -- data[1] 的世界座標與尺寸
--   solid_of  = {[cid] = true},      -- 提供側向圍壓（walkable，含未載入的 ignore）
--   weight_of = {[cid] = γ},         -- 承載荷重的格與其單位重 (kN/m³)；nil = 不承載
--   lith_of   = {[cid] = "shale"},   -- 本 mod 岩性（只有這些會被評估）
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

-- 計算整個網格的柱狀荷重 L 與頂板荷重 R（kPa），存入 g.L、g.R
function failure.compute_loads(g, p)
	local nx, ny, nz = g.nx, g.ny, g.nz
	local data, weight_of = g.data, g.weight_of
	local L, R = {}, {}
	local ytop = g.oy + ny - 1
	local extra = math.max(0, p.surface_y - 1 - ytop) -- 網格上方假設的岩層厚度
	for lz = 0, nz - 1 do
		for lx = 0, nx - 1 do
			local i = 1 + lx + (ny - 1) * nx + lz * nx * ny
			local w = weight_of[data[i]]
			if w then
				L[i] = w * (1 + extra)
			else
				L[i] = 0
			end
			R[i] = 0
			for _ = ny - 2, 0, -1 do
				local ia = i
				i = i - nx
				w = weight_of[data[i]]
				if w then
					L[i] = w + L[ia]
					R[i] = 0
				else
					L[i] = 0
					R[i] = L[ia] > 0 and L[ia] or R[ia]
				end
			end
		end
	end
	g.L, g.R = L, R
	return L, R
end

-- 荷重擴散後的垂直應力 σy (MPa)。回傳 σy, 窗格總荷重 (kPa·格), 實心格數
function failure.spread_load(g, x, y, z, w)
	local L, R, weight_of, data = g.L, g.R, g.weight_of, g.data
	local total, n = 0, 0
	for dz = -w, w do
		for dx = -w, w do
			local i = index(g, x + dx, y, z + dz)
			if i then
				if weight_of[data[i]] then
					total = total + L[i]
					n = n + 1
				else
					total = total + R[i]
				end
			end
		end
	end
	if n == 0 then return 0, total, 0 end
	return total / n / 1000, total, n
end

-- 單格應力狀態。非本 mod 岩性回傳 nil。
function failure.cell_state(g, x, y, z, p)
	local i = index(g, x, y, z)
	if not i then return nil end
	local key = g.lith_of[g.data[i]]
	local lith = key and p.lithologies[key]
	if not lith then return nil end
	if not g.L then failure.compute_loads(g, p) end

	local sv0 = g.L[i] / 1000                 -- 自身柱狀荷重 (MPa)
	local sh = stress.sigma_h(sv0, p.k0)
	local sv = failure.spread_load(g, x, y, z, p.window)

	local ex = not is_solid(g, x + 1, y, z) or not is_solid(g, x - 1, y, z)
	local ez = not is_solid(g, x, y, z + 1) or not is_solid(g, x, y, z - 1)
	local e_up = not is_solid(g, x, y + 1, z)
	local e_down = not is_solid(g, x, y - 1, z)

	-- 下方臨空（頂板／懸垂）：水平自由面上的垂直正應力 = 0。
	-- 上方臨空（地表／階梯狀坡面）不歸零：擴散荷重代表沿坡面方向的壓應力。
	local sx = ex and 0 or sh
	local sy = e_down and 0 or sv
	local sz = ez and 0 or sh

	local s1 = math.max(sx, sy, sz)
	local s3 = math.min(sx, sy, sz)
	local q = s1 - s3
	local strength = lith.ucs * p.strength_scale
	local exposed = ex or ez or e_up or e_down

	return {
		lith = key, h = stress.depth(y, p.surface_y),
		sv0 = sv0, sv = sv, sh = sh,
		factor = sv0 > 0 and sv / sv0 or 1,
		sx = sx, sy = sy, sz = sz, s1 = s1, s3 = s3, q = q,
		strength = strength, fs = q > 0 and strength / q or math.huge,
		exposed_x = ex, exposed_z = ez, exposed_up = e_up, exposed_down = e_down,
		exposed = exposed,
		fails = exposed and q >= strength,
	}
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

-- 以 (cx,cy,cz) 為中心、半邊長 r 的立方體評估
function failure.evaluate(g, p, cx, cy, cz, r)
	return failure.evaluate_boxes(g, p, {{
		{x = cx - r, y = cy - r, z = cz - r}, {x = cx + r, y = cy + r, z = cz + r},
	}})
end

return failure
