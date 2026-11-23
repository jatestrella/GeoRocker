-- rockmech/slurry.lua
-- 穩定液（皂土泥漿）：連續壁溝槽的護壁液。比水重（γ ≈ 11 kN/m³），液壓頂住溝壁，溝槽挖深才不會塌（femstress.lua 當面壓）。
--
-- 自製的守恆流體（不用引擎的液體：引擎的液體一格源頭可以無限往下流）：
--   每格分 8 級（1/8 m），rockmech:slurry 是滿格，rockmech:slurry_l1 … _l7 是不滿格。總量守恆：灌多少就有多少。
--   每一步（rockmech_slurry_step 秒，慢慢流）：底下是空的 → 整格往下掉；底下不滿 → 先把底下補滿；
--   底下撐著 → 跟四周比液面，比最低的那一格高 2 級以上就分一半過去（差 1 級就算平了）。
--   流進洞裡、漏到坑裡，液面就降下來，要補液。
--   人、東西可以在裡面（不能站、會減速，像在水裡）；放方塊、碎石掉進去會把那一格的穩定液往上擠（排開）
-- 碎石的孔隙：碎石格也裝得了液（孔隙率 n，rockmech_rubble_porosity）。r 級碎石的孔隙裝 round(n·r) 級，上面空的 8 − r 級
--   照常裝；水位在碎石裡時液面 = r·w / 孔隙容量。量記在 mod storage 的位置表（param2 已經存成分比例，不加方塊）。
--   碎石被挖走、流走：液留在原地；碎石變多：多的往上擠。只畫液面那一層（半格碎石上面的自由液，一格一個拉伸的方塊實體），
--   孔隙裡的液看不到也不畫

local S = rockmech.S
local cfg = rockmech.cfg

local NL = 8
local BASE = "rockmech:slurry"
local GAMMA = 11                     -- kN/m³（皂土泥漿，比重約 1.05–1.1）
local STEP = tonumber(core.settings:get("rockmech_slurry_step") or "") or 0.25
rockmech.SLURRY = BASE
rockmech.SLURRY_GAMMA = GAMMA
rockmech.slurry_level = {}           -- 方塊名稱 → 級數（滿格 8）
-- 應力解裡也算液壓的其他流體（concrete.lua 的新拌混凝土）：方塊名稱 → {級數比例, γ kN/m³}
rockmech.fluid_extra = rockmech.fluid_extra or {}

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
		liquid_move_physics = true, move_resistance = 1,
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

-- 碎石孔隙裡的液 ---------------------------------------------------------
local PORE = tonumber(core.settings:get("rockmech_rubble_porosity") or "") or 0.35
rockmech.RUBBLE_POROSITY = PORE
local storage = core.get_mod_storage()
local wet = core.deserialize(storage:get_string("slurry_wet")) or {}   -- 位置 hash → 級數（1/8 m³）
local wet_dirty = false
local function pore_cap(r) return math.floor(PORE * r + 0.5) end
local function wcap(r) return pore_cap(r) + NL - r end                 -- r 級碎石的格最多裝幾級
local function surface(r, w)                                           -- 液面高度（1/8 m）
	if w <= 0 then return 0 end
	local pc = pore_cap(r)
	if w <= pc then return r * w / pc end
	return r + w - pc
end
-- 一格裝液的狀態：r（碎石級數，空氣、穩定液是 0）、w（液的級數）。實心的格回傳 nil
local function cell(p)
	local n = core.get_node(p).name
	if n == "air" then return 0, 0 end
	local k = rockmech.slurry_level[n]
	if k then return 0, k end
	local r = rockmech.rubble_level[n]
	if r then return r, wet[core.hash_node_position(p)] or 0 end
end
local function cap_of(r) return r == 0 and NL or wcap(r) end

-- 液面那一層的畫面：半格碎石上面的自由液，一格一個拉伸的方塊實體
local SHOW = "rockmech:slurry_free"
local SHOW_RANGE = 48
local shown = {}                       -- 位置 hash → 實體
local free_tex = "[fill:16x16:" .. COLOR .. "c8"
core.register_entity(SHOW, {
	initial_properties = {
		visual = "cube", textures = {free_tex, free_tex, free_tex, free_tex, free_tex, free_tex},
		use_texture_alpha = true, backface_culling = false,
		physical = false, pointable = false, static_save = false, collisionbox = {0, 0, 0, 0, 0, 0},
	},
	on_activate = function(self) self.object:set_armor_groups({immortal = 1}) end,
})
local function near_player(p)
	if rockmech.slurry_show_all then return true end     -- 測試用
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), p) < SHOW_RANGE then return true end
	end
