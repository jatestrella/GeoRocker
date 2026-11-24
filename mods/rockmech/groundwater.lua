-- rockmech/groundwater.lua
-- 地下水：世界設定 rockmech_water_table_depth（天然地表下幾 m；slurry.lua 的 rockmech.water_table_natural 算天然水位）。
-- 滲流（Dupuit 假設：每一欄土一個水位 H，水平流；暫態）：
--   相鄰兩欄的流量 q = k·b·ΔH（每 1 m 寬、相距 1 m；b = 兩欄飽和厚度的平均），k = 透水係數 rockmech_soil_permeability。
--   一欄的水位變化 Sy·dH/dt = 流進來的總量；給水度 Sy = 孔隙率 ×（1 − 背景含水）：水位降下去，飽和的土剩背景含水，
--     放出來的水流向坑（slurry.lua 的 rockmech_soil_porosity、rockmech_soil_saturation）。
--   含水層底：天然水位以下往下穿過土、坑，碰到岩石（或其他不透水的東西：混凝土、連續壁）為止，最多 BASE_MAX m。
--   坑（天然水位以下有挖開的格、或有液體的格）：水頭 = 坑裡的水面（乾的就是坑底），固定。灌滿、上面又被土蓋住的空洞不算坑。
--     地圖產生器生的崩積土、天然空洞（沒挖過、沒有液體）跟周圍的土一起飽和，不算坑。
--   坑一直把水位壓低，漏斗就隨時間往外擴（擴多快看 k、Sy、含水層厚度），沒有規定半徑；坑積水、水被抽走都自然平衡。
--     計算範圍：離坑 RANGE m 以內、水位跟天然差 EPS 以上的欄；再外面當天然水位（無限的含水層）。
--   冒水：坑邊那一欄收到的流量，每 STEP_DT 秒加進坑裡最低、還有空間的那一格（之後照 slurry.lua 守恆地流）。
--     坑裡的水比旁邊的土高就不流（不往回灌進含水層；水位以上的土照 slurry.lua 慢慢滲）。
--   rockmech.water_table_y 換成算出來的水位：漏斗裡水位以上的土不再飽和（slurry.lua 的 soil_room）。
--   岩石不透水、先不冒水（之後照節理）。關遊戲時記下每一欄的水位，下次接著算。
-- 抽水井：抽水機放在往下鑽的岩芯孔套管上。井那一欄的水頭壓到孔底（不低於含水層底）；周圍流進來的比抽水機抽得多，
--   水頭就停在剛好抽得完的高度（Σ k·b·(H_鄰 − h) = 抽水量）。抽出來的水倒在機器後面（排水溝就排掉）；出水擋住就停。
-- 排水溝：液體流到旁邊、上面就沒了（每步 DRAIN 級）。給深開挖的地圖把抽出來的水排掉。
-- 抽水機：放在坑邊，吸管朝前伸進坑裡（跟出液口一樣朝放的人那一側）；每秒從前面那一欄的液面抽 PUMP_RATE 級，
--   倒在機器後面那一格（守恆）；後面那一格是排水溝就直接排掉。

local S = rockmech.S
local setting = rockmech.get_setting or function(k) return core.settings:get(k) end
local NL = rockmech.RUBBLE_LEVELS
local WATER = rockmech.LIQUID_WATER

local K = tonumber(setting("rockmech_soil_permeability") or "") or 1e-3          -- 透水係數（m/s）
local SY = (rockmech.SOIL_POROSITY or 0.4) * (1 - (rockmech.SOIL_S0 or 0.33))     -- 給水度
local RANGE = tonumber(setting("rockmech_groundwater_range") or "") or 64        -- 計算範圍（離坑幾 m）
local EPS = 0.01                                                                  -- 跟天然水位差不到 1 cm 不算
local BASE_MAX = 40                                                               -- 含水層最厚（m）
local STEP_DT = 1                                                                 -- 每幾秒推進一次
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
local function aquifer(i) return i and (i.low or i.h0 - i.base > 0.01) end

local info = {}         -- 範圍內的欄 → scan 的結果（土欄的 low 是 nil）
local H = {}            -- 範圍內的土欄 → 現在的水位
local OPEN = {}         -- 範圍內的坑 → 水頭
local DIST = {}         -- 範圍內的欄 → 離坑幾 m（4 鄰的步數）
local ROCK = {}         -- 查過、不是含水層的欄（岩石、沒有地下水）
local BND = {}          -- 範圍外緣的欄 → 天然水位
local dirty = {}        -- 要重看的欄
local WELL = {}         -- 抽水井的欄 → {bot = 孔底高程, cap = 抽水量 m³/s, h = 井的水頭, out = 累積抽出的 m³, seen = 上次抽的時間}
local acc = {}          -- 坑 → 累積的級數
local D4 = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

