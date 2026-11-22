-- rockmech/concrete.lua
-- 混凝土：連續壁的水中混凝土（特密管從槽底灌、把穩定液往上擠）。
--
--   特密管支架（物品）：對著溝槽按右鍵，支架架在槽口、管子自己伸到槽底（管子是畫面上的一根桿子，不佔方塊）。
--     預拌車（vehicle_mixer.lua）倒車到支架旁按 E，混凝土一格（1 m³）一格灌進去：
--     永遠從管口附近（水平 FLOW_R m 內）最低、最近的那一格開始，混凝土面從槽底一層一層往上長，灌到槽口下 TOP_GAP m，
--     管子跟著自動往上縮（實務上管口要一直埋在混凝土裡 2 m 以上，這裡當作都做對了，不會夾泥）。
--     被取代的那一格穩定液往上排開（守恆），液面上升；出液口（slurrytank.lua）把高出目標的抽回儲槽。
--   新拌混凝土：液體，γ = 23 kN/m³（比穩定液重，沉在底下），應力解裡跟穩定液一樣當液壓頂著溝壁（femstress.lua）。
--   凝固：灌下去 SET_DAYS 天（一天 = 一個交易日，rockmech_price_period）變成硬化的混凝土；
--     強度照 ACI 209 的曲線長（concretecurve.lua）：f_c(t) = f_c28 · t / (4 + 0.85 t)，指著看齡期、強度。
--   硬化的混凝土：應力解裡的元素（跟鋼板樁同一套：勁度比 CONC_R、沒有現地應力、不加重力）。
--     一道 1 m 厚的牆（一欄混凝土，兩側是土）照彈性支承梁法（retain.lua、wallbeam.lua）算彎矩，
--     EI = E_c(t)·h³/12；素混凝土沒有鋼筋，彎矩超過開裂彎矩 M_cr = f_r·h²/6（÷ 相似比）整欄彎裂（勁度剩 1/10）。
--   挖它：跟磚牆一樣變成建築廢棄物。

local S = rockmech.S
local cfg = rockmech.cfg
local CC = dofile(rockmech.modpath .. "/concretecurve.lua")
rockmech.concrete_curve = CC

local FRESH = "rockmech:concrete_fresh"
local HARD = "rockmech:concrete"
local CRACKED = "rockmech:concrete_cracked"
local FRAME = "rockmech:tremie_frame"
local PIPE_ENT = "rockmech:tremie_pipe"
local ITEM_M3 = "rockmech:concrete_m3"         -- 預拌車上的混凝土（只在車上，背包拿不到）
local GAMMA = 23                                -- kN/m³
local FC28 = tonumber(core.settings:get("rockmech_concrete_fc") or "") or 28     -- 設計強度 f_c28 (MPa)
local SET_DAYS = 0.25                           -- 初凝（變成固體）
local FLOW_R = 3                                -- 一支特密管灌得到的水平距離 (m)
-- 灌到槽口下 TOP_GAP m 為止：灌到頂的話，槽口那 1–2 m 的土上面沒有覆土壓著，新拌混凝土的液壓（23 kN/m³）
-- 會把它推壞（應力解：槽口兩側的土流動；實務上靠導溝撐住，混凝土也只灌到設計頂高附近）
local TOP_GAP = 1
local CONC_R = 1.0                              -- 應力解的勁度比（跟岩體同級；彎矩由彈性支承梁照真的 EI 算）
local CRACK_R = 0.1
local DEPTH = 60
rockmech.CONCRETE, rockmech.CONCRETE_FRESH, rockmech.TREMIE_FRAME, rockmech.CONCRETE_M3 = HARD, FRESH, FRAME, ITEM_M3
rockmech.fluid_extra = rockmech.fluid_extra or {}
rockmech.fluid_extra[FRESH] = {1, GAMMA}
local IS_WALL = {[HARD] = true, [CRACKED] = true}
rockmech.concrete_wall = IS_WALL

local function day_s() return math.max(1, cfg.price_period or 1200) end
local function now() return core.get_gametime() end
local function age_of(meta)
	if not meta:contains("t0") then return 0 end
	return (now() - meta:get_float("t0")) / day_s()
end
local function n_scale() return cfg.model_scale or 1 end
local function d0(v) return ("%d"):format(math.floor(v + 0.5)) end
local function tell_near(p, msg)
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), p) <= 32 then rockmech.notify(pl:get_player_name(), msg) end
	end
