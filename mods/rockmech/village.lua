-- rockmech/village.lua
-- 村莊配置（新的隨機、自訂世界）：營地不再是一整片混凝土地坪，而是沿著道路分散的店家，像 Minecraft 的村莊。
-- 這裡只決定「路在哪、每家店的地塊在哪、面向哪」（純計算，由種子和地形決定，每次算出來都一樣）；蓋房子在各店的建造函式。
--
-- 道路：主路從村莊中心往兩側各延伸約 120 m，每步 4 m，方向照雜訊緩慢彎曲；遇到陡的方向就改走比較緩的方向
--   （每步試 ±0°、±20°、±40°，挑坡度最緩、又不太偏離原方向的）。主路上再長出 2–3 條岔路（各 40–80 m）。
-- 地塊：店家照清單（LOTS）一家一家沿路找位置：路的左右兩側、離路邊 2 m，面向道路；
--   地塊內地面高差 ≤ MAX_RELIEF m、不壓到道路和別的地塊（各留 3 m）。找不到就退到離路遠一點、或放寬高差再找。
-- 回傳 {roads = {{points = {{x, z}, …}}, …}, lots = {{kind, x, z（地塊中心）, w, d（沿路寬、垂直路深）, rot（0..3，門朝 +z 轉幾個 90°）,
--   y（地塊整地後的地面高度）}, …}}

local V = {}

local STEP = 4
local MAX_RELIEF = 3
-- 店家（kind、沿路寬 w、深 d）。順序 = 找位置的順序（大的先找）
V.LOTS = {
	{kind = "vehicle_dealer", w = 28, d = 22},     -- 重型機械車輛商：展示間＋交車展示場
	{kind = "receiving", w = 10, d = 20},          -- 收料場：收料車、地磅
	{kind = "crusher", w = 12, d = 12},            -- 破碎站
	{kind = "garage", w = 14, d = 12},             -- 修車廠：工房＋待修空地
	{kind = "lecture_hall", w = 13, d = 10},       -- 大學講堂
	{kind = "research", w = 11, d = 9},            -- 研究所
	{kind = "consulting", w = 10, d = 8},          -- 工程顧問公司（採礦設備）
	{kind = "tech_office", w = 10, d = 8},         -- 技師事務所（最多三位技師）
	{kind = "tech_office", w = 10, d = 8},
	{kind = "blasting", w = 9, d = 8},             -- 爆破器材行
	{kind = "hardware", w = 10, d = 8},            -- 五金工具行
	{kind = "staffing", w = 9, d = 8},             -- 人力派遣（操作員休息）
}

local function hash(a, b, seed)
	local v = math.sin(a * 127.1 + b * 311.7 + seed * 74.7) * 43758.5453
	return v - math.floor(v)
end