end
local function show(p, r, w)
	local h = core.hash_node_position(p)
	local free = r < NL and w - pore_cap(r) or 0
	local o = shown[h]
	if o and not o:get_pos() then o = nil; shown[h] = nil end
	if free <= 0 or not near_player(p) then
		if o then o:remove(); shown[h] = nil end
		return
	end
	free = math.min(free, NL - r)
	local key = r * 16 + free
	if o and o:get_luaentity().key == key then return end
	local pos = {x = p.x, y = p.y - 0.5 + (r + free / 2) / NL, z = p.z}
	if not o then
		o = core.add_entity(pos, SHOW)
		if not o then return end
		shown[h] = o
	else
		o:set_pos(pos)
	end
	o:get_luaentity().key = key
	o:set_properties({visual_size = {x = 1, y = free / NL, z = 1}})
end
local function set_cell(p, r, w)
	if r == 0 then set_level(p, w); return end
	local h = core.hash_node_position(p)
	wet[h] = w > 0 and w or nil
	wet_dirty = true
	show(p, r, w)
end
-- 從 p 往上一格一格加 k 級（碎石格加進孔隙、上面的空隙），回傳加不進去的級數
local function push_up(p, k)
	local q = {x = p.x, y = p.y + 1, z = p.z}
	for _ = 1, 32 do
		if k <= 0 then return 0 end
		local r, w = cell(q)
		if not r then return k end
		local put = math.min(cap_of(r) - w, k)
		if put > 0 then set_cell(q, r, w + put); k = k - put; schedule(q) end
		q.y = q.y + 1
	end
	return k
end
-- 側向一級一級流：流完 a 的液面還不比 b 低才流。回傳流了幾級
local function seep_amount(ra, wa, rb, wb)
	local cb, t = cap_of(rb), 0
	while wa - t > 0 and wb + t < cb and surface(ra, wa - t - 1) >= surface(rb, wb + t + 1) do t = t + 1 end
	return t
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
	-- 擠進來的是碎石：先裝進它的孔隙、上面的空隙
	local r, w = cell(p)
	if r and r > 0 then
		local t = math.min(k, math.max(0, wcap(r) - w))
		if t > 0 then set_cell(p, r, w + t); k = k - t; schedule(p) end
		if k <= 0 then return end
	end
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
local equalize            -- 連通管（靜水平衡），下面定義
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
-- 碎石格裡的液：先往下滲，再往旁邊液面低的格流，碎石變多裝不下就往上擠
local function rubble_step(p, r, w)
	if w <= 0 then return end
	local cap = wcap(r)
	if w > cap then
		local left = push_up(p, w - cap)
		set_cell(p, r, cap + left)
		wake_around(p)
		return
	end
	local below = {x = p.x, y = p.y - 1, z = p.z}
	local rb, wb = cell(below)
	if rb and wb < cap_of(rb) then
		local t = math.min(cap_of(rb) - wb, w)
		set_cell(below, rb, wb + t)
		set_cell(p, r, w - t)
		schedule(below); wake_around(p)
		if w - t > 0 then schedule(p) end
		return
	end
	local best, bt
	local s = math.random(4)
	for j = 0, 3 do
		local d = DIRS[(s + j - 1) % 4 + 1]
		local q = {x = p.x + d[1], y = p.y, z = p.z + d[2]}
		local rq, wq = cell(q)
		if rq then
			local t = seep_amount(r, w, rq, wq)
			if t > 0 and (not bt or t > bt) then best, bt = {q, rq, wq}, t end
		end
	end
	if best then
		set_cell(best[1], best[2], best[3] + bt)
		set_cell(p, r, w - bt)
		schedule(best[1]); wake_around(p); schedule(p)
		return
	end
	show(p, r, w)
end

