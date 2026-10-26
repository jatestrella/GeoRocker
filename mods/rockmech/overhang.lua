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
-- ## 節理（只在局部版 find_failing_local；params.face_jointed）
-- 節理面不傳張力。相鄰兩欄的介面上，被節理切過的面不算：
--   * 根部斷面（懸空欄與有支撐欄之間）完好面數 t_eff：σb = 3γ·t·d²/t_eff²，
--     即 L_max 變成 L_max·(t_eff/t)；t_eff = 0 → 張力為 0。
--   * 介面完全被切開 → 兩欄不相連；碰不到有支撐欄的那一段被切離而掉落。
--   * 水平面被切過 → 欄（run）在此斷開：上段坐在下段上（只傳壓力，下段有支撐上段就有），
--     下段不能吊在上段下面（頂板沿層面剝落、只靠上方吊著的岩塊掉落）。
--   * 頂板（兩側都連著岩體）：沿 x、z 直線、在 run 自己的厚度帶內往兩側找有支撐的欄；某一方向兩側
--     都有，就是開挖的頂板，不用懸臂判定（FS = ∞），改由開挖周邊的應力判定（failure.lua 的 Inglis
--     解：頂板受拉張裂、受壓剝落），被節理切開的岩塊由關鍵塊體判定。只有一側連著岩體的才是懸臂。
--   * 層疊（Obert & Duvall 疊層梁）：上段坐在懸空的下段上時（上段 d = 0），下段承受的荷重
--     q₁ = γ·t₁³·Σt / Σt³（同材料；依序往上加入各層，加入後 q₁ 沒有變大的層自己分離、不加載）。
--     FS ÷ (q₁ / γt₁)。較厚、較勁的上層自己撐得住，不壓在較薄的下層上。
--
-- ## 網格格式
-- grid = {data, ox, oy, oz, nx, ny, nz, bonded_of, solid_of, lith_of,
--         req = {x1, x2, y1, y2, z1, z2}（世界座標；省略時為整個網格）}
-- params = {lithologies, scale, tensile_other (MPa), gamma_other (kN/m³), max_voxels,
--           tensile_at(g, i, lith_key)（可選）：格 i 的張力強度 (MPa)，取代 lith.tensile／tensile_other
--           （岩體強度：GSI、相似比 N）}

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
		local st = (p.tensile_at and p.tensile_at(g, i, key)
			or lith and lith.tensile or p.tensile_other or 2) * 1000 * scale -- kPa
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

	-- 面是否被節理切過（p.face_jointed(fx, fy, fz, axis)，世界座標；axis 1 = x、2 = y、3 = z）
	local face_jointed = p.face_jointed
	local ox, oy, oz = g.ox, g.oy, g.oz
	-- 格 (lx, ly, lz) 與其 +axis 方向鄰格之間的面（快取：同一次搜尋中常被重複查詢）
	local fj_cache = {}
	local function fjl(lx, ly, lz, axis)
		local k = (((lz + 1) * (ny + 2) + (ly + 1)) * (nx + 2) + (lx + 1)) * 4 + axis
		local v = fj_cache[k]
		if v == nil then
			v = face_jointed(ox + lx, oy + ly, oz + lz, axis) and true or false
			fj_cache[k] = v
		end
		return v
	end
	-- (lx, ly, lz) 與其正上方之間的水平面
	local function hjoint(lx, ly, lz)
		return face_jointed and fjl(lx, ly, lz, 2) or false
	end

	-- run 快取：格索引 → {bot, top, lx, lz, supported, edge, t, lmax, crit}
	--   run = 垂直連續、且中間沒有被節理切過的鍵結格（水平節理面不傳張力：
	--   上段坐在下段上只傳壓力，下段不能吊在上段下面）
	--   t：厚度（接到上下邊界時視為很厚）；lmax：run 內最小 L_max；
	--   crit：決定 lmax 的那一格的 {tensile (MPa, 已乘 scale), gamma}
	local run_of = {}
	function ctx.get_run(lx, ly, lz)
		local i = 1 + lx + ly * sy + lz * sz
		local r = run_of[i]
		if r then return r end
		local b, t = ly, ly
		while b - 1 >= y1 and bonded_of[data[i - (ly - b + 1) * sy]] and not hjoint(lx, b - 1, lz) do b = b - 1 end
		while t + 1 <= y2 and bonded_of[data[i + (t - ly + 1) * sy]] and not hjoint(lx, t, lz) do t = t + 1 end
		local ib = 1 + lx + b * sy + lz * sz
		r = {bot = b, top = t, lx = lx, lz = lz}
		local edge = lx == x1 or lx == x2 or lz == z1 or lz == z2 or b == y1 or t == y2
		local below = data[ib - sy]
		r.supported = edge or (solid_of[below] and not bonded_of[below]) or false
		for yy = b, t do run_of[ib + (yy - b) * sy] = r end
		if not r.supported and bonded_of[below] then
			-- 隔著節理面坐在下方的岩石上：壓力可以傳過節理面。
			-- 往下找連續鍵結格的底部：坐在群外實心格上或接到範圍底部 → 有支撐
			local k = b - 1
			while k >= y1 and bonded_of[data[1 + lx + k * sy + lz * sz]] do k = k - 1 end
			if k < y1 then
				r.supported = true
			else
				r.supported = solid_of[data[1 + lx + k * sy + lz * sz]] or false
			end
		end
		r.edge = edge
		r.edge_lat = lx == x1 or lx == x2 or lz == z1 or lz == z2   -- 水平方向碰到範圍邊界
		local thick = (b == y1 or t == y2) and THICK or (t - b + 1)
		r.t = thick
		local lm, crit = math.huge, nil
		for yy = b, t do
			local c = ib + (yy - b) * sy
			local key = lith_of[data[c]]
			local lith = key and p.lithologies[key]
			local st = (p.tensile_at and p.tensile_at(g, c, key)
				or lith and lith.tensile or p.tensile_other or 2) * 1000 * scale
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
	-- (lx, ly, lz) 往 (hx, hz) 方向的側面是否被節理切過
	local function jointed(lx, ly, lz, hx, hz)
		if not face_jointed then return false end
		if hx == 1 then return fjl(lx, ly, lz, 1) end
		if hx == -1 then return fjl(lx - 1, ly, lz, 1) end
		if hz == 1 then return fjl(lx, ly, lz, 3) end
		return fjl(lx, ly, lz - 1, 3)
	end

	-- 從懸空 run r0 探索一群。相連方式：
	--   * 側向：介面至少有一個完好面（未被節理切過）→ 雙向，d + 1
	--   * 垂直（只發生在水平節理面兩側）：上方的 run 坐在下方的 run 上 →
	--     支撐只能由下往上傳（d 相同）；吊在上方 run 下面的不能從上面得到支撐
	-- 回傳 {comp, d = {[run] = 支撐距離}, rho = {[run] = 根部斷面比 t_eff/t}, n_cells, aborted, edge,
	--       cut = 只隔著被節理完全切開的介面相鄰的懸空 run（另外當成起點處理）}
	-- 根部斷面：與有支撐 run 之間完好面最多的介面；rho = t_eff / t（上限 1），子 run 沿用。
	-- 每個 run 取最有利的根部：FS ∝ (rho/d)²，以 d/rho 最小者為準（Dijkstra；荷重走最強的路徑，
	-- 不是最先碰到的根部——否則結果會隨搜尋順序、讀取範圍而變）
	-- d 為 nil：碰不到任何支撐（被節理切離，或吊在節理面下）。
	function ctx.explore(r0)
		local comp, queue, inq = {}, {r0}, {[r0] = true}
		local n_cells, aborted, edge = 0, false, false
		local d, rho = {}, {}
		local frontier, root_teff = {}, {}
		local lat = {}        -- run → 側向相連的懸空 run
		local up, up_set = {}, {} -- run → 坐在它上面的懸空 run（支撐由下往上）
		local cut, cut_seen = {}, {}
		local function visit(rn)
			if not inq[rn] then inq[rn] = true; queue[#queue + 1] = rn end
		end
		local function add_up(lower, upper)
			up_set[lower] = up_set[lower] or {}
			if not up_set[lower][upper] then
				up_set[lower][upper] = true
				up[lower] = up[lower] or {}
				up[lower][#up[lower] + 1] = upper
			end
		end
		local qi = 1
		while qi <= #queue do
			local r = queue[qi]; qi = qi + 1
			ctx.done[r] = true
			comp[#comp + 1] = r
			n_cells = n_cells + (r.top - r.bot + 1)
			if n_cells > max_voxels then aborted = true; break end
			lat[r] = {}
			local intact, nbs = {}, {}
			for yy = r.bot, r.top do
				for _, h in ipairs(H) do
					local ax, az = r.lx + h[1], r.lz + h[2]
					if ax >= x1 and ax <= x2 and az >= z1 and az <= z2 then
						local j = 1 + ax + yy * sy + az * sz
						if bonded_of[data[j]] then
							local rn = ctx.get_run(ax, yy, az)
							if rn ~= r then
								if intact[rn] == nil then intact[rn] = 0; nbs[#nbs + 1] = rn end
								if not jointed(r.lx, yy, r.lz, h[1], h[2]) then
									intact[rn] = intact[rn] + 1
								end
							end
						end
					end
				end
			end
			local best = 0
			for _, rn in ipairs(nbs) do
				local n = intact[rn]
				if rn.supported then
					if n > 0 and rn.edge_lat then edge = true end
					if n > best then best = n end
				elseif n > 0 then
					lat[r][#lat[r] + 1] = rn
					visit(rn)
				elseif not cut_seen[rn] then
					cut_seen[rn] = true
					cut[#cut + 1] = rn
				end
			end
			if best > 0 then
				frontier[#frontier + 1] = r
				root_teff[r] = best
			end
			-- 垂直：上下相鄰的另一個 run（中間是水平節理面）
			if r.top + 1 <= y2 and bonded_of[data[1 + r.lx + (r.top + 1) * sy + r.lz * sz]] then
				local ra = ctx.get_run(r.lx, r.top + 1, r.lz)
				if not ra.supported then add_up(r, ra); visit(ra) end
			end
			if r.bot - 1 >= y1 and bonded_of[data[1 + r.lx + (r.bot - 1) * sy + r.lz * sz]] then
				local rb = ctx.get_run(r.lx, r.bot - 1, r.lz)
				if not rb.supported then add_up(rb, r); visit(rb) end
			end
		end
		-- 層疊：坐在下方懸空 run 上的 run 由下方承擔（d = 0，不用自己的彎曲強度）；
		-- 下方 run 的荷重倍數依 Obert & Duvall 疊層梁：m = t₁²·Σt / Σt³（只納入會加載的層）
		local load = {}
		local function od_factor(lower)
			local t1 = lower.t
			if t1 >= THICK then return 1 end
			local st, st3, best = t1, t1 * t1 * t1, 1
			local cur = lower
			for _ = 1, 32 do
				local ups = up[cur]
				local u = ups and ups[1]
				if not u then break end
				local tu = u.t >= THICK and 1e4 or u.t
				local m = t1 * t1 * (st + tu) / (st3 + tu * tu * tu)
				if m <= best then break end   -- 這層比下層勁，自己分離、不加載
				best, st, st3, cur = m, st + tu, st3 + tu * tu * tu, u
			end
			return best
		end
		if not aborted then
			-- Dijkstra（鍵 = d/rho，越小越有利）：坐在下層上的 d = 0、與有支撐 run 相鄰的 d = 1、側向 d + 1
			local heap, hn = {}, 0
			local function push(r, k)
				hn = hn + 1
				local i = hn
				heap[i] = {k, r}
				while i > 1 do
					local pi = (i - i % 2) / 2
					if heap[pi][1] <= heap[i][1] then break end
					heap[pi], heap[i] = heap[i], heap[pi]
					i = pi
				end
			end
			local function pop()
				local top = heap[1]
				heap[1] = heap[hn]; heap[hn] = nil; hn = hn - 1
				local i = 1
				while true do
					local l, s = 2 * i, i
					if l <= hn and heap[l][1] < heap[s][1] then s = l end
					if l + 1 <= hn and heap[l + 1][1] < heap[s][1] then s = l + 1 end
					if s == i then break end
					heap[s], heap[i] = heap[i], heap[s]
					i = s
				end
				return top[1], top[2]
			end
			local key = {}
			for lower, ups in pairs(up) do
				for _, rn in ipairs(ups) do
					d[rn] = 0
					rho[rn] = 1
					key[rn] = 0
					push(rn, 0)
					load[lower] = od_factor(lower)
				end
			end
			for _, r in ipairs(frontier) do
				if not d[r] then
					local rh = math.min(1, root_teff[r] / (r.t >= THICK and root_teff[r] or r.t))
					d[r], rho[r], key[r] = 1, rh, 1 / rh
					push(r, key[r])
				end
			end
			while hn > 0 do
				local k, r = pop()
				if k <= key[r] then
					local nd, rh = d[r] + 1, rho[r]
					local nk = nd / rh
					for _, rn in ipairs(lat[r] or {}) do
						if not key[rn] or nk < key[rn] then
							d[rn], rho[rn], key[rn] = nd, rh, nk
							push(rn, nk)
						end
					end
				end
			end
		end
		local real_cut = {}
		for _, rn in ipairs(cut) do
			if not inq[rn] then real_cut[#real_cut + 1] = rn end
		end
		-- 兩端支撐梁：沿 (hx, hz) 直線在 r 的厚度帶內找有支撐的欄。回傳 距離 k、支承面完好比；
		-- 碰到空氣（斷開）或找不到 → nil
		-- 看頂板面往上 4 格（容許凹凸不平的頂板）：成本低，每個懸空 run 都能做
		local function scan(r, hx, hz)
			local ytop = math.min(r.bot + 3, y2)
			for k = 1, 48 do
				local cx, cz = r.lx + hx * k, r.lz + hz * k
				if cx < x1 or cx > x2 or cz < z1 or cz > z2 then return k end   -- 範圍外視為連回大岩體
				local any = false
				for yy = r.bot, ytop do
					local j = 1 + cx + yy * sy + cz * sz
					if bonded_of[data[j]] then
						any = true
						if ctx.get_run(cx, yy, cz).supported then return k end
					end
				end
				if not any then return nil end   -- 這一帶都是空氣才算斷開；被節理切開的仍是頂板
			end
			return nil
		end
		local beam = {}
		if not aborted then
			local S6 = math.sqrt(6)
			for _, r in ipairs(comp) do
				if d[r] ~= 0 then
					local best
					for _, ax in ipairs({{1, 0}, {0, 1}}) do
						local kp = scan(r, ax[1], ax[2])
						if kp then
							local kn = scan(r, -ax[1], -ax[2])
							if kn then
								-- 兩側都連著岩體：頂板，由應力判定
								local span = kp + kn - 1
								if not best or span < best.span then best = {fs = math.huge, span = span, roof = true} end
							end
						end
					end
					beam[r] = best
				end
			end
		end
		return {comp = comp, d = d, rho = rho, n_cells = n_cells, aborted = aborted, edge = edge,
			cut = real_cut, lat = lat, load = load, beam = beam}
	end
	return ctx
end

-- run 的懸臂安全係數。根部斷面完好面數 t_eff、run 厚度 t：
--   σb = M/Z = (γ·t·d²/2) / (t_eff²/6) = 3γ·t·d²/t_eff² → FS = σt/σb = (L_max·rho / d)²，rho = t_eff/t
-- d 為 nil（碰不到支撐）時 FS = 0。
-- load：疊層的荷重倍數 m = q₁/(γt)（Obert & Duvall，≥ 1）：σb × m → FS ÷ m
-- d = 0：坐在下層岩體上，由下層承擔 → FS = ∞
-- beam：兩端支撐梁的 FS（未含疊層荷重），有就取兩者較大
local function run_fs(r, d, rho, load, beam)
	if d == 0 then return math.huge end
	local f = d and (r.lmax * (rho or 1) / d) ^ 2 or 0
	if beam and beam > f then f = beam end
	if load and load > 1 then f = f / load end
	return f
end
overhang.run_fs = run_fs

-- 把一群分成「側向相連的段」（上下之間只傳支撐，不併成同一段）。回傳 段陣列, run → 段
local function segments(res)
	local seg_of, list = {}, {}
	for _, r in ipairs(res.comp) do
		if not seg_of[r] then
			local sg = {}
			list[#list + 1] = sg
			seg_of[r] = sg
			local st = {r}
			while #st > 0 do
				local x = st[#st]; st[#st] = nil
				sg[#sg + 1] = x
				for _, y in ipairs(res.lat[x] or {}) do
					if not seg_of[y] then seg_of[y] = sg; st[#st + 1] = y end
				end
			end
		end
	end
	return list, seg_of
end

-- 一段的判定：碰不到支撐（d = nil）→ 掉、FS 0；有任一 run FS < 1 → 整段從根部斷。
-- 回傳 falls, fs（段內最小 FS）, crit（最小 FS 的 run）
local function judge_segment(res, sg)
	local minf, crit, fail = math.huge, sg[1], false
	for _, r in ipairs(sg) do
		local f = run_fs(r, res.d[r], res.rho[r], res.load and res.load[r], res.beam and res.beam[r] and res.beam[r].fs)
		if f < minf then minf, crit = f, r end
		if f < 1 then fail = true end
	end
	return fail, minf, crit
end

local function run_cells(g, runs)
	local cells = {}
	for _, r in ipairs(runs) do
		for yy = r.bot, r.top do
			cells[#cells + 1] = {x = g.ox + r.lx, y = g.oy + yy, z = g.oz + r.lz}
		end
	end
	table.sort(cells, function(a, b) return a.y < b.y end)
	return cells
end

-- 遊戲中使用的局部判定。params 另可有 face_jointed(fx, fy, fz, axis)：
-- 相鄰兩格之間的面是否被節理切過（見 local_ctx）。
-- 回傳 groups = {{cells, fs}...}（每個會掉的側向相連段；fs：段內最小 FS，碰不到支撐為 0）, stats
function overhang.find_failing_local(g, p, starts)
	local ctx = local_ctx(g, p)
	local data, bonded_of = g.data, g.bonded_of
	local sy, sz = ctx.sy, ctx.sz
	local stats = {cells = 0, groups = 0, failing_groups = 0}
	local groups = {}
	local function try(r0)
		if r0.supported or ctx.done[r0] then return end
		stats.groups = stats.groups + 1
		local res = ctx.explore(r0)
		stats.cells = stats.cells + res.n_cells
		if not res.aborted then
			for _, sg in ipairs((segments(res))) do
				local falls, fs = judge_segment(res, sg)
				if falls then
					groups[#groups + 1] = {cells = run_cells(g, sg), fs = fs}
					stats.failing_groups = stats.failing_groups + 1
				end
			end
		end
		-- 只隔著節理相鄰的懸空塊：也要判定（可能是被節理切離的塊）
		for _, rn in ipairs(res.cut) do try(rn) end
	end
	for _, s in ipairs(starts) do
		local lx, ly, lz = s.x - g.ox, s.y - g.oy, s.z - g.oz
		if lx >= ctx.x1 and lx <= ctx.x2 and ly >= ctx.y1 and ly <= ctx.y2 and lz >= ctx.z1 and lz <= ctx.z2
				and bonded_of[data[1 + lx + ly * sy + lz * sz]] then
			try(ctx.get_run(lx, ly, lz))
		end
	end
	return groups, stats
end

-- 單格（世界座標）的懸臂狀態，供 HUD／資訊頁顯示。回傳 nil（非鍵結格或在範圍外）或
--   {supported = true}                         該欄坐在支撐上（d = 0）
--   {aborted = true, n_cells}                   懸空群太大，判定時保守地不處理
--   {d, t, rho, lmax, tensile, gamma, sigma_b, fs, group_fs, crit, n_cells, edge, cut_cells}
--     d：支撐距離；t：此欄厚度；rho：根部斷面完好比 t_eff/t；σb = 3γ·t·d²/t_eff² (MPa)；
--     group_fs：此欄所在「側向相連段」的最小 FS（碰不到支撐時為 0）；
--     crit = 最小 FS 的欄 {x, z, ybot, ytop, d, t, rho, lmax}；
--     edge = 群在水平方向碰到範圍邊界（FS 可能高估）；
--     cut_cells = 其他會掉落的段（上下相鄰、或只隔著節理相鄰）的格數
-- d 為 nil 表示此欄碰不到有支撐的岩柱（被節理切離或吊在節理面下，fs = 0）。
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
	local d0, rho0 = res.d[r0], res.rho[r0]
	local load0 = res.load and res.load[r0] or 1
	local sigma_b = math.huge
	if d0 and rho0 and rho0 > 0 then
		-- σb = 3γ·t·d²/t_eff² × m（疊層荷重倍數），t_eff = rho·t
		sigma_b = 3 * r0.crit.gamma * d0 * d0 * r0.t * math.max(1, load0) / (r0.t * r0.t * rho0 * rho0) / 1000
	end
	local out = {
		d = d0, t = r0.t, rho = rho0, lmax = r0.lmax, tensile = r0.crit.tensile, gamma = r0.crit.gamma,
		sigma_b = sigma_b, fs = run_fs(r0, d0, rho0, load0, res.beam and res.beam[r0] and res.beam[r0].fs),
		n_cells = res.n_cells, edge = res.edge,
		beam = res.beam and res.beam[r0] or nil,
		load = load0,
	}
	local segs, seg_of = segments(res)
	local cut_cells = 0
	local _, gfs, cr = judge_segment(res, seg_of[r0])
	for _, sg in ipairs(segs) do
		if sg ~= seg_of[r0] and judge_segment(res, sg) then
			for _, r in ipairs(sg) do cut_cells = cut_cells + (r.top - r.bot + 1) end
		end
	end
	out.group_fs = gfs
	out.crit = {x = g.ox + cr.lx, z = g.oz + cr.lz, ybot = g.oy + cr.bot, ytop = g.oy + cr.top,
		d = res.d[cr], t = cr.t, rho = res.rho[cr], lmax = cr.lmax}
	-- 只隔著節理相鄰的懸空塊中，會掉落的格數（例如梁外側被節理切離的那一段）
	local stack = {}
	for _, rn in ipairs(res.cut) do stack[#stack + 1] = rn end
	while #stack > 0 do
		local rn = stack[#stack]; stack[#stack] = nil
		if not rn.supported and not ctx.done[rn] then
			local r2 = ctx.explore(rn)
			if not r2.aborted then
				for _, sg in ipairs((segments(r2))) do
					if judge_segment(r2, sg) then
						for _, r in ipairs(sg) do cut_cells = cut_cells + (r.top - r.bot + 1) end
					end
				end
			end
			for _, rc in ipairs(r2.cut) do stack[#stack + 1] = rc end
		end
	end
	out.cut_cells = cut_cells
	return out
end

-- 對同一個網格查詢多個格所在「側向相連段」的最小 FS（共用一次搜尋的快取）。
-- 回傳 query(x, y, z) → FS（非鍵結格、有支撐、或群太大時為 math.huge）
-- (x, y, z) 所在「側向相連段」的所有格（世界座標）、段內最小 FS、該欄的厚度 t；
-- 該欄坐在支撐上（不是懸空）、非鍵結格、範圍外或群太大時回傳 nil。
-- 用於：會掉的群被下方懸空的岩體擋住時，判斷下方承受額外重量後是否也撐不住。
function overhang.segment_at(g, p, x, y, z)
	local ctx = local_ctx(g, p)
	local lx, ly, lz = x - g.ox, y - g.oy, z - g.oz
	if lx < ctx.x1 or lx > ctx.x2 or ly < ctx.y1 or ly > ctx.y2 or lz < ctx.z1 or lz > ctx.z2 then
		return nil
	end
	if not g.bonded_of[g.data[1 + lx + ly * ctx.sy + lz * ctx.sz]] then return nil end
	local r0 = ctx.get_run(lx, ly, lz)
	if r0.supported then return nil end
	local res = ctx.explore(r0)
	if res.aborted then return nil end
	local _, seg_of = segments(res)
	local _, fs = judge_segment(res, seg_of[r0])
	return run_cells(g, seg_of[r0]), fs, r0.t
end

-- 以 starts 為起點，列出碰到的所有懸空「側向相連段」與其最小 FS（顯示用）。
-- 回傳 {{cells = {{x,y,z}...}, fs}...}；群太大（不判定）者不列出
function overhang.scan_segments(g, p, starts)
	local ctx = local_ctx(g, p)
	local out = {}
	for _, s in ipairs(starts) do
		local lx, ly, lz = s.x - g.ox, s.y - g.oy, s.z - g.oz
		if lx >= ctx.x1 and lx <= ctx.x2 and ly >= ctx.y1 and ly <= ctx.y2 and lz >= ctx.z1 and lz <= ctx.z2
				and g.bonded_of[g.data[1 + lx + ly * ctx.sy + lz * ctx.sz]] then
			local r0 = ctx.get_run(lx, ly, lz)
			if not r0.supported and not ctx.done[r0] then
				local res = ctx.explore(r0)
				if not res.aborted then
					for _, sg in ipairs((segments(res))) do
						local _, fs = judge_segment(res, sg)
						out[#out + 1] = {cells = run_cells(g, sg), fs = fs}
					end
				end
			end
		end
	end
	return out
end

function overhang.make_query(g, p)
	local ctx = local_ctx(g, p)
	local fs_of = {}       -- run → 所在段的最小 FS
	return function(x, y, z)
		local lx, ly, lz = x - g.ox, y - g.oy, z - g.oz
		if lx < ctx.x1 or lx > ctx.x2 or ly < ctx.y1 or ly > ctx.y2 or lz < ctx.z1 or lz > ctx.z2 then
			return math.huge
		end
		if not g.bonded_of[g.data[1 + lx + ly * ctx.sy + lz * ctx.sz]] then return math.huge end
		local r0 = ctx.get_run(lx, ly, lz)
		if r0.supported then return math.huge end
		if fs_of[r0] then return fs_of[r0] end
		local res = ctx.explore(r0)
		if res.aborted then fs_of[r0] = math.huge; return math.huge end
		for _, sg in ipairs((segments(res))) do
			local _, fs = judge_segment(res, sg)
			for _, r in ipairs(sg) do fs_of[r] = fs end
		end
		return fs_of[r0] or math.huge
	end
end

-- 給定岩性與厚度的極限懸臂長度 (m)
function overhang.lmax(tensile_mpa, gamma, t, scale)
	return sqrt(tensile_mpa * 1000 * (scale or 1) * t / (3 * gamma))
end

return overhang
