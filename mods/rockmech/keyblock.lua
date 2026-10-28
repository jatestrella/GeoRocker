-- rockmech/keyblock.lua
-- 關鍵塊體（純函式，不依賴引擎；Goodman & Shi 塊體理論的簡化版，只考慮重力）。
--
-- ## 找岩塊
-- 從起點的鍵結格出發，只穿過「沒被節理切過的面」擴展（被切過的面是節理，不相連）。
-- 擴展到 max_cells 格以上、或碰到範圍邊界 → 與岩體相連（有岩橋），不是獨立岩塊。
--
-- ## 接觸面
-- 岩塊邊界上的每個格面（往外的軸向單位向量 e）：
--   * 鄰格是空氣（非實心）           → 自由面
--   * 鄰格是鍵結格（中間一定是節理） → 屬於該組節理的一個平面。法向量用節理的真實方向：
--       ν = sign(n·e)·n（由岩塊指向鄰格），依 (組, 正負) 合併；真實面積 = Σ |e·ν|
--   * 鄰格是其他實心格（碎石、地面…） → 以格面方向為法向量（ν = e），凝聚力 0
--     碎石（grid.rubble_of）只有在岩塊下方時算接觸面（承托）；側面、上方的碎石擋不住岩塊
--
-- ## 運動模式（取運動學上可行者之最小 FS）
-- 重力方向 g = (0, −1, 0)，W = Σγ (kN)。凝聚力 c (kPa)、tanφ。
--   * 落下（m = g）：所有接觸面 ν·m ≤ 0（不擠進任何接觸面）。
--       只有平行於 m 的面（垂直面）提供剪力：FS = Σ c·A(平行面) / W
--   * 平面滑動（面 k，ν_k·g > 0）：m = g 在面上的投影（順傾向）；其他面 ν·m ≤ 0。
--       FS = (W cosψ tanφ + c·A_k + Σ c·A(平行於 m 的面)) / (W sinψ)
--   * 楔形滑動（面 k、l）：m = 交線方向（往下）；其他面 ν·m ≤ 0；
--       兩面的正向力 N_k、N_l 由 W·g⊥ = N_k ν_k + N_l ν_l 求出，皆須 ≥ 0。
--       FS = (N_k tanφ + N_l tanφ + c·A_k + c·A_l + Σ c·A(平行於 m 的其他面)) / (W g·m)
--   都不可行 → 卡住（FS = ∞）。
--   支護（grid.support，見 support.lua）：岩塊臨空面上的噴凝土、穿過岩塊且錨進岩塊外岩體的岩栓，
--   對把岩塊推出該面的運動 m 提供抵抗 Σ F·(面外法向·m)，加進各模式的抗力。
--
-- ## 應力夾持（Unwedge 式的現地應力，含應力釋放係數）
-- 每個節理接觸面的夾持力 C = λ·σn·A（σn = ν·σ·ν，σ 取塊體這一側格子的局部應力，
-- 已含開挖後的集中與臨空面釋放；λ = params.clamp，0 = 不考慮）。
-- 運動時仍保持接觸的面（滑動面、與運動方向平行的面）才提供摩擦 C·tanφ；會打開的面沒有夾持。
-- 先不含夾持分析，FS < 1 才算應力再分析一次（節省時間）。
--
-- ## 網格與參數
-- grid = {data, ox, oy, oz, nx, ny, nz, bonded_of, solid_of, lith_of,
--         req = {x1, x2, y1, y2, z1, z2}（世界座標，省略時為整個網格）}
-- params = {face_set(fx, fy, fz, axis) → 切過格 (fx,fy,fz) 與其 +axis 鄰格之間的面的節理組索引或 nil,
--           joint_sets = {{n_eff = 向上單位法向, name}...}, c (kPa), tanphi,
--           lithologies, gamma_other (kN/m³), max_cells}

local keyblock = {}

local sqrt, abs = math.sqrt, math.abs
local EPS = 1e-6
local AX = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}