step = function(p)
	local k = level_at(p)
	if not k then
		local r, w = cell(p)
		if r and r > 0 then rubble_step(p, r, w) end
		return
	end
	if k <= 0 then return end
	local below = {x = p.x, y = p.y - 1, z = p.z}
	local kb = level_at(below)
	if not kb then
		-- 底下是碎石：先滲進它的孔隙、補滿它上面的空隙
		local rb, wb = cell(below)
		if rb and wb < wcap(rb) then
			local t = math.min(wcap(rb) - wb, k)
			set_cell(below, rb, wb + t)
			set_level(p, k - t)
			schedule(below)
			wake_around(p)
			if k - t > 0 then schedule(p) end
			return
		end
	end
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
	-- 旁邊是碎石：液面比它的高就滲過去
	for j = 0, 3 do
		local d = DIRS[(s + j - 1) % 4 + 1]
		local q = {x = p.x + d[1], y = p.y, z = p.z + d[2]}
		local rq, wq = cell(q)
		if rq and rq > 0 then
			local t = seep_amount(0, k, rq, wq)
			if t > 0 then
				set_cell(q, rq, wq + t)
				set_level(p, k - t)
				schedule(q); wake_around(p); schedule(p)
				return
			end
		end
	end
	-- 旁邊都只差 1 級（一格一格差 1/8 m 的階梯，長溝槽兩端差很多、遠端流不到）：連通管——
	-- 同一層連通的液面（含底下撐著的空格）裡最低的那一格比這格低 2 級以上，就搬差距的一半過去。流平，最後整片差不到 1 級
	if k >= 2 then
		local low, lk = level_low(p, k)
		if low then
			local t = math.floor((k - lk) / 2)       -- 搬差距的一半
			set_level(low, lk + t)
			set_level(p, k - t)
			schedule(low)
			wake_around(p)
			schedule(p)
			return
		end
	end
	-- 局部都平了：整片做一次靜水平衡（不同層之間的落差）
	if equalize then equalize(p) end
end
rockmech.slurry_step = step