-- ground(x, z)：地面高度（公式地形）。路照地形自由彎曲；只有建築正前方那一段是正方向（V.plan 的門前路）
local CORE = 0
local HALF = math.pi / 2
local function grow_road(ground, x, z, ang, steps, seed, id, cx, cz)
	local pts = {{x, z}}
	local straight = 0
	for i = 1, steps do
		local core_zone = (x - (cx or 0)) ^ 2 + (z - (cz or 0)) ^ 2 < CORE * CORE
		local choices
		if core_zone then
			ang = math.floor(ang / HALF + 0.5) * HALF
			straight = straight + 1
			choices = straight >= 3 and {0, HALF, -HALF} or {0}
		else
			ang = ang + (hash(i, id, seed) - 0.5) * 0.35          -- 緩慢彎曲
			choices = {0, 0.35, -0.35, 0.7, -0.7}
		end
		local best, bscore
		for _, da in ipairs(choices) do
			local a = ang + da
			local nx, nz = x + STEP * math.sin(a), z + STEP * math.cos(a)
			local grade = math.abs(ground(nx, nz) - ground(x, z)) / STEP
			local score = grade + (core_zone and 0.25 or 0.15) * math.abs(da)
			if not bscore or score < bscore then best, bscore = a, score end
		end
		if core_zone and best ~= ang then straight = 0 end
		ang = best
		x, z = x + STEP * math.sin(ang), z + STEP * math.cos(ang)
		pts[#pts + 1] = {math.floor(x + 0.5), math.floor(z + 0.5)}
	end
	return pts, ang
end

-- 兩點之間的路段格子（每 1 m）
local function road_cells(roads)
	local cells = {}
	for _, r in ipairs(roads) do
		for i = 2, #r.points do
			local a, b = r.points[i - 1], r.points[i]
			local n = math.max(math.abs(b[1] - a[1]), math.abs(b[2] - a[2]))
			for k = 0, n do
				local x = math.floor(a[1] + (b[1] - a[1]) * k / math.max(1, n) + 0.5)
				local z = math.floor(a[2] + (b[2] - a[2]) * k / math.max(1, n) + 0.5)
				for dx = -1, 1 do for dz = -1, 1 do cells[(x + dx) .. "," .. (z + dz)] = true end end      -- 路寬 3 m
			end
		end
	end
	return cells
end
V.road_cells = road_cells

-- 地塊的四個角（rot：門朝 +z 轉幾個 90°；w 沿路、d 垂直路）
local function lot_rect(L)
	local w, d = L.w, L.d
	if L.rot % 2 == 1 then w, d = d, w end
	return L.x - w / 2, L.z - d / 2, L.x + w / 2, L.z + d / 2
end
V.lot_rect = lot_rect

function V.plan(ground, seed, cx, cz)
	cx, cz = cx or 0, cz or 0
	seed = (seed or 0) % 997
	local roads = {}
	local a0 = 2 * math.pi * hash(1, 2, seed)
	local p1 = grow_road(ground, cx, cz, a0, 30, seed, 1, cx, cz)
	local p2 = grow_road(ground, cx, cz, a0 + math.pi, 30, seed, 2, cx, cz)
	-- 主路：p2 反過來接 p1
	local main = {}
	for i = #p2, 2, -1 do main[#main + 1] = p2[i] end
	for _, p in ipairs(p1) do main[#main + 1] = p end
	roads[1] = {points = main, main = true}
	-- 岔路：主路上 2–3 個點，往左或右
	local nb = 2 + math.floor(hash(3, 4, seed) * 2)
	for b = 1, nb do
		local i = math.floor(#main * (0.2 + 0.6 * hash(b, 5, seed))) + 1
		local p, q = main[i], main[math.min(#main, i + 1)]
		local ang = math.atan2(q[1] - p[1], q[2] - p[2]) + (hash(b, 6, seed) < 0.5 and 1 or -1) * math.pi / 2
		local pts = grow_road(ground, p[1], p[2], ang, 10 + math.floor(hash(b, 7, seed) * 10), seed, 10 + b, cx, cz)
		roads[#roads + 1] = {points = pts}
	end
	-- 地塊
	local cells = road_cells(roads)
	local taken = {}
	local lots = {}
	local function free(L)
		local x1, z1, x2, z2 = lot_rect(L)
		for x = math.floor(x1) - 3, math.ceil(x2) + 3 do for z = math.floor(z1) - 3, math.ceil(z2) + 3 do
			if cells[x .. "," .. z] or taken[x .. "," .. z] then return false end
		end end
		return true
	end
	local function relief(L)
		local x1, z1, x2, z2 = lot_rect(L)
		local lo, hi, hs = math.huge, -math.huge, {}
		for x = math.floor(x1), math.ceil(x2), 2 do for z = math.floor(z1), math.ceil(z2), 2 do
			local h = ground(x, z)
			lo, hi = math.min(lo, h), math.max(hi, h)
			hs[#hs + 1] = h
		end end
		table.sort(hs)
		return hi - lo, hs[math.floor(#hs / 2) + 1]
	end
	-- 候選位置：所有道路每個點、左右兩側
	local cand = {}
	for ri, r in ipairs(roads) do
		for i = 2, #r.points - 1 do
			local p, q = r.points[i], r.points[i + 1]
			local ang = math.atan2(q[1] - p[1], q[2] - p[2])
			for _, side in ipairs({1, -1}) do cand[#cand + 1] = {x = p[1], z = p[2], ang = ang, side = side, ri = ri, i = i} end
		end
	end
	-- 離中心近的先試（店家集中在村子中間）
	table.sort(cand, function(a, b)
		local da, db = (a.x - cx) ^ 2 + (a.z - cz) ^ 2, (b.x - cx) ^ 2 + (b.z - cz) ^ 2
		if da ~= db then return da < db end
		return a.ri * 1000 + a.i * 2 + a.side < b.ri * 1000 + b.i * 2 + b.side
	end)
	for _, spec in ipairs(V.LOTS) do
		local placed
		for pass = 1, 3 do
			local lim, off = MAX_RELIEF + (pass - 1) * 2, 2 + (pass - 1) * 3
			for _, c in ipairs(cand) do
				-- 面向道路：門朝向路，rot 照路的垂直方向取最近的 90°
				local nx, nz = c.side * math.cos(c.ang), -c.side * math.sin(c.ang)       -- 路的法線（往地塊那一側）
				local face = math.atan2(-nx, -nz)                                        -- 門朝路
				local rot = math.floor(((face / (math.pi / 2)) % 4) + 0.5) % 4
				local L = {kind = spec.kind, w = spec.w, d = spec.d, rot = rot}
				local dd = (rot % 2 == 1) and spec.w or spec.d
				local dist = 1.5 + off + dd / 2
				L.x, L.z = math.floor(c.x + nx * dist + 0.5), math.floor(c.z + nz * dist + 0.5)
				if free(L) then
					local r, med = relief(L)
					if r <= lim then
						L.y = math.floor(med + 0.5)
						L.rx, L.rz = c.x, c.z          -- 接到的路上那一點（門前路從這裡接）
						placed = L
						break
					end
				end
			end
			if placed then break end
		end
		if placed then
			lots[#lots + 1] = placed
			local x1, z1, x2, z2 = lot_rect(placed)
			for x = math.floor(x1), math.ceil(x2) do for z = math.floor(z1), math.ceil(z2) do taken[x .. "," .. z] = true end end
			-- 門前路：沿著建築正面、正東西或正南北的一段直路（中線在正面外 2 m，寬 3 m、長 = 建築寬），接到彎曲的路上
			local r = placed.rot
			local fx, fz = ({0, 1, 0, -1})[r + 1], ({1, 0, -1, 0})[r + 1]
			local wx, wz = fz, -fx
			local hd = ((r % 2 == 1) and placed.w or placed.d) / 2 + 2      -- 中心到門前路中線
			local hw = ((r % 2 == 1) and placed.d or placed.w) / 2          -- 正面的半寬
			local mx, mz = placed.x + fx * hd, placed.z + fz * hd
			local seg = {points = {{math.floor(mx - wx * hw + 0.5), math.floor(mz - wz * hw + 0.5)},
				{math.floor(mx + wx * hw + 0.5), math.floor(mz + wz * hw + 0.5)}}, front = true}
			roads[#roads + 1] = seg
			-- 離路比較遠（第 2、3 輪往外退）：門前路中點拉一段接到路上
			local link = {points = {{math.floor(mx + 0.5), math.floor(mz + 0.5)}, {placed.rx, placed.rz}}, front = true}
			roads[#roads + 1] = link
			for k in pairs(road_cells({seg, link})) do cells[k] = true end
			placed.rx, placed.rz = nil, nil
		end
	end
	return {roads = roads, lots = lots, cx = cx, cz = cz}
end

-- 鋪路、整地（VoxelManip：不算開挖，天然邊坡照舊）。plan：V.plan 的結果；done()：做完呼叫
--   路：3 m 寬，路面是壓實碎石，高度照當地地面（順著地形），路上 4 m 內的樹、草清掉
--   地塊（外推 1 m）：整平到 L.y，高的削掉（12 m 內）、低的用表土填，表面是表土
function V.build_ground(plan, done, progress)
	local x1, z1, x2, z2 = math.huge, math.huge, -math.huge, -math.huge
	local function grow(x, z) x1, z1, x2, z2 = math.min(x1, x), math.min(z1, z), math.max(x2, x), math.max(z2, z) end
	local cells = road_cells(plan.roads)
	for k in pairs(cells) do
		local x, z = k:match("^(%-?%d+),(%-?%d+)$")
		grow(tonumber(x) - 10, tonumber(z) - 10); grow(tonumber(x) + 10, tonumber(z) + 10)
	end
	for _, L in ipairs(plan.lots) do local a, b, c, d = lot_rect(L); grow(a - 10, b - 10); grow(c + 10, d + 10) end
	local sy = math.floor(rockmech.cfg.surface_y or 0)
	-- 高度範圍：地塊高度和地形起伏以內（不要整根 180 m 都生成，進遊戲比較快）
	local ylo, yhi = sy, sy
	for _, L in ipairs(plan.lots) do ylo, yhi = math.min(ylo, L.y), math.max(yhi, L.y) end
	local H = rockmech.cfg.terrain and rockmech.cfg.terrain.h or 30
	local pmin = {x = math.floor(x1), y = ylo - 16, z = math.floor(z1)}
	local pmax = {x = math.ceil(x2), y = math.max(yhi, sy + H) + 24, z = math.ceil(z2)}
	local total
	core.emerge_area(pmin, pmax, function(_, _, left)
		total = total or (left + 1)
		if progress then progress(1 - left / total) end
		if left > 0 then return end
		local vm = core.get_voxel_manip()
		local e1, e2 = vm:read_from_map(pmin, pmax)
		local area = VoxelArea:new({MinEdge = e1, MaxEdge = e2})
		local data = vm:get_data()
		local c_air = core.get_content_id("air")
		local c_soil = core.get_content_id("rockmech:topsoil")
		local road_name = rockmech.compact_of and rockmech.compact_of[rockmech.rubble_with_level(rockmech.RUBBLE, rockmech.RUBBLE_LEVELS)]
		local c_road = core.get_content_id(road_name or "rockmech:topsoil")
		-- 地面：從上往下第一個走得上去、不是樹（樹幹、樹葉、蘋果）的方塊
		local skip = {}
		for _, n in ipairs({"default:tree", "default:leaves", "default:apple", "rockmech:grass"}) do
			if core.registered_nodes[n] then skip[core.get_content_id(n)] = true end
		end
		local function solid(c)
			if c == c_air or skip[c] then return false end
			local d = core.registered_nodes[core.get_name_from_content_id(c)]
			return d and d.walkable ~= false
		end
		-- 村莊範圍（道路、地塊各外推 2 m）裡不滿 1 m 的薄表土先拿掉：路面、地塊都在整格的地面上，路不會比旁邊高出一截
		local thin = {}
		for k = 1, (rockmech.RUBBLE_LEVELS or 8) - 1 do
			local n = "rockmech:topsoil_" .. k
			if core.registered_nodes[n] then thin[core.get_content_id(n)] = true end
		end
		local function top_at(x, z)
			if not area:contains(x, pmin.y, z) then return nil end
			for y = pmax.y, pmin.y, -1 do
				local i = area:index(x, y, z)
				local c = data[i]
				if thin[c] or skip[c] then data[i] = c_air
				elseif solid(c) then return y end
			end
		end
		local margin = {}
		for k in pairs(cells) do
			local x, z = k:match("^(%-?%d+),(%-?%d+)$")
			x, z = tonumber(x), tonumber(z)
			for dx = -2, 2 do for dz = -2, 2 do margin[(x + dx) .. "," .. (z + dz)] = true end end
		end
		for _, L in ipairs(plan.lots) do
			local a, b, c, d = lot_rect(L)
			for x = math.floor(a) - 3, math.ceil(c) + 3 do for z = math.floor(b) - 3, math.ceil(d) + 3 do margin[x .. "," .. z] = true end end
		end
		for k in pairs(margin) do
			local x, z = k:match("^(%-?%d+),(%-?%d+)$")
			top_at(tonumber(x), tonumber(z))
		end
		-- 村莊範圍（道路、地塊外推 8 m）的地表：裸露的岩石表面一層換成表土（郊外照舊有露頭）
		local bonded = {}
		for name in pairs(core.registered_nodes) do
			if rockmech.lith_of_node and rockmech.lith_of_node[name] then bonded[core.get_content_id(name)] = true end
		end
		local wide = {}
		for k in pairs(cells) do
			local x, z = k:match("^(%-?%d+),(%-?%d+)$")
			x, z = tonumber(x), tonumber(z)
			for dx = -8, 8, 1 do for dz = -8, 8, 1 do wide[(x + dx) .. "," .. (z + dz)] = true end end
		end
		for _, L in ipairs(plan.lots) do
			local a, b, c, d = lot_rect(L)
			for x = math.floor(a) - 8, math.ceil(c) + 8 do for z = math.floor(b) - 8, math.ceil(d) + 8 do wide[x .. "," .. z] = true end end
		end
		for k in pairs(wide) do
			local x, z = k:match("^(%-?%d+),(%-?%d+)$")
			x, z = tonumber(x), tonumber(z)
			if area:contains(x, pmin.y, z) then
				local t = top_at(x, z)
				if t then
					local i = area:index(x, t, z)
					if bonded[data[i]] then data[i] = c_soil end
				end
			end
		end
		local function clear_above(x, y, z, h)
			for yy = y + 1, math.min(pmax.y, y + h) do data[area:index(x, yy, z)] = c_air end
		end
		-- 地塊
		local lotted = {}
		for _, L in ipairs(plan.lots) do
			local a, b, c, d = lot_rect(L)
			for x = math.floor(a) - 1, math.ceil(c) + 1 do for z = math.floor(b) - 1, math.ceil(d) + 1 do
				local t = top_at(x, z) or L.y
				for y = math.min(t, L.y) - 0, L.y do
					local i = area:index(x, y, z)
					if y > t or y == L.y then data[i] = c_soil end
				end
				clear_above(x, L.y, z, 12)
				lotted[x .. "," .. z] = true
			end end
		end
		-- 路
		for k in pairs(cells) do
			if not lotted[k] then
				local x, z = k:match("^(%-?%d+),(%-?%d+)$")
				x, z = tonumber(x), tonumber(z)
				local t = top_at(x, z)
				if t then
					data[area:index(x, t, z)] = c_road
					clear_above(x, t, z, 4)
				end
			end
		end
		vm:set_data(data)
		vm:write_to_map(true)
		if done then done() end
	end)
end

-- 存起來的村莊配置（mod storage "village_plan"）：建造時算一次，之後建築、NPC、保護、出生點都照它
local KEY = "village_plan"
local cache
function V.store(plan)
	cache = plan
	rockmech.collapse.storage:set_string(KEY, core.serialize({roads = plan.roads, lots = plan.lots, cx = plan.cx, cz = plan.cz}))
end
function V.get()
	if cache == nil then
		local s = rockmech.collapse.storage:get_string(KEY)
		cache = s ~= "" and core.deserialize(s) or false
	end
	return cache or nil
end
-- 第 n 個（預設第 1 個）kind 的地塊；沒有村莊回傳 nil
function rockmech.village_lot(kind, n)
	local P = V.get()
	if not P then return nil end
	local k = 0
	for _, L in ipairs(P.lots) do
		if L.kind == kind then
			k = k + 1
			if k == (n or 1) then return L end
		end
	end
end
-- (x, z) 在不在村莊的地塊或道路上（保護、爆炸不炸村莊建築用）
function V.in_village(x, z, margin)
	local P = V.get()
	if not P then return false end
	margin = margin or 0
	for _, L in ipairs(P.lots) do
		local a, b, c, d = lot_rect(L)
		if x >= a - margin and x <= c + margin and z >= b - margin and z <= d + margin then return true end
	end
	return false
end

rockmech.village = V
return V