end
local function may(pos, name)
	local owner = core.get_meta(pos):get_string("owner")
	return owner == "" or (rockmech.owner_ok and rockmech.owner_ok(owner, name)) or owner == name
end

---------------------------------------------------------------------------
-- 方塊
---------------------------------------------------------------------------
local TEX = "[fill:16x16:#a3a39c^[fill:1x1:2,3:#8e8e88^[fill:1x1:9,6:#8e8e88^[fill:1x1:5,11:#b4b4ae^[fill:1x1:13,13:#8e8e88"
	.. "^[fill:1x1:12,2:#b4b4ae^[fill:1x1:3,13:#b4b4ae^[fill:1x1:10,10:#8e8e88"
local CRACK_TEX = TEX .. "^[fill:1x4:7,0:#4a4a46^[fill:1x4:8,4:#4a4a46^[fill:1x4:7,8:#4a4a46^[fill:1x4:8,12:#4a4a46"
	.. "^[fill:3x1:9,6:#4a4a46"

-- 硬化的混凝土：齡期、強度（還有應力解算的彎矩，meta mtxt）
local function hard_info(pos)
	local meta = core.get_meta(pos)
	local t = age_of(meta)
	local fc = CC.fc(FC28, t)
	local cracked = core.get_node(pos).name == CRACKED
	local s = (cracked and S("Concrete (cracked)") or S("Concrete")) .. "\n"
		.. S("Age @1 days, strength @2 / @3 MPa (@4%)", ("%.1f"):format(t), ("%.1f"):format(fc), d0(FC28), d0(fc / FC28 * 100))
	local m = meta:get_string("mtxt")
	if m ~= "" then s = s .. "\n" .. m end
	meta:set_string("infotext", s)
end

local function queue_fem(pos)
	if rockmech.fem_queue then rockmech.fem_queue(pos, 1, false, false) end
end

local function harden(pos)
	core.swap_node(pos, {name = HARD})
	hard_info(pos)
	core.get_node_timer(pos):start(day_s() / 2)
	queue_fem(pos)
end

core.register_node(FRESH, {
	description = S("Fresh concrete"),
	drawtype = "normal",
	tiles = {"[fill:16x16:#7c7c76^[fill:1x1:4,5:#6c6c66^[fill:1x1:11,9:#6c6c66"},
	paramtype = "light",
	walkable = false, pointable = false, diggable = false, buildable_to = false,
	liquid_move_physics = true, move_resistance = 7,
	post_effect_color = {a = 240, r = 0x6c, g = 0x6c, b = 0x66},
	drowning = 1,
	drop = "",
	is_ground_content = false,
	groups = {rockmech_concrete = 1, not_in_creative_inventory = 1},
	on_timer = function(pos)
		if age_of(core.get_meta(pos)) >= SET_DAYS - 1e-3 then harden(pos); return false end
		return true
	end,
})

local function waste_after_dig(pos)
	if core.get_node(pos).name ~= "air" or not rockmech.RUBBLE_DEBRIS then return end
	rockmech.assay.place(pos, rockmech.RUBBLE_DEBRIS, rockmech.RUBBLE_LEVELS, rockmech.assay.new(0))
	if rockmech.collapse and rockmech.collapse.update_affected_area then
		core.after(0.05, function() rockmech.collapse.update_affected_area(pos) end)
	end
end
for _, v in ipairs({{HARD, TEX, S("Concrete")}, {CRACKED, CRACK_TEX, S("Concrete (cracked)")}}) do
	core.register_node(v[1], {
		description = v[3],
		tiles = {v[2]},
		is_ground_content = false,
		groups = {cracky = 1, rockmech_concrete = 2, not_in_creative_inventory = 1},
		drop = "",
		sounds = default and default.node_sound_stone_defaults and default.node_sound_stone_defaults() or nil,
		on_timer = function(pos)
			hard_info(pos)
			return age_of(core.get_meta(pos)) < 28
		end,
		after_dig_node = function(pos) waste_after_dig(pos) end,
	})
end
-- 預拌車上的混凝土（存放畫面的圖示；背包裡不會有）
core.register_craftitem(ITEM_M3, {
	description = S("Ready-mix concrete (m³)"),
	inventory_image = "[fill:16x16:#00000000^[fill:12x10:2,4:#8c8c86^[fill:12x2:2,4:#a8a8a2",
	groups = {not_in_creative_inventory = 1},
})

