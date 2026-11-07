-- rockmech/femstress.lua
-- 開挖周圍彈性應力場（fem.lua）。
-- 地質羅盤點一格 → 以該格為中心讀 ±radius 的地圖，丟到背景執行緒解應力，解完用一兩行回報：
--   這一格的 σ1、σ3、FS（強度用現有的 Hoek-Brown 岩體強度，加張力截斷），以及範圍內臨空格最小的 FS。
-- 有臨空面的格取面上的應力（和崩落判定同一個數），內部的格取周圍 1 格內岩石格的平均。
-- 範圍外用粗網格（rockmech_fem_coarse）：先解大範圍的粗網格，它的位移當細網格的外緣，開口比範圍大也看得到。
-- 支護（岩栓、噴凝土）是面上的力，沿打設方向推進岩體。目前不含節理：岩體是均質彈性體。
-- 滿格碎石是軟的元素（rockmech_fem_rubble_e），岩壁收斂壓它就有水平與垂直的反力；貼著碎石的岩面照樣判定，碎石的應力當圍壓。
-- 參數在設定 rockmech_fem_*。
-- drive（rockmech_fem_drive）：由應力解決定崩落。開挖後排一次求解（同時只有一個工作，附近的開挖併在一起），
-- 解完檢查對著開挖空間的臨空面：取面上的應力（格中心看不到一格厚的梁的彎曲），與同一面相鄰的格平均以消掉角點奇異，
-- 拉力超過 σt 或軸差超過強度 → 該格變碎石，再解下一輪（最多 failure.max_cascade 輪）。
-- 檢查的面：對著開挖空間的面，加上離開挖點 NEAR 格內的所有臨空面（懸臂的拉力在上緣，上緣常常是天然地表）——
-- 後者只在觸發點真的挖過岩石時（砍樹、鏟土、放東西、碎石流動不算）；
-- 更遠的天然岩面不判定，避免別處的天然崖壁平白崩掉。

local cfg = rockmech.cfg
local fcfg = cfg.fem
local fem = rockmech.fem
core.register_async_dofile(rockmech.modpath .. "/fem.lua")

local function in_situ(job, c, sv)
	local th = math.rad(cfg.sH_azimuth or 0)
	local s2, c2, sc = math.sin(th) ^ 2, math.cos(th) ^ 2, math.sin(th) * math.cos(th)
	local sH, sh = rockmech.stress.horizontal({KH = cfg.KH, Kh = cfg.Kh, sH0 = cfg.sH0, sh0 = cfg.sh0, k0 = cfg.k0}, sv / 1000)
	sH, sh = sH * 1000, sh * 1000
	job.syy[c] = sv
	job.sxx[c] = s2 * sH + c2 * sh
	job.szz[c] = c2 * sH + s2 * sh
	job.sxz[c] = (sH - sh) * sc
end

-- 開挖前的地表：surface_y（挖掉的算回去，開挖才會放出應力）。生成時就有的露天坑是天然地形、已經平衡，
-- 坑裡的地表是坑的地面，否則一解就等於整個坑同時開挖
local function natural_top(x, z)
	local surface = cfg.surface_y or 0
	local h = cfg.open_pit and rockmech.stress.pit_surface(cfg.open_pit, surface, x, z)
	return h and math.floor(h) or surface
end

-- 支護（support.lua）→ job.press：力沿打設方向作用在面上。to_cell(世界 x, y, z) → 格索引或 nil；
-- scale = 1 m² 的力換成這個網格一面的壓力（粗網格 1/C²）
local function set_press(job, g, to_cell, scale)
	if not g.support then return end
	local sum = {}
	local pface = g.support.pface or {}
	for key, p0 in pairs(g.support.face) do
		local p = p0 - (pface[key] or 0)     -- 木柱在應力解裡是有勁度的元素，不是推力（make_job）
		local k = key % 8
		local i = (key - k) / 8 - 1
		local x = i % g.nx
		local r = (i - x) / g.nx
		local y = r % g.ny
		local c = to_cell(g.ox + x, g.oy + y, g.oz + (r - y) / g.ny)
		if c then sum[c * 8 + k] = (sum[c * 8 + k] or 0) + p * 1000 * scale end
	end
	local press, m = {}, 0
	for key, p in pairs(sum) do
		local k = key % 8
		press[m + 1], press[m + 2], press[m + 3] = (key - k) / 8, k, p
		m = m + 3
	end
	job.press = press
end