-- 算出來的水位：範圍內照算的，其他照天然
rockmech.water_table_y = function(x, z)
	local k = ckey(x, z)
	local h = H[k] or OPEN[k] or (WELL[k] and WELL[k].h)
	if h then
		local i = info[k]
		if i and h > i.h0 then h = i.h0 end
		return math.floor(h - 0.5 + 1e-6)
	end
	return natural(x, z)
end

-- 把一欄加進範圍（已經 scan 過）
local function add(k, i, d)
	info[k] = i
	DIST[k] = math.min(DIST[k] or d, d)
	BND[k] = nil
	if i.low then OPEN[k] = math.min(i.hs, i.h0); H[k] = nil
	elseif not H[k] then H[k] = i.h0 end
end
local function drop(k) info[k], H[k], OPEN[k], DIST[k], acc[k] = nil, nil, nil, nil, nil end
-- 坑旁邊的土欄要在範圍裡（不然坑收不到水）
local function add_ring(k)
	local x, z = cxz(k)
	for _, dd in ipairs(D4) do
		local nk = ckey(x + dd[1], z + dd[2])
		if not info[nk] and not ROCK[nk] then
			local i = scan(x + dd[1], z + dd[2])
			if i == nil or (i and not aquifer(i)) then ROCK[nk] = true
			elseif i then add(nk, i, 1) end
		end
	end
end
-- 一欄重看完
local function update(k, i)
	if not i then
		if i == nil and info[k] then drop(k) end
		return
	end
	if i.low then
		if i.h0 - i.hs > EPS or info[k] then add(k, i, 0); add_ring(k) end
	elseif OPEN[k] then                           -- 坑填回去了
		local h = OPEN[k]
		OPEN[k] = nil; info[k] = i; H[k] = math.min(h, i.h0)
	elseif info[k] then info[k] = i end
end

-- 鄰欄的水頭和含水層底（範圍外：天然水位，底跟自己一樣）
local function nb_head(nk)
	local h = H[nk]
	if h then return h, info[nk].base, false end
	local w = WELL[nk]
	if w then return w.h, info[nk].base, true end
	h = OPEN[nk]
	if h then return h, info[nk].base, true end
	if ROCK[nk] then return nil end
	h = BND[nk]
	if not h then
		local x, z = cxz(nk)
		h = H0(x, z)
		if not h then ROCK[nk] = true; return nil end
		BND[nk] = h
	end
	return h, nil, false
end

-- 推進 dt 秒（顯式：先算每一欄的淨流量再一起改；坑收到的累積起來）
local inflow_now = {}   -- 坑 → 最近一步的流量（m³/s）
local function advance(dt)
	-- 穩定：dt ≤ Sy / (4·T)
	local tmax = K * 1
	for k, h in pairs(H) do local t = K * (h - info[k].base); if t > tmax then tmax = t end end
	local n = math.max(1, math.ceil(dt / (0.8 * SY / (4 * tmax))))
	local h_dt = dt / n
	local q_open = {}
	-- 井的水頭：壓到孔底；周圍流進來的比抽水量多就停在 Σ k·t·(H_鄰 − h) = 抽水量 的高度
	local now = core.get_us_time()
	for k, w in pairs(WELL) do
		if now - w.seen > 5e6 then                       -- 抽水機沒在抽了（拿走、區塊沒載入）
			WELL[k] = nil
			local i = info[k]
			if i then H[k] = math.min(w.h, i.h0) end
		else
			local x, z = cxz(k)
			local base = info[k].base
			local sk, skh = 0, 0
			for _, dd in ipairs(D4) do
				local hj, bj = nb_head(ckey(x + dd[1], z + dd[2]))
				if hj and not WELL[ckey(x + dd[1], z + dd[2])] then
					local t = K * ((hj - (bj or base)) + math.max(w.h - base, 0)) / 2
					if t > 0 then sk = sk + t; skh = skh + t * hj end
				end
			end
			local h = sk > 0 and (skh - w.cap) / sk or info[k].h0
			if h < w.bot then h = w.bot end
			if h > info[k].h0 then h = info[k].h0 end
			w.h = h
		end
	end
	for _ = 1, n do
		local dH = {}
		for k, hi in pairs(H) do
			local x, z = cxz(k)
			local bi = info[k].base
			local ti = math.max(hi - bi, 0)
			local net = 0
			for _, dd in ipairs(D4) do
				local nk = ckey(x + dd[1], z + dd[2])
				local hj, bj, open = nb_head(nk)
				if hj then
					local tj = bj and math.max(hj - bj, 0) or ti
					if open then
						if hj < hi then                                   -- 流進坑（坑比土高不往回流）
							local q = K * (ti + tj) / 2 * (hi - hj)
							net = net - q
							q_open[nk] = (q_open[nk] or 0) + q * h_dt
						end
					else
						net = net + K * (ti + tj) / 2 * (hj - hi)
					end
				end
			end
			dH[k] = net * h_dt / SY
		end
		for k, d in pairs(dH) do
			local i = info[k]
			local h = H[k] + d
			if h > i.h0 then h = i.h0 elseif h < i.base then h = i.base end
			H[k] = h
		end
	end
	inflow_now = {}
	for k, v in pairs(q_open) do
		local w = WELL[k]
		if w then w.out = w.out + v
		else acc[k] = (acc[k] or 0) + v * NL end          -- m³ → 級
		inflow_now[k] = v / dt
	end
