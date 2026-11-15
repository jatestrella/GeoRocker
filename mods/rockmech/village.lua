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

-- ground(x, z)：地面高度（公式地形）
local function grow_road(ground, x, z, ang, steps, seed, id)
	local pts = {{x, z}}
	for i = 1, steps do
		ang = ang + (hash(i, id, seed) - 0.5) * 0.35          -- 緩慢彎曲
		local best, bscore
		for _, da in ipairs({0, 0.35, -0.35, 0.7, -0.7}) do
			local a = ang + da
			local nx, nz = x + STEP * math.sin(a), z + STEP * math.cos(a)
			local grade = math.abs(ground(nx, nz) - ground(x, z)) / STEP
			local score = grade + 0.15 * math.abs(da)
			if not bscore or score < bscore then best, bscore = a, score end
		end
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
	local p1 = grow_road(ground, cx, cz, a0, 30, seed, 1)
	local p2 = grow_road(ground, cx, cz, a0 + math.pi, 30, seed, 2)
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
		local pts = grow_road(ground, p[1], p[2], ang, 10 + math.floor(hash(b, 7, seed) * 10), seed, 10 + b)
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
		end
	end
	return {roads = roads, lots = lots, cx = cx, cz = cz}
end

return V
