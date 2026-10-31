-- rockmech/femstress.lua
-- 開挖周圍彈性應力場的原型（fem.lua）：只顯示，不影響任何崩落判定。
-- 地質羅盤點一格 → 以該格為中心讀 ±radius 的地圖，丟到背景執行緒解應力，解完用一兩行回報：
--   這一格的 σ1、σ3、FS（強度用現有的 Hoek-Brown 岩體強度，加張力截斷），以及範圍內臨空格最小的 FS。
-- 應力取周圍 1 格內岩石格的平均（消掉方塊角點的應力奇異）。
-- 目前不含節理與支護：岩體是均質彈性體。
-- 參數在設定 rockmech_fem_*。
-- drive（rockmech_fem_drive）：由應力解決定崩落。開挖後排一次求解（同時只有一個工作，附近的開挖併在一起），
-- 解完檢查對著開挖空間的臨空面：取面上的應力（格中心看不到一格厚的梁的彎曲），與同一面相鄰的格平均以消掉角點奇異，
-- 拉力超過 σt 或軸差超過強度 → 該格變碎石，再解下一輪（最多 failure.max_cascade 輪）。
-- 檢查的面：對著開挖空間的面，加上離開挖點 NEAR 格內的所有臨空面（懸臂的拉力在上緣，上緣常常是天然地表）；
-- 更遠的天然岩面不判定，避免別處的天然崖壁平白崩掉。

local cfg = rockmech.cfg
local fcfg = cfg.fem
local fem = rockmech.fem
core.register_async_dofile(rockmech.modpath .. "/fem.lua")

-- 組工作：box 內的岩石格、每格的現地應力（kPa，壓為正）
local function make_job(pos)
	local r = fcfg.radius
	local a = vector.subtract(pos, r)
	local b = vector.add(pos, r)
	local g = rockmech.collapse.read_grid(a, b)      -- 往上多讀，找每一欄的岩石頂面
	local n = 2 * r + 1
	local job = {nx = n, ny = n, nz = n, solid = {}, sxx = {}, syy = {}, szz = {}, sxz = {},
		nu = fcfg.nu, tol = fcfg.tol, max_iter = fcfg.max_iter, gamma = 25}
	local th = math.rad(cfg.sH_azimuth or 0)
	local s2, c2, sc = math.sin(th) ^ 2, math.cos(th) ^ 2, math.sin(th) * math.cos(th)
	local hcfg = {KH = cfg.KH, Kh = cfg.Kh, sH0 = cfg.sH0, sh0 = cfg.sh0, k0 = cfg.k0}
	local gsy, gsz = g.nx, g.nx * g.ny
	local gam_sum, gam_n = 0, 0
	for z = 0, n - 1 do for x = 0, n - 1 do
		-- 這一欄的地表：岩石頂面，或 surface_y（挖掉的算回去，所以開挖才會放出應力）
		local gx, gz = a.x + x - g.ox, a.z + z - g.oz
		local top = cfg.surface_y or 0
		for ly = g.ny - 1, 0, -1 do
			if g.bonded_of[g.data[1 + gx + ly * gsy + gz * gsz]] then
				top = math.max(top, g.oy + ly)
				break
			end
		end
		for y = 0, n - 1 do
			local wy = a.y + y
			local gi = 1 + gx + (wy - g.oy) * gsy + gz * gsz
			local cid = g.data[gi]
			local c = 1 + x + y * n + z * n * n
			local key = g.lith_of[cid]
			local lith = key and cfg.lithologies[key]
			local gamma = lith and lith.gamma or cfg.failure.gamma_other
			local solid = g.bonded_of[cid] and true or false
			if solid then gam_sum, gam_n = gam_sum + gamma, gam_n + 1 end
			local sv = gamma * math.max(0, top + 0.5 - wy)     -- kPa
			local sH, sh = rockmech.stress.horizontal(hcfg, sv / 1000)
			sH, sh = sH * 1000, sh * 1000
			job.solid[c] = solid
			job.syy[c] = sv
			job.sxx[c] = s2 * sH + c2 * sh
			job.szz[c] = c2 * sH + s2 * sh
			job.sxz[c] = (sH - sh) * sc
		end
	end end
	if gam_n > 0 then job.gamma = gam_sum / gam_n end
	-- 判定要用：每格的岩性（collapse.rock 查強度）、是不是空的（碎石不算空）
	local meta = {a = a, r = r, lith = {}, p2 = {}, open = {}}
	for c = 1, n * n * n do
		local k = c - 1
		local x, y, z = k % n, math.floor(k / n) % n, math.floor(k / (n * n))
		local gi = 1 + (a.x + x - g.ox) + (a.y + y - g.oy) * gsy + (a.z + z - g.oz) * gsz
		meta.lith[c] = g.lith_of[g.data[gi]]
		meta.p2[c] = g.p2[gi]
		meta.open[c] = not g.solid_of[g.data[gi]]
	end
	return job, meta