end
rockmech.groundwater_inflow = function(x, z) return inflow_now[ckey(x, z)] or 0 end

-- 範圍往外長：水位降了 EPS 以上的欄，旁邊還不在範圍裡的（RANGE 以內）加進來；回到天然的拿掉
local function grow()
	local new = {}
	for k, h in pairs(H) do
		local i = info[k]
		if i.h0 - h > EPS and DIST[k] < RANGE then
			local x, z = cxz(k)
			for _, dd in ipairs(D4) do
				local nk = ckey(x + dd[1], z + dd[2])
				if not info[nk] and not ROCK[nk] and not new[nk] then new[nk] = DIST[k] + 1 end
			end
		end
	end
	local n = 0
	for nk, d in pairs(new) do
		local x, z = cxz(nk)
		local i = scan(x, z)
		if i == nil or (i and not aquifer(i)) then ROCK[nk] = true
		elseif i then add(nk, i, d) end
		n = n + 1
		if n >= 2000 then break end                       -- 一次最多長 2000 欄
	end
	-- 沒有坑在抽了、全部回到天然：清掉
	local active = next(WELL) ~= nil
	for k, h in pairs(OPEN) do if info[k].h0 - h > EPS then active = true; break end end
	if not active then
		local far = false
		for k, h in pairs(H) do if info[k].h0 - h > EPS then far = true; break end end
		if not far then
			for k in pairs(info) do drop(k) end
			BND, ROCK = {}, {}
		end
	end
end

local function deliver()
	for k, a in pairs(acc) do
		local add_n = math.floor(a)
		if add_n > 0 and OPEN[k] then
			local x, z = cxz(k)
			local i = info[k]
			local p = {x = x, y = i.low, z = z}
			for _ = 1, 64 do                          -- 坑裡最低、還有空間的那一格
				local r, w = cell(p)
				if not r then p = nil; break end
				if w < rockmech.liquid_cap(r) then break end
				p.y = p.y + 1
			end
			if p and core.get_node(p).name ~= "ignore" then
				local left = rockmech.slurry_add_at(p, add_n, WATER)
				a = a - (add_n - left)
				if left < add_n then rockmech.slurry_schedule(p); rockmech.slurry_wake(p) end
			end
			if a > 1 then a = 1 end
			acc[k] = a
			dirty[k] = true                            -- 水面變了：重看坑的水頭
		elseif not OPEN[k] then acc[k] = nil end
	end
end

-- 抽水井（抽水機每秒呼叫）：(x, z, 孔底高程, 抽水量 m³/s) → 這段時間抽出來的 m³、最近一步的流量（m³/s）；抽水量 nil = 停
function rockmech.groundwater_well(x, z, bot, cap)
	local k = ckey(x, z)
	local w = WELL[k]
	if not cap then
		if w then
			WELL[k] = nil
			local i = info[k]
			if i then H[k] = math.min(w.h, i.h0) end
		end
		return 0
	end
	if not w then
		local i = info[k] or scan(x, z)
		if not i or i.low or not aquifer(i) then return 0 end      -- 沒有地下水、是坑
		if math.max(bot, i.base) >= i.h0 then return 0 end         -- 孔底在水位以上（或含水層底以下的部分是岩石）
		add(k, i, 0)
		w = {bot = math.max(bot, i.base), h = H[k] or i.h0, out = 0}
		H[k] = nil
		WELL[k] = w
		add_ring(k)
	end
	w.cap, w.seen = cap, core.get_us_time()
	local o = w.out
	w.out = 0
	return o, inflow_now[k] or 0
