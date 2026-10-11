-- rockmech/overhang.lua
-- 懸臂／頂板的彎曲斷裂（純函式，不依賴引擎）。
--
-- ## 支撐距離（仿 Minecraft 鷹架）
-- 對範圍內每個鍵結格（bonded）算「支撐距離」d：
--   * 來源 d = 0：正下方是「群外的實心格」（地面、碎石…），或位於範圍邊界
--     （範圍外視為連回大岩體）。
--   * 上下相鄰：d 不變（疊在上面、或掛在下面的岩石跟著所在的柱）。
--   * 水平相鄰：d + 1。
-- 以 0-1 BFS 求最小值。d 即「到最近有支撐岩柱的水平距離」。
--
-- ## 極限長度（懸臂梁自重彎曲）
-- 懸臂長 L、厚 t、單位重 γ：根部最大彎曲張應力 σ = 3γL²/t。
-- 令 σ = σt × scale：L_max = √(σt·scale·t / (3γ))。
-- t 取該格所在那一欄連續鍵結格的厚度（接到範圍上下邊界時視為很厚）。
--
-- ## 斷在根部（B 方案）
-- 把 d ≥ 1 的鍵結格依相鄰關係分群（每群是一段懸空的岩石，根部接在 d = 0 的岩柱）。
-- 群內只要有任一格 d > L_max，就整群從根部斷開掉落。
-- 群太大（> max_voxels）或碰到範圍邊界（實際大小不明）時保守地不處理。
--
-- ## 網格格式
-- grid = {data, ox, oy, oz, nx, ny, nz, bonded_of, solid_of, lith_of,
--         req = {x1, x2, y1, y2, z1, z2}（世界座標；省略時為整個網格）}
-- params = {lithologies, scale, tensile_other (MPa), gamma_other (kN/m³), max_voxels}

local overhang = {}

local floor, sqrt = math.floor, math.sqrt
local THICK = 1e9 -- 接到範圍邊界的柱：視為很厚

