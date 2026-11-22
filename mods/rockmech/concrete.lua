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
--
--   鋼筋籠（物品）：對著溝槽按右鍵，吊放一片 1 m 寬、從槽口到槽底的鋼筋籠（那一欄記在 mod storage，畫面上是一根格子框）。
--     灌進籠子裡的混凝土就是鋼筋混凝土：開裂不要緊（鋼筋接手拉力），檢查改成極限彎矩
--     M_u = A_s·f_y·(d − a/2)（每面 D32@150、SD420、d = 0.9 m；concretecurve.lua），EI 取有效勁度 RC_EI × 全斷面；
--     M > M_u（÷ 相似比）→ 鋼筋降伏，整欄勁度剩 1/10。
--   導溝（物品）：對著地面按右鍵，沿你看的方向（x 或 z）在溝槽線兩側各放一道 GUIDE_D m 深的混凝土牆（1 m 一段），
--     中間那一欄留給抓斗挖。槽口兩側有導溝，混凝土就能灌到槽口（沒有的話停在槽口下 TOP_GAP m）。
--     應力解裡是勁度比 CONC_R 的元素（跟硬化的混凝土一樣）。

local S = rockmech.S
local cfg = rockmech.cfg
local CC = dofile(rockmech.modpath .. "/concretecurve.lua")
rockmech.concrete_curve = CC

local FRESH = "rockmech:concrete_fresh"
local HARD = "rockmech:concrete"
local CRACKED = "rockmech:concrete_cracked"
local RC = "rockmech:concrete_rc"                -- 鋼筋混凝土
local RC_Y = "rockmech:concrete_rc_yielded"      -- 鋼筋降伏
local GUIDE = "rockmech:guide_wall"
local CAGE = "rockmech:rebar_cage"               -- 物品
local CAGE_ENT = "rockmech:rebar_cage_view"
local GUIDE_D = 2                                -- 導溝深 (m)
local RC_EI = 0.5                                -- 鋼筋混凝土牆的有效勁度（開裂斷面，× 全斷面 EI）
local AS, FY, D_EFF = 5360, 420, 0.9             -- 每面主筋 D32@150 (mm²/m)、SD420 (MPa)、有效深度 (m)
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
local IS_WALL = {[HARD] = true, [CRACKED] = true, [RC] = true, [RC_Y] = true}
local IS_RC = {[RC] = true, [RC_Y] = true}
local IS_BAD = {[CRACKED] = true, [RC_Y] = true}
rockmech.concrete_wall = IS_WALL
rockmech.GUIDE_WALL = GUIDE

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
-- 鋼筋混凝土：表面看得到一點鏽色的鋼筋頭；降伏：裂縫加鏽水痕
local RC_TEX = TEX .. "^[fill:2x2:3,3:#7a4a30^[fill:2x2:11,3:#7a4a30^[fill:2x2:3,11:#7a4a30^[fill:2x2:11,11:#7a4a30"
local RCY_TEX = CRACK_TEX .. "^[fill:2x2:3,3:#7a4a30^[fill:2x2:11,3:#7a4a30^[fill:2x2:3,11:#7a4a30^[fill:2x2:11,11:#7a4a30"
	.. "^[fill:1x5:4,5:#8a5a3a^[fill:1x5:12,5:#8a5a3a"
local LABEL = {}

-- 硬化的混凝土：齡期、強度（還有應力解算的彎矩，meta mtxt）
local function hard_info(pos)
	local meta = core.get_meta(pos)
	local t = age_of(meta)
	local fc = CC.fc(FC28, t)
	local s = (LABEL[core.get_node(pos).name] or S("Concrete")) .. "\n"
		.. S("Age @1 days, strength @2 / @3 MPa (@4%)", ("%.1f"):format(t), ("%.1f"):format(fc), d0(FC28), d0(fc / FC28 * 100))
	local m = meta:get_string("mtxt")
	if m ~= "" then s = s .. "\n" .. m end
	meta:set_string("infotext", s)