local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b)
	return {x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x}
end
local function norm(a)
	local l = sqrt(dot(a, a))
	if l < EPS then return nil end
	return {x = a.x / l, y = a.y / l, z = a.z / l}
end

-- 一個查詢環境（同一個網格可重複查詢，已找過的格共用結果）
local function ctx_new(g, p)
	local nx, ny, nz = g.nx, g.ny, g.nz
	local sy, sz = nx, nx * ny
	local x1, x2, y1, y2, z1, z2 = 0, nx - 1, 0, ny - 1, 0, nz - 1
	if g.req then
		x1 = math.max(0, g.req.x1 - g.ox); x2 = math.min(nx - 1, g.req.x2 - g.ox)
		y1 = math.max(0, g.req.y1 - g.oy); y2 = math.min(ny - 1, g.req.y2 - g.oy)
		z1 = math.max(0, g.req.z1 - g.oz); z2 = math.min(nz - 1, g.req.z2 - g.oz)
	end
	local ctx = {g = g, p = p, nx = nx, ny = ny, nz = nz, sy = sy, sz = sz,
		x1 = x1, x2 = x2, y1 = y1, y2 = y2, z1 = z1, z2 = z2, block_of = {}}
	-- 格 (lx, ly, lz) 往 AX[k] 方向的面上的節理組（快取）
	local cache = {}
	function ctx.face(lx, ly, lz, k)
		local a = AX[k]
		local fx, fy, fz, axis = lx, ly, lz, 0
		if a[1] ~= 0 then axis = 1; if a[1] < 0 then fx = lx - 1 end
		elseif a[2] ~= 0 then axis = 2; if a[2] < 0 then fy = ly - 1 end
		else axis = 3; if a[3] < 0 then fz = lz - 1 end end
		local key = (((fz + 1) * (ny + 2) + (fy + 1)) * (nx + 2) + (fx + 1)) * 4 + axis
		local v = cache[key]
		if v == nil then
			v = p.face_set(g.ox + fx, g.oy + fy, g.oz + fz, axis) or false
			cache[key] = v
		end
		return v or nil
	end
	return ctx
end

