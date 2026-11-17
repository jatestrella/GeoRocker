-- rockmech/slurry.lua
-- 穩定液（皂土泥漿）：連續壁溝槽的護壁液。比水重（γ ≈ 11 kN/m³），液壓頂住溝壁，溝槽挖深才不會塌（femstress.lua 當面壓）。
--
-- 自製的守恆流體（不用引擎的液體：引擎的液體一格源頭可以無限往下流）：
--   每格分 8 級（1/8 m），rockmech:slurry 是滿格，rockmech:slurry_l1 … _l7 是不滿格。總量守恆：灌多少就有多少。
--   每一步（rockmech_slurry_step 秒，慢慢流）：底下是空的 → 整格往下掉；底下不滿 → 先把底下補滿；
--   底下撐著 → 跟四周比液面，比最低的那一格高 2 級以上就分一半過去（差 1 級就算平了）。
--   流進洞裡、漏到坑裡，液面就降下來，要補液。
--   人、東西可以在裡面（不能站、會減速，像在水裡）；放方塊、碎石掉進去會把那一格的穩定液擠掉（不守恆，簡化）

local S = rockmech.S
local cfg = rockmech.cfg

local NL = 8
local BASE = "rockmech:slurry"
local GAMMA = 11                     -- kN/m³（皂土泥漿，比重約 1.05–1.1）
local STEP = tonumber(core.settings:get("rockmech_slurry_step") or "") or 0.5
rockmech.SLURRY = BASE
rockmech.SLURRY_GAMMA = GAMMA
rockmech.slurry_level = {}           -- 方塊名稱 → 級數（滿格 8）

local COLOR = "#8a7a5c"
local function name_of(k)
	if k <= 0 then return "air" end
	if k >= NL then return BASE end
	return BASE .. "_l" .. k
end
rockmech.slurry_with_level = name_of

-- 被擠掉（放方塊、碎石掉進來、之後灌混凝土）：那一格的穩定液往上推（排開），不會憑空消失
local internal = false               -- 流動自己改的不算
local displace
for k = 1, NL do
	local top = -0.5 + k / NL
	local name = name_of(k)
	core.register_node(name, {
		description = S("Bentonite slurry"),
		drawtype = "nodebox",
		node_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, top, 0.5}},
		tiles = {"[fill:16x16:" .. COLOR .. "c8"},
		use_texture_alpha = "blend",
		paramtype = "light",
		sunlight_propagates = true,
		walkable = false, pointable = false, diggable = false, buildable_to = true,
		liquid_move_physics = true, move_resistance = 4,
		post_effect_color = {a = 200, r = 0x6a, g = 0x5c, b = 0x44},
		drowning = 1,
		drop = "",
		is_ground_content = false,
		groups = {rockmech_slurry = k, not_in_creative_inventory = 1},
		on_destruct = function(pos)
			if internal then return end
			local p = vector.copy(pos)
			core.after(0, function() displace(p, k) end)
		end,
	})
	rockmech.slurry_level[name] = k
end

local function level_at(p)
	local n = core.get_node(p).name
	if n == "air" then return 0 end
	return rockmech.slurry_level[n]
end
local schedule
local function set_level(p, k)
	internal = true
	core.set_node(p, {name = name_of(k)})
	internal = false
end
-- 從 p 往上加 k 級：穿過滿格的穩定液，加在第一個不滿或空的格，滿了再往上（最多 32 格）。回傳加不進去的級數
local function add_up(p, k, ymax)
	local q = vector.copy(p)
	for _ = 1, 32 do
		if ymax and q.y > ymax then return k end
		if k <= 0 then return 0 end
		local kq = level_at(q)
		if not kq then return k end                  -- 擋住了
		local put = math.min(NL - kq, k)
		if put > 0 then set_level(q, kq + put); k = k - put end
		q.y = q.y + 1
	end
	return k
end
displace = function(p, k)
	local up = {x = p.x, y = p.y + 1, z = p.z}
	local left = add_up(up, k)
	if left < k then schedule(up) end
end

-- 排一次流動判定（同一格合併）
local pending = {}
local step
schedule = function(p)
	local key = core.hash_node_position(p)
	if pending[key] then return end
	pending[key] = true
	core.after(STEP, function()
		pending[key] = nil
		step(p)
	end)
end
local function wake_around(p)
	schedule({x = p.x, y = p.y + 1, z = p.z})
	schedule({x = p.x + 1, y = p.y, z = p.z}); schedule({x = p.x - 1, y = p.y, z = p.z})
	schedule({x = p.x, y = p.y, z = p.z + 1}); schedule({x = p.x, y = p.y, z = p.z - 1})
end
rockmech.slurry_wake = wake_around

local DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
local LAYER_MAX = 256        -- 連通管：同一層最多找幾格
-- p 這一層連通的格子（穩定液或空氣，底下是實心或滿格的穩定液）裡，級數最低、比 k 低 2 級以上的那一格
local function level_low(p, k)
	local seen, queue = {[core.hash_node_position(p)] = true}, {p}
	local best, bk
	local i = 1
	while queue[i] and #queue < LAYER_MAX do
		local c = queue[i]; i = i + 1
		for _, d in ipairs(DIRS) do
			local n = {x = c.x + d[1], y = c.y, z = c.z + d[2]}
			local h = core.hash_node_position(n)
			if not seen[h] then
				seen[h] = true
				local kn = level_at(n)
				local kb = kn and level_at({x = n.x, y = n.y - 1, z = n.z})
				-- 連通：這格有液（或是空的、但旁邊有液接過來），底下撐著
				if kn and (kb == nil or kb == NL) and (kn > 0 or (level_at(c) or 0) > 0) then
					queue[#queue + 1] = n
					if k - kn >= 2 and (not bk or kn < bk) then best, bk = n, kn end
				end
			end
		end
	end
	return best, bk
end
step = function(p)
	local k = level_at(p)
	if not k or k <= 0 then return end
	local below = {x = p.x, y = p.y - 1, z = p.z}
	local kb = level_at(below)
	if kb and kb < NL then
		-- 往下：先把底下補滿
		local put = math.min(NL - kb, k)
		set_level(below, kb + put)
		set_level(p, k - put)
		schedule(below)
		wake_around(p)
		if k - put > 0 then schedule(p) end
		return
	end
	-- 底下撐著：往四周液面最低的那一格分一半
	local best, bk
	local s = math.random(4)
	for j = 0, 3 do
		local d = DIRS[(s + j - 1) % 4 + 1]
		local q = {x = p.x + d[1], y = p.y, z = p.z + d[2]}
		local kq = level_at(q)
		if kq and (not bk or kq < bk) then best, bk = q, kq end
	end
	if best and k - bk >= 2 then
		local t = math.floor((k - bk) / 2)
		set_level(best, bk + t)
		set_level(p, k - t)
		schedule(best)
		wake_around(p)
		schedule(p)
		return
	end
	-- 旁邊都只差 1 級（一格一格差 1/8 m 的階梯，長溝槽兩端差很多、遠端流不到）：連通管——
	-- 同一層連通的液面（含底下撐著的空格）裡最低的那一格比這格低 2 級以上，就搬 1 級過去。慢慢流平，最後整片差不到 1 級
	if k >= 2 then
		local low, lk = level_low(p, k)
		if low then
			set_level(low, lk + 1)
			set_level(p, k - 1)
			schedule(low)
			wake_around(p)
			schedule(p)
		end
	end
end
rockmech.slurry_step = step
rockmech.slurry_add_up = add_up            -- (p, 級數, 最高到哪一格) → 加不進去的級數
rockmech.slurry_schedule = function(p) schedule(p) end

-- p 剛被挖空（抓斗咬走）：上面那一欄穩定液馬上往下補（由下往上一格一格掉一層），液面跟著降。
-- 不等慢慢流：泥漿裡挖出來的空洞不會撐著不動，不然應力解會把空洞當成臨空面
function rockmech.slurry_settle(p)
	if level_at(p) ~= 0 then return end
	local q = {x = p.x, y = p.y + 1, z = p.z}
	for _ = 1, 64 do
		local k = level_at(q)
		if not k or k <= 0 then break end
		local below = {x = q.x, y = q.y - 1, z = q.z}
		local kb = level_at(below)
		if not kb or kb >= NL then break end
		local put = math.min(NL - kb, k)
		set_level(below, kb + put)
		set_level(q, k - put)
		schedule(below)
		q.y = q.y + 1
	end
	wake_around({x = q.x, y = q.y - 1, z = q.z})
end

-- 旁邊、底下的方塊被挖掉：穩定液往那裡流
core.register_on_dignode(function(pos)
	for _, v in ipairs({{x = 0, y = 1, z = 0}, {x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0}, {x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1}}) do
		local q = vector.add(pos, v)
		if level_at(q) and level_at(q) > 0 then schedule(q) end
	end
end)
-- 保險：玩家附近還沒平的穩定液（區塊重新載入、被別的機制改過）
core.register_abm({
	label = "rockmech: 穩定液流動",
	nodenames = {"group:rockmech_slurry"},
	neighbors = {"air", "group:rockmech_slurry"},
	interval = 3, chance = 3, catch_up = false,
	action = function(pos) schedule(pos) end,
})

-- 從 p（空氣或穩定液的格）倒 k 級進去：沉到那一欄液體的底，從第一個不滿的格往上加（液面上升，不會疊成一根柱子），
-- 最多到溝槽的頂（cap：再低一點的上限）；這一欄放不下的分給同一層相連的格。
-- partial = false：整份放得下才倒（守恆：不倒一半丟一半）。回傳倒進去的級數
local function pour(p, k, cap, partial)
	p = vector.copy(p)
	if not level_at(p) then return 0 end
	while level_at({x = p.x, y = p.y - 1, z = p.z}) do p.y = p.y - 1 end
	-- 最多倒到溝槽的頂：這一欄往上，旁邊還有溝壁（實心）的最高那格；平地上就是一層（穩定液指不到，
	-- 準心會穿過液面指到溝底，所以不能用指到的高度）
	local function walled(q)
		for _, d in ipairs(DIRS) do
			if not level_at({x = q.x + d[1], y = q.y, z = q.z + d[2]}) then return true end
		end
	end
	local ymax, w = p.y, vector.copy(p)
	for _ = 1, 48 do
		if not level_at(w) or not walled(w) then break end
		ymax = w.y
		w.y = w.y + 1
	end
	if cap then ymax = math.min(ymax, cap) end
	if ymax < p.y then return 0 end
	local room, q = 0, vector.copy(p)
	while q.y <= ymax and level_at(q) do room = room + NL - level_at(q); q.y = q.y + 1 end
	-- 這一欄放不下（液面還沒流平）：分給溝槽裡連通、底下撐著的格子（同一層往旁邊、也往下找，低的先填；
	-- 不往上找，最高到 ymax）
	local spill = {}
	if room < k then
		local seen, queue = {[core.hash_node_position(p)] = true}, {vector.copy(p)}
		local cand = {}
		local i = 1
		while queue[i] and #queue < 256 do
			local c = queue[i]; i = i + 1
			for _, d in ipairs({{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}, {0, -1, 0}, {0, 1, 0}}) do
				local n = {x = c.x + d[1], y = c.y + d[2], z = c.z + d[3]}
				local h = core.hash_node_position(n)
				local kn = not seen[h] and n.y <= ymax and level_at(n)
				if kn and walled(n) and not (n.x == p.x and n.z == p.z) then
					seen[h] = true
					queue[#queue + 1] = n
					local kb = level_at({x = n.x, y = n.y - 1, z = n.z})
					if kn < NL and (kb == nil or kb == NL) then cand[#cand + 1] = {n = n, k = kn} end
				end
			end
		end
		table.sort(cand, function(u, v) if u.n.y ~= v.n.y then return u.n.y < v.n.y end return u.k < v.k end)
		for _, c in ipairs(cand) do
			if room >= k then break end
			spill[#spill + 1] = c.n
			room = room + NL - c.k
		end
	end
	if room <= 0 or (room < k and not partial) then return 0 end
	k = math.min(k, room)
	local left = add_up(p, k, ymax)
	for _, n in ipairs(spill) do
		if left <= 0 then break end
		local kn = level_at(n)
		local put = math.min(NL - kn, left)
		set_level(n, kn + put)
		left = left - put
		schedule(n)
	end
	wake_around(p)
	schedule(p)
	for y = p.y, p.y + 16 do
		local q = {x = p.x, y = y, z = p.z}
		if not level_at(q) or level_at(q) == 0 then break end
		schedule(q)
	end
	return k - left
end
rockmech.slurry_pour = pour

-- 穩定液（1 m³）：對著地面、溝槽按右鍵倒進去（加在對準的那一格；滿了往上疊），然後自己流
local ITEM = "rockmech:slurry_m3"
core.register_craftitem(ITEM, {
	description = S("Bentonite slurry\n1 m³ each. Right-click to pour; it flows slowly and holds up trench walls"),
	short_description = S("Bentonite slurry"),
	inventory_image = "[fill:16x16:#00000000^[fill:10x12:3,3:" .. COLOR .. "^[fill:10x2:3,3:#a8987a",
	stack_max = 99,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" then return itemstack end
		-- 指著有右鍵功能的方塊（穩定液儲槽：存進去）：交給它；按住 Shift 才倒
		local un = core.get_node(pointed.under)
		local udef = core.registered_nodes[un.name]
		if udef and udef.on_rightclick and not (placer and placer.get_player_control and placer:get_player_control().sneak) then
			return udef.on_rightclick(pointed.under, un, placer, itemstack, pointed) or itemstack
		end
		local name = placer and placer:get_player_name() or ""
		local p = level_at(pointed.under) and pointed.under or pointed.above
		if core.is_protected(p, name) or not level_at(p) then return itemstack end
		if pour(p, NL) == 0 then return itemstack end
		if not (core.is_creative_enabled and core.is_creative_enabled(name)) then itemstack:take_item() end
		return itemstack
	end,
})
rockmech.SLURRY_ITEM = ITEM