-- 連通管（靜水平衡）：p 所在的整片連通穩定液，加上片內比最高液面低的空格（溝槽裡還沒流到的地方、新挖的槽段），
-- 總級數不變，從最低層往上填滿，最上面那層平均分（差不到 1 級）。兩段液面落在不同層時，局部的流動要靠邊緣
-- 那一格慢慢往下倒、量少了會卡住，液面一段高一段低，低的那段溝壁就沒撐住。
-- 整片超過 EQ_MAX 格（溢到地面上攤開）就不算，交給局部的流動。同一片（約 16 m 範圍）每 EQ_DT 秒最多算一次
local EQ_MAX, EQ_DT = 3000, 1.0
local eq_last = {}
local NB6 = {{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}, {0, -1, 0}, {0, 1, 0}}
equalize = function(p)
	local key = math.floor(p.x / 16) .. "," .. math.floor(p.y / 16) .. "," .. math.floor(p.z / 16)
	local now = core.get_us_time() / 1e6
	if eq_last[key] and now - eq_last[key] < EQ_DT then return end
	eq_last[key] = now
	-- 第一遍：連通的穩定液（有液的格）
	local seen, cells, total, ymax = {}, {}, 0, -math.huge
	local queue = {p}
	seen[core.hash_node_position(p)] = true
	local i = 1
	while queue[i] do
		local c = queue[i]; i = i + 1
		local k = level_at(c)
		cells[#cells + 1] = {p = c, k = k}
		total = total + k
		if c.y > ymax then ymax = c.y end
		if #cells > EQ_MAX then return end
		for _, d in ipairs(NB6) do
			local n = {x = c.x + d[1], y = c.y + d[2], z = c.z + d[3]}
			local h = core.hash_node_position(n)
			if not seen[h] then
				local kn = level_at(n)
				if kn and kn > 0 then seen[h] = true; queue[#queue + 1] = n end
			end
		end
	end
	-- 第二遍：片內比最高液面低（或同一層）的空格，從有液的格往外、往下找
	i = 1
	local q2 = {}
	for _, c in ipairs(cells) do q2[#q2 + 1] = c.p end
	while q2[i] do
		local c = q2[i]; i = i + 1
		for _, d in ipairs(NB6) do
			local n = {x = c.x + d[1], y = c.y + d[2], z = c.z + d[3]}
			local h = core.hash_node_position(n)
			if not seen[h] and n.y <= ymax then
				seen[h] = true
				if level_at(n) == 0 then
					cells[#cells + 1] = {p = n, k = 0}
					q2[#q2 + 1] = n
					if #cells > EQ_MAX then return end
				end
			end
		end
	end
	-- 由下往上填
	table.sort(cells, function(a, b) return a.p.y < b.p.y end)
	local want = {}
	local j = 1
	local left = total
	while j <= #cells do
		local y = cells[j].p.y
		local layer = {}
		while j <= #cells and cells[j].p.y == y do layer[#layer + 1] = cells[j]; j = j + 1 end
		local n = #layer
		if left >= NL * n then
			for _, c in ipairs(layer) do want[c] = NL end
			left = left - NL * n
		else
			-- 最上面那層：平均分，原本比較多的先多拿 1 級（少搬一點）
			table.sort(layer, function(a, b) return a.k > b.k end)
			local base, extra = math.floor(left / n), left % n
			for idx, c in ipairs(layer) do want[c] = base + (idx <= extra and 1 or 0) end
			left = 0
		end
	end
	for _, c in ipairs(cells) do
		local w = want[c] or 0
		if w ~= c.k then set_level(c.p, w); schedule(c.p) end
	end
end
rockmech.slurry_equalize = equalize
rockmech.slurry_add_up = add_up            -- (p, 級數, 最高到哪一格) → 加不進去的級數
rockmech.slurry_schedule = function(p) schedule(p) end
-- 把 p 換成別的方塊（特密管灌混凝土），不觸發排開：回傳原本那一格的穩定液級數，排去哪裡由呼叫的人決定
function rockmech.slurry_replace(p, node)
	local k = level_at(p) or 0
	internal = true
	core.set_node(p, node)
	internal = false
	if k > 0 then wake_around(p) end
	return k
end

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
		if (level_at(q) and level_at(q) > 0) or wet[core.hash_node_position(q)] then schedule(q) end
	end
end)

-- 孔隙液的帳：碎石被挖走、流走、換成別的（滿格、壓實、VoxelManip 大崩塌都不會通知），每 0.5 s 對一次。
-- 碎石沒了：液留在原地（空氣、穩定液的格）或往上擠；碎石變多裝不下：多的往上擠。順便更新液面那一層的畫面
local REC_DT, SAVE_DT = 0.5, 5
local rec_t, save_t = 0, 0
rockmech.slurry_wet_stats = {n = 0, us = 0, shown = 0}
local function reconcile()
	local t0 = core.get_us_time()
	local todo, n = {}, 0
	for h, w in pairs(wet) do
		n = n + 1
		local p = core.get_position_from_hash(h)
		local node = core.get_node_or_nil(p)
		if node then
			local r = rockmech.rubble_level[node.name]
			if not r or w > wcap(r) then todo[#todo + 1] = {p, h, w, r}
			else show(p, r, w) end
		end
	end
	for _, a in ipairs(todo) do
		local p, h, w, r = a[1], a[2], a[3], a[4]
		if r then
			local left = push_up(p, w - wcap(r))
			wet[h] = wcap(r) + left
			show(p, r, wet[h])
		else
			wet[h] = nil
			if shown[h] then shown[h]:remove(); shown[h] = nil end
			local k = level_at(p)
			if k then
				local put = math.min(NL - k, w)
				if put > 0 then set_level(p, k + put); w = w - put end
			end
			if w > 0 then
				local left = push_up(p, w)
				if left > 0 then core.log("warning", ("[rockmech] 孔隙液 %d 級沒地方放（%s）"):format(left, core.pos_to_string(p))) end
			end
			schedule(p)
		end
		wet_dirty = true
		wake_around(p)
	end
	local st = rockmech.slurry_wet_stats
	st.n, st.us = n, core.get_us_time() - t0
	st.shown = 0
	for _ in pairs(shown) do st.shown = st.shown + 1 end
end
local function save_wet()
	if not wet_dirty then return end
	wet_dirty = false
	storage:set_string("slurry_wet", core.serialize(wet))
end
core.register_globalstep(function(dt)
	rec_t, save_t = rec_t + dt, save_t + dt
	if rec_t >= REC_DT then rec_t = 0; reconcile() end
	if save_t >= SAVE_DT then save_t = 0; save_wet() end
end)
core.register_on_shutdown(save_wet)
core.after(1, function()
	for h in pairs(wet) do schedule(core.get_position_from_hash(h)) end
end)
rockmech.slurry_wet = wet
rockmech.slurry_cell = cell
-- 保險：玩家附近還沒平的穩定液（區塊重新載入、被別的機制改過）
core.register_abm({
	label = "rockmech: 穩定液流動",
	nodenames = {"group:rockmech_slurry"},
	neighbors = {"air", "group:rockmech_slurry"},
	interval = 2, chance = 1, catch_up = false,
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
