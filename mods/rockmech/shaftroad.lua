-- rockmech/shaftroad.lua
-- 豎井道路：營地到每口豎井鋪一條壓碎大理岩（壓實）的路（寬 WIDTH m），玩家一看就知道礦要載去哪裡倒。
-- 路線：5 m 格網上 A*，成本 = 距離 ×（1 + 坡度超過 8% 的懲罰）；已經有路的格便宜（幾條路共用主幹）；繞開其他豎井。
-- 縱斷面：貼著實際地面（短距離平滑）；採場裡跟階面齊高，換階的地方平滑成坡道。找路線用沒切階的地形。
-- 路面：最上面一格是對應級數的壓實碎石，底下填到碰到實心為止；上面的岩石、表土、樹清掉（天然地形，不算開挖）。
-- 只蓋一次（mod storage shaft_roads），豎井都蓋好之後由 oreshaft.lua 呼叫。

local cfg = rockmech.cfg
local storage = rockmech.collapse.storage
local WIDTH = 8
local GRADE = 0.12
local CELL = 5
local PAD = 58              -- 營地平台（半徑 60 m）裡面不鋪
local NLEV = rockmech.RUBBLE_LEVELS
local P2 = 200             -- 大理岩碎石的品位（跟豎井填料一樣）

-- 路面的參考地面：真實地形用沒切成階的高程（採場的階之間沒有坡道，照階算會找不到路、或墊出高牆）
local function surface(x, z)
	local T = cfg.terrain
	if T and T.smooth_height then
		-- 採場裡：階的中間（實際的階面比沒切階的地形低 0–B m），路面一半挖、一半填
		local half = T.quarry and T.quarry(x, z) and (T.bench or 0) / 2 or 0
		return cfg.surface_y + T.smooth_height(x, z) + 1 - half
	end
	return cfg.surface_y + rockmech.stress.terrain_rise(cfg, x, z) + 1
end

-- 二元堆積（A* 的 open list）
local function heap_push(h, k, v)
	local i = #h + 1
	h[i] = {k, v}
	while i > 1 do
		local p = math.floor(i / 2)
		if h[p][1] <= h[i][1] then break end
		h[p], h[i] = h[i], h[p]; i = p
	end
end
local function heap_pop(h)
	local top = h[1]
	local last = table.remove(h)
	if #h > 0 then
		h[1] = last
		local i = 1
		while true do
			local l, r, m = 2 * i, 2 * i + 1, i
			if h[l] and h[l][1] < h[m][1] then m = l end
			if h[r] and h[r][1] < h[m][1] then m = r end
			if m == i then break end
			h[m], h[i] = h[i], h[m]; i = m
		end
	end
	return top[1], top[2]
end

