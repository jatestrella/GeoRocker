-- rockmech/airq.lua
-- 空氣品質：計算在 airflow.lua（純函式），這裡接引擎：
--   地形：每個 8³ 格子用 VoxelManip 讀一次，記哪些格是空氣（不可走、非液體的方塊也算空氣），
--         看得到天空的比例（格子頂層的自然光）；挖、放方塊時重讀那格，其他改地圖（爆破）RESCAN 秒內重讀
--   來源：柴油引擎（fuel.lua 每步燒掉的柴油）、炸藥（drilling.lua 引爆時的炸藥量）
--   通風：抽風機（rockmech:vent_fan）＋風管（rockmech:vent_duct）。從風機沿著接起來的風管走到最遠那節（風管口），
--         隧道裡的空氣沿著這條路線往風管口流，從風管口吸走、排到外面
--   人：  氣體偵測器（背包裡有就顯示 CO 濃度）；濃了起霧；ppm ≥ HURT 開始扣血，越濃扣越快

local A = rockmech.airflow
local S = rockmech.S
local CELL = A.CELL
local STEP = 1            -- 模擬間隔（s）
local RESCAN = 15         -- 地形快取（s）
local HURT = 200          -- 開始頭痛、扣血的濃度（ppm）
local HP_PER_PPM_S = 1 / 6000   -- 扣血速度：每 ppm 每秒（1200 ppm → 5 秒 1 滴；6000 ppm → 每秒 1 滴）
local FOG0, FOG1 = 50, 3000     -- 開始起霧、霧最濃的濃度
local FAN_Q = tonumber(core.settings:get("rockmech_vent_fan_q")) or 10   -- 抽風機風量（m³/s）
local MAX_DUCT = 600
local FAN, DUCT, DETECTOR = "rockmech:vent_fan", "rockmech:vent_duct", "rockmech:gas_detector"
local EMULSION_KG, ANFO_KG_PER_M = 1, 7 / 1.5

local state = A.new()
rockmech.airq_state = state

-- 地形 ---------------------------------------------------------------------
local pass_cid = {}
local function passable(cid)
	local p = pass_cid[cid]
	if p == nil then
		local name = core.get_name_from_content_id(cid)
		local def = core.registered_nodes[name]
		p = name == "air" or (name ~= "ignore" and def ~= nil and def.walkable == false
			and (def.liquidtype or "none") == "none") or false
		pass_cid[cid] = p
	end
	return p
end

local scan = {}
local function now() return core.get_us_time() / 1e6 end
local function idx(lx, ly, lz) return lx + ly * CELL + lz * CELL * CELL + 1 end

local function get_scan(x, y, z)
	local k = A.key(x, y, z)
	local s = scan[k]
	local t = now()
	if s and t - s.t < RESCAN then s.used = t; return s end
	local minp = {x = x * CELL, y = y * CELL, z = z * CELL}
	local maxp = {x = minp.x + CELL - 1, y = minp.y + CELL - 1, z = minp.z + CELL - 1}
	local vm = VoxelManip()
	local e1, e2 = vm:read_from_map(minp, maxp)
	local data = vm:get_data()
	local area = VoxelArea:new({MinEdge = e1, MaxEdge = e2})
	local open, v = {}, 0
	for lz = 0, CELL - 1 do for ly = 0, CELL - 1 do for lx = 0, CELL - 1 do
		if passable(data[area:index(minp.x + lx, minp.y + ly, minp.z + lz)]) then
			v = v + 1
			open[idx(lx, ly, lz)] = true
		end
	end end end
	-- 看得到天空：頂層的空氣有幾格曬得到太陽（中午的自然光 15）
	local sky = 0
	if v > 0 then
		local n = 0
		for lz = 0, CELL - 1 do for lx = 0, CELL - 1 do
			if open[idx(lx, CELL - 1, lz)] then
				local l = core.get_natural_light({x = minp.x + lx, y = maxp.y, z = minp.z + lz}, 0.5)
				if l and l >= 15 then n = n + 1 end
			end
		end end
		sky = n / (CELL * CELL)
	end
	s = {t = t, used = t, open = open, v = v, sky = sky}
	scan[k] = s
	return s
end

local function face(x, y, z, d)
	local dir = A.DIRS[d]
	local a = get_scan(x, y, z)
	if a.v == 0 then return 0 end
	local b = get_scan(x + dir[1], y + dir[2], z + dir[3])
	if b.v == 0 then return 0 end
	local L = CELL - 1
	local n = 0
	for i = 0, L do for j = 0, L do
		local ia, ib
		if dir[1] ~= 0 then
			ia, ib = idx(dir[1] > 0 and L or 0, i, j), idx(dir[1] > 0 and 0 or L, i, j)
		elseif dir[2] ~= 0 then
			ia, ib = idx(i, dir[2] > 0 and L or 0, j), idx(i, dir[2] > 0 and 0 or L, j)
		else
			ia, ib = idx(i, j, dir[3] > 0 and L or 0), idx(i, j, dir[3] > 0 and 0 or L)
		end
		if a.open[ia] and b.open[ib] then n = n + 1 end
	end end
	return n