-- 載入時：計時器沒在跑就補上（沒有齡期的當作現在灌的）
core.register_lbm({
	label = "rockmech: 混凝土凝固、強度計時器", name = "rockmech:concrete_timer", nodenames = {FRESH, HARD, CRACKED},
	run_at_every_load = true,
	action = function(pos, node)
		local meta = core.get_meta(pos)
		if not meta:contains("t0") then meta:set_float("t0", now()) end
		local t = age_of(meta)
		local timer = core.get_node_timer(pos)
		if node.name == FRESH then
			if t >= SET_DAYS then harden(pos)
			elseif not timer:is_started() then timer:start((SET_DAYS - t) * day_s() + 0.1) end
		elseif t < 28 and not timer:is_started() then
			hard_info(pos)
			timer:start(day_s() / 2)
		end
	end,
})

---------------------------------------------------------------------------
-- 特密管支架、管子
---------------------------------------------------------------------------
local lvl = rockmech.slurry_level
local function passable(n) return n == "air" or lvl[n] ~= nil or n == FRESH end
local function fillable(n) return n == "air" or lvl[n] ~= nil end
local function name_at(p) return core.get_node(p).name end
local DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
local function walled(p)
	for _, d in ipairs(DIRS) do
		if not passable(name_at({x = p.x + d[1], y = p.y, z = p.z + d[2]})) then return true end
	end
end

-- 管口的高度（世界座標 y）：管子那一欄最上面的混凝土往下 1.5 m（埋在混凝土裡），還沒灌就到槽底
local function tip_y(F)
	local q = {x = F.x, y = F.y - 1, z = F.z}
	local bottom = q.y
	for _ = 1, DEPTH do
		local n = name_at(q)
		if n == FRESH or IS_WALL[n] then return math.max(bottom - 0.4, q.y + 0.5 - 1.5) end
		if not passable(n) then break end
		bottom = q.y
		q.y = q.y - 1
	end
	return bottom - 0.4
end

local pipes = {}
local PIPE_W = 0.22
core.register_entity(PIPE_ENT, {
	initial_properties = {
		visual = "cube", textures = {"[fill:16x16:#6c7278", "[fill:16x16:#6c7278", "[fill:16x16:#5c6268",
			"[fill:16x16:#5c6268", "[fill:16x16:#646a70", "[fill:16x16:#646a70"},
		visual_size = {x = PIPE_W, y = 0.3, z = PIPE_W},
		physical = false, pointable = false, static_save = false,
		collisionbox = {0, 0, 0, 0, 0, 0},
	},
	apply = function(self)
		local top = self.frame.y - 0.05
		self.object:set_pos({x = self.frame.x, y = top - self.len / 2, z = self.frame.z})
		self.object:set_properties({visual_size = {x = PIPE_W, y = math.max(0.05, self.len), z = PIPE_W}})
	end,
	on_step = function(self, dtime)
		if not self.frame then self.object:remove(); return end
		self.chk = (self.chk or 0) + dtime
		if self.chk > 2 then
			self.chk = 0
			if name_at(self.frame) ~= FRAME then self.object:remove(); return end
		end
		if self.len ~= self.target then        -- 伸縮：每秒 6 m
			local dl = self.target - self.len
			self.len = math.abs(dl) <= 6 * dtime and self.target or self.len + (dl > 0 and 1 or -1) * 6 * dtime
			self:apply()
		end
	end,
})
local function pipe_update(F)
	local h = core.hash_node_position(F)
	local target = math.max(0.3, F.y - 0.05 - tip_y(F))
	local o = pipes[h]
	local e = o and o:get_pos() and o:get_luaentity()
	if not e then
		o = core.add_entity({x = F.x, y = F.y - 0.2, z = F.z}, PIPE_ENT)
		e = o and o:get_luaentity()
		if not e then return end
		e.frame, e.len = vector.copy(F), 0.3
		e:apply()
		pipes[h] = o
	end
	e.target = target
end
local function pipe_remove(F)
	local h = core.hash_node_position(F)
	local o = pipes[h]
	if o and o:get_pos() then o:remove() end
	pipes[h] = nil
end

local function frame_info(pos, extra)
	local meta = core.get_meta(pos)
	if extra then meta:set_string("msg", extra) end
	local s = S("Tremie frame") .. "\n" .. S("Poured @1 m³", meta:get_int("poured"))
	local m = meta:get_string("msg")
	if m ~= "" then s = s .. "\n" .. m end
	meta:set_string("infotext", s)
end

