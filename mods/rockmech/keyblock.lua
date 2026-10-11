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

-- 整理岩塊的重量與接觸平面
local function contacts(ctx, block)
	local g, p = ctx.g, ctx.p
	local data, bonded_of, solid_of, lith_of = g.data, g.bonded_of, g.solid_of, g.lith_of
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
				elseif solid_of[nb] then
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
						pl = {nu = nu, area = 0, c = coh, set = pk > 0 and math.floor(pk / 2) or nil}
						by_key[pk] = pl
						planes[#planes + 1] = pl
					end
					pl.area = pl.area + area
				end
			end
		end
	end
	return W, planes, n_free
end

-- 運動學與安全係數。回傳 {fs, mode = "fall"|"plane"|"wedge"|nil, dir = m, planes = {k,l}}
function keyblock.analyze(W, planes, tanphi)
	local gv = {x = 0, y = -1, z = 0}
	local best = {fs = math.huge}
	local function admissible(m, skip1, skip2)
		for idx, pl in ipairs(planes) do
			if idx ~= skip1 and idx ~= skip2 and dot(pl.nu, m) > 1e-3 then return false end
		end
		return true
	end
	local function parallel_coh(m, skip1, skip2)
		local s = 0
		for idx, pl in ipairs(planes) do
			if idx ~= skip1 and idx ~= skip2 and abs(dot(pl.nu, m)) <= 1e-3 then s = s + pl.c * pl.area end
		end
		return s
	end
	-- 落下
	if admissible(gv) then
		local fs = parallel_coh(gv) / W
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
					local R = W * gn * tanphi + pl.c * pl.area + parallel_coh(m, k)
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
								+ parallel_coh(line, k, l)
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
				local W, planes, n_free = contacts(ctx, b)
				local r = keyblock.analyze(W, planes, p.tanphi)
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