end

local geo = {
	vol = function(x, y, z) return get_scan(x, y, z).v end,
	sky = function(x, y, z) return get_scan(x, y, z).sky end,
	face = face,
}

local function dirty(pos) scan[A.key_of(pos)] = nil end
core.register_on_dignode(function(pos) dirty(pos) end)
core.register_on_placenode(function(pos) dirty(pos) end)

-- 來源 ---------------------------------------------------------------------
function rockmech.airq_emit(pos, m3)
	if m3 <= 0 then return end
	local x, y, z = A.cell_of(pos)
	A.emit(state, geo, x, y, z, m3)
end
function rockmech.airq_diesel(pos, litre) rockmech.airq_emit(pos, A.diesel_m3(litre)) end
function rockmech.airq_blast(pos, kg) rockmech.airq_emit(pos, A.blast_m3(kg)) end
rockmech.airq_kg = {emulsion = EMULSION_KG, anfo_per_m = ANFO_KG_PER_M}

function rockmech.airq_ppm(pos)
	local c = state.cells[A.key_of(pos)]
	return c and A.ppm(c) or 0
end

-- 通風 ---------------------------------------------------------------------
local storage = core.get_mod_storage()
local fans = core.deserialize(storage:get_string("airq_fans")) or {}
local function save_fans() storage:set_string("airq_fans", core.serialize(fans)) end