end

-- 一格的 FS：剪力 q_f(σ3)/q、張力 σt/|σ3|（σ3 < 0 為拉），取較小
local function cell_fs(job, res, meta, x, y, z)
	local s1, _, s3 = fem.cell_principal(job, res, x, y, z, 1)
	if not s1 then return nil end
	s1, s3 = s1 / 1000, s3 / 1000
	local n = job.nx
	local c = 1 + x + y * n + z * n * n
	local rm = rockmech.collapse.rock.at(meta.lith[c], meta.a.y + y, meta.p2[c])
	local fs, mode
	local q = s1 - s3
	local qf = rockmech.collapse.rock.q_fail(rm, math.max(0, s3))
	fs, mode = q > 0 and qf / q or math.huge, "剪"
	if s3 < 0 then
		local ft = rm.sigt / -s3
		if ft < fs then fs, mode = ft, "拉" end
	end
	return fs, s1, s3, mode
end

local function fs_text(f) return f == math.huge and "∞" or ("%.2f"):format(f) end

-- 強度：剪力 q_f(σ3)/q、張力 σt/|σ3|（應力 MPa），取較小
local function strength_fs(job, meta, x, y, z, s1, s3)
	local n = job.nx
	local c = 1 + x + y * n + z * n * n
	local rm = rockmech.collapse.rock.at(meta.lith[c], meta.a.y + y, meta.p2[c])
	local q = s1 - s3
	local fs = q > 0 and rockmech.collapse.rock.q_fail(rm, math.max(0, s3)) / q or math.huge
	if s3 < 0 then fs = math.min(fs, rm.sigt / -s3) end
	return fs
end

-- 六個面：往 (dx, dy, dz) 的臨空面上的點，與面上的兩個切向
local FACES = {
	{1, 0, 0, 0, 1, 0, 0, 0, 1}, {-1, 0, 0, 0, 1, 0, 0, 0, 1},
	{0, 1, 0, 1, 0, 0, 0, 0, 1}, {0, -1, 0, 1, 0, 0, 0, 0, 1},
	{0, 0, 1, 1, 0, 0, 0, 1, 0}, {0, 0, -1, 1, 0, 0, 0, 1, 0},
}
-- 格 (x, y, z) 往 f 的面：與同一面相鄰（±1 格、同樣對著空的）的面上應力平均 → FS
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
				and job.solid[1 + cx + cy * n + cz * n * n]
				and meta.open[1 + (cx + dx) + (cy + dy) * n + (cz + dz) * n * n] then
			local t = {fem.point_stress(job, res, cx, cy, cz, xi, eta, zeta)}
			for i = 1, 6 do sum[i] = sum[i] + t[i] end
			m = m + 1
		end
	end end
	if m == 0 then return math.huge end
	local s1, _, s3 = fem.principal(sum[1] / m, sum[2] / m, sum[3] / m, sum[4] / m, sum[5] / m, sum[6] / m)
	return strength_fs(job, meta, x, y, z, s1 / 1000, s3 / 1000)
end