-- 溝槽口：從 p（溝槽裡的一格）往上，最上面那一格還夾在溝壁之間的；支架架在它上面。回傳支架的位置或 nil
local function mouth_of(p)
	if not passable(name_at(p)) then return nil end
	local q = vector.copy(p)
	for _ = 1, DEPTH do
		local up = {x = q.x, y = q.y + 1, z = q.z}
		if not (passable(name_at(up)) and walled(up)) then break end
		q = up
	end
	if not walled(q) then return nil end
	local F = {x = q.x, y = q.y + 1, z = q.z}
	if name_at(F) ~= "air" then return nil end
	return F
end

-- 從支架 F 灌 1 m³：回傳 true，或 false 和原因
local NB6 = {{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}, {0, -1, 0}, {0, 1, 0}}
local function find_cell(F, owner)
	local start = {x = F.x, y = F.y - 1 - TOP_GAP, z = F.z}
	if not passable(name_at(start)) then return nil end
	local seen, queue = {[core.hash_node_position(start)] = true}, {start}
	local best, by, bd
	local i = 1
	while queue[i] and #queue < 3000 do
		local c = queue[i]; i = i + 1
		local n = name_at(c)
		if fillable(n) and not fillable(name_at({x = c.x, y = c.y - 1, z = c.z}))
				and not core.is_protected(c, owner) then
			local dd = (c.x - F.x) ^ 2 + (c.z - F.z) ^ 2
			if not best or c.y < by or (c.y == by and dd < bd) then best, by, bd = c, c.y, dd end
		end
		for _, d in ipairs(NB6) do
			local q = {x = c.x + d[1], y = c.y + d[2], z = c.z + d[3]}
			local h = core.hash_node_position(q)
			if not seen[h] and q.y < F.y - TOP_GAP and q.y > F.y - DEPTH and (q.x - F.x) ^ 2 + (q.z - F.z) ^ 2 <= FLOW_R * FLOW_R + 0.5 then
				seen[h] = true
				if passable(name_at(q)) then queue[#queue + 1] = q end
			end
		end
	end
	return best
end

-- 排開的穩定液：先往上倒回這一段溝槽（液面上升），溝槽滿了就從槽口溢到地面。
-- 溢出來的攤成薄薄一層（槽口那一層地面，從支架往外，每格補到 FILM 級），不要在槽口疊成液柱：
-- 液柱的重量壓在槽口邊的土上，應力解的塑性迭代很難收斂、會判出一大片破壞
local FILM = 2
local function spill(F, left)
	local lv = rockmech.slurry_level
	local seen, queue = {[core.hash_node_position(F)] = true}, {F}
	local i = 1
	while queue[i] and left > 0 and #queue < 1200 do
		local c = queue[i]; i = i + 1
		for _, d in ipairs(DIRS) do
			local q = {x = c.x + d[1], y = F.y, z = c.z + d[2]}
			local h = core.hash_node_position(q)
			if not seen[h] then
				seen[h] = true
				local n = name_at(q)
				local below = name_at({x = q.x, y = q.y - 1, z = q.z})
				if fillable(n) and (not fillable(below) or lv[below] == 8) then
					queue[#queue + 1] = q
					local k = lv[n] or 0
					if k < FILM and left > 0 then
						local put = math.min(FILM - k, left)
						rockmech.slurry_replace(q, {name = rockmech.slurry_with_level(k + put)})
						rockmech.slurry_schedule(q)
						left = left - put
					end
				end
			end
		end
	end
	if left > 0 then          -- 四周都攤滿了（或被擋住）：疊在槽口旁邊
		for _, d in ipairs(DIRS) do
			if left <= 0 then break end
			local q = {x = F.x + d[1], y = F.y, z = F.z + d[2]}
			if fillable(name_at(q)) then
				left = rockmech.slurry_add_up(q, left)
				rockmech.slurry_schedule(q)
			end
		end
	end
end
local function displace(c, F, k)
	if k <= 0 then return end
	local up = {x = c.x, y = c.y + 1, z = c.z}
	local left = k
	if fillable(name_at(up)) then left = left - rockmech.slurry_pour(up, left, F.y - 1, true) end
	if left > 0 then spill(F, left) end
end

local fem_wait = {}
function rockmech.tremie_pour(F)
	if name_at(F) ~= FRAME then return false, S("The tremie frame is gone") end
	local meta = core.get_meta(F)
	local c = find_cell(F, meta:get_string("owner"))
	if not c then
		frame_info(F, S("The panel is full"))
		return false, S("The panel is full")
	end
	local k = rockmech.slurry_replace(c, {name = FRESH})
	local cm = core.get_meta(c)
	cm:set_float("t0", now())
	core.get_node_timer(c):start(SET_DAYS * day_s())
	displace(c, F, k)
	meta:set_int("poured", meta:get_int("poured") + 1)
	frame_info(F, "")
	pipe_update(F)
	-- 應力解：灌完一陣子（5 秒沒有再灌）排一次（新拌混凝土的液壓）
	local h = core.hash_node_position(F)
	fem_wait[h] = (fem_wait[h] or 0) + 1
	local mine = fem_wait[h]
	core.after(5, function()
		if fem_wait[h] == mine then fem_wait[h] = nil; queue_fem(c) end
	end)
	return true
end

local FRAME_C = "#d8b020"
core.register_node(FRAME, {
	description = S("Tremie frame\nRight-click a trench: the frame sits on the mouth and the tremie pipe reaches the bottom. A concrete mixer truck pours through it"),
	short_description = S("Tremie frame"),
	drawtype = "nodebox",
	tiles = {"[fill:16x16:" .. FRAME_C .. "^[fill:10x10:3,3:#3a3a3a", "[fill:16x16:#8a7010", "[fill:16x16:" .. FRAME_C},
	inventory_image = "[fill:16x16:#00000000^[fill:12x4:2,2:" .. FRAME_C .. "^[fill:6x3:5,6:#b89010^[fill:2x7:7,9:#6c7278^[fill:16x2:0,13:#8a7010",
	node_box = {type = "fixed", fixed = {
		{-1.3, -0.5, -0.12, 1.3, -0.32, 0.12},        -- 架在槽口兩邊的橫梁（十字）
		{-0.12, -0.5, -1.3, 0.12, -0.32, 1.3},
		{-0.1, -0.5, -0.1, 0.1, 0.1, 0.1},            -- 管夾
		{-0.2, 0.0, -0.2, 0.2, 0.15, 0.2},            -- 漏斗頸
		{-0.42, 0.15, -0.42, 0.42, 0.22, 0.42},       -- 漏斗底
		{-0.45, 0.22, -0.45, 0.45, 0.5, -0.38},       -- 漏斗四面
		{-0.45, 0.22, 0.38, 0.45, 0.5, 0.45},
		{-0.45, 0.22, -0.38, -0.38, 0.5, 0.38},
		{0.38, 0.22, -0.38, 0.45, 0.5, 0.38},
	}},
	selection_box = {type = "fixed", fixed = {{-0.45, -0.5, -0.45, 0.45, 0.5, 0.45}}},
	collision_box = {type = "fixed", fixed = {{-0.45, -0.5, -0.45, 0.45, 0.5, 0.45}}},
	paramtype = "light",
	sunlight_propagates = true,
	is_ground_content = false,
	groups = {cracky = 2, oddly_breakable_by_hand = 1},
	sounds = default and default.node_sound_metal_defaults and default.node_sound_metal_defaults() or nil,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local un = core.get_node(pointed.under)
		local udef = core.registered_nodes[un.name]
		if udef and udef.on_rightclick and not placer:get_player_control().sneak then
			return udef.on_rightclick(pointed.under, un, placer, itemstack, pointed) or itemstack
		end
		local name = placer:get_player_name()
		local F = mouth_of(pointed.above)
		if not F then
			rockmech.notify(name, S("Point into a trench: the frame sits on its mouth"))
			return itemstack
		end
		if core.is_protected(F, name) then return itemstack end
		core.set_node(F, {name = FRAME})
		local meta = core.get_meta(F)
		meta:set_string("owner", rockmech.account_of and rockmech.account_of(name) or name)
		frame_info(F, "")
		pipe_update(F)
		core.sound_play("default_place_node_metal", {pos = F, gain = 0.8}, true)
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	on_destruct = function(pos) pipe_remove(pos) end,
	can_dig = function(pos, player) return player and may(pos, player:get_player_name()) end,
})
core.register_lbm({
	label = "rockmech: 特密管", name = "rockmech:tremie_pipe", nodenames = {FRAME}, run_at_every_load = true,
	action = function(pos) core.after(0.5, function() if name_at(pos) == FRAME then pipe_update(pos) end end) end,
})

---------------------------------------------------------------------------
-- 應力解：勁度比（femstress.lua 的 support_ids.retain_r；retain.lua、steelarch.lua 之後補上）
---------------------------------------------------------------------------
core.register_on_mods_loaded(function()
	local ids = rockmech.support_ids
	if not (ids and ids.retain_r and ids.pile) then return end
	ids.retain_r[core.get_content_id(HARD)] = CONC_R
	ids.retain_r[core.get_content_id(CRACKED)] = CONC_R * CRACK_R
	ids.pile[core.get_content_id(HARD)] = true
	ids.pile[core.get_content_id(CRACKED)] = true
end)

-- 彈性支承梁（retain.lua 的 wall_solve 叫）：lo..hi 裡一欄一欄 1 m 厚的混凝土牆。
-- 牆的法向：那一欄每一格法向兩側都不是混凝土、沿牆方向有接著混凝土（或單獨一欄就看不出來，不算）
local function wall_cols(lo, hi)
	local out, seen = {}, {}
	for _, p in ipairs(core.find_nodes_in_area(lo, hi, {HARD, CRACKED})) do
		local key = p.x .. "," .. p.z
		if not seen[key] then
			seen[key] = true
			local y = p.y
			while IS_WALL[name_at({x = p.x, y = y + 1, z = p.z})] do y = y + 1 end
			local cells = {}
			while IS_WALL[name_at({x = p.x, y = y, z = p.z})] do
				cells[#cells + 1] = {x = p.x, y = y, z = p.z}
				y = y - 1
			end
			local fx, fz, nx, nz = 0, 0, 0, 0      -- 兩側都空著（不是混凝土）的格數、沿那個方向接著混凝土的格數
			for _, c in ipairs(cells) do
				local ex = IS_WALL[name_at({x = c.x + 1, y = c.y, z = c.z})] or IS_WALL[name_at({x = c.x - 1, y = c.y, z = c.z})]
				local ez = IS_WALL[name_at({x = c.x, y = c.y, z = c.z + 1})] or IS_WALL[name_at({x = c.x, y = c.y, z = c.z - 1})]
				if not ex then fx = fx + 1 else nx = nx + 1 end
				if not ez then fz = fz + 1 else nz = nz + 1 end
			end
			local xaxis                        -- true：法向是 x（牆沿 z 走）
			if fx == #cells and nz > 0 and nx == 0 then xaxis = true
			elseif fz == #cells and nx > 0 and nz == 0 then xaxis = false end
			if xaxis ~= nil and #cells >= 2 then
				local fc, bent = math.huge, false
				for _, c in ipairs(cells) do
					fc = math.min(fc, CC.fc(FC28, age_of(core.get_meta(c))))
					if name_at(c) == CRACKED then bent = true end
				end
				local col = {cells = cells, ax = xaxis and {x = 1, y = 0, z = 0} or {x = 0, y = 0, z = 1}, xaxis = xaxis,
					t = xaxis and p.z or p.x, plane = xaxis and p.x or p.z, bent = bent,
					EI = CC.ei(fc) * (bent and CRACK_R or 1)}
				col.check = function(r, t)
					if bent or #t.soil == 0 then return end
					local Mcr = CC.mcr(fc) / n_scale()
					if not r.ok or r.Mmax > Mcr then
						for _, c in ipairs(cells) do
							core.swap_node(c, {name = CRACKED})
							core.get_meta(c):set_string("mtxt", "")
							hard_info(c)
						end
						local top = cells[1]
						core.sound_play("default_dug_node", {pos = top, gain = 1.0, max_hear_distance = 32}, true)
						-- 埋入不夠（土撐不住，形成機構）：牆被推動、跟著裂；不然就是彎矩超過開裂彎矩
						tell_near(top, r.ok and S("[Concrete] The plain concrete wall at @1 cracked in bending", core.pos_to_string(top))
							or S("[Concrete] The concrete wall at @1 is not embedded deep enough: the soil pushed it over and it cracked", core.pos_to_string(top)))
						core.log("action", ("[rockmech] 混凝土牆%s %s（%d m）"):format(r.ok and "彎裂" or "埋入不夠", core.pos_to_string(top), #cells))
					else
						local txt = S("Bending moment @1 kN·m/m / cracking @2 kN·m/m (@3%)", d0(r.Mmax), d0(Mcr), d0(r.Mmax / Mcr * 100))
						for _, c in ipairs(cells) do
							core.get_meta(c):set_string("mtxt", txt)
							hard_info(c)
						end
					end
				end
				out[#out + 1] = col
			end
		end
	end
	return out
end
rockmech.retain_extra_cols = wall_cols

dofile(rockmech.modpath .. "/vehicle_mixer.lua")
