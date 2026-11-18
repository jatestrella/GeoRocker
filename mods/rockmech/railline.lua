-- rockmech/railline.lua
-- 鐵路線形（純函數，不碰 core；單元測試 tests/railline_spec.lua）。
-- 控制點由北到南（z 遞減），用 Catmull-Rom 連成平順的曲線；線形要大致南北向（沿 z 單調），
-- 每一排 z 只有一個中線位置 xc(z)。縱斷面：沿線地面的長窗平均，坡度不超過 grade，裝車點前後一段是平的。

local R = {}

-- "x,z;x,z;…" → {{x=,z=},…}
function R.parse(str)
	local pts = {}
	for a, b in tostring(str or ""):gmatch("(%-?[%d.]+)%s*,%s*(%-?[%d.]+)") do
		pts[#pts + 1] = {x = tonumber(a), z = tonumber(b)}
	end
	return #pts >= 2 and pts or nil
end

local function catmull(p0, p1, p2, p3, t)
	local t2, t3 = t * t, t * t * t
	local function f(a, b, c, d)
		return 0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
	end
	return f(p0.x, p1.x, p2.x, p3.x), f(p0.z, p1.z, p2.z, p3.z)
end

-- pts：控制點；ground(x, z)：地面高（相對 surface_y）；o：{grade, load_z, flat, win, hold}
function R.build(pts, ground, o)
	o = o or {}
	local grade = o.grade or 0.015
	-- 密集取樣
	local dx, dz = {}, {}
	for i = 1, #pts - 1 do
		local p0, p1, p2, p3 = pts[math.max(1, i - 1)], pts[i], pts[i + 1], pts[math.min(#pts, i + 2)]
		local n = 400
		for k = (i == 1 and 0 or 1), n do
			local x, z = catmull(p0, p1, p2, p3, k / n)
			dx[#dx + 1], dz[#dz + 1] = x, z
		end
	end
	-- 每 1 m 重新取樣（弧長 s 從北端 0 開始）
	local L = {x = {}, z = {}, yaw = {}}
	local acc, j = 0, 1
	L.x[1], L.z[1] = dx[1], dz[1]
	local want = 1
	for i = 2, #dx do
		local seg = math.sqrt((dx[i] - dx[i - 1]) ^ 2 + (dz[i] - dz[i - 1]) ^ 2)
		while seg > 0 and acc + seg >= want do
			local f = (want - acc) / seg
			j = j + 1
			L.x[j] = dx[i - 1] + f * (dx[i] - dx[i - 1])
			L.z[j] = dz[i - 1] + f * (dz[i] - dz[i - 1])
			want = want + 1
		end
		acc = acc + seg
	end
	-- 最後不足 1 m 的那段：補上終點（最後一格的間距比 1 m 短）
	if acc > want - 1 + 1e-6 then j = j + 1; L.x[j], L.z[j] = dx[#dx], dz[#dz] end
	L.n = j
	-- 方向（車頭朝 s 增加的方向）：Luanti 的 yaw，朝 +z 是 0，朝 +x 是 −π/2
	for i = 1, L.n do
		local a, b = math.max(1, i - 2), math.min(L.n, i + 2)
		local tx, tz = L.x[b] - L.x[a], L.z[b] - L.z[a]
		L.yaw[i] = (math.atan2 or math.atan)(-tx, tz)
	end
	-- 每一排 z：中線 xc、方向、離北端的弧長
	L.rows = {}
	for i = 1, L.n - 1 do
		local z1, z2 = L.z[i], L.z[i + 1]
		for z = math.ceil(math.min(z1, z2)), math.floor(math.max(z1, z2)) do
			if not L.rows[z] then
				local f = z2 ~= z1 and (z - z1) / (z2 - z1) or 0
				local tx, tz = L.x[i + 1] - L.x[i], z2 - z1
				local len = math.sqrt(tx * tx + tz * tz)
				L.rows[z] = {xc = L.x[i] + f * (L.x[i + 1] - L.x[i]), s = i - 1 + f,
					c = math.abs(tz) / len, th = (math.atan2 or math.atan)(tx, tz)}
			end
		end
	end
	-- 縱斷面
	local hold = o.hold or math.huge
	local G = {}
	for i = 1, L.n do
		local z = math.max(-hold, math.min(hold, L.z[i]))
		local zr = math.floor(z + 0.5)
		local row = L.rows[zr]
		G[i] = ground(row and row.xc or L.x[i], zr)
	end
	local half = math.floor((o.win or 120) / 2)
	local T = {}
	for i = 1, L.n do
		local s, n = 0, 0
		for k = math.max(1, i - half), math.min(L.n, i + half) do s = s + G[k]; n = n + 1 end
		T[i] = s / n
	end
	local il = L.rows[math.floor((o.load_z or 0) + 0.5)]
	il = il and math.floor(il.s + 1.5) or math.floor(L.n / 2)
	local fl = o.flat or 60
	local a, b = math.max(1, il - fl), math.min(L.n, il + fl)
	local yl = 0
	for k = math.max(1, il - 15), math.min(L.n, il + 15) do yl = yl + G[k] end
	yl = math.floor(yl / (math.min(L.n, il + 15) - math.max(1, il - 15) + 1) + 0.5)
	local Y = {}
	for i = a, b do Y[i] = yl end
	for i = a - 1, 1, -1 do Y[i] = math.max(Y[i + 1] - grade, math.min(Y[i + 1] + grade, T[i])) end
	for i = b + 1, L.n do Y[i] = math.max(Y[i - 1] - grade, math.min(Y[i - 1] + grade, T[i])) end
	L.y, L.s_load, L.y_load = Y, il - 1, yl
	for _, row in pairs(L.rows) do
		local i = math.floor(row.s) + 1
		local f = row.s - (i - 1)
		row.y = Y[i] + f * ((Y[i + 1] or Y[i]) - Y[i])
		row.yr = math.floor(row.y + 0.5)
	end
	return setmetatable(L, {__index = R})
end

-- 弧長 s 的位置（內插）：x, z, 縱斷面 y（相對 surface_y）, yaw
function R.at(L, s)
	s = math.max(0, math.min(L.n - 1, s))
	local i = math.floor(s) + 1
	local f = s - (i - 1)
	local k = math.min(L.n, i + 1)
	local y1, y2 = L.yaw[i], L.yaw[k]
	if y2 - y1 > math.pi then y2 = y2 - 2 * math.pi elseif y1 - y2 > math.pi then y2 = y2 + 2 * math.pi end
	return L.x[i] + f * (L.x[k] - L.x[i]), L.z[i] + f * (L.z[k] - L.z[i]), L.y[i] + f * (L.y[k] - L.y[i]), y1 + f * (y2 - y1)
end

-- (x, z) 到中線的水平垂直距離（往 +x 那側為正）與那一排的資料；不在線的 z 範圍回傳 nil
function R.lateral(L, x, z)
	local row = L.rows[z]
	if not row then return nil end
	return (x - row.xc) * row.c, row
end

-- 弧長 s 離北端最近的那一排 z
function R.s_of_z(L, z)
	local row = L.rows[math.floor(z + 0.5)]
	return row and row.s
end

---------------------------------------------------------------------------
-- 這張地圖的鐵路（cfg.railway）：主環境和 mapgen 執行緒各算一次（同一套設定，結果一樣）
---------------------------------------------------------------------------

R.N, R.L_LOCO, R.PITCH = 4, 9, 7.6        -- 車廂數、機車長、車廂間距（中心到中心）
R.FW = 3.5                                -- 道床半寬（道碴面）
R.CW = 4                                  -- 淨空半寬（路塹底）
R.H = 6                                   -- 淨空高
R.CUT_K = 0.5                             -- 路塹邊坡：每往上 1 m 往外 0.5 m（岩坡約 63°）
R.FILL_K = 1.5                            -- 路堤邊坡 1:1.5
R.TUNNEL = 24                             -- 中線上的地面比軌面高過這麼多就開隧道（低地丘陵最高約 20 m，都用路塹）
R.END = 35                                -- 兩端多長一定是隧道
R.LINING = 1                              -- 隧道襯砌厚
R.POST_D = 3                              -- 裝車點標示柱離中線（往 +x，小鎮那側）

function R.for_cfg(cfg, stress)
	if not cfg.railway then return nil end
	if cfg._rail_line then return cfg._rail_line end
	local pts = R.parse(cfg.railway.pts)
	if not pts then return nil end
	local L = R.build(pts, function(x, z) return stress.terrain_rise(cfg, x, z) end,
		{grade = 0.015, load_z = cfg.railway.load_z, flat = 70, win = 120,
			hold = cfg.map_edge and (cfg.map_edge.foot - 40) or math.huge})
	L.sy = math.floor(cfg.surface_y or 0)
	-- 停好時車頭的弧長：第 1 節在裝車點，後面幾節往北排
	L.s_stop = L.s_load + R.L_LOCO + R.PITCH / 2
	L.posts = {}
	for i = 1, R.N do
		local x, z = L:at(L.s_load - (i - 1) * R.PITCH)
		L.posts[math.floor(z + 0.5)] = i
	end
	cfg._rail_line = L
	return L
end
-- 停好時第 i 節中心的弧長
function R.wagon_s(L, head, i) return head - R.L_LOCO - (i - 1) * R.PITCH - R.PITCH / 2 end
function R.rail_y(L, z) local row = L.rows[z]; return row and (L.sy + row.yr) end
-- 鋼軌方塊：8 種橫向偏移（模型 rockmech_rail_o0..7）＋ degrotate 轉角
function R.rail_variant(row)
	local xr = math.floor(row.xc + 0.5)
	local off = (row.xc - xr) * row.c
	local k = math.max(0, math.min(7, math.floor((off + 0.5) * 8)))
	local th = math.deg(row.th)
	if th > 90 then th = th - 180 elseif th <= -90 then th = th + 180 end
	return xr, k, math.floor(-th / 1.5 + 0.5) % 240
end

-- 地圖產生時挖路塹、填路堤、開隧道、鋪道床和鋼軌、插裝車點標示柱（只動 minp..maxp）
-- ground(x, z)：地面高（相對 sy）；ids：{air, bed, lining, post, rail = {[0..7]}}；回傳有沒有改
function R.carve(L, ground, data, p2data, area, minp, maxp, ids)
	local changed = false
	local sy = L.sy
	for z = minp.z, maxp.z do
		local row = L.rows[z]
		if row then
			local yr = sy + row.yr
			local gc = sy + math.floor(ground(row.xc, z) + 0.5)
			-- 兩端 END m 一律是隧道（列車從隧道裡出現、消失）；地面不夠高的那段襯砌露出來，像明挖覆蓋的隧道口
			local tunnel = gc - yr > R.TUNNEL or row.s < R.END or row.s > L.n - 1 - R.END
			-- 這一排最寬會動到哪裡（地面沿橫向會起伏，多留一些）
			local reach = tunnel and (R.FW + R.LINING + 1)
				or (R.CW + R.CUT_K * math.max(0, gc - yr + 14) + R.FILL_K * math.max(0, yr - gc + 4) + 6)
			local xa = math.max(minp.x, math.floor(row.xc - reach / row.c))
			local xb = math.min(maxp.x, math.ceil(row.xc + reach / row.c))
			for x = xa, xb do
				local ad = math.abs((x - row.xc) * row.c)
				if tunnel then
					for y = math.max(minp.y, yr), math.min(maxp.y, yr + R.H) do
						local vi = area:index(x, y, z)
						local id
						if ad <= R.FW and y == yr then id = ids.bed
						elseif ad <= R.FW and y < yr + R.H then id = ids.air
						elseif ad <= R.FW + R.LINING then id = ids.lining end
						if id and data[vi] ~= id then data[vi] = id; changed = true end
					end
				else
					local g = sy + math.floor(ground(x, z) + 0.5)
					-- 路塹：軌面以上，邊坡往外開（地面以上的樹也清掉）
					local top = math.min(maxp.y, math.max(g, yr + R.H) + 12)
					for y = math.max(minp.y, yr + 1), top do
						local w = R.CW + R.CUT_K * math.max(0, y - yr - 1)
						if ad <= w then
							local vi = area:index(x, y, z)
							if data[vi] ~= ids.air then data[vi] = ids.air; changed = true end
						end
					end
					-- 道床；路堤：軌面以下、地面以上填起來
					for y = math.max(minp.y, g + 1, yr - 60), math.min(maxp.y, yr) do
						local w = (y == yr) and R.FW or (R.FW + R.FILL_K * (yr - y))
						if ad <= w then
							local vi = area:index(x, y, z)
							if data[vi] ~= ids.bed then data[vi] = ids.bed; changed = true end
						end
					end
					if yr >= minp.y and yr <= maxp.y and ad <= R.FW then
						local vi = area:index(x, yr, z)
						if data[vi] ~= ids.bed then data[vi] = ids.bed; changed = true end
					end
				end
			end
			-- 鋼軌
			local xr, k, p2 = R.rail_variant(row)
			if xr >= minp.x and xr <= maxp.x and yr + 1 >= minp.y and yr + 1 <= maxp.y then
				local vi = area:index(xr, yr + 1, z)
				data[vi] = ids.rail[k]; p2data[vi] = p2; changed = true
			end
			-- 裝車點標示柱
			if L.posts[z] then
				local xp = math.floor(row.xc + R.POST_D / row.c + 0.5)
				if xp >= minp.x and xp <= maxp.x and yr + 1 >= minp.y and yr + 1 <= maxp.y then
					data[area:index(xp, yr + 1, z)] = ids.post; changed = true
				end
			end
		end
	end
	return changed
end

return R