-- 從 (lx,ly,lz) 擴展岩塊。回傳 block（獨立岩塊）或 false（與岩體相連）
local function grow(ctx, lx, ly, lz)
	local g, p = ctx.g, ctx.p
	local data, bonded_of = g.data, g.bonded_of
	local sy, sz = ctx.sy, ctx.sz
	local max_cells = p.max_cells or 500
	local i0 = 1 + lx + ly * sy + lz * sz
	if ctx.block_of[i0] ~= nil then return ctx.block_of[i0] end
	local cells, seen = {}, {[i0] = true}
	local queue, qi = {{lx, ly, lz}}, 1
	local open = false
	while qi <= #queue do
		local c = queue[qi]; qi = qi + 1
		cells[#cells + 1] = c
		if #cells > max_cells then open = true; break end
		local cx, cy, cz = c[1], c[2], c[3]
		if cx <= ctx.x1 or cx >= ctx.x2 or cy <= ctx.y1 or cy >= ctx.y2 or cz <= ctx.z1 or cz >= ctx.z2 then
			open = true; break
		end
		for k = 1, 6 do
			local a = AX[k]
			local nx_, ny_, nz_ = cx + a[1], cy + a[2], cz + a[3]
			local j = 1 + nx_ + ny_ * sy + nz_ * sz
			if not seen[j] and bonded_of[data[j]] and not ctx.face(cx, cy, cz, k) then
				seen[j] = true
				queue[#queue + 1] = {nx_, ny_, nz_}
			end
		end
	end
	local result = false
	if not open then result = {cells = cells, set = seen} end
	for idx in pairs(seen) do ctx.block_of[idx] = result end
	return result
end

-- 每個平面的夾持力（kN）：取最多 6 個格面的局部應力平均 σn × 面積 × λ
local function add_clamp(ctx, planes, lam)
	local p, g = ctx.p, ctx.g
	if not (p.stress_at and lam and lam > 0) then return end
	for _, pl in ipairs(planes) do
		local fl = pl.faces
		if fl and #fl > 0 then
			local nsm = math.min(6, #fl)
			local sum, n = 0, 0
			for s = 1, nsm do
				local f = fl[math.floor((s - 0.5) * #fl / nsm) + 1]
				local st = p.stress_at(g, g.ox + f[1], g.oy + f[2], g.oz + f[3])
				if st then
					local v = pl.nu
					local sn = st[1] * v.x * v.x + st[2] * v.y * v.y + st[3] * v.z * v.z + 2 * st[4] * v.x * v.z
					sum, n = sum + math.max(0, sn), n + 1
				end
			end
			if n > 0 then pl.clamp = lam * sum / n * pl.area * 1000 end
		end
	end
end
keyblock.add_clamp = add_clamp

-- 整理岩塊的重量與接觸平面
local function contacts(ctx, block)
	local g, p = ctx.g, ctx.p
	local data, bonded_of, solid_of, lith_of = g.data, g.bonded_of, g.solid_of, g.lith_of
	local rubble_of = g.rubble_of or {}
	local sy, sz = ctx.sy, ctx.sz
	local W = 0
	local planes, by_key = {}, {}
	local n_free = 0
	for _, c in ipairs(block.cells) do
		local cx, cy, cz = c[1], c[2], c[3]
		local i = 1 + cx + cy * sy + cz * sz
		local key = lith_of[data[i]]
		local lith = key and p.lithologies[key]
		W = W + (lith and lith.gamma or p.gamma_other or 20)
		for k = 1, 6 do
			local a = AX[k]
			local j = 1 + (cx + a[1]) + (cy + a[2]) * sy + (cz + a[3]) * sz
			if not block.set[j] then
				local e = {x = a[1], y = a[2], z = a[3]}
				local nb = data[j]
				local pk, nu, area, coh
				if bonded_of[nb] then
					local si = ctx.face(cx, cy, cz, k)
					local n = si and p.joint_sets[si].n_eff
					if n then
						local s = dot(n, e) >= 0 and 1 or -1
						pk = si * 2 + (s > 0 and 1 or 0)
						nu = {x = s * n.x, y = s * n.y, z = s * n.z}
						area = abs(dot(e, nu))
						coh = p.c
					end
				elseif solid_of[nb] and not (rubble_of[nb] and a[2] >= 0) then
					pk = -k        -- 非岩體實心格：依格面方向
					nu = e
					area = 1
					coh = 0
				else
					n_free = n_free + 1
				end
				if pk then
					local pl = by_key[pk]
					if not pl then
						pl = {nu = nu, area = 0, c = coh, set = pk > 0 and math.floor(pk / 2) or nil,
							faces = pk > 0 and {} or nil}
						by_key[pk] = pl
						planes[#planes + 1] = pl
					end
					pl.area = pl.area + area
					if pl.faces then pl.faces[#pl.faces + 1] = c end
				end
			end
		end
	end
	local S = g.support and g.support.forces(g, g.support, block.cells, block.set)
	return W, planes, n_free, S
end

-- 運動學與安全係數。回傳 {fs, mode = "fall"|"plane"|"wedge"|nil, dir = m, planes = {k,l}}
-- S：支護力（support.forces 的 6 桶，可省略）
function keyblock.analyze(W, planes, tanphi, S)
	local gv = {x = 0, y = -1, z = 0}
	local best = {fs = math.huge}
	local function sres(m)
		if not S then return 0 end
		local r = 0
		for k = 1, 6 do
			if S[k] > 0 then
				local a = AX[k]
				local d = a[1] * m.x + a[2] * m.y + a[3] * m.z
				if d > 0 then r = r + S[k] * d end
			end
		end
		return r
	end
	local function admissible(m, skip1, skip2)
		for idx, pl in ipairs(planes) do
			if idx ~= skip1 and idx ~= skip2 and dot(pl.nu, m) > 1e-3 then return false end
		end
		return true
	end
	-- 與運動方向平行的面：凝聚力＋夾持摩擦；滑動面本身的夾持摩擦另外加
	local function parallel_coh(m, skip1, skip2)
		local s = 0
		for idx, pl in ipairs(planes) do
			if idx ~= skip1 and idx ~= skip2 and abs(dot(pl.nu, m)) <= 1e-3 then
				s = s + pl.c * pl.area + (pl.clamp or 0) * tanphi
			end
		end
		return s
	end
	local function clamp_of(k) return (planes[k].clamp or 0) * tanphi end
	-- 落下
	if admissible(gv) then
		local fs = (parallel_coh(gv) + sres(gv)) / W
		if fs < best.fs then best = {fs = fs, mode = "fall", dir = gv} end
	end
	-- 平面滑動
	for k, pl in ipairs(planes) do
		local gn = dot(gv, pl.nu)
		if gn > 1e-3 then
			local t = {x = gv.x - gn * pl.nu.x, y = gv.y - gn * pl.nu.y, z = gv.z - gn * pl.nu.z}
			local tl = sqrt(dot(t, t))
			if tl > 1e-3 then
				local m = {x = t.x / tl, y = t.y / tl, z = t.z / tl}
				if admissible(m, k) then
					local R = W * gn * tanphi + pl.c * pl.area + clamp_of(k) + parallel_coh(m, k) + sres(m)
					local fs = R / (W * tl)
					if fs < best.fs then best = {fs = fs, mode = "plane", dir = m, planes = {k}} end
				end
			end
		end
	end
	-- 楔形滑動
	for k = 1, #planes do
		for l = k + 1, #planes do
			local a, b = planes[k].nu, planes[l].nu
			local line = norm(cross(a, b))
			if line then
				if dot(gv, line) < 0 then line = {x = -line.x, y = -line.y, z = -line.z} end
				local gl = dot(gv, line)
				if gl > 1e-3 and admissible(line, k, l) then
					local gp = {x = gv.x - gl * line.x, y = gv.y - gl * line.y, z = gv.z - gl * line.z}
					local ab = dot(a, b)
					local det = 1 - ab * ab
					if det > 1e-6 then
						local fa, fb = W * dot(gp, a), W * dot(gp, b)
						local Na = (fa - ab * fb) / det
						local Nb = (fb - ab * fa) / det
						if Na >= 0 and Nb >= 0 then
							local R = (Na + Nb) * tanphi + planes[k].c * planes[k].area + planes[l].c * planes[l].area
								+ clamp_of(k) + clamp_of(l) + parallel_coh(line, k, l) + sres(line)
							local fs = R / (W * gl)
							if fs < best.fs then best = {fs = fs, mode = "wedge", dir = line, planes = {k, l}} end
						end
					end
				end
			end
		end
	end
	return best
end

-- 從起點找獨立岩塊並分析。回傳 blocks = {{cells = {{x,y,z}...}（世界座標）, W, fs, mode, dir, planes}...}
-- （同一岩塊只回傳一次；與岩體相連者不回傳）
function keyblock.find_blocks(g, p, starts)
	local ctx = ctx_new(g, p)
	local out, done = {}, {}
	for _, s in ipairs(starts) do
		local lx, ly, lz = s.x - g.ox, s.y - g.oy, s.z - g.oz
		if lx > ctx.x1 and lx < ctx.x2 and ly > ctx.y1 and ly < ctx.y2 and lz > ctx.z1 and lz < ctx.z2
				and g.bonded_of[g.data[1 + lx + ly * ctx.sy + lz * ctx.sz]] then
			local b = grow(ctx, lx, ly, lz)
			if b and not done[b] then
				done[b] = true
				local W, planes, n_free, S = contacts(ctx, b)
				local r = keyblock.analyze(W, planes, p.tanphi, S)
				if r.fs < 1 and (p.clamp or 0) > 0 then
					add_clamp(ctx, planes, p.clamp)
					r = keyblock.analyze(W, planes, p.tanphi, S)
				end
				local cells = {}
				for _, c in ipairs(b.cells) do
					cells[#cells + 1] = {x = g.ox + c[1], y = g.oy + c[2], z = g.oz + c[3]}
				end
				table.sort(cells, function(u, v) return u.y < v.y end)
				out[#out + 1] = {cells = cells, W = W, fs = r.fs, mode = r.mode, dir = r.dir,
					planes = r.planes and (function()
						local t = {}
						for _, idx in ipairs(r.planes) do t[#t + 1] = planes[idx] end
						return t
					end)() or nil,
					n_free = n_free}
			end
		end
	end
	return out
end

---------------------------------------------------------------------------
-- 整體滑動（楔形稜柱）
-- 節理貫通、間距小於坡高時，坡面上的小岩塊被其他節理面切成一塊塊、互相卡住；但沿兩組
-- 節理交線 l 的運動與這兩組的所有平面都平行，所以夾在兩組各自相鄰兩道面之間的「稜柱」
-- （截面約 間距×間距，沿 l 從坡面延伸到地表）可以整根滑出，其他組（例如近水平的 J1）切過
-- 稜柱內部也不影響（隨稜柱一起移動、不提供強度）。
--
-- 稜柱 = 起點所在、a 組平面編號 = ka 且 b 組 = kb（plane_k = ⌊(m·p + o)/L⌋）的相連鍵結格。
--   稜柱的下端從坡面露出 → 被空氣隔開，有界；下端插進坡腳前方的岩體（例如坑底）→ 沿 l 一直
--   延伸到範圍邊界、超過 max_mass 格、或延伸到起點下方 drop_max（預設 12）m 以下 → 沒有露出，不判定。
-- 邊界：鄰格是鍵結格 → 跨過 a 或 b 組的平面（下方的底面或上方平行的面）；該格面是節理
--       → 節理面（c、φ），是岩橋（延續性 < 1 的缺口）→ 以岩橋強度 bridge_c 計凝聚力。
--       其他同 contacts()。力學用 keyblock.analyze（兩個底面的楔形；平行的上方面不擋運動）。
-- 單一平面的平面滑動（岩板沿走向無限延伸，需要側向釋放面）由小岩塊與逐格節理滑動處理。
--
-- params 另需：max_mass（預設 8000）、bridge_c（kPa，岩橋的凝聚力；nil = 有岩橋就不判定）、
--             max_floods（每次最多擴展幾根稜柱，預設 24）、collect_all（顯示用：FS ≥ 1 的稜柱也回傳）
-- 回傳 masses = {{cells（世界座標）, W, fs, mode, dir, sets = {組名...}, ks}...}（只含 FS < 1 者）, stats

-- 某組節理在格 (x, y, z)（世界座標）的平面編號
local function plane_k(js, x, y, z)
	return math.floor((js.mx * x + js.my * y + js.mz * z + js.o) / js.L)
end
keyblock.plane_k = plane_k

function keyblock.find_masses(g, p, starts)
	local ctx = ctx_new(g, p)
	local sets = p.joint_sets
	local data, bonded_of, solid_of, lith_of = g.data, g.bonded_of, g.solid_of, g.lith_of
	local rubble_of = g.rubble_of or {}
	local sy, sz = ctx.sy, ctx.sz
	local ox, oy, oz = g.ox, g.oy, g.oz
	local max_mass = p.max_mass or 8000
	local max_floods = p.max_floods or 48
	local drop_max = p.drop_max or 12
	local stats = {floods = 0, visited = 0, unbounded = 0, evaluated = 0}

	-- 組合：單一平面與兩兩一對；重力下可能的運動方向（平面：沿傾向往下；楔形：交線往下）
	local combos = {}
	for a = 1, #sets do
		if (sets[a].persistence or 1) > 0 and sets[a].mx then
			local n = sets[a].n_eff
			for b = a + 1, #sets do
				if (sets[b].persistence or 1) > 0 and sets[b].mx then
					local l = norm(cross(n, sets[b].n_eff))
					if l then
						if l.y > 0 then l = {x = -l.x, y = -l.y, z = -l.z} end
						if -l.y > 0.17 then combos[#combos + 1] = {a, b, dir = l} end
					end
				end
			end
		end
	end
	if #combos == 0 then return {}, stats end

	local function open(i)
		local c = data[i]
		return not solid_of[c] or rubble_of[c] ~= nil
	end
	-- 起點：鍵結格、由低到高
	local list = {}
	for _, s in ipairs(starts) do
		local lx, ly, lz = s.x - ox, s.y - oy, s.z - oz
		if lx > ctx.x1 and lx < ctx.x2 and ly > ctx.y1 and ly < ctx.y2 and lz > ctx.z1 and lz < ctx.z2
				and bonded_of[data[1 + lx + ly * sy + lz * sz]] then
			list[#list + 1] = {lx, ly, lz}
		end
	end
	table.sort(list, function(u, v) return u[2] < v[2] end)

	local out, tried = {}, {}
	local taken = {}
	for _, s in ipairs(list) do
		if stats.floods >= max_floods then break end
		local lx, ly, lz = s[1], s[2], s[3]
		local i0 = 1 + lx + ly * sy + lz * sz
		for ci, cb in ipairs(combos) do
			if not taken[i0] and stats.floods < max_floods then
				-- 運動方向的水平分量須朝向起點的開放側面（或下方開放）
				local d = cb.dir
				local hl = sqrt(d.x * d.x + d.z * d.z)
				local ok = open(i0 - sy)
				if not ok and hl > EPS then
					local hx, hz = d.x / hl, d.z / hl
					ok = (hx > 0.5 and open(i0 + 1)) or (hx < -0.5 and open(i0 - 1))
						or (hz > 0.5 and open(i0 + sz)) or (hz < -0.5 and open(i0 - sz))
				end
				if ok then
					local wx, wy, wz = ox + lx, oy + ly, oz + lz
					local ks = {}
					for t = 1, #cb do ks[t] = plane_k(sets[cb[t]], wx, wy, wz) end
					local key = ci .. ":" .. table.concat(ks, ",")
					if not tried[key] then
						tried[key] = true
						stats.floods = stats.floods + 1
						local function inside(x, y, z)
							for t = 1, #cb do
								if plane_k(sets[cb[t]], x, y, z) ~= ks[t] then return false end
							end
							return true
						end
						-- 擴展
						local cells, set = {}, {[i0] = true}
						local queue, qi = {{lx, ly, lz}}, 1
						local bounded = true
						while qi <= #queue do
							local c = queue[qi]; qi = qi + 1
							cells[#cells + 1] = c
							if #cells > max_mass then bounded = false; break end
							local cx, cy, cz = c[1], c[2], c[3]
							if cx <= ctx.x1 or cx >= ctx.x2 or cy <= ctx.y1 or cy >= ctx.y2 or cz <= ctx.z1 or cz >= ctx.z2
									or cy < ly - drop_max then
								bounded = false; break
							end
							for k = 1, 6 do
								local a = AX[k]
								local nx_, ny_, nz_ = cx + a[1], cy + a[2], cz + a[3]
								local j = 1 + nx_ + ny_ * sy + nz_ * sz
								if not set[j] and bonded_of[data[j]] and inside(ox + nx_, oy + ny_, oz + nz_) then
									set[j] = true
									queue[#queue + 1] = {nx_, ny_, nz_}
								end
							end
						end
						stats.visited = stats.visited + #cells
						if not bounded then
							stats.unbounded = stats.unbounded + 1
						else
							-- 接觸面
							local W = 0
							local planes, by_key = {}, {}
							local bridged = false
							for _, c in ipairs(cells) do
								local cx, cy, cz = c[1], c[2], c[3]
								local i = 1 + cx + cy * sy + cz * sz
								local lk = lith_of[data[i]]
								local lith = lk and p.lithologies[lk]
								W = W + (lith and lith.gamma or p.gamma_other or 20)
								for k = 1, 6 do
									local a = AX[k]
									local j = 1 + (cx + a[1]) + (cy + a[2]) * sy + (cz + a[3]) * sz
									if not set[j] then
										local e = {x = a[1], y = a[2], z = a[3]}
										local nb = data[j]
										local pk, nu, area, coh
										if bonded_of[nb] then
											-- 跨過哪一組的面
											local si
											for t = 1, #cb do
												if plane_k(sets[cb[t]], ox + cx + a[1], oy + cy + a[2], oz + cz + a[3]) ~= ks[t] then
													si = cb[t]; break
												end
											end
											if si then
												local n = sets[si].n_eff
												local sg = dot(n, e) >= 0 and 1 or -1
												pk = si * 2 + (sg > 0 and 1 or 0)
												nu = {x = sg * n.x, y = sg * n.y, z = sg * n.z}
												area = abs(dot(e, nu))
												if ctx.face(cx, cy, cz, k) then
													coh = p.c
												else
													coh = p.bridge_c or 0
													bridged = true
												end
											else
												pk, nu, area, coh = -k, e, 1, p.bridge_c or 0
											end
										elseif solid_of[nb] and not (rubble_of[nb] and a[2] >= 0) then
											pk, nu, area, coh = -k, e, 1, 0
										end
										if pk then
											local pl = by_key[pk]
											if not pl then
												pl = {nu = nu, area = 0, ca = 0, set = pk > 0 and math.floor(pk / 2) or nil,
													faces = pk > 0 and {} or nil}
												by_key[pk] = pl
												planes[#planes + 1] = pl
											end
											pl.area = pl.area + area
											pl.ca = pl.ca + area * coh
											if pl.faces then pl.faces[#pl.faces + 1] = c end
										end
									end
								end
							end
							for _, pl in ipairs(planes) do pl.c = pl.area > 0 and pl.ca / pl.area or 0 end
							if not (bridged and not p.bridge_c) then
								stats.evaluated = stats.evaluated + 1
								local S = g.support and g.support.forces(g, g.support, cells, set)
								local r = keyblock.analyze(W, planes, p.tanphi, S)
								if r.fs < 1 and (p.mass_clamp or 0) > 0 then
									add_clamp(ctx, planes, p.mass_clamp)
									r = keyblock.analyze(W, planes, p.tanphi, S)
								end
								if r.fs < 1 or p.collect_all then
									local wc = {}
									for _, c in ipairs(cells) do
										wc[#wc + 1] = {x = ox + c[1], y = oy + c[2], z = oz + c[3]}
										if r.fs < 1 then taken[1 + c[1] + c[2] * sy + c[3] * sz] = true end
									end
									table.sort(wc, function(u, v) return u.y < v.y end)
									local names = {}
									for t = 1, #cb do names[t] = sets[cb[t]].name end
									out[#out + 1] = {cells = wc, W = W, fs = r.fs, mode = r.mode, dir = r.dir,
										sets = names, ks = ks}
								end
							end
						end
					end
				end
			end
		end
	end
	return out, stats
end

-- 給定的格子群（世界座標）當成一個塊體分析：回傳 analyze 的結果（含夾持）
function keyblock.analyze_group(g, p, cells)
	local ctx = ctx_new(g, p)
	local sy, sz = ctx.sy, ctx.sz
	local block = {cells = {}, set = {}}
	for _, c in ipairs(cells) do
		local lx, ly, lz = c.x - g.ox, c.y - g.oy, c.z - g.oz
		if lx <= 0 or ly <= 0 or lz <= 0 or lx >= g.nx - 1 or ly >= g.ny - 1 or lz >= g.nz - 1 then
			return {fs = 0}   -- 碰到範圍邊界：無法判斷，照舊（掉落）
		end
		block.cells[#block.cells + 1] = {lx, ly, lz}
		block.set[1 + lx + ly * sy + lz * sz] = true
	end
	local W, planes, _, S = contacts(ctx, block)
	local r = keyblock.analyze(W, planes, p.tanphi, S)
	if r.fs < 1 and (p.clamp or 0) > 0 then
		add_clamp(ctx, planes, p.clamp)
		r = keyblock.analyze(W, planes, p.tanphi, S)
	end
	r.W = W
	return r
end

-- 單格所在岩塊（顯示用）。回傳 nil（非鍵結格／範圍外）、false（與岩體相連）或同 find_blocks 的一項
function keyblock.block_at(g, p, x, y, z)
	local blocks = keyblock.find_blocks(g, p, {{x = x, y = y, z = z}})
	if blocks[1] then return blocks[1] end
	local lx, ly, lz = x - g.ox, y - g.oy, z - g.oz
	if lx < 0 or ly < 0 or lz < 0 or lx >= g.nx or ly >= g.ny or lz >= g.nz then return nil end
	if not g.bonded_of[g.data[1 + lx + ly * g.nx + lz * g.nx * g.ny]] then return nil end
	return false
end

-- 滑動後的位移：沿滑動方向 m 一格一格移動（貪婪）。每一步從「橫向一格、往下一格、
-- 或兩者組合」中，挑與 m 夾角最小（< 66°）、且放得下的一步；都放不下、或平移一步後
-- 落不下去（已離開節理面、在平地上）就停，最後再往下落到底。
-- is_free(x, y, z)：群外的格是否可進入。回傳 {x, y, z} 位移（0,0,0 → 動不了）
function keyblock.slide_offset(cells, m, is_free, max_steps)
	max_steps = max_steps or 16
	local own = {}
	for _, c in ipairs(cells) do own[c.x .. "," .. c.y .. "," .. c.z] = true end
	local function fits(dx, dy, dz)
		for _, c in ipairs(cells) do
			local x, y, z = c.x + dx, c.y + dy, c.z + dz
			if not own[x .. "," .. y .. "," .. z] and not is_free(x, y, z) then return false end
		end
		return true
	end
	-- 候選步：與 m 同向（夾角 < 66°）者，依夾角排序
	local cand = {}
	for dx = -1, 1 do for dy = -1, 0 do for dz = -1, 1 do
		if dx ~= 0 or dy ~= 0 or dz ~= 0 then
			local l = sqrt(dx * dx + dy * dy + dz * dz)
			local c = (dx * m.x + dy * m.y + dz * m.z) / l
			if c > 0.4 then cand[#cand + 1] = {dx, dy, dz, c} end
		end
	end end end
	table.sort(cand, function(u, v) return u[4] > v[4] end)
	local off = {x = 0, y = 0, z = 0}
	local horiz, flat = 0, 0
	for _ = 1, max_steps * 3 do
		local moved = false
		for _, st in ipairs(cand) do
			local nx_, ny_, nz_ = off.x + st[1], off.y + st[2], off.z + st[3]
			if fits(nx_, ny_, nz_) then
				off = {x = nx_, y = ny_, z = nz_}
				if st[1] ~= 0 or st[3] ~= 0 then horiz = horiz + 1 end
				if st[2] == 0 then flat = flat + 1 else flat = 0 end
				moved = true
				break
			end
		end
		-- 往下落得了就先落（離開節理面後是自由落下）
		local fall = 0
		while fall < 256 and fits(off.x, off.y - 1, off.z) do off.y = off.y - 1; flat = 0; fall = fall + 1 end
		if fall >= 256 then break end
		if not moved or horiz >= max_steps or flat >= 1 then break end
	end
	-- 往下落到底
	for _ = 1, 256 do
		if fits(off.x, off.y - 1, off.z) then off.y = off.y - 1 else break end
	end
	return off
end

return keyblock
