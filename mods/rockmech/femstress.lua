-- rockmech/femstress.lua
-- 開挖周圍彈性應力場的原型（fem.lua）：只顯示，不影響任何崩落判定。
-- 地質羅盤點一格 → 以該格為中心讀 ±radius 的地圖，丟到背景執行緒解應力，解完回報：
--   這一格的 σ1、σ3、莫爾庫倫型的 FS（強度用現有的 Hoek-Brown 岩體強度，加張力截斷），以及範圍內臨空格最小的 FS。
-- 應力取周圍 1 格內岩石格的平均（消掉方塊角點的應力奇異）。
-- 目前不含節理與支護：岩體是均質彈性體。
-- 參數在設定 rockmech_fem_*。

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
	-- 判定要用：每格的岩性（collapse.rock 查強度）
	local meta = {a = a, r = r, lith = {}, p2 = {}}
	for c = 1, n * n * n do
		local k = c - 1
		local x, y, z = k % n, math.floor(k / n) % n, math.floor(k / (n * n))
		local gi = 1 + (a.x + x - g.ox) + (a.y + y - g.oy) * gsy + (a.z + z - g.oz) * gsz
		meta.lith[c] = g.lith_of[g.data[gi]]
		meta.p2[c] = g.p2[gi]
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

-- 回報：點的那一格與範圍內臨空格最小的 FS
local function report(pos, job, res, meta)
	local n = job.nx
	local a = meta.a
	local lines = {}
	local x0, y0, z0 = pos.x - a.x, pos.y - a.y, pos.z - a.z
	local fs, s1, s3, mode = cell_fs(job, res, meta, x0, y0, z0)
	lines[#lines + 1] = core.colorize("#80d0ff", "[應力解] ") ..
		("%s 半徑 %d：%d 輪、殘差 %.1e、%.0f ms（只顯示、不影響崩落；不含節理與支護）"):format(
			core.pos_to_string(pos), meta.r, res.iters, res.res, res.ms)
	if fs then
		lines[#lines + 1] = ("  這一格 σ1 %.3f、σ3 %.3f MPa → FS %s（%s）"):format(s1, s3, fs_text(fs), mode)
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
	if best then
		lines[#lines + 1] = ("  範圍內臨空格 %d 格，FS < 1 的 %d 格；最小 FS %s（%s）@ %s：σ1 %.3f、σ3 %.3f MPa"):format(
			cnt, fails, fs_text(best), bm, core.pos_to_string(bp), bs1, bs3)
	end
	return table.concat(lines, "\n"), {fs = fs, s1 = s1, s3 = s3, mode = mode, min = best, min_pos = bp, fails = fails, count = cnt}
end
rockmech.fem_report = report

-- 同一個範圍上次的解當初始值，迭代會少很多（u 留在主執行緒）
local last_key, last_u
function rockmech.fem_run(pos, callback)
	local job, meta = make_job(pos)
	local key = core.pos_to_string(meta.a)
	if key == last_key then job.u0 = last_u end
	local t0 = core.get_us_time()
	core.handle_async(function(j)
		return core.rockmech_fem.solve(j)
	end, function(res)
		last_key, last_u = key, res.u
		callback(job, res, meta, (core.get_us_time() - t0) / 1000)
	end, job)
end

-- 羅盤點一格：解完送訊息給玩家
function rockmech.fem_request(pos, name)
	if not fcfg.enabled then return end
	rockmech.fem_run(pos, function(job, res, meta, ms)
		local text = report(pos, job, res, meta)
		core.chat_send_player(name, text .. ("\n  從送出到算完 %.0f ms"):format(ms))
	end)
end