end

-- 一格騰出空間、挖開（slurry.lua 呼叫）：在天然水位附近以下就重看那一欄
function rockmech.groundwater_poke(p)
	local wt = natural(p.x, p.z)
	if not wt or p.y > wt + 1 then return end
	dirty[ckey(p.x, p.z)] = true
end

local t_acc = 0
if rockmech.GROUNDWATER_DEPTH then
	core.register_globalstep(function(dt)
		t_acc = t_acc + dt
		if t_acc < STEP_DT then return end
		local step_dt = math.min(t_acc, 5)
		t_acc = 0
		for k in pairs(dirty) do
			local x, z = cxz(k)
			local i = scan(x, z)
			if i ~= false then dirty[k] = nil; update(k, i) end
		end
		if not next(info) then return end
		advance(step_dt)
		deliver()
		grow()
	end)
	-- 關遊戲時記下每一欄的水位，下次接著算
	local saved = core.deserialize(storage:get_string("gw_state")) or {}
	for k, v in pairs(saved.H or {}) do
		info[k] = {h0 = v[2], base = v[3]}; H[k] = v[1]; DIST[k] = v[4]
	end
	for k in pairs(saved.OPEN or {}) do dirty[k] = true end
	core.register_on_shutdown(function()
		local h, o = {}, {}
		for k, v in pairs(H) do h[k] = {v, info[k].h0, info[k].base, DIST[k]} end
		for k in pairs(OPEN) do o[k] = true end
		storage:set_string("gw_state", core.serialize({H = h, OPEN = o}))
	end)
end
rockmech.groundwater_state = function()
	local n = 0
	for _ in pairs(H) do n = n + 1 end
	return {dom = n, H = H, OPEN = OPEN, info = info, WELL = WELL}
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
local CASING = "rockmech:borehole"
-- 抽水機底下是往下鑽的岩芯孔套管：孔底那一格的 y
local function well_bottom(pos)
	local c = {x = pos.x, y = pos.y - 1, z = pos.z}
	if core.get_node(c).name ~= CASING then return nil end
	return tonumber(core.get_meta(c):get_string("bottom"))
end
local function well_tick(pos, bot, out)
	local meta = core.get_meta(pos)
	local m3, rate = rockmech.groundwater_well(pos.x, pos.z, bot - 0.5, PUMP_RATE / NL)
	local a = meta:get_float("well_acc") + m3 * NL
	local n = math.floor(a)
	if n > 0 then
		if rockmech.liquid_drains[core.get_node(out).name] then a = a - n          -- 後面接著排水溝：直接排掉
		else
			local left = rockmech.slurry_add_up(out, n, nil, WATER)
			rockmech.slurry_schedule(out); rockmech.slurry_wake(out)
			if left > 0 then                            -- 出水的地方擋住了：井停下來
				rockmech.groundwater_well(pos.x, pos.z, nil)
				meta:set_float("well_acc", 0)
				pump_info(pos, S("Outlet blocked"))
				return
			end
			a = a - n
		end
	end
	meta:set_float("well_acc", a)
	if (rate or 0) > 0 then pump_info(pos, S("Well") .. ": " .. S("Pumping @1 m³/h", math.floor(rate * 3600 + 0.5)))
	else pump_info(pos, S("No water in reach")) end
end
local function pump_tick(pos)
	local node = core.get_node(pos)
	local f, b = pump_dirs(node)
	local bot = well_bottom(pos)
	if bot then well_tick(pos, bot, vector.add(pos, b)); return end
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
	description = S("Water pump\nThe suction hose points back at you: stand at the pit edge and place it on the far side. Pumps water from the pit and pours it out behind the pump; lead it into a drain") .. "\n" ..
		S("On a borehole casing it pumps the well and lowers the groundwater around it"),
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
	on_destruct = function(pos) rockmech.groundwater_well(pos.x, pos.z, nil) end,
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
