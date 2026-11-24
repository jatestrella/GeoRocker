-- rockmech/groundwater.lua
-- 地下水：世界設定 rockmech_water_table_depth（天然地表下幾 m；slurry.lua 的 rockmech.water_table_natural 算天然水位）。
-- 滲流（Dupuit 假設：每一欄土一個水位 H，水平流）：
--   達西定律 q = k·b·i（每 1 m 寬；b = 飽和厚度 H − 含水層底，i = 相鄰兩欄的水頭差 ÷ 1 m），k = 透水係數 rockmech_soil_permeability。
--   含水層底：天然水位以下往下穿過土、坑，碰到岩石（或其他不透水的東西：混凝土、連續壁）為止，最多 BASE_MAX m。
--   坑（天然水位以下有挖開的格、或有液體的格）：水頭 = 坑裡的水面（乾的就是坑底）。灌滿、上面又被土蓋住的空洞不算坑。
--     地圖產生器生的崩積土、天然空洞（沒挖過、沒有液體）跟周圍的土一起飽和，不算坑。
--   影響半徑：起始坡降 I0（1/8：水頭差不到 1/8 m 流不動）→ 洩降 s 的坑最多影響到 R = s ÷ I0（最多 RMAX m）。
--     R 以外是沒受影響的含水層（天然水位，無限的水源）；R 以內解穩態（Gauss-Seidel，每個 globalstep 算 BUDGET 微秒）。
--   冒水：坑邊那一欄收到的流量 Σ k·b·(H_鄰 − H_坑)，每 IN_DT 秒加進坑裡最低、還有空間的那一格（之後照 slurry.lua 守恆地流）。
--     坑裡的水漲到離天然水位不到 1/8 m，洩降沒了，就不冒了；水被抽走、流走（slurry.lua 呼叫 rockmech.groundwater_poke）又冒。
--   rockmech.water_table_y 換成解出來的水位：漏斗裡水位以上的土不再飽和（slurry.lua 的 soil_room）。
--   岩石不透水、先不冒水（之後照節理）。
-- 排水溝：液體流到旁邊、上面就沒了（每步 DRAIN 級）。給深開挖的地圖把抽出來的水排掉。
-- 抽水機：放在坑邊，吸管朝前伸進坑裡（跟出液口一樣朝放的人那一側）；每秒從前面那一欄的液面抽 PUMP_RATE 級，
--   倒在機器後面那一格（守恆）；後面那一格是排水溝就直接排掉。

local S = rockmech.S
local setting = rockmech.get_setting or function(k) return core.settings:get(k) end
local NL = rockmech.RUBBLE_LEVELS
local WATER = rockmech.LIQUID_WATER

local K = tonumber(setting("rockmech_soil_permeability") or "") or 1e-3          -- 透水係數（m/s）
local I0 = tonumber(setting("rockmech_groundwater_i0") or "") or 1 / 8           -- 起始坡降
local RMAX = 64                                                                   -- 影響半徑上限（m）
local BASE_MAX = 40                                                               -- 含水層最厚（m）
local IN_DT = 1                                                                   -- 冒水交付間隔（秒）
local BUDGET = 4000                                                               -- 每個 globalstep 解滲流的時間（微秒）
local OMEGA = 1.6                                                                 -- 超鬆弛
local PUMP_RATE = tonumber(setting("rockmech_pump_rate") or "") or 1             -- 級／秒
local HOSE = 30                                                                   -- 吸管長（m）
local DRAIN = 8                                                                   -- 排水溝每步吃掉幾級

-- 滲流 -------------------------------------------------------------------
local storage = core.get_mod_storage()
local natural = rockmech.water_table_natural
local soil_frac = rockmech.soil_frac
local cell = rockmech.slurry_cell
local is_excavated = rockmech.collapse.is_excavated
local function ckey(x, z) return (x + 32768) * 65536 + (z + 32768) end
local function cxz(k) local a = math.floor(k / 65536); return a - 32768, k - a * 65536 - 32768 end
local function H0(x, z) local w = natural(x, z); return w and w + 0.5 end