-- 粗網格（子模型的外圍）：同樣的格數，每格 C³ 公尺，一半以上是岩石就算實心。
-- 原點對齊 C 的倍數，附近的開挖共用同一個粗網格，上次的解當初始值。
-- 頂面對齊粗格（現地應力與重力才平衡，沒有開挖時 Δu = 0）。還沒生成的區塊：地表以下算岩石
local function make_coarse(pos)
	local C, r = fcfg.coarse, fcfg.radius
	local n = 2 * r + 1
	local half = r * C + (C - 1) / 2
	local function snap(v) return math.floor((v - half) / C + 0.5) * C end
	local a = {x = snap(pos.x), y = snap(pos.y), z = snap(pos.z)}
	local g = rockmech.collapse.read_grid(a, vector.add(a, n * C - 1))
	local job = {nx = n, ny = n, nz = n, h = C, a = a, solid = {}, sxx = {}, syy = {}, szz = {}, sxz = {},
		nu = fcfg.nu, tol = fcfg.tol, max_iter = fcfg.max_iter, blend = fcfg.coarse_blend,
		soft = {}, soft_e = fcfg.rubble_e}
	local sy, sz = g.nx, g.nx * g.ny
	local data, bonded = g.data, g.bonded_of
	local rubble = fcfg.rubble_e > 0 and g.rubble_of or {}
	local ignore, surf = core.CONTENT_IGNORE, cfg.surface_y or 0
	local base = 1 + (a.x - g.ox) + (a.y - g.oy) * sy + (a.z - g.oz) * sz
	local mid = math.floor((C - 1) / 2)
	local gam_sum, gam_n = 0, 0
	for z = 0, n - 1 do for x = 0, n - 1 do
		local cx, cz = C * x + mid, C * z + mid
		local top = natural_top(a.x + cx, a.z + cz)
		local col = 1 + (a.x + cx - g.ox) + (a.z + cz - g.oz) * sz
		for ly = g.ny - 1, 0, -1 do
			if bonded[data[col + ly * sy]] then
				top = math.max(top, g.oy + ly)
				break
			end
		end
		local ktop = math.floor((top - a.y) / C)
		for y = 0, n - 1 do
			local c = 1 + x + y * n + z * n * n
			local count, loose = 0, 0
			for dz = 0, C - 1 do for dy = 0, C - 1 do
				local row = base + C * x + (C * y + dy) * sy + (C * z + dz) * sz
				local under = a.y + C * y + dy <= surf
				for dx = 0, C - 1 do
					local id = data[row + dx]
					if bonded[id] or (under and id == ignore) then count = count + 1
					elseif rubble[id] == 1 then loose = loose + 1 end
				end
			end end
			local solid = 2 * count > C * C * C
			local soft = not solid and 2 * (count + loose) > C * C * C
			job.solid[c] = solid or soft
			job.soft[c] = soft or nil
			local lith = cfg.lithologies[g.lith_of[data[base + cx + (C * y + mid) * sy + cz * sz]]]
			local gamma = lith and lith.gamma or cfg.failure.gamma_other
			if solid then gam_sum, gam_n = gam_sum + gamma, gam_n + 1 end
			in_situ(job, c, gamma * C * math.max(0, ktop - y + 0.5))
			if soft then job.sxx[c], job.syy[c], job.szz[c], job.sxz[c] = 0, 0, 0, 0 end
		end
	end end
	job.gamma = C * (gam_n > 0 and gam_sum / gam_n or 25)    -- 單位立方體的方程式：γ·h，解出 Δu / h
	set_press(job, g, function(wx, wy, wz)
		local x, y, z = math.floor((wx - a.x) / C), math.floor((wy - a.y) / C), math.floor((wz - a.z) / C)
		if x >= 0 and y >= 0 and z >= 0 and x < n and y < n and z < n then return 1 + x + y * n + z * n * n end
	end, 1 / (C * C))
	return job
end

-- 上覆的鬆散材料（碎石、鬆土、崩積土、表土）的重量（collapse.lua 的 loose_of：cid → 厚度比例）：
--   頂面荷重 q = γ·h：岩石格正上方疊著的鬆散材料，h = 那一疊的厚度（不滿格照比例）
--   側向土壓 K₀·γ·z（Jaky：K₀ = 1 − sin φ，φ = 安息角）：靠在岩壁上的鬆散材料，z = 那一格中心到鬆散材料表面的深度
-- 天然表土（mapgen 鋪的，stress.natural_soil 算得出厚度）的重量也算進現地應力 σ₀，所以沒動過的地形兩邊抵銷、照樣平衡；
-- 剝掉表土等於卸載，堆上碎石等於加載。γ 用非岩性格的單位重（rockmech_failure_gamma_other）
local GAMMA_S = cfg.failure.gamma_other
local K0_S = 1 - math.sin(math.rad(cfg.slope.angle))
-- 網格 g 裡 (gx, ly, gz)（g 的索引，0 起算）往上連續的鬆散材料厚度 (m)，從 ly 那一格開始算
local function loose_above(g, gx, ly, gz)
	local h = 0
	local sy, sz = g.nx, g.nx * g.ny
	for y = ly, g.ny - 1 do
		local f = g.loose_of[g.data[1 + gx + y * sy + gz * sz]]
		if not f then break end
		h = h + f
	end
	return h
end
-- 這一欄天然表土的厚度 (m)：礦帶地形的岩石頂用公式算（跟 mapgen 一樣），否則用目前的岩石頂
local function natural_soil_m(wx, wz, top)
	local S = rockmech.stress
	local sy = math.floor(cfg.surface_y or 0)
	local rise
	if cfg.lane_terrain then rise = math.floor(S.lane_terrain(cfg, wx, wz) + 0.5) else rise = top - sy end
	if top < sy + rise then return 0 end      -- 從頂上挖低了：表土跟岩石一起挖掉了
	local key = S.lith_key_at(cfg, wx, sy + rise, wz)
	local ore = key and cfg.lithologies[key] and cfg.lithologies[key].ore
	local function rise_at(x, z)
		if cfg.lane_terrain then return math.floor(S.lane_terrain(cfg, x, z) + 0.5) end
		return 0
	end
	return S.natural_soil(cfg, wx, wz, rise, rise_at, ore) / 8