-- 對著開挖空間、或離開挖點 near 格內的臨空格裡，FS < 1 的格（由上往下）。回傳 failed, 檢查的面數
local NEAR = 8
local function find_failed(job, res, meta, center)
	local n = job.nx
	local a = meta.a
	local failed, faces = {}, 0
	for z = 2, n - 3 do for y = 2, n - 3 do for x = 2, n - 3 do
		if job.solid[1 + x + y * n + z * n * n] and meta.lith[1 + x + y * n + z * n * n] then
			for _, f in ipairs(FACES) do
				local ax, ay, az = x + f[1], y + f[2], z + f[3]
				local wx, wy, wz = a.x + ax, a.y + ay, a.z + az
				if meta.open[1 + ax + ay * n + az * n * n]
						and (math.max(math.abs(wx - center.x), math.abs(wy - center.y), math.abs(wz - center.z)) <= NEAR
							or rockmech.collapse.is_excavated({x = wx, y = wy, z = wz})) then
					faces = faces + 1
					if face_fs(job, res, meta, x, y, z, f) < 1 then
						failed[#failed + 1] = {x = a.x + x, y = a.y + y, z = a.z + z}
						break
					end
				end
			end
		end
	end end end
	table.sort(failed, function(u, v) return u.y > v.y end)
	return failed, faces
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
		return x >= 0 and y >= 0 and z >= 0 and x < n and y < n and z < n and solid[1 + x + y * n + z * n * n]
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
local last_key, last_u
local last_job, last_res, last_meta      -- 最後一次的解（HUD 用）
function rockmech.fem_run(pos, callback)
	local t0 = core.get_us_time()
	local job, meta = make_job(pos)
	local key = core.pos_to_string(meta.a)
	if key == last_key then job.u0 = last_u end
	local t_build = (core.get_us_time() - t0) / 1000
	core.handle_async(function(j)
		return core.rockmech_fem.solve(j)
	end, function(res)
		last_key, last_u = key, res.u
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
	if not last_job.solid[1 + x + y * n + z * n * n] then return nil end
	local fs, s1, s3 = cell_fs(last_job, last_res, last_meta, x, y, z)
	return fs and {fs = fs, s1 = s1, s3 = s3}
end

-- 開挖後排解：同時只有一個工作；排隊中離得近的併成一個（範圍內都檢查得到）
local pending, busy = {}, false
local function pump()
	if busy or #pending == 0 then return end
	busy = true
	local cur = table.remove(pending, 1)
	rockmech.fem_run(cur.pos, function(job, res, meta, ms, t_build)
		local t0 = core.get_us_time()
		local failed, faces = find_failed(job, res, meta, cur.pos)
		local t_eval = (core.get_us_time() - t0) / 1000
		core.log("action", ("[rockmech] 應力解驅動 %s 第 %d 輪：%d 輪迭代、解 %.0f ms、組工作 %.1f ms、判定 %.1f ms（%d 面）、總 %.0f ms → %d 格破壞")
			:format(core.pos_to_string(cur.pos), cur.round, res.iters, res.ms, t_build, t_eval, faces, ms, #failed))
		if #failed > 0 then
			rockmech.collapse.apply_failure(failed, cur.round)
			if cur.round < cfg.failure.max_cascade then
				core.after(cfg.failure.cascade_delay, rockmech.fem_queue, cur.pos, cur.round + 1)
			end
		end
		busy = false
		pump()
	end)
end
function rockmech.fem_queue(pos, round)
	local p = vector.round(pos)
	for _, q in ipairs(pending) do
		if vector.distance(q.pos, p) <= fcfg.radius / 2 then
			q.round = math.min(q.round, round)
			return
		end
	end
	pending[#pending + 1] = {pos = p, round = round}
	core.after(0, pump)
end
if fcfg.drive then
	local collapse = rockmech.collapse
	local orig = collapse.queue_failure_check
	collapse.queue_failure_check = function(pos, prev, r, round)
		orig(pos, prev, r, round)
		rockmech.fem_queue(pos, round or 1)
	end
end

-- 羅盤點一格：解完送訊息給玩家
function rockmech.fem_request(pos, name)
	rockmech.fem_run(pos, function(job, res, meta)
		core.chat_send_player(name, (report(pos, job, res, meta)))
	end)
end