end

local function queue_fem(pos)
	if rockmech.fem_queue then rockmech.fem_queue(pos, 1, false, false) end
end

local function harden(pos)
	core.swap_node(pos, {name = core.get_meta(pos):get_int("rc") == 1 and RC or HARD})
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
LABEL[HARD], LABEL[CRACKED] = S("Concrete"), S("Concrete (cracked)")
LABEL[RC], LABEL[RC_Y] = S("Reinforced concrete"), S("Reinforced concrete (rebar yielded)")
for _, v in ipairs({{HARD, TEX}, {CRACKED, CRACK_TEX}, {RC, RC_TEX}, {RC_Y, RCY_TEX}}) do
	v[3] = LABEL[v[1]]
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
	label = "rockmech: 混凝土凝固、強度計時器", name = "rockmech:concrete_timer", nodenames = {FRESH, HARD, CRACKED, RC, RC_Y},
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
local function guided(c)
	local function g(dx, dz) return name_at({x = c.x + dx, y = c.y, z = c.z + dz}) == GUIDE end
	return (g(1, 0) and g(-1, 0)) or (g(0, 1) and g(0, -1))
end
local function find_cell(F, owner)
	local start = {x = F.x, y = F.y - 1, z = F.z}
	if not passable(name_at(start)) then return nil end
	local seen, queue = {[core.hash_node_position(start)] = true}, {start}
	local best, by, bd
	local i = 1
	while queue[i] and #queue < 3000 do
		local c = queue[i]; i = i + 1
		local n = name_at(c)
		if fillable(n) and not fillable(name_at({x = c.x, y = c.y - 1, z = c.z}))
				and (c.y < F.y - TOP_GAP or guided(c)) and not core.is_protected(c, owner) then
			local dd = (c.x - F.x) ^ 2 + (c.z - F.z) ^ 2
			if not best or c.y < by or (c.y == by and dd < bd) then best, by, bd = c, c.y, dd end
		end
		for _, d in ipairs(NB6) do
			local q = {x = c.x + d[1], y = c.y + d[2], z = c.z + d[3]}
			local h = core.hash_node_position(q)
			if not seen[h] and q.y < F.y and q.y > F.y - DEPTH and (q.x - F.x) ^ 2 + (q.z - F.z) ^ 2 <= FLOW_R * FLOW_R + 0.5 then
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
	if rockmech.rebar_caged(c) then cm:set_int("rc", 1) end
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
-- 預拌車灌得進去的東西（vehicle_mixer.lua：溜槽對準哪一格、E 就灌那一格）：方塊名 → function(pos) return ok, 原因 end。
-- 之後的地基模板等也登記在這裡
rockmech.pour_targets = rockmech.pour_targets or {}
rockmech.pour_targets[FRAME] = rockmech.tremie_pour

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
	for name in pairs(IS_WALL) do
		ids.retain_r[core.get_content_id(name)] = IS_BAD[name] and CONC_R * CRACK_R or CONC_R
		ids.pile[core.get_content_id(name)] = true
	end
	ids.retain_r[core.get_content_id(GUIDE)] = CONC_R
end)