end

-- 組工作：box 內的岩石格、每格的現地應力（kPa，壓為正）。
-- 現地應力是開挖前的狀態，由座標算（挖掉的算回去，所以開挖才會放出應力）；
-- 開挖過的位置上的岩石是回填，從沒受過上覆荷重，現地應力為 0
local function make_job(pos)
	local r = fcfg.radius
	local a = vector.subtract(pos, r)
	local b = vector.add(pos, r)
	local g = rockmech.collapse.read_grid(a, b)      -- 往上多讀，找每一欄的岩石頂面
	local n = 2 * r + 1
	local job = {nx = n, ny = n, nz = n, solid = {}, sxx = {}, syy = {}, szz = {}, sxz = {},
		nu = fcfg.nu, tol = fcfg.tol, max_iter = fcfg.max_iter, gamma = 25, soft = {}, soft_e = fcfg.rubble_e}
	local gsy, gsz = g.nx, g.nx * g.ny
	local gam_sum, gam_n = 0, 0
	local is_excavated_at = rockmech.collapse.is_excavated_at
	-- 木柱（timber.lua）：有勁度的元素，勁度 = 岩石 × 等效斷面積 A_eff / 1 m²（假設木材與岩石的 E 同級）。
	-- 跟碎石一樣沒有現地應力、不加重力，頂板往下收斂壓它才受力；這格的 σv × 1 m² 就是木柱的軸力
	local post_ids = rockmech.support_ids and rockmech.support_ids.post or {}
	local post_r = math.max(1e-4, cfg.support.post_fem_area or 0.5)
	for z = 0, n - 1 do for x = 0, n - 1 do
		-- 這一欄的地表：岩石頂面，或 surface_y（挖掉的算回去，所以開挖才會放出應力）
		local gx, gz = a.x + x - g.ox, a.z + z - g.oz
		local top = natural_top(a.x + x, a.z + z)
		for ly = g.ny - 1, 0, -1 do
			if g.bonded_of[g.data[1 + gx + ly * gsy + gz * gsz]] then
				top = math.max(top, g.oy + ly)
				break
			end
		end
		local sv_soil = g.loose_of and GAMMA_S * natural_soil_m(a.x + x, a.z + z, top) or 0   -- 天然表土的重量 (kPa)
		for y = 0, n - 1 do
			local wy = a.y + y
			local gi = 1 + gx + (wy - g.oy) * gsy + gz * gsz
			local cid = g.data[gi]
			local c = 1 + x + y * n + z * n * n
			local key = g.lith_of[cid]
			local lith = key and cfg.lithologies[key]
			local gamma = lith and lith.gamma or cfg.failure.gamma_other
			local solid = g.bonded_of[cid] and true or false
			local soft = fcfg.rubble_e > 0 and g.rubble_of[cid] == 1
			if post_ids[cid] then soft = post_r end
			if solid then gam_sum, gam_n = gam_sum + gamma, gam_n + 1 end
			local sv = gamma * math.max(0, top + 0.5 - wy) + (wy <= top and sv_soil or 0)     -- kPa
			job.solid[c] = solid or (soft and true) or false
			job.soft[c] = soft or nil
			if soft or (solid and is_excavated_at(a.x + x, wy, a.z + z)) then
				job.syy[c], job.sxx[c], job.szz[c], job.sxz[c] = 0, 0, 0, 0
			else
				in_situ(job, c, sv)
			end
		end
	end end
	if gam_n > 0 then job.gamma = gam_sum / gam_n end
	set_press(job, g, function(wx, wy, wz)
		local x, y, z = wx - a.x, wy - a.y, wz - a.z
		if x >= 0 and y >= 0 and z >= 0 and x < n and y < n and z < n then return 1 + x + y * n + z * n * n end
	end, 1)
	-- 鬆散材料的重量：頂面 γ·h、側面 K₀·γ·z（見上面 loose_above）
	if g.loose_of then
		local press = job.press or {}
		job.press = press
		local SIDES = {{1, 0, 1}, {-1, 0, 2}, {0, 1, 5}, {0, -1, 6}}
		for z = 0, n - 1 do for y = 0, n - 1 do for x = 0, n - 1 do
			local c = 1 + x + y * n + z * n * n
			if job.solid[c] and not job.soft[c] then
				local gx, ly, gz = a.x + x - g.ox, a.y + y - g.oy, a.z + z - g.oz
				local h = loose_above(g, gx, ly + 1, gz)
				if h > 0 then press[#press + 1], press[#press + 2], press[#press + 3] = c, 3, GAMMA_S * h end
				for _, d in ipairs(SIDES) do
					local nx_, nz_ = gx + d[1], gz + d[2]
					if nx_ >= 0 and nz_ >= 0 and nx_ < g.nx and nz_ < g.nz then
						local f = g.loose_of[g.data[1 + nx_ + ly * gsy + nz_ * gsz]]
						if f then
							local zc = loose_above(g, nx_, ly + 1, nz_) + f / 2
							press[#press + 1], press[#press + 2], press[#press + 3] = c, d[3], K0_S * GAMMA_S * zc
						end
					end
				end
			end
		end end end
	end
	-- 判定要用：每格的岩性（collapse.rock 查強度）、是不是空的（碎石算空：貼著它的岩面要判定，反力在 face_fs）
	local meta = {a = a, r = r, lith = {}, p2 = {}, open = {}, press = {}}
	local press = job.press or {}
	for i = 1, #press, 3 do
		local key = press[i] * 8 + press[i + 1]
		meta.press[key] = (meta.press[key] or 0) + press[i + 2]
	end
	for c = 1, n * n * n do
		local k = c - 1
		local x, y, z = k % n, math.floor(k / n) % n, math.floor(k / (n * n))
		local gi = 1 + (a.x + x - g.ox) + (a.y + y - g.oy) * gsy + (a.z + z - g.oz) * gsz
		meta.lith[c] = g.lith_of[g.data[gi]]
		meta.p2[c] = g.p2[gi]
		meta.open[c] = not g.solid_of[g.data[gi]] or g.rubble_of[g.data[gi]] ~= nil
	end
	return job, meta
end

local function fs_text(f) return f == math.huge and "∞" or ("%.2f"):format(f) end

-- 強度：剪力 q_f(σ3)/q、張力 σt/|σ3|（應力 MPa），取較小。回傳 FS, 破壞型式
local function strength_fs(job, meta, x, y, z, s1, s3)
	local n = job.nx
	local c = 1 + x + y * n + z * n * n
	local rm = rockmech.collapse.rock.at(meta.lith[c], meta.a.y + y, meta.p2[c])
	local q = s1 - s3
	local fs, mode = q > 0 and rockmech.collapse.rock.q_fail(rm, math.max(0, s3)) / q or math.huge, "剪"
	if s3 < 0 and rm.sigt / -s3 < fs then fs, mode = rm.sigt / -s3, "拉" end
	return fs, mode
end

-- 六個面：往 (dx, dy, dz) 的臨空面上的點，與面上的兩個切向
local FACES = {
	{1, 0, 0, 0, 1, 0, 0, 0, 1}, {-1, 0, 0, 0, 1, 0, 0, 0, 1},
	{0, 1, 0, 1, 0, 0, 0, 0, 1}, {0, -1, 0, 1, 0, 0, 0, 0, 1},
	{0, 0, 1, 1, 0, 0, 0, 1, 0}, {0, 0, -1, 1, 0, 0, 0, 1, 0},
}
-- 格 (x, y, z) 往 f 的面：與同一面相鄰（±1 格、同樣對著空的）的面上應力平均 → FS, 破壞型式, σ1, σ3（MPa）
local function face_fs(job, res, meta, x, y, z, f)
	local n = job.nx
	local dx, dy, dz = f[1], f[2], f[3]
	local sum, m = {0, 0, 0, 0, 0, 0}, 0
	local xi = dx ~= 0 and (dx > 0 and 1 or 0) or 0.5
	local eta = dy ~= 0 and (dy > 0 and 1 or 0) or 0.5
	local zeta = dz ~= 0 and (dz > 0 and 1 or 0) or 0.5
	for a = -1, 1 do for b = -1, 1 do
		local cx, cy, cz = x + a * f[4] + b * f[7], y + a * f[5] + b * f[8], z + a * f[6] + b * f[9]
		if cx >= 1 and cy >= 1 and cz >= 1 and cx < n - 1 and cy < n - 1 and cz < n - 1
				and job.solid[1 + cx + cy * n + cz * n * n] and not job.soft[1 + cx + cy * n + cz * n * n]
				and meta.open[1 + (cx + dx) + (cy + dy) * n + (cz + dz) * n * n] then
			local t = {fem.point_stress(job, res, cx, cy, cz, xi, eta, zeta)}
			for i = 1, 6 do sum[i] = sum[i] + t[i] end
			m = m + 1
		end
	end end
	if m == 0 then return math.huge end
	local st = {}
	for i = 1, 6 do st[i] = sum[i] / m end
	local k = dx > 0 and 1 or dx < 0 and 2 or dy > 0 and 3 or dy < 0 and 4 or dz > 0 and 5 or 6
	local p = meta.press[(1 + x + y * n + z * n * n) * 8 + k] or 0
	local out = 1 + (x + dx) + (y + dy) * n + (z + dz) * n * n
	if job.soft[out] then       -- 碎石壓在這一面的反力（受拉不算）
		p = p + math.max(0, (dx ~= 0 and res.sxx or dy ~= 0 and res.syy or res.szz)[out])
	end
	fem.free_face(st, dx ~= 0 and 1 or dy ~= 0 and 2 or 3, p)
	local s1, _, s3 = fem.principal(st[1], st[2], st[3], st[4], st[5], st[6])
	s1, s3 = s1 / 1000, s3 / 1000
	local fs, mode = strength_fs(job, meta, x, y, z, s1, s3)
	return fs, mode, s1, s3
end

-- 顯示用的 FS：有臨空面取最危險的面（與崩落判定同一個數），內部的格取周圍 1 格平均。回傳 FS, σ1, σ3, 破壞型式
local function cell_fs(job, res, meta, x, y, z)
	local n = job.nx
	if not meta.lith[1 + x + y * n + z * n * n] then return nil end
	if x >= 1 and y >= 1 and z >= 1 and x < n - 1 and y < n - 1 and z < n - 1 then
		local best, b1, b3, bm
		for _, f in ipairs(FACES) do
			if meta.open[1 + (x + f[1]) + (y + f[2]) * n + (z + f[3]) * n * n] then
				local fs, mode, s1, s3 = face_fs(job, res, meta, x, y, z, f)
				if not best or fs < best then best, b1, b3, bm = fs, s1, s3, mode end
			end
		end
		if best and b1 then return best, b1, b3, bm end
	end
	local s1, _, s3 = fem.cell_principal(job, res, x, y, z, 1)
	if not s1 then return nil end
	s1, s3 = s1 / 1000, s3 / 1000
	local fs, mode = strength_fs(job, meta, x, y, z, s1, s3)
	return fs, s1, s3, mode
end

-- 對著開挖空間、或離開挖點 near 格內（center 為 nil 時只看開挖空間）的臨空格裡，FS < 1 的格（由上往下）。
-- 回傳 failed, 檢查的面數
local NEAR = 8
local function find_failed(job, res, meta, center)
	local n = job.nx
	local a = meta.a
	local failed, faces, warned = {}, 0, {}
	for z = 2, n - 3 do for y = 2, n - 3 do for x = 2, n - 3 do
		if job.solid[1 + x + y * n + z * n * n] and meta.lith[1 + x + y * n + z * n * n] then
			local low, lmode = math.huge, nil
			for _, f in ipairs(FACES) do
				local ax, ay, az = x + f[1], y + f[2], z + f[3]
				local wx, wy, wz = a.x + ax, a.y + ay, a.z + az
				if meta.open[1 + ax + ay * n + az * n * n]
						and ((center and math.max(math.abs(wx - center.x), math.abs(wy - center.y), math.abs(wz - center.z)) <= NEAR)
							or rockmech.collapse.is_excavated({x = wx, y = wy, z = wz})) then
					faces = faces + 1
					local fs, mode = face_fs(job, res, meta, x, y, z, f)
					if fs < low then low, lmode = fs, mode end
				end
			end
			if low < 1 then
				failed[#failed + 1] = {x = a.x + x, y = a.y + y, z = a.z + z}
			elseif low < cfg.fswarn.max then
				warned[#warned + 1] = {pos = {x = a.x + x, y = a.y + y, z = a.z + z}, fs = low, mode = lmode}
			end
		end
	end end end
	table.sort(failed, function(u, v) return u.y > v.y end)
	return failed, faces, warned
end

-- 警戒裂紋：每次解完，範圍內判定過的面裡 1 ≤ FS < fswarn.max 的格（換掉這個範圍原本的記錄）
local cracks = {}
local function update_cracks(meta, n, warned)
	local x1, y1, z1 = meta.a.x + 2, meta.a.y + 2, meta.a.z + 2
	local x2, y2, z2 = meta.a.x + n - 3, meta.a.y + n - 3, meta.a.z + n - 3
	for k, c in pairs(cracks) do
		local p = c.pos
		if p.x >= x1 and p.x <= x2 and p.y >= y1 and p.y <= y2 and p.z >= z1 and p.z <= z2 then cracks[k] = nil end
	end
	for _, c in ipairs(warned) do cracks[core.pos_to_string(c.pos)] = c end
end

-- a..b 內有裂紋的格：{{pos, fs, mode}...}
function rockmech.fem_warned(a, b)
	local out = {}
	for _, c in pairs(cracks) do
		local p = c.pos
		if p.x >= a.x and p.x <= b.x and p.y >= a.y and p.y <= b.y and p.z >= a.z and p.z <= b.z then out[#out + 1] = c end
	end
	return out
end

-- 回報：點的那一格與範圍內臨空格最小的 FS
local function report(pos, job, res, meta)
	local n = job.nx
	local a = meta.a
	local lines = {}
	local x0, y0, z0 = pos.x - a.x, pos.y - a.y, pos.z - a.z
	local fs, s1, s3, mode = cell_fs(job, res, meta, x0, y0, z0)
	core.log("action", ("[rockmech] 應力解 %s 半徑 %d：%d 輪、殘差 %.1e、%.0f ms"):format(
		core.pos_to_string(pos), meta.r, res.iters, res.res, res.ms))
	if fs then
		lines[#lines + 1] = core.colorize("#80d0ff", "[羅盤] ") ..
			("σ1 %.2f　σ3 %.2f MPa　FS %s（%s）"):format(s1, s3, fs_text(fs), mode)
	end
	local best, bp, bs1, bs3, bm
	local cnt, fails = 0, 0
	local solid = job.solid
	local function at(x, y, z)
		local c = 1 + x + y * n + z * n * n
		return x >= 0 and y >= 0 and z >= 0 and x < n and y < n and z < n and solid[c] and not job.soft[c]
	end
	for z = 1, n - 2 do for y = 1, n - 2 do for x = 1, n - 2 do
		if at(x, y, z) and meta.lith[1 + x + y * n + z * n * n] and
				(not at(x + 1, y, z) or not at(x - 1, y, z) or not at(x, y + 1, z) or not at(x, y - 1, z)
				or not at(x, y, z + 1) or not at(x, y, z - 1)) then
			local f, a1, a3, m = cell_fs(job, res, meta, x, y, z)
			if f then
				cnt = cnt + 1
				if f < 1 then fails = fails + 1 end
				if not best or f < best then best, bp, bs1, bs3, bm = f, {x = a.x + x, y = a.y + y, z = a.z + z}, a1, a3, m end
			end
		end
	end end end
	-- 周圍有明顯比這一格更危險的才顯示
	if best and (not fs or best < 0.95 * fs) then
		lines[#lines + 1] = ("周圍最低 FS %s（%s）@ %s"):format(fs_text(best), bm, core.pos_to_string(bp))
	end
	return table.concat(lines, "\n"), {fs = fs, s1 = s1, s3 = s3, mode = mode, min = best, min_pos = bp, fails = fails, count = cnt}
end
rockmech.fem_report = report

-- 同一個範圍上次的解當初始值，迭代會少很多（u 留在主執行緒）
local last_key, last_u, last_ckey, last_cu
local last_job, last_res, last_meta      -- 最後一次的解（HUD 用）
function rockmech.fem_run(pos, callback)
	local t0 = core.get_us_time()
	local job, meta = make_job(pos)
	local key = core.pos_to_string(meta.a)
	if key == last_key then job.u0 = last_u end
	local ckey
	if fcfg.coarse > 1 then
		local cj = make_coarse(pos)
		cj.ox, cj.oy, cj.oz = cj.a.x - meta.a.x, cj.a.y - meta.a.y, cj.a.z - meta.a.z
		ckey = core.pos_to_string(cj.a)
		if ckey == last_ckey then cj.u0 = last_cu end
		job.coarse = cj
	end
	local t_build = (core.get_us_time() - t0) / 1000
	core.handle_async(function(j)
		return core.rockmech_fem.solve_nested(j)
	end, function(res)
		last_key, last_u, last_ckey, last_cu = key, res.u, ckey, res.cu
		last_job, last_res, last_meta = job, res, meta
		callback(job, res, meta, (core.get_us_time() - t0) / 1000, t_build)
	end, job)
end

-- 最後一次解涵蓋 pos 時回傳 {s1, s3, fs}（MPa），給 HUD
function rockmech.fem_cell(pos)
	if not (fcfg.drive and last_job) then return nil end
	local n = last_job.nx
	local x, y, z = pos.x - last_meta.a.x, pos.y - last_meta.a.y, pos.z - last_meta.a.z
	if x < 0 or y < 0 or z < 0 or x >= n or y >= n or z >= n then return nil end
	local c = 1 + x + y * n + z * n * n
	if not last_job.solid[c] or last_job.soft[c] then return nil end
	local fs, s1, s3 = cell_fs(last_job, last_res, last_meta, x, y, z)
	return fs and {fs = fs, s1 = s1, s3 = s3}
end

-- 粗網格看到細網格範圍外有拉力大的開挖頂板（開挖點在房間邊緣時，跨中不在範圍內）：回傳該處的位置，派細網格去判定。
-- 粗網格的應力只用來找位置，FS < HOT_FS 才值得多解一次
local HOT_FS = 1.5
local function hot_spot(job, res, cur)
	local cj = job.coarse
	if not (cj and res.hot) then return nil end
	local C, a = cj.h, cj.a
	local mid = math.floor((C - 1) / 2)
	local collapse = rockmech.collapse
	for _, h in ipairs(res.hot) do
		local p = {x = a.x + C * h[1] + mid, y = a.y + C * h[2], z = a.z + C * h[3]}
		if math.max(math.abs(p.x - cur.pos.x), math.abs(p.y - cur.pos.y), math.abs(p.z - cur.pos.z)) > fcfg.radius / 2 then
			for dy = 0, C - 1 do
				local q = {x = p.x, y = p.y + dy, z = p.z}
				local node = core.get_node(q)
				local lith = rockmech.lith_of_node[node.name]
				if lith then
					if collapse.is_excavated({x = q.x, y = q.y - 1, z = q.z}) then
						local rm = collapse.rock.at(lith.name, q.y, node.param2)
						local s1, s3 = h[4] / 1000, h[5] / 1000
						local fs = math.min(collapse.rock.q_fail(rm, 0) / (s1 - s3), rm.sigt / -s3)
						if fs < HOT_FS then return q end
					end
					break
				end
			end
		end
	end
	return nil
end

-- 最後一次解涵蓋 (x, y, z) 時回傳格中心的應力 {σxx, σyy, σzz, σxz, σxy, σyz}（MPa），給關鍵塊體的夾持力
function rockmech.fem_tensor(x, y, z)
	if not last_job then return nil end
	local n = last_job.nx
	local cx, cy, cz = x - last_meta.a.x, y - last_meta.a.y, z - last_meta.a.z
	if cx < 2 or cy < 2 or cz < 2 or cx >= n - 2 or cy >= n - 2 or cz >= n - 2 then return nil end
	local c = 1 + cx + cy * n + cz * n * n
	if not last_job.solid[c] or last_job.soft[c] then return nil end
	local r = last_res
	return {r.sxx[c] / 1000, r.syy[c] / 1000, r.szz[c] / 1000, r.szx[c] / 1000, r.sxy[c] / 1000, r.syz[c] / 1000}
end

-- 頂到岩石、旁邊有自由面的碎石：解出來的 σv 當荷重，往自由面擠（每次解最多 SQUEEZE_MAX 欄，應力大的先）。
-- 四周都被圍住的碎石只受壓，不動
local SQUEEZE_MAX = 32
local function squeeze_rubble(job, res, meta)
	local n = job.nx
	local list = {}
	for c, s in pairs(job.soft) do
		local k = c - 1
		local x, y, z = k % n, math.floor(k / n) % n, math.floor(k / (n * n))
		local above = c + n
		if type(s) ~= "number"          -- 木柱不是碎石
				and x >= 2 and y >= 2 and z >= 2 and x < n - 2 and y < n - 2 and z < n - 2
				and job.solid[above] and not job.soft[above] and res.syy[c] > 0 then
			for _, o in ipairs({1, -1, n * n, -n * n}) do
				if meta.open[c + o] and not job.soft[c + o] then
					list[#list + 1] = {x, y, z, res.syy[c]}
					break
				end
			end
		end
	end
	table.sort(list, function(p, q) return p[4] > q[4] end)
	for i = 1, math.min(#list, SQUEEZE_MAX) do
		local e = list[i]
		rockmech.collapse.squeeze({x = meta.a.x + e[1], y = meta.a.y + e[2], z = meta.a.z + e[3]}, e[4])
	end
end

-- 開挖後排解：同時只有一個工作；排隊中離得近的併成一個（範圍內都檢查得到）。
-- far：粗網格派來的，只判定對著開挖空間的面
local pending, busy = {}, false

-- 離所有玩家超過 active_range 的工作先擱置（連鎖崩落的每一輪都經過這裡），玩家回來才從那一輪接著解。
-- 擱置的工作存在世界裡，重開遊戲也接得上
local PARK_KEY = "fem_parked"
local parked = core.deserialize(rockmech.collapse.storage:get_string(PARK_KEY)) or {}
local function save_parked()
	rockmech.collapse.storage:set_string(PARK_KEY, #parked > 0 and core.serialize(parked) or "")
end
local function player_near(p)
	if fcfg.active_range <= 0 then return true end
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), p) <= fcfg.active_range then return true end
	end
	return false
end
local function park(cur)
	core.log("action", ("[rockmech] 玩家離開，應力解暫停 %s 第 %d 輪"):format(core.pos_to_string(cur.pos), cur.round))
	for _, q in ipairs(parked) do
		if vector.distance(q.pos, cur.pos) <= fcfg.radius / 2 then
			q.round = math.min(q.round, cur.round)
			q.far = q.far and cur.far
			q.excav = q.excav or cur.excav
			save_parked()
			return
		end
	end
	parked[#parked + 1] = {pos = cur.pos, round = cur.round, far = cur.far, excav = cur.excav}
	save_parked()
end

-- 同一區（fcfg.radius / 2 內）最快 INTERVAL 秒解一次：這段時間內的觸發併進同一筆（fem_queue），主執行緒組工作不必每秒都做
local INTERVAL = rockmech.cfg.failure.interval or 5
local recent = {}         -- 最近解過的 {pos, t}
local pump_at             -- 已排定的下一次 pump 時間 (s)
local function now() return core.get_us_time() / 1e6 end
local function ready_in(p)
	local t, wait = now(), 0
	for i = #recent, 1, -1 do
		local r = recent[i]
		if t - r.t >= INTERVAL then table.remove(recent, i)
		elseif vector.distance(r.pos, p) <= fcfg.radius / 2 then wait = math.max(wait, r.t + INTERVAL - t) end
	end
	return wait
end
local pump
local function schedule_pump(wait)
	local at = now() + wait
	if pump_at and pump_at <= at + 0.01 then return end
	pump_at = at
	core.after(wait, function() pump_at = nil; pump() end)
end

pump = function()
	if busy then return end
	local cur
	while not cur do
		-- 第一個不用等的；都要等就排在最早可以的時候
		local best_wait, idx = math.huge, nil
		for i, q in ipairs(pending) do
			local w = ready_in(q.pos)
			if w <= 0 then idx = i; best_wait = 0; break end
			if w < best_wait then best_wait = w end
		end
		if not idx then
			if #pending > 0 then schedule_pump(best_wait) end
			return
		end
		cur = table.remove(pending, idx)
		if not player_near(cur.pos) then
			park(cur)
			cur = nil
		end
	end
	recent[#recent + 1] = {pos = cur.pos, t = now()}
	busy = true
	rockmech.fem_run(cur.pos, function(job, res, meta, ms, t_build)
		local t0 = core.get_us_time()
		-- 天然坡面（離觸發點 NEAR 格內、不是對著開挖空間的面）只在觸發點真的挖過岩石（或上一輪有破壞）時才判定：
		-- 天然地形視為已經平衡，砍樹、鏟土、放東西、碎石流動不會讓附近的天然邊坡平白垮掉
		local failed, faces, warned = find_failed(job, res, meta, (not cur.far and cur.excav) and cur.pos or nil)
		update_cracks(meta, job.nx, warned)
		-- 木柱（timber.lua）：木柱格的 σv × 1 m² = 軸力，超過承載力就壓斷；柱頂上方頂板破壞也一起斷。
		-- 名牌寫軸力和上方頂板的 FS
		if rockmech.timber_fem_check then
			local n, a = job.nx, meta.a
			local function cell(wx, wy, wz)
				local x, y, z = wx - a.x, wy - a.y, wz - a.z
				if x < 1 or y < 1 or z < 1 or x >= n - 1 or y >= n - 1 or z >= n - 1 then return nil end
				return 1 + x + y * n + z * n * n, x, y, z
			end
			rockmech.timber_fem_check(a, n, failed, function(wx, wy, wz)
				local c, x, y, z = cell(wx, wy, wz)
				if not c or not job.solid[c] or job.soft[c] or not meta.lith[c] or not meta.open[c - n] then return nil end
				return (face_fs(job, res, meta, x, y, z, FACES[4]))
			end, function(wx, wy, wz)
				local c = cell(wx, wy, wz)
				if not c or type(job.soft[c]) ~= "number" then return nil end
				return math.max(0, res.syy[c])        -- kPa × 1 m² = kN（壓為正）
			end)
		end
		if not cur.far then squeeze_rubble(job, res, meta) end
		if rockmech.fswarn_refresh then rockmech.fswarn_refresh(cur.pos) end
		if cur.excav or #failed > 0 then rockmech.collapse.queue_block_check(cur.pos) end
		local t_eval = (core.get_us_time() - t0) / 1000
		if #failed > 0 then      -- 只有真的有岩石破壞才記（每次都記 debug.txt 一天幾十 MB）
			core.log("action", ("[rockmech] 應力解驅動 %s 第 %d 輪：%d 輪迭代、解 %.0f ms、組工作 %.1f ms、判定 %.1f ms（%d 面）、總 %.0f ms → %d 格破壞")
				:format(core.pos_to_string(cur.pos), cur.round, res.iters, res.ms, t_build, t_eval, faces, ms, #failed))
		end
		if #failed > 0 then
			rockmech.collapse.apply_failure(failed, cur.round)
			if cur.round < cfg.failure.max_cascade then
				core.after(cfg.failure.cascade_delay, rockmech.fem_queue, cur.pos, cur.round + 1, cur.far, true)
			end
		end
		if cur.round < cfg.failure.max_cascade then
			local q = hot_spot(job, res, cur)
			if q then rockmech.fem_queue(q, cur.round + 1, true) end
		end
		busy = false
		pump()
	end)
end
-- excav：觸發點是挖過的岩石（省略時查開挖紀錄）；只有這樣才判定附近的天然坡面
function rockmech.fem_queue(pos, round, far, excav)
	local p = vector.round(pos)
	if excav == nil then excav = rockmech.collapse.is_excavated(p) end
	for _, q in ipairs(pending) do
		if vector.distance(q.pos, p) <= fcfg.radius / 2 then
			q.round = math.min(q.round, round)
			q.far = q.far and far
			q.excav = q.excav or excav
			return
		end
	end
	pending[#pending + 1] = {pos = p, round = round, far = far, excav = excav}
	core.after(0, pump)
end
local PARK_CHECK = 2      -- 每幾秒看一次玩家回來了沒
local park_t = 0
core.register_globalstep(function(dtime)
	park_t = park_t + dtime
	if park_t < PARK_CHECK or #parked == 0 then return end
	park_t = 0
	for i = #parked, 1, -1 do
		local q = parked[i]
		if player_near(q.pos) then
			table.remove(parked, i)
			save_parked()
			core.log("action", ("[rockmech] 玩家回來，應力解接著 %s 第 %d 輪"):format(core.pos_to_string(q.pos), q.round))
			rockmech.fem_queue(q.pos, q.round, q.far, q.excav)
		end
	end
end)

-- 玩家走到附近有開挖、但還沒解過的地方（例如重開遊戲）：解一次，裂紋才看得到
local WATCH_MOVE, WATCH_R = 6, 10
local watched
function rockmech.fem_watch(center)
	if not fcfg.drive or (watched and vector.distance(watched, center) <= WATCH_MOVE) then return end
	watched = vector.round(center)
	local is_excavated = rockmech.collapse.is_excavated
	for dz = -WATCH_R, WATCH_R, 2 do for dy = -WATCH_R, WATCH_R, 2 do for dx = -WATCH_R, WATCH_R, 2 do
		if is_excavated({x = watched.x + dx, y = watched.y + dy, z = watched.z + dz}) then
			rockmech.fem_queue(watched, 1, true)
			return
		end
	end end end
end

if fcfg.drive then
	local collapse = rockmech.collapse
	local orig = collapse.queue_failure_check
	collapse.queue_failure_check = function(pos, prev, r, round, far)
		orig(pos, prev, r, round)
		-- 被移除的是完整岩石才算開挖（碎石、土、樹、木頭不算；on_destruct 時那一格還是原本的方塊）
		local name = prev or core.get_node(vector.round(pos)).name
		rockmech.fem_queue(pos, round or 1, far, rockmech.lith_of_node[name] ~= nil)
	end
end

-- 羅盤點一格：解完送訊息給玩家
function rockmech.fem_request(pos, name)
	rockmech.fem_run(pos, function(job, res, meta)
		core.chat_send_player(name, (report(pos, job, res, meta)))
	end)
end