-- 回傳 groups = {{cells = {{x,y,z}...}, max_ratio = d/L_max 最大值}...}（只含要掉落的群）, stats
function overhang.find_failing(g, p)
	local nx, ny, nz = g.nx, g.ny, g.nz
	local sy, sz = nx, nx * ny
	local data, bonded_of, solid_of, lith_of = g.data, g.bonded_of, g.solid_of, g.lith_of
	local x1, x2, y1, y2, z1, z2 = 0, nx - 1, 0, ny - 1, 0, nz - 1
	if g.req then
		x1 = math.max(0, g.req.x1 - g.ox); x2 = math.min(nx - 1, g.req.x2 - g.ox)
		y1 = math.max(0, g.req.y1 - g.oy); y2 = math.min(ny - 1, (g.req.y2 or (g.oy + ny - 1)) - g.oy)
		z1 = math.max(0, g.req.z1 - g.oz); z2 = math.min(nz - 1, g.req.z2 - g.oz)
	end
	local scale = p.scale or 1
	local max_voxels = p.max_voxels or 2000
	local stats = {cells = 0, groups = 0, failing_groups = 0}

	local function idx(lx, ly, lz) return 1 + lx + ly * sy + lz * sz end

	-- 1. 每欄連續鍵結格的厚度 t
	local thick = {}
	for lz = z1, z2 do
		for lx = x1, x2 do
			local ly = y1
			while ly <= y2 do
				if bonded_of[data[idx(lx, ly, lz)]] then
					local a = ly
					while ly + 1 <= y2 and bonded_of[data[idx(lx, ly + 1, lz)]] do ly = ly + 1 end
					local t = ly - a + 1
					if a == y1 or ly == y2 then t = THICK end
					for yy = a, ly do thick[idx(lx, yy, lz)] = t end
				end
				ly = ly + 1
			end
		end
	end

	-- 2. 0-1 BFS 求支撐距離 d（雙端佇列：front 為 cost 0）
	local d = {}
	local q, head, tail = {}, 1, 0       -- 主佇列
	local f, fn = {}, 0                   -- 前端堆疊（cost 0）
	local function on_edge(lx, ly, lz)
		return lx == x1 or lx == x2 or ly == y1 or ly == y2 or lz == z1 or lz == z2
	end
	for lz = z1, z2 do
		for ly = y1, y2 do
			for lx = x1, x2 do
				local i = idx(lx, ly, lz)
				if bonded_of[data[i]] then
					stats.cells = stats.cells + 1
					local below = data[i - sy]
					if on_edge(lx, ly, lz) or (solid_of[below] and not bonded_of[below]) then
						d[i] = 0
						tail = tail + 1; q[tail] = i
					end
				end
			end
		end
	end
	local function relax(j, nd, zero_cost)
		local cur = d[j]
		if cur == nil or nd < cur then
			d[j] = nd
			if zero_cost then fn = fn + 1; f[fn] = j
			else tail = tail + 1; q[tail] = j end
		end
	end
	while fn > 0 or head <= tail do
		local i
		if fn > 0 then i = f[fn]; f[fn] = nil; fn = fn - 1
		else i = q[head]; head = head + 1 end
		local di = d[i]
		local k = i - 1
		local lx = k % nx
		local ly = floor(k / sy) % ny
		local lz = floor(k / sz)
		-- 上下：cost 0
		if ly + 1 <= y2 and bonded_of[data[i + sy]] then relax(i + sy, di, true) end
		if ly - 1 >= y1 and bonded_of[data[i - sy]] then relax(i - sy, di, true) end
		-- 水平：cost 1
		if lx + 1 <= x2 and bonded_of[data[i + 1]] then relax(i + 1, di + 1, false) end
		if lx - 1 >= x1 and bonded_of[data[i - 1]] then relax(i - 1, di + 1, false) end
		if lz + 1 <= z2 and bonded_of[data[i + sz]] then relax(i + sz, di + 1, false) end
		if lz - 1 >= z1 and bonded_of[data[i - sz]] then relax(i - sz, di + 1, false) end
	end

	-- 3. 每格 L_max
	local function lmax(i)
		local key = lith_of[data[i]]
		local lith = key and p.lithologies[key]
		local st = (lith and lith.tensile or p.tensile_other or 2) * 1000 * scale -- kPa
		local gam = lith and lith.gamma or p.gamma_other or 20
		return sqrt(st * thick[i] / (3 * gam))
	end

	-- 4. d ≥ 1 的格分群；群內有 d > L_max 就整群掉
	local seen = {}
	local groups = {}
	for lz = z1, z2 do
		for ly = y1, y2 do
			for lx = x1, x2 do
				local i0 = idx(lx, ly, lz)
				local d0 = d[i0]
				if d0 and d0 >= 1 and not seen[i0] then
					stats.groups = stats.groups + 1
					local stack, list = {i0}, {}
					seen[i0] = true
					local touches_edge, max_ratio, too_big = false, 0, false
					while #stack > 0 do
						local i = stack[#stack]; stack[#stack] = nil
						list[#list + 1] = i
						if #list > max_voxels then too_big = true end
						local k = i - 1
						local cx, cy, cz = k % nx, floor(k / sy) % ny, floor(k / sz)
						if on_edge(cx, cy, cz) then touches_edge = true end
						local ratio = d[i] / lmax(i)
						if ratio > max_ratio then max_ratio = ratio end
						local nbs = {i + 1, i - 1, i + sy, i - sy, i + sz, i - sz}
						for n = 1, 6 do
							local j = nbs[n]
							local dj = d[j]
							if dj and dj >= 1 and not seen[j] then
								seen[j] = true
								stack[#stack + 1] = j
							end
						end
					end
					if max_ratio > 1 and not touches_edge and not too_big then
						local cells = {}
						for _, i in ipairs(list) do
							local k = i - 1
							cells[#cells + 1] = {
								x = g.ox + k % nx, y = g.oy + floor(k / sy) % ny, z = g.oz + floor(k / sz),
							}
						end
						table.sort(cells, function(a, b) return a.y < b.y end)
						groups[#groups + 1] = {cells = cells, max_ratio = max_ratio}
						stats.failing_groups = stats.failing_groups + 1
					end
				end
			end
		end
	end
	return groups, stats, d
end

---------------------------------------------------------------------------
-- 局部版本（遊戲中使用）：只探索被移除格附近受影響的懸空岩石
---------------------------------------------------------------------------
-- 與 find_failing 相同的模型，但以「垂直連續的鍵結格」（一欄 run）為單位：
--   * run 的底部坐在群外實心格上、或接到範圍邊界 → 有支撐（d = 0）
--   * 否則從 starts 出發，沿水平相鄰的 run 探索出整段懸空岩石（一群），
--     遇到有支撐的 run 即停止往外；d = 到最近有支撐 run 的水平步數
-- 一般開挖時周圍都是厚岩體，起點的 run 往下就碰到支撐，幾乎立刻結束。
-- 回傳格式同 find_failing。
-- 局部搜尋的共用部分：get_run（垂直 run 與其 L_max）、explore（從一個懸空 run
-- 探索出整群並以多源 BFS 求每個 run 的 d）
local function local_ctx(g, p)
	local nx, ny, nz = g.nx, g.ny, g.nz
	local sy, sz = nx, nx * ny
	local data, bonded_of, solid_of, lith_of = g.data, g.bonded_of, g.solid_of, g.lith_of
	local x1, x2, y1, y2, z1, z2 = 0, nx - 1, 0, ny - 1, 0, nz - 1
	if g.req then
		x1 = math.max(0, g.req.x1 - g.ox); x2 = math.min(nx - 1, g.req.x2 - g.ox)
		y1 = math.max(0, g.req.y1 - g.oy); y2 = math.min(ny - 1, (g.req.y2 or (g.oy + ny - 1)) - g.oy)
		z1 = math.max(0, g.req.z1 - g.oz); z2 = math.min(nz - 1, g.req.z2 - g.oz)
	end
	local scale = p.scale or 1
	local max_voxels = p.max_voxels or 2000
	local ctx = {x1 = x1, x2 = x2, y1 = y1, y2 = y2, z1 = z1, z2 = z2, sy = sy, sz = sz}

	-- run 快取：格索引 → {bot, top, lx, lz, supported, edge, t, lmax, crit}
	--   t：厚度（接到上下邊界時視為很厚）；lmax：run 內最小 L_max；
	--   crit：決定 lmax 的那一格的 {tensile (MPa, 已乘 scale), gamma}
	local run_of = {}
	function ctx.get_run(lx, ly, lz)
		local i = 1 + lx + ly * sy + lz * sz
		local r = run_of[i]
		if r then return r end
		local b, t = ly, ly
		while b - 1 >= y1 and bonded_of[data[i - (ly - b + 1) * sy]] do b = b - 1 end
		while t + 1 <= y2 and bonded_of[data[i + (t - ly + 1) * sy]] do t = t + 1 end
		local ib = 1 + lx + b * sy + lz * sz
		r = {bot = b, top = t, lx = lx, lz = lz}
		local edge = lx == x1 or lx == x2 or lz == z1 or lz == z2 or b == y1 or t == y2
		local below = data[ib - sy]
		r.supported = edge or (solid_of[below] and not bonded_of[below]) or false
		r.edge = edge
		local thick = (b == y1 or t == y2) and THICK or (t - b + 1)
		r.t = thick
		local lm, crit = math.huge, nil
		for yy = b, t do
			local c = ib + (yy - b) * sy
			local key = lith_of[data[c]]
			local lith = key and p.lithologies[key]
			local st = (lith and lith.tensile or p.tensile_other or 2) * 1000 * scale
			local gam = lith and lith.gamma or p.gamma_other or 20
			local v = sqrt(st * thick / (3 * gam))
			if v < lm then lm = v; crit = {tensile = st / 1000, gamma = gam} end
			run_of[c] = r
		end
		r.lmax = lm
		r.crit = crit
		return r
	end

	ctx.done = {}          -- 已處理過的 run（跨起點共用）
	local H = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

	-- 回傳 {comp = run 陣列, d = {[run] = 支撐距離}, n_cells, aborted}
	-- d[run] 為 nil：整群都碰不到有支撐的 run（完全懸空，交給支撐判定）
	function ctx.explore(r0)
		local comp, queue, inq = {}, {r0}, {[r0] = true}
		local n_cells, aborted = 0, false
		local d = {}
		local frontier = {}   -- 與有支撐 run 相鄰者 → d = 1
		local adj = {}        -- run → 相鄰的懸空 run 清單
		local qi = 1
		while qi <= #queue do
			local r = queue[qi]; qi = qi + 1
			ctx.done[r] = true
			comp[#comp + 1] = r
			n_cells = n_cells + (r.top - r.bot + 1)
			if n_cells > max_voxels then aborted = true; break end
			adj[r] = {}
			local touches_support = false
			for yy = r.bot, r.top do
				for _, h in ipairs(H) do
					local ax, az = r.lx + h[1], r.lz + h[2]
					if ax >= x1 and ax <= x2 and az >= z1 and az <= z2 then
						local j = 1 + ax + yy * sy + az * sz
						if bonded_of[data[j]] then
							local rn = ctx.get_run(ax, yy, az)
							if rn.supported then
								touches_support = true
							elseif rn ~= r then
								adj[r][#adj[r] + 1] = rn
								if not inq[rn] then inq[rn] = true; queue[#queue + 1] = rn end
							end
						end
					end
				end
			end
			if touches_support then frontier[#frontier + 1] = r end
		end
		if not aborted then
			local bq, bh = {}, 1
			for _, r in ipairs(frontier) do d[r] = 1; bq[#bq + 1] = r end
			while bh <= #bq do
				local r = bq[bh]; bh = bh + 1
				for _, rn in ipairs(adj[r]) do
					if not d[rn] then d[rn] = d[r] + 1; bq[#bq + 1] = rn end
				end
			end
		end
		return {comp = comp, d = d, n_cells = n_cells, aborted = aborted}
	end
	return ctx
end

-- run 的懸臂安全係數：FS = σt·scale / (3γd²/t) = (L_max / d)²
local function run_fs(r, d)
	if not d then return 0 end
	return (r.lmax / d) ^ 2
end
overhang.run_fs = run_fs

function overhang.find_failing_local(g, p, starts)
	local ctx = local_ctx(g, p)
	local data, bonded_of = g.data, g.bonded_of
	local sy, sz = ctx.sy, ctx.sz
	local stats = {cells = 0, groups = 0, failing_groups = 0}
	local groups = {}
	for _, s in ipairs(starts) do
		local lx, ly, lz = s.x - g.ox, s.y - g.oy, s.z - g.oz
		if lx >= ctx.x1 and lx <= ctx.x2 and ly >= ctx.y1 and ly <= ctx.y2 and lz >= ctx.z1 and lz <= ctx.z2
				and bonded_of[data[1 + lx + ly * sy + lz * sz]] then
			local r0 = ctx.get_run(lx, ly, lz)
			if not r0.supported and not ctx.done[r0] then
				stats.groups = stats.groups + 1
				local res = ctx.explore(r0)
				stats.cells = stats.cells + res.n_cells
				if not res.aborted then
					local fails = false
					for _, r in ipairs(res.comp) do
						if (res.d[r] or math.huge) > r.lmax then fails = true; break end
					end
					if fails then
						local cells = {}
						for _, r in ipairs(res.comp) do
							for yy = r.bot, r.top do
								cells[#cells + 1] = {x = g.ox + r.lx, y = g.oy + yy, z = g.oz + r.lz}
							end
						end
						table.sort(cells, function(a, b) return a.y < b.y end)
						groups[#groups + 1] = {cells = cells}
						stats.failing_groups = stats.failing_groups + 1
					end
				end
			end
		end
	end
	return groups, stats
end

-- 單格（世界座標）的懸臂狀態，供 HUD／資訊頁顯示。回傳 nil（非鍵結格或在範圍外）或
--   {supported = true}                         該欄坐在支撐上（d = 0）
--   {aborted = true, n_cells}                   懸空群太大，判定時保守地不處理
--   {d, t, lmax, tensile, gamma, sigma_b, fs,    此格所在欄：支撐距離、厚度、L_max、
--    group_fs, crit = {x, z, ybot, ytop, d, t, lmax}, n_cells}
--                                               σ_b = 3γd²/t (MPa)、FS；整群最小 FS 與臨界欄
-- d 為 nil 表示整群碰不到有支撐的岩柱（fs = 0）。
function overhang.cell_state(g, p, x, y, z)
	local ctx = local_ctx(g, p)
	local lx, ly, lz = x - g.ox, y - g.oy, z - g.oz
	if lx < ctx.x1 or lx > ctx.x2 or ly < ctx.y1 or ly > ctx.y2 or lz < ctx.z1 or lz > ctx.z2 then
		return nil
	end
	if not g.bonded_of[g.data[1 + lx + ly * ctx.sy + lz * ctx.sz]] then return nil end
	local r0 = ctx.get_run(lx, ly, lz)
	if r0.supported then return {supported = true} end
	local res = ctx.explore(r0)
	if res.aborted then return {aborted = true, n_cells = res.n_cells} end
	local d0 = res.d[r0]
	local out = {
		d = d0, t = r0.t, lmax = r0.lmax, tensile = r0.crit.tensile, gamma = r0.crit.gamma,
		sigma_b = d0 and 3 * r0.crit.gamma * d0 * d0 / r0.t / 1000 or math.huge,
		fs = run_fs(r0, d0), n_cells = res.n_cells,
	}
	local gfs, crit = math.huge, nil
	for _, r in ipairs(res.comp) do
		local f = run_fs(r, res.d[r])
		if f < gfs then
			gfs = f
			crit = {x = g.ox + r.lx, z = g.oz + r.lz, ybot = g.oy + r.bot, ytop = g.oy + r.top,
				d = res.d[r], t = r.t, lmax = r.lmax}
		end
	end
	out.group_fs, out.crit = gfs, crit
	return out
end

-- 給定岩性與厚度的極限懸臂長度 (m)
function overhang.lmax(tensile_mpa, gamma, t, scale)
	return sqrt(tensile_mpa * 1000 * (scale or 1) * t / (3 * gamma))
end

return overhang