-- 從風機沿著風管走到最遠的那節：回傳路線上的格子（從風機那端到風管口）、風管長度（m）
local function duct_path(fp)
	local start = core.pos_to_string(fp)
	local prev, dist = {[start] = false}, {[start] = 0}
	local queue, head = {fp}, 1
	local far, far_d, n = nil, -1, 0
	while head <= #queue and n < MAX_DUCT do
		local p = queue[head]; head = head + 1
		for _, d in ipairs(A.DIRS) do
			local q = {x = p.x + d[1], y = p.y + d[2], z = p.z + d[3]}
			local qs = core.pos_to_string(q)
			if prev[qs] == nil and core.get_node(q).name == DUCT then
				local ps = core.pos_to_string(p)
				prev[qs], dist[qs] = ps, dist[ps] + 1
				n = n + 1
				queue[#queue + 1] = q
				if dist[qs] > far_d then far, far_d = q, dist[qs] end
			end
		end
	end
	local chain = {}
	local cur = far and core.pos_to_string(far)
	while cur do
		chain[#chain + 1] = core.string_to_pos(cur)
		cur = prev[cur] or nil
	end
	-- chain：風管口 → 風機；倒過來、換成格子、相鄰重複的合併
	local cells, last = {}, nil
	for i = #chain, 1, -1 do
		local x, y, z = A.cell_of(chain[i])
		local k = A.key(x, y, z)
		if k ~= last then cells[#cells + 1] = {x, y, z}; last = k end
	end
	-- 風管口（最遠那節）和它開口的方向、接在風機旁邊的第一節
	local tip, tip_dir, first
	if far and #chain >= 2 then
		tip = chain[1]
		tip_dir = vector.subtract(chain[1], chain[2])
		first = chain[#chain - 1]
	end
	return cells, math.max(0, far_d), tip, tip_dir, first
end

local fan_cache = {}
local function player_near(p, r)
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), p) < r then return true end
	end
	return false
end
-- 粒子：風機出風口往外吹；風管口的空氣往管子裡吸
local AIR_TEX = "[fill:4x4:#e8ecee^[opacity:120"
local function fan_particles(p, c)
	local o = c.out
	if player_near(p, 40) then
		local m = vector.add(p, vector.multiply(o, 0.55))
		local spread = {x = 0.3 - math.abs(o.x) * 0.3, y = 0.3 - math.abs(o.y) * 0.3, z = 0.3 - math.abs(o.z) * 0.3}
		core.add_particlespawner({amount = 18, time = STEP, glow = 2,
			minpos = vector.subtract(m, spread), maxpos = vector.add(m, spread),
			minvel = vector.add(vector.multiply(o, 4), {x = -0.3, y = -0.2, z = -0.3}),
			maxvel = vector.add(vector.multiply(o, 6), {x = 0.3, y = 0.4, z = 0.3}),
			minexptime = 0.4, maxexptime = 0.9, minsize = 1.5, maxsize = 3, texture = AIR_TEX})
	end
	if c.tip and player_near(c.tip, 40) then
		-- 從開口前方約 1.8 m 一帶往開口飄進去
		local d = c.tip_dir
		local m = vector.add(c.tip, vector.multiply(d, 1.8))
		local sp = vector.multiply(d, -2.5)
		core.add_particlespawner({amount = 14, time = STEP, glow = 2,
			minpos = vector.subtract(m, 0.6), maxpos = vector.add(m, 0.6),
			minvel = vector.add(sp, {x = -0.15, y = -0.15, z = -0.15}), maxvel = vector.add(sp, {x = 0.15, y = 0.15, z = 0.15}),
			minexptime = 0.5, maxexptime = 0.6, minsize = 1, maxsize = 2, texture = AIR_TEX})
	end
end
local function active_fans()
	local list, t = {}, now()
	for ps in pairs(fans) do
		local p = core.string_to_pos(ps)
		local node = core.get_node_or_nil(p)
		if node and node.name == FAN then
			local c = fan_cache[ps]
			local meta = core.get_meta(p)
			local on = meta:get_int("off") == 0
			if not c or t - c.t > 5 then
				local cells, len, tip, tip_dir, first = duct_path(p)
				-- 出風口：接風管那一邊的對面；沒接風管就從正面（facedir 的反方向）吹
				local out = first and vector.subtract(p, first) or vector.multiply(core.facedir_to_dir(node.param2), -1)
				c = {t = t, path = cells, len = len, tip = tip, tip_dir = tip_dir, out = out}
				fan_cache[ps] = c
			end
			local info = S("Ventilation fan @1 m³/s", tostring(FAN_Q)) .. "\n" .. S("Duct @1 m", tostring(c.len))
				.. "\n" .. (on and S("Fan running") or S("Fan off"))
			if meta:get_string("infotext") ~= info then meta:set_string("infotext", info) end
			if on then
				if #c.path > 0 then list[#list + 1] = {path = c.path, q = FAN_Q} end
				fan_particles(p, c)
			end
		elseif node then
			fans[ps] = nil; fan_cache[ps] = nil; save_fans()
		end
	end
	return list
end

-- 人 -----------------------------------------------------------------------
local pl = {}     -- 玩家名 → {hud, shown, fog, dmg, warned}

local function level_color(ppm)
	if ppm < A.LIMIT_PPM then return 0x60e060 elseif ppm < HURT then return 0xf0c040 else return 0xf04040 end
end

local function update_player(player, dt)
	local name = player:get_player_name()
	local d = pl[name]
	if not d then d = {dmg = 0}; pl[name] = d end
	local pos = player:get_pos()
	local ppm = rockmech.airq_ppm({x = pos.x, y = pos.y + 1.5, z = pos.z})
	-- 氣體偵測器：背包裡有就顯示
	local has = player:get_inventory():contains_item("main", DETECTOR)
	if has then
		local txt = S("CO @1 ppm", ("%d"):format(math.floor(ppm + 0.5)))
		if not d.hud then
			d.hud = player:hud_add({type = "text", position = {x = 1, y = 0.3}, offset = {x = -16, y = 0},
				alignment = {x = -1, y = 0}, text = txt, number = level_color(ppm), size = {x = 2, y = 0}, z_index = 10})
			d.shown = txt
		elseif d.shown ~= txt then
			player:hud_change(d.hud, "text", txt)
			player:hud_change(d.hud, "number", level_color(ppm))
			d.shown = txt
		end
	elseif d.hud then
		player:hud_remove(d.hud); d.hud, d.shown = nil, nil
	end
	-- 霧：濃度越高看得越近
	local fog = 0
	if ppm > FOG0 then fog = math.min(1, math.log(ppm / FOG0) / math.log(FOG1 / FOG0)) end
	local step = math.floor(fog * 10 + 0.5)
	if step ~= (d.fog or 0) then
		d.fog = step
		if step == 0 then
			player:set_sky({fog = {fog_distance = -1, fog_start = -1}})
		else
			player:set_sky({fog = {fog_distance = 200 - step * 19, fog_start = 0.0, fog_color = "#6a665c"}})
		end
	end
	-- 扣血
	if ppm >= HURT and player:get_hp() > 0 then
		if not d.warned then
			d.warned = true
			rockmech.notify(name, S("The air is bad: headache and dizziness"))
		end
		d.dmg = d.dmg + ppm * HP_PER_PPM_S * dt
		if d.dmg >= 1 then
			local n = math.floor(d.dmg)
			d.dmg = d.dmg - n
			player:set_hp(player:get_hp() - n, {type = "set_hp", from = "mod"})
		end
	else
		d.dmg = 0
		if ppm < HURT / 2 then d.warned = nil end
	end
end

core.register_on_leaveplayer(function(player) pl[player:get_player_name()] = nil end)
core.register_on_respawnplayer(function(player)
	local d = pl[player:get_player_name()]
	if d then d.dmg = 0 end
end)

-- 主迴圈 -------------------------------------------------------------------
local acc, gc = 0, 0
local function tick(dt)
	-- 追蹤中的格子：地形變了（重讀過）就更新空氣體積；被填滿就不追蹤
	for k, c in pairs(state.cells) do
		local s = get_scan(c.x, c.y, c.z)
		if s.v <= 0 then state.cells[k] = nil else c.v, c.sky = s.v, s.sky end
	end
	A.step(state, geo, dt, active_fans())
	for _, player in ipairs(core.get_connected_players()) do update_player(player, dt) end
	-- 地形快取：一分鐘沒用到就丟掉
	gc = gc + dt
	if gc > 30 then
		gc = 0
		local t = now()
		for k, s in pairs(scan) do if t - s.used > 60 then scan[k] = nil end end
	end
end
rockmech.airq_tick = tick     -- 測試用：直接快轉
core.register_globalstep(function(dtime)
	acc = acc + dtime
	if acc < STEP then return end
	local dt = acc
	acc = 0
	tick(dt)
end)

-- 物品 ---------------------------------------------------------------------
core.register_craftitem(DETECTOR, {
	description = S("Gas detector\nWorks from your inventory"),
	short_description = S("Gas detector"),
	inventory_image = "[fill:16x16:#00000000^[fill:8x12:4,2:#e8b020^[fill:6x4:5,4:#1a2a1a^[fill:4x1:6,5:#60e060^[fill:2x2:7,10:#303030^[fill:2x1:7,1:#c03020",
	stack_max = 1,
})

local grill = "[fill:16x16:#4a5a48^[fill:14x14:1,1:#202020^[fill:12x2:2,7:#9a9a9a^[fill:2x12:7,2:#9a9a9a^[fill:4x4:6,6:#c8c8c8"
local fan_side = "[fill:16x16:#4a5a48^[fill:16x2:0,0:#3a4838^[fill:16x2:0,14:#3a4838"
core.register_node(FAN, {
	description = S("Ventilation fan"),
	drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
	node_box = {type = "fixed", fixed = {
		{-0.45, -0.45, -0.5, 0.45, 0.45, 0.5},
		{-0.5, -0.5, -0.3, 0.5, -0.4, 0.3},
	}},
	tiles = {fan_side, fan_side, fan_side, fan_side, grill, grill},
	inventory_image = grill, wield_image = grill,
	groups = {dig_immediate = 2},
	sounds = default.node_sound_metal_defaults and default.node_sound_metal_defaults() or nil,
	-- 右鍵：開、關；手上拿著方塊（例如風管）時照常放方塊
	on_rightclick = function(pos, node, clicker, itemstack, pointed)
		local w = itemstack and itemstack:get_name() or ""
		if core.registered_nodes[w] then return (core.item_place_node(itemstack, clicker, pointed)) end
		local meta = core.get_meta(pos)
		meta:set_int("off", meta:get_int("off") == 0 and 1 or 0)
		core.sound_play("default_dig_metal", {pos = pos, gain = 0.4, max_hear_distance = 12}, true)
		return itemstack
	end,
	on_construct = function(pos)
		fans[core.pos_to_string(pos)] = true; save_fans()
		core.get_meta(pos):set_string("infotext", S("Ventilation fan @1 m³/s", tostring(FAN_Q)))
	end,
	after_destruct = function(pos)
		local ps = core.pos_to_string(pos)
		fans[ps], fan_cache[ps] = nil, nil; save_fans()
	end,
})

local R = 0.3
local duct_tex = "[fill:16x16:#e0b020^[fill:16x1:0,3:#a07810^[fill:16x1:0,7:#a07810^[fill:16x1:0,11:#a07810^[fill:16x1:0,15:#a07810"
core.register_node(DUCT, {
	description = S("Ventilation duct"),
	drawtype = "nodebox", paramtype = "light", sunlight_propagates = true,
	walkable = false,
	node_box = {type = "connected",
		fixed = {-R, -R, -R, R, R, R},
		connect_top = {-R, R, -R, R, 0.5, R}, connect_bottom = {-R, -0.5, -R, R, -R, R},
		connect_front = {-R, -R, -0.5, R, R, -R}, connect_back = {-R, -R, R, R, R, 0.5},
		connect_left = {-0.5, -R, -R, -R, R, R}, connect_right = {R, -R, -R, 0.5, R, R},
	},
	connects_to = {DUCT, FAN},
	tiles = {duct_tex},
	groups = {dig_immediate = 3},
	after_place_node = function(pos) for ps in pairs(fan_cache) do fan_cache[ps].t = 0 end end,
	after_destruct = function() for ps in pairs(fan_cache) do fan_cache[ps].t = 0 end end,
})