-- 彈性支承梁（retain.lua 的 wall_solve 叫）：lo..hi 裡一欄一欄 1 m 厚的混凝土牆。
-- 牆的法向：那一欄每一格法向兩側都不是混凝土、沿牆方向有接著混凝土（或單獨一欄就看不出來，不算）
local function wall_cols(lo, hi)
	local out, seen = {}, {}
	for _, p in ipairs(core.find_nodes_in_area(lo, hi, {HARD, CRACKED, RC, RC_Y})) do
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
				-- 整欄都是鋼筋混凝土才算鋼筋混凝土牆（籠子沒放到的那幾格是素混凝土，從那裡斷）
				local fc, bent, rc = math.huge, false, true
				for _, c in ipairs(cells) do
					fc = math.min(fc, CC.fc(FC28, age_of(core.get_meta(c))))
					local n = name_at(c)
					if IS_BAD[n] then bent = true end
					if not IS_RC[n] then rc = false end
				end
				local col = {cells = cells, ax = xaxis and {x = 1, y = 0, z = 0} or {x = 0, y = 0, z = 1}, xaxis = xaxis,
					t = xaxis and p.z or p.x, plane = xaxis and p.x or p.z, bent = bent,
					EI = CC.ei(fc) * (rc and RC_EI or 1) * (bent and CRACK_R or 1)}
				col.check = function(r, t)
					if bent or #t.soil == 0 then return end
					-- 素混凝土：開裂彎矩 M_cr；鋼筋混凝土：極限彎矩 M_u（開裂由鋼筋接手）
					local Mcap = (rc and CC.mu(fc, AS, FY, D_EFF) or CC.mcr(fc)) / n_scale()
					if not r.ok or r.Mmax > Mcap then
						for _, c in ipairs(cells) do
							core.swap_node(c, {name = rc and RC_Y or CRACKED})
							core.get_meta(c):set_string("mtxt", "")
							hard_info(c)
						end
						local top = cells[1]
						core.sound_play("default_dug_node", {pos = top, gain = 1.0, max_hear_distance = 32}, true)
						-- 埋入不夠（土撐不住，形成機構）：牆被推動、跟著裂；不然就是彎矩超過開裂（素）／極限（鋼筋）彎矩
						tell_near(top, not r.ok and S("[Concrete] The concrete wall at @1 is not embedded deep enough: the soil pushed it over and it cracked", core.pos_to_string(top))
							or rc and S("[Concrete] The rebar in the wall at @1 yielded: the bending moment exceeded M_u", core.pos_to_string(top))
							or S("[Concrete] The plain concrete wall at @1 cracked in bending", core.pos_to_string(top)))
						core.log("action", ("[rockmech] 混凝土牆%s %s（%d m）"):format(not r.ok and "埋入不夠" or rc and "鋼筋降伏" or "彎裂", core.pos_to_string(top), #cells))
					else
						local txt = rc and S("Bending moment @1 kN·m/m / ultimate @2 kN·m/m (@3%)", d0(r.Mmax), d0(Mcap), d0(r.Mmax / Mcap * 100))
							or S("Bending moment @1 kN·m/m / cracking @2 kN·m/m (@3%)", d0(r.Mmax), d0(Mcap), d0(r.Mmax / Mcap * 100))
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

---------------------------------------------------------------------------
-- 鋼筋籠
---------------------------------------------------------------------------
-- 一欄一個籠子：mod storage "cage:x,z" = "下端 y,上端 y"
local storage = core.get_mod_storage()
local function cage_key(x, z) return "cage:" .. x .. "," .. z end
local function cage_of(x, z)
	local v = storage:get_string(cage_key(x, z))
	if v == "" then return nil end
	local a, b = v:match("^(-?%d+),(-?%d+)$")
	return tonumber(a), tonumber(b)
end
function rockmech.rebar_caged(p)
	local a, b = cage_of(p.x, p.z)
	return a and p.y >= a and p.y <= b
end

-- 畫面：一根格子框（主筋直的、箍筋每 0.5 m 一圈），長度照籠子。跟著區塊存檔；籠子整欄都灌好了就拿掉
local function cage_tex(len)
	local h = math.max(1, math.floor(len + 0.5)) * 16
	local t = {("[fill:16x%d:#00000000"):format(h)}
	for _, x in ipairs({1, 7, 14}) do t[#t + 1] = ("[fill:1x%d:%d,0:#7a5a40"):format(h, x) end
	for y = 0, h - 1, 8 do t[#t + 1] = ("[fill:16x1:0,%d:#5a4030"):format(y) end
	return table.concat(t, "^")
end
core.register_entity(CAGE_ENT, {
	initial_properties = {
		visual = "cube", textures = {"[fill:1x1:#00000000"}, use_texture_alpha = true, backface_culling = false,
		physical = false, pointable = false, static_save = true, collisionbox = {0, 0, 0, 0, 0, 0},
		visual_size = {x = 0.85, y = 1, z = 0.85},
	},
	setup = function(self, x, z, a, b)
		self.cx, self.cz, self.ya, self.yb = x, z, a, b
		local len = b - a + 1
		local t = cage_tex(len)
		self.object:set_properties({visual_size = {x = 0.85, y = len, z = 0.85}, textures = {"[fill:1x1:#00000000", "[fill:1x1:#00000000", t, t, t, t}})
		self.object:set_pos({x = x, y = (a + b) / 2, z = z})
	end,
	get_staticdata = function(self) return core.write_json({x = self.cx, z = self.cz, a = self.ya, b = self.yb}) end,
	on_activate = function(self, sd)
		local d = sd and sd ~= "" and core.parse_json(sd)
		if not d then self.object:remove(); return end
		self:setup(d.x, d.z, d.a, d.b)
	end,
	on_step = function(self, dtime)
		self.chk = (self.chk or 0) + dtime
		if self.chk < 3 then return end
		self.chk = 0
		-- 籠子拆了（storage 沒了），或整欄都是混凝土了：拿掉畫面
		local a, b = cage_of(self.cx, self.cz)
		if not a then self.object:remove(); return end
		for y = a, b do
			local n = name_at({x = self.cx, y = y, z = self.cz})
			if n ~= FRESH and not IS_WALL[n] then return end
		end
		self.object:remove()
	end,
})

-- 對著溝槽按右鍵：那一欄從槽口（支架那一層下面一格）到槽底放一個籠子
core.register_craftitem(CAGE, {
	description = S("Rebar cage\nRight-click a slurry trench: lowers a 1 m wide cage from the mouth to the bottom. Concrete poured around it becomes reinforced concrete"),
	short_description = S("Rebar cage"),
	inventory_image = "[fill:16x16:#00000000^[fill:1x14:3,1:#7a5a40^[fill:1x14:8,1:#7a5a40^[fill:1x14:12,1:#7a5a40"
		.. "^[fill:12x1:2,2:#5a4030^[fill:12x1:2,6:#5a4030^[fill:12x1:2,10:#5a4030^[fill:12x1:2,14:#5a4030",
	stack_max = 99,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local name = placer:get_player_name()
		local F = mouth_of(pointed.above)
		if not F then
			rockmech.notify(name, S("Point into a trench: the cage hangs from its mouth"))
			return itemstack
		end
		-- 槽口往下到槽底（混凝土頂上為止）
		local top, bot = F.y - 1, nil
		for y = top, top - DEPTH, -1 do
			if not fillable(name_at({x = F.x, y = y, z = F.z})) then break end
			bot = y
		end
		if not bot or top - bot < 1 then rockmech.notify(name, S("Point into a trench: the cage hangs from its mouth")); return itemstack end
		if cage_of(F.x, F.z) then rockmech.notify(name, S("This trench column already has a cage")); return itemstack end
		if core.is_protected(F, name) then return itemstack end
		storage:set_string(cage_key(F.x, F.z), bot .. "," .. top)
		local o = core.add_entity({x = F.x, y = (bot + top) / 2, z = F.z}, CAGE_ENT)
		local e = o and o:get_luaentity()
		if e then e:setup(F.x, F.z, bot, top) end
		core.sound_play("default_place_node_metal", {pos = F, gain = 0.8}, true)
		rockmech.notify(name, S("Rebar cage lowered: @1 m", top - bot + 1))
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
})
-- 籠子那一欄的混凝土被挖掉、或抓斗又挖了：籠子記錄跟著那一欄的混凝土走，不另外處理；
-- 那一欄全部挖空（沒有穩定液、沒有混凝土）時拿掉記錄（下次放籠子不會說「已經有了」）
core.register_on_dignode(function(pos)
	local a, b = cage_of(pos.x, pos.z)
	if not a or pos.y < a - 1 or pos.y > b + 1 then return end
	for y = a, b do
		local n = name_at({x = pos.x, y = y, z = pos.z})
		if n == FRESH or IS_WALL[n] or lvl[n] then return end
	end
	storage:set_string(cage_key(pos.x, pos.z), "")
end)

---------------------------------------------------------------------------
-- 導溝
---------------------------------------------------------------------------
-- 換得掉的：空氣、土、碎石、鬆土（岩盤不用導溝）
local function soft_ground(n)
	if n == "air" or (rockmech.air_like and rockmech.air_like(n)) then return true end
	local g = core.registered_nodes[n] and core.registered_nodes[n].groups or {}
	return (g.rockmech_topsoil or 0) > 0 or (g.rockmech_rubble or 0) > 0 or n == "rockmech:subsoil"
		or (rockmech.is_rubble and rockmech.is_rubble(n))
end
core.register_node(GUIDE, {
	description = S("Guide wall\nRight-click the ground: builds a 1 m length of guide walls on both sides of the trench line, along the way you look. With guide walls at the mouth, concrete can be poured right up to the top"),
	short_description = S("Guide wall"),
	tiles = {TEX .. "^[fill:16x2:0,0:#8e8e88^[fill:16x2:0,14:#8e8e88", TEX, TEX},
	inventory_image = "[fill:16x16:#00000000^[fill:4x12:2,3:#a3a39c^[fill:4x12:10,3:#a3a39c^[fill:4x2:2,3:#8e8e88^[fill:4x2:10,3:#8e8e88",
	is_ground_content = false,
	groups = {cracky = 1, rockmech_concrete = 3},
	drop = "",
	sounds = default and default.node_sound_stone_defaults and default.node_sound_stone_defaults() or nil,
	after_dig_node = function(pos) waste_after_dig(pos) end,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local un = core.get_node(pointed.under)
		local udef = core.registered_nodes[un.name]
		if udef and udef.on_rightclick and not placer:get_player_control().sneak then
			return udef.on_rightclick(pointed.under, un, placer, itemstack, pointed) or itemstack
		end
		local name = placer:get_player_name()
		local G = pointed.under
		if pointed.above.y ~= G.y + 1 then
			rockmech.notify(name, S("Point at the top of the ground where the trench will be"))
			return itemstack
		end
		-- 溝槽線沿你看的方向；導溝在兩側（法向 ±1）、從地面往下 GUIDE_D 格
		local d = placer:get_look_dir()
		local nx, nz = 0, 0
		if math.abs(d.x) >= math.abs(d.z) then nz = 1 else nx = 1 end
		local cells = {}
		for _, s in ipairs({1, -1}) do
			for dy = 0, GUIDE_D - 1 do
				local q = {x = G.x + s * nx, y = G.y - dy, z = G.z + s * nz}
				local n = name_at(q)
				if n ~= GUIDE then
					if not soft_ground(n) or core.is_protected(q, name) then
						rockmech.notify(name, S("Guide walls go in soil, not rock"))
						return itemstack
					end
					cells[#cells + 1] = q
				end
			end
		end
		if #cells == 0 then return itemstack end
		for _, q in ipairs(cells) do
			core.set_node(q, {name = GUIDE})
			rockmech.collapse.mark_excavated(q)     -- 天然地形那一解照原本的土算
		end
		core.sound_play("default_place_node", {pos = G, gain = 0.8}, true)
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		queue_fem(G)
		return itemstack
	end,
})

dofile(rockmech.modpath .. "/vehicle_mixer.lua")