local MOVES = {}
for dx = -2, 2 do for dz = -2, 2 do
	local g = math.abs(dx) + math.abs(dz)
	if g > 0 and not (math.abs(dx) == 2 and math.abs(dz) == 2) and not (math.abs(dx) == 2 and dz == 0) and not (dx == 0 and math.abs(dz) == 2) then
		MOVES[#MOVES + 1] = {dx, dz, math.sqrt(dx * dx + dz * dz) * CELL}
	end
end end

-- A*：from → 離 goal 中心 reach m 內；blocked(x, z)；used[key] = 已經有路。回傳 {{x, z}, ...}
local function route(from, goal, reach, blocked, used, box, max_grade)
	local nx = math.floor((box.x2 - box.x1) / CELL) + 1
	local nz = math.floor((box.z2 - box.z1) / CELL) + 1
	local function wx(i) return box.x1 + i * CELL end
	local function wz(j) return box.z1 + j * CELL end
	local H = {}
	local function h_at(i, j)
		local k = j * nx + i
		local v = H[k]
		if not v then v = surface(wx(i), wz(j)); H[k] = v end
		return v
	end
	local si = math.floor((from.x - box.x1) / CELL + 0.5)
	local sj = math.floor((from.z - box.z1) / CELL + 0.5)
	local g, prev, done = {}, {}, {}
	local open = {}
	local function hcost(i, j) return math.sqrt((wx(i) - goal.x) ^ 2 + (wz(j) - goal.z) ^ 2) * 0.5 end
	local s = sj * nx + si
	g[s] = 0
	heap_push(open, hcost(si, sj), s)
	local found
	local n = 0
	while #open > 0 do
		local _, k = heap_pop(open)
		if not done[k] then
			done[k] = true
			n = n + 1
			if n > 400000 then break end
			local i, j = k % nx, math.floor(k / nx)
			if math.sqrt((wx(i) - goal.x) ^ 2 + (wz(j) - goal.z) ^ 2) <= reach then found = k; break end
			local h0 = h_at(i, j)
			for _, m in ipairs(MOVES) do
				local a, b = i + m[1], j + m[2]
				if a >= 0 and b >= 0 and a < nx and b < nz then
					local q = b * nx + a
					if not done[q] and not blocked(wx(a), wz(b)) then
						local grade = math.abs(h_at(a, b) - h0) / m[3]
						local c = grade <= max_grade and m[3] * (1 + 12 * math.max(0, grade - 0.08))
						if c and used[q] then c = c * 0.4 end
						local ng = c and g[k] + c
						if ng and (not g[q] or ng < g[q]) then
							g[q], prev[q] = ng, k
							heap_push(open, ng + hcost(a, b), q)
						end
					end
				end
			end
		end
	end
	if not found then return nil end
	local path, k = {}, found
	while k do
		used[k] = true
		table.insert(path, 1, {x = wx(k % nx), z = wz(math.floor(k / nx))})
		k = prev[k]
	end
	return path
end

-- 折線磨圓（Chaikin 兩次）再每 1 m 取一點
local function smooth_line(pts)
	for _ = 1, 2 do
		local out = {pts[1]}
		for i = 1, #pts - 1 do
			local a, b = pts[i], pts[i + 1]
			out[#out + 1] = {x = a.x * 0.75 + b.x * 0.25, z = a.z * 0.75 + b.z * 0.25}
			out[#out + 1] = {x = a.x * 0.25 + b.x * 0.75, z = a.z * 0.25 + b.z * 0.75}
		end
		out[#out + 1] = pts[#pts]
		pts = out
	end
	local res = {{x = pts[1].x, z = pts[1].z}}
	local carry = 0
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local L = math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
		local s = 1 - carry
		while s <= L do
			res[#res + 1] = {x = a.x + (b.x - a.x) * s / L, z = a.z + (b.z - a.z) * s / L}
			s = s + 1
		end
		carry = L - (s - 1)
	end
	return res
end

-- 縱斷面：貼著地面，前後各 SMOOTH m 平均（不硬壓坡度：硬壓的話過山谷會墊出高牆）；end_y：終點固定的高程，最後 30 m 漸變過去
-- 路面照實際地面（採場裡就是階面，跟兩旁齊高）；換階的地方靠平滑做出坡道：採場裡前後各 SMOOTH_Q m（5 m 一階 → 約 10%）
local SMOOTH, SMOOTH_Q = 8, 25
local function ground_surface(x, z) return cfg.surface_y + rockmech.stress.terrain_rise(cfg, x, z) + 1 end
local function profile(line, end_y)
	local n = #line
	local gy, win = {}, {}
	local T = cfg.terrain
	for i, p in ipairs(line) do
		gy[i] = ground_surface(p.x, p.z)
		win[i] = T and T.quarry and T.quarry(p.x, p.z) and SMOOTH_Q or SMOOTH
	end
	local y = {}
	for i = 1, n do
		local sum, cnt = 0, 0
		for k = math.max(1, i - win[i]), math.min(n, i + win[i]) do sum = sum + gy[k]; cnt = cnt + 1 end
		y[i] = sum / cnt
	end
	if end_y then
		for i = math.max(1, n - 30), n do
			local t = (i - (n - 30)) / 30
			if t > 0 then y[i] = y[i] + (end_y - y[i]) * t end
		end
	end
	return y
end

-- 路面的每一格：key → {x, z, y = 路面高程, w = 離中線}
local function stamp(cells, line, ys)
	for i, p in ipairs(line) do
		local a, b = line[math.max(1, i - 2)], line[math.min(#line, i + 2)]
		local tx, tz = b.x - a.x, b.z - a.z
		local L = math.sqrt(tx * tx + tz * tz)
		if L > 0 then
			local nx, nz = -tz / L, tx / L
			for w = -WIDTH / 2, WIDTH / 2, 0.5 do
				local x, z = math.floor(p.x + nx * w + 0.5), math.floor(p.z + nz * w + 0.5)
				if x * x + z * z > PAD * PAD then
					local k = x .. "," .. z
					local c = cells[k]
					if not c or math.abs(w) < c.w then cells[k] = {x = x, z = z, y = ys[i], w = math.abs(w)} end
				end
			end
		end
	end
end

-- 這一欄可以動的方塊：天然岩石、碎石、表土、樹、空氣
local function natural(name)
	if name == "air" then return true end
	if name == "rockmech:shaft_marble" then return false end
	if rockmech.lith_of_node[name] or rockmech.rubble_level[name] then return true end
	if core.get_item_group(name, "rockmech_topsoil") > 0 then return true end      -- 表土（草）
	return name == "default:tree" or name == "default:leaves" or name == "default:apple"
end
local function is_air(name) return name == "air" end

local function pave(c)
	local S = c.y
	local yb = math.ceil(S) - 1
	local k = math.floor((S - yb) * NLEV + 0.5)
	if k <= 0 then yb, k = yb - 1, NLEV end
	-- 先檢查這欄：有建築（非天然）就不動
	for y = yb - 2, yb + 8 do
		if not natural(core.get_node({x = c.x, y = y, z = c.z}).name) then return false end
	end
	local base = rockmech.rubble_for("rockmech:marble")
	local full = {name = rockmech.compact_of[rockmech.rubble_with_level(base, NLEV, P2)], param2 = P2}
	local top = {name = rockmech.compact_of[rockmech.rubble_with_level(base, k, P2)] or full.name, param2 = P2}
	core.swap_node({x = c.x, y = yb, z = c.z}, top)
	-- 往下填到實心
	for y = yb - 1, yb - 15, -1 do
		local p = {x = c.x, y = y, z = c.z}
		local n = core.get_node(p).name
		local def = core.registered_nodes[n]
		if n ~= "air" and def and def.walkable ~= false and not rockmech.rubble_level[n] and n ~= "default:leaves" then
			if rockmech.lith_of_node[n] then core.swap_node(p, full) end      -- 路面下第一格岩石也鋪平
			break
		end
		core.swap_node(p, full)
	end
	-- 往上清空，連續 4 格空氣就停
	local air = 0
	for y = yb + 1, yb + 80 do
		local p = {x = c.x, y = y, z = c.z}
		local n = core.get_node(p).name
		if is_air(n) then
			air = air + 1
			if air >= 4 then break end
		else
			air = 0
			if not natural(n) then break end
			core.swap_node(p, {name = "air"})
		end
	end
end

local building = false
function rockmech.shaft_roads(owner)
	if building or storage:get_string("shaft_roads") ~= "" or not cfg.shafts then return end
	local shafts = {}
	for i in ipairs(cfg.shafts) do
		local d = core.deserialize(storage:get_string("shaft:" .. i))
		if not d then return end
		shafts[#shafts + 1] = d
	end
	building = true
	local t0 = core.get_us_time()
	local R = (cfg.shaft_r or 6) + (cfg.shaft_ring or 6)
	local box = {x1 = -200, z1 = -200, x2 = 200, z2 = 200}
	for _, d in ipairs(shafts) do
		box.x1, box.x2 = math.min(box.x1, d.x - 250), math.max(box.x2, d.x + 250)
		box.z1, box.z2 = math.min(box.z1, d.z - 250), math.max(box.z2, d.z + 250)
	end
	local used, cells = {}, {}
	-- 近的先蓋，遠的可以沿用前面的路
	table.sort(shafts, function(a, b) return a.x * a.x + a.z * a.z < b.x * b.x + b.z * b.z end)
	local n_ok = 0
	for _, d in ipairs(shafts) do
		local function blocked(x, z)
			for _, o in ipairs(shafts) do
				if (x - o.x) ^ 2 + (z - o.z) ^ 2 <= (R + 3) ^ 2 then return true end
			end
			return false
		end
		-- 坡度上限先試 GRADE，找不到再放寬
		local path
		for _, mg in ipairs({GRADE, 0.18, 0.3, 10}) do
			path = route({x = 0, z = 0}, d, R + 9, blocked, used, box, mg)
			if path then
				if mg > GRADE then core.log("warning", ("[rockmech] 豎井道路：(%d, %d) 坡度放寬到 %g"):format(d.x, d.z, mg)) end
				break
			end
		end
		if path then
			-- 最後接到井壁外緣（離中心 R + 0.5 m）
			local last = path[#path]
			local dx, dz = last.x - d.x, last.z - d.z
			local L = math.sqrt(dx * dx + dz * dz)
			path[#path + 1] = {x = d.x + dx / L * (R + 0.5), z = d.z + dz / L * (R + 0.5)}
			local line = smooth_line(path)
			stamp(cells, line, profile(line, d.top + 1))
			n_ok = n_ok + 1
		else
			core.log("warning", ("[rockmech] 豎井道路：(%d, %d) 找不到路線"):format(d.x, d.z))
		end
	end
	-- 按 80 m 一塊分組，一塊一塊載入後鋪
	local tiles, order = {}, {}
	for _, c in pairs(cells) do
		local tk = math.floor(c.x / 80) .. "," .. math.floor(c.z / 80)
		local t = tiles[tk]
		if not t then t = {cells = {}, lo = math.huge, hi = -math.huge}; tiles[tk] = t; order[#order + 1] = tk end
		t.cells[#t.cells + 1] = c
		t.lo, t.hi = math.min(t.lo, c.y), math.max(t.hi, c.y)
	end
	local ncell, high, maxd, flush = 0, 0, 0, 0
	for _, c in pairs(cells) do
		ncell = ncell + 1
		local d = c.y - (cfg.surface_y + rockmech.stress.terrain_rise(cfg, c.x, c.z) + 1)      -- 正：填，負：挖
		if d > 5 then high = high + 1 end
		if math.abs(d) <= 0.6 then flush = flush + 1 end
		if math.abs(d) > math.abs(maxd) then maxd = d end
	end
	core.log("action", ("[rockmech] 豎井道路：跟地面齊高（±0.6 m）%d%%、填超過 5 m 的格 %d、最大挖填 %.1f m")
		:format(math.floor(100 * flush / math.max(1, ncell) + 0.5), high, maxd))
	core.log("action", ("[rockmech] 豎井道路：%d 條、%d 格，路線 %.0f ms"):format(n_ok, ncell, (core.get_us_time() - t0) / 1000))
	local idx, skipped = 0, 0
	local function next_tile()
		idx = idx + 1
		local tk = order[idx]
		if not tk then
			storage:set_string("shaft_roads", "1")
			building = false
			core.log("action", ("[rockmech] 豎井道路鋪好了（有建築跳過 %d 格）"):format(skipped))
			return
		end
		local t = tiles[tk]
		local tx, tz = tk:match("^(%-?%d+),(%-?%d+)$")
		tx, tz = tonumber(tx) * 80, tonumber(tz) * 80
		core.emerge_area({x = tx - 1, y = math.floor(t.lo) - 45, z = tz - 1}, {x = tx + 81, y = math.ceil(t.hi) + 85, z = tz + 81}, function(_, _, rem)
			if rem > 0 then return end
			local C = rockmech.collapse
			C.quiet = C.quiet + 1
			local ok, err = pcall(function() for _, c in ipairs(t.cells) do if pave(c) == false then skipped = skipped + 1 end end end)
			C.quiet = C.quiet - 1
			if not ok then core.log("error", "[rockmech] 豎井道路：" .. tostring(err)) end
			core.after(0, next_tile)
		end)
	end
	next_tile()
end