-- 一欄：天然水位以下往下看。回傳 {h0, base, low, hs}（low/hs：坑的最低格、坑的水頭；沒有坑就 nil）；
-- nil = 沒有地下水；false = 還沒載入
local function scan(x, z)
	local h0 = H0(x, z)
	if not h0 then return nil end
	local top = math.floor(h0 - 0.5)
	local p = {x = x, y = top, z = z}
	local base = top - BASE_MAX - 0.5
	local stacks = {}                       -- 空格堆的最低格（由上往下）
	local prev_open = false
	for y = top, top - BASE_MAX, -1 do
		p.y = y
		local n = core.get_node(p).name
		if n == "ignore" then return false end
		local open = false
		if not soil_frac[n] then
			local r, w = cell(p)
			if not r then base = y + 0.5; break end
			open = w > 0 or is_excavated(p)          -- 天然的崩積土、空洞：跟周圍的土一起飽和，不算坑
		end
		if open then
			if prev_open then stacks[#stacks] = y else stacks[#stacks + 1] = y end
		end
		prev_open = open
	end
	local info = {h0 = h0, base = base}
	-- 由下往上：第一個有自由液面的空格堆（灌滿、上面又是土的不算）
	for i = #stacks, 1, -1 do
		local low = stacks[i]
		local h, free = low - 0.5, false
		local q = {x = x, y = low, z = z}
		for _ = 1, 64 do
			local r, w = cell(q)
			if not r then break end
			local cap = rockmech.liquid_cap(r)
			local f = cap > 0 and math.min(1, w / cap) or 1
			h = h + f
			if f < 1 then free = true; break end
			q.y = q.y + 1
		end
		if free then info.low, info.hs = low, h; break end
	end
	return info
end
local function is_sink(inf) return inf and inf.low and inf.h0 - inf.hs > I0 end
local function radius(inf) return math.min(RMAX, (inf.h0 - inf.hs) / I0) end

local info = {}         -- 範圍內的欄 → scan 的結果
local H = {}            -- 範圍內的土欄 → 現在的水位
local FH = {}           -- 固定水頭的欄（坑、範圍外緣）→ 水頭
local B = {}            -- 欄 → 含水層底
local OPEN = {}         -- 坑的欄 → true
local NB = {}           -- 欄 → 會流的鄰欄（4 鄰，不含岩石）
local dom = {}          -- 範圍內的土欄（解的順序）
local sinks = {}        -- 洩降中的坑的欄 → 影響半徑（記到 mod storage）
local dirty = {}        -- 要重看的欄
local acc = {}          -- 坑的欄 → 累積的小數級
local converged, cursor, maxd = true, 1, 0
local need_build, building = false, nil
local function idle() return not next(sinks) end

-- 抽水後的水位：範圍內照解，其他照天然
rockmech.water_table_y = function(x, z)
	local k = ckey(x, z)
	local h = H[k] or (OPEN[k] and FH[k])
	if h then
		local i = info[k]
		if i and h > i.h0 then h = i.h0 end
		return math.floor(h - 0.5 + 1e-6)
	end
	return natural(x, z)
end

-- 重建範圍：每個洩降中的坑往外擴到影響半徑（8 鄰，斜的 √2），碰到岩石、沒載入的就停
local D8 = {{1, 0, 1}, {-1, 0, 1}, {0, 1, 1}, {0, -1, 1}, {1, 1, 1.414}, {1, -1, 1.414}, {-1, 1, 1.414}, {-1, -1, 1.414}}
local D4 = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
local function build()
	local ni, best, queue = {}, {}, {}
	local n_scan = 0
	local function get(k)
		local i = ni[k]
		if i == nil then
			if info[k] and not dirty[k] then i = info[k]
			else
				local x, z = cxz(k)
				i = scan(x, z) or false
				n_scan = n_scan + 1
				if n_scan % 200 == 0 then coroutine.yield() end
			end
			ni[k] = i
		end
		return i
	end
	for k, r in pairs(sinks) do
		if is_sink(get(k)) then best[k] = r; queue[#queue + 1] = k end
	end
	local qi = 1
	while queue[qi] do
		local k = queue[qi]; qi = qi + 1
		local x, z = cxz(k)
		for _, d in ipairs(D8) do
			local rem = best[k] - d[3]
			if rem >= 0 then
				local nk = ckey(x + d[1], z + d[2])
				if rem > (best[nk] or -1) then
					local i = get(nk)
					if i and (i.low or i.h0 - i.base > 0.01) then best[nk] = rem; queue[#queue + 1] = nk end
				end
			end
		end
	end
	-- 換成新的範圍
	local nH, nFH, nB, nOPEN, nNB, ndom = {}, {}, {}, {}, {}, {}
	for k in pairs(best) do
		local i = ni[k]
		nB[k] = i.base
		if i.low then nOPEN[k] = true; nFH[k] = math.min(i.hs, i.h0)
		else nH[k] = H[k] or i.h0; ndom[#ndom + 1] = k end
	end
	for k in pairs(best) do
		local x, z = cxz(k)
		local nb = {}
		for _, d in ipairs(D4) do
			local nk = ckey(x + d[1], z + d[2])
			if best[nk] then
				if not (nOPEN[k] and nOPEN[nk]) then nb[#nb + 1] = nk end
			else
				local i = ni[nk]
				if i == nil then i = get(nk) end
				if i and not i.low and i.h0 - i.base > 0.01 then      -- 範圍外緣：天然水位
					nFH[nk] = i.h0; nB[nk] = i.base; nb[#nb + 1] = nk
				end
			end
		end
		nNB[k] = nb
	end
	for k in pairs(ni) do if best[k] then dirty[k] = nil end end
	local keep = {}
	for k in pairs(best) do keep[k] = ni[k] end
	info, H, FH, B, OPEN, NB, dom = keep, nH, nFH, nB, nOPEN, nNB, ndom
	converged, cursor, maxd = false, 1, 0
end

-- 一欄重看完：洩降有沒有變（要不要重建範圍）、坑的水頭
local function update(k, i)
	local was = sinks[k]
	if is_sink(i) then
		local r = radius(i)
		if not was or math.abs(r - was) >= 1 then sinks[k] = r; need_build = true end
	elseif was then sinks[k] = nil; need_build = true end
	if info[k] ~= nil then
		local open_now = i and i.low and true or false
		if open_now ~= (OPEN[k] or false) then need_build = true
		elseif open_now then
			info[k] = i
			local h = math.min(i.hs, i.h0)
			if math.abs(h - FH[k]) > 1e-3 then FH[k] = h; converged = false end
		end
	end
end

-- 坑收到的流量（m³/s）
local function inflow(k)
	local hs, bs = FH[k], B[k]
	local q = 0
	for _, nk in ipairs(NB[k]) do
		local hj = H[nk] or FH[nk]
		if hj and hj > hs then
			local t = ((hj - B[nk]) + math.max(hs - bs, 0)) / 2
			if t > 0 then q = q + K * t * (hj - hs) end
		end
	end
	return q
end
rockmech.groundwater_inflow = function(x, z) local k = ckey(x, z); return OPEN[k] and inflow(k) or 0 end

local function deliver()
	for k in pairs(OPEN) do
		local q = inflow(k)
		if q > 0 then
			local a = (acc[k] or 0) + q * IN_DT * NL
			local add = math.floor(a)
			if add > 0 then
				local x, z = cxz(k)
				local i = info[k]
				local p = {x = x, y = i.low, z = z}
				for _ = 1, 64 do                          -- 坑裡最低、還有空間的那一格
					local r, w = cell(p)
					if not r then p = nil; break end
					if w < rockmech.liquid_cap(r) then break end
					p.y = p.y + 1
				end
				if p then
					local left = rockmech.slurry_add_at(p, add, WATER)
					a = a - (add - left)
					if left < add then rockmech.slurry_schedule(p); rockmech.slurry_wake(p) end
				end
				if a > 1 then a = 1 end
				local ni = scan(x, z)
				if ni ~= false then update(k, ni) end
			end
			acc[k] = a
		end
	end
end

-- 一格騰出空間、挖開（slurry.lua 呼叫）：在天然水位附近以下就重看那一欄
function rockmech.groundwater_poke(p)
	local wt = natural(p.x, p.z)
	if not wt or p.y > wt + 1 then return end
	dirty[ckey(p.x, p.z)] = true
end

-- Gauss-Seidel（超鬆弛）一段
local function relax(t_end)
	local n = #dom
	while cursor <= n do
		local k = dom[cursor]
		local hi, bi = H[k], B[k]
		local ti = math.max(hi - bi, 0.05)
		local num, den = 0, 0
		for _, nk in ipairs(NB[k]) do
			local hj = H[nk] or FH[nk]
			local t = (ti + math.max(hj - B[nk], 0.05)) / 2
			num = num + t * hj; den = den + t
		end
		if den > 0 then
			local nh = hi + OMEGA * (num / den - hi)
			local h0 = info[k].h0
			if nh > h0 then nh = h0 elseif nh < bi then nh = bi end
			local d = math.abs(nh - hi)
			if d > maxd then maxd = d end
			H[k] = nh
		end
		cursor = cursor + 1
		if cursor % 64 == 0 and core.get_us_time() > t_end then return end
	end
	if maxd < 1e-3 then converged = true end
	cursor, maxd = 1, 0
end

local t_dirty, t_in, t_build = 0, 0, 0
if rockmech.GROUNDWATER_DEPTH then
	core.register_globalstep(function(dt)
		local t_end = core.get_us_time() + BUDGET
		t_dirty, t_in, t_build = t_dirty + dt, t_in + dt, t_build + dt
		if t_dirty >= 1 then
			t_dirty = 0
			for k in pairs(dirty) do
				local x, z = cxz(k)
				local i = scan(x, z)
				if i ~= false then dirty[k] = nil; update(k, i) end
			end
		end
		if building then
			while core.get_us_time() < t_end do
				local ok, err = coroutine.resume(building)
				if not ok then core.log("error", "[rockmech] groundwater build: " .. tostring(err)); building = nil; break end
				if coroutine.status(building) == "dead" then building = nil; break end
			end
			return
		end
		if need_build and t_build >= 2 then
			need_build, t_build = false, 0
			if idle() then
				info, H, FH, B, OPEN, NB, dom, acc = {}, {}, {}, {}, {}, {}, {}, {}
				converged = true
			else
				building = coroutine.create(build)
			end
			return
		end
		if not converged then
			while not converged and core.get_us_time() < t_end do relax(t_end) end
		end
		if t_in >= IN_DT then t_in = 0; deliver() end
	end)
	-- 洩降中的坑：關遊戲時記下來，下次開重看
	local saved = core.deserialize(storage:get_string("gw_sinks")) or {}
	for k in pairs(saved) do dirty[k] = true end
	core.register_on_shutdown(function() storage:set_string("gw_sinks", core.serialize(sinks)) end)
end
rockmech.groundwater_state = function()
	return {sinks = sinks, dom = #dom, converged = converged, building = building ~= nil, H = H, FH = FH, OPEN = OPEN, info = info}
end

-- 排水溝 -------------------------------------------------------------------
local DRAIN_NODE = "rockmech:drain"
core.register_node(DRAIN_NODE, {
	description = S("Drain\nWater that flows into it or onto it is carried away"),
	short_description = S("Drain"),
	drawtype = "nodebox",
	node_box = {type = "fixed", fixed = {
		{-0.5, -0.5, -0.5, 0.5, -0.375, 0.5},          -- 底
		{-0.5, -0.375, -0.5, -0.375, -0.0625, 0.5},    -- 兩側
		{0.375, -0.375, -0.5, 0.5, -0.0625, 0.5},
	}},
	selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.0625, 0.5}},
	tiles = {"[fill:16x16:#9a9a94^[fill:12x16:2,0:#5a6470", "[fill:16x16:#8a8a84", "[fill:16x16:#a2a29c"},
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = {cracky = 2},
	on_construct = function(pos)
		rockmech.slurry_wake(pos)
		rockmech.slurry_schedule({x = pos.x, y = pos.y + 1, z = pos.z})
	end,
})
rockmech.liquid_drains[DRAIN_NODE] = DRAIN
rockmech.DRAIN = DRAIN_NODE

-- 抽水機 -------------------------------------------------------------------
local PUMP = "rockmech:water_pump"
local function pump_dirs(node)
	local f = core.facedir_to_dir(node.param2)       -- 吸管伸出去的方向
	return f, {x = -f.x, y = 0, z = -f.z}
end
local function pump_info(pos, txt)
	core.get_meta(pos):set_string("infotext", S("Water pump") .. "\n" .. txt)
end
local function may(pos, name)
	local owner = core.get_meta(pos):get_string("owner")
	return rockmech.owner_ok and rockmech.owner_ok(owner, name) or owner == "" or owner == name
end
local level_of = rockmech.slurry_level
local function pump_tick(pos)
	local node = core.get_node(pos)
	local f, b = pump_dirs(node)
	local col = vector.add(pos, f)
	-- 吸管：往下穿過空氣、液體，找第一格有液的（最多 HOSE m）
	local q, intake = vector.copy(col), nil
	for _ = 0, HOSE do
		local n = core.get_node(q).name
		local k = n == "air" and 0 or level_of[n]
		if not k then break end
		if k > 0 then intake = q; break end
		q.y = q.y - 1
	end
	if not intake then pump_info(pos, S("No water in reach")); return end
	local c = rockmech.liquid_comp(intake)
	local took = rockmech.slurry_take(intake, PUMP_RATE)
	if took <= 0 then pump_info(pos, S("No water in reach")); return end
	local out = vector.add(pos, b)
	if rockmech.liquid_drains[core.get_node(out).name] then       -- 後面接著排水溝：直接排掉
		pump_info(pos, S("Pumping @1 m³/h", math.floor(took / NL * 3600 + 0.5)))
		return
	end
	local left = rockmech.slurry_add_up(out, took, nil, c)
	if left > 0 then                                -- 出水的地方擋住了：放回去
		rockmech.slurry_add_up(intake, left, nil, c)
		pump_info(pos, S("Outlet blocked"))
	else
		pump_info(pos, S("Pumping @1 m³/h", math.floor(took / NL * 3600 + 0.5)))
	end
	rockmech.slurry_schedule(out); rockmech.slurry_wake(out)
end
core.register_node(PUMP, {
	description = S("Water pump\nThe suction hose points back at you: stand at the pit edge and place it on the far side. Pumps water from the pit and pours it out behind the pump; lead it into a drain"),
	short_description = S("Water pump"),
	drawtype = "nodebox",
	node_box = {type = "fixed", fixed = {
		{-0.35, -0.5, -0.3, 0.35, 0.1, 0.3},           -- 機身
		{-0.06, -0.1, 0.3, 0.06, 0.02, 1.06},          -- 吸管（往前）
		{-0.06, -0.5, 0.94, 0.06, 0.02, 1.06},         -- 往下垂
		{-0.08, -0.45, -0.5, 0.08, -0.29, -0.3},       -- 出水口（往後）
	}},
	selection_box = {type = "fixed", fixed = {-0.35, -0.5, -0.3, 0.35, 0.1, 0.3}},
	collision_box = {type = "fixed", fixed = {-0.35, -0.5, -0.3, 0.35, 0.1, 0.3}},
	tiles = {"[fill:16x16:#3f73a8^[fill:10x10:3,3:#2a4e78", "[fill:16x16:#3a3f44", "[fill:16x16:#4a80b8^[fill:16x2:0,7:#2a4e78"},
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = {cracky = 2},
	on_construct = function(pos) core.get_node_timer(pos):start(1) end,
	after_place_node = function(pos, placer)
		if placer and placer.get_look_dir then
			local d = placer:get_look_dir()
			core.swap_node(pos, {name = PUMP, param2 = core.dir_to_facedir({x = -d.x, y = 0, z = -d.z})})
		end
		core.get_meta(pos):set_string("owner", placer and rockmech.account_of and rockmech.account_of(placer:get_player_name())
			or (placer and placer:get_player_name()) or "")
		pump_info(pos, S("No water in reach"))
	end,
	on_timer = function(pos) pump_tick(pos); return true end,
	can_dig = function(pos, player) return player and may(pos, player:get_player_name()) end,
})
core.register_lbm({
	label = "rockmech: 抽水機計時器", name = "rockmech:water_pump_timer", nodenames = {PUMP}, run_at_every_load = true,
	action = function(pos)
		local t = core.get_node_timer(pos)
		if not t:is_started() then t:start(1) end
	end,
})
rockmech.WATER_PUMP = PUMP
