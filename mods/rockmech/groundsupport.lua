-- rockmech/groundsupport.lua
-- 支護：岩栓、噴凝土（隧道與邊坡都能用）。力學見 support.lua：換算成臨空面上的等效圍壓 pᵢ，
-- 進到軸差（Hoek-Brown σ3）、節理弱面（σn）與關鍵塊體／整體滑動的判定。參數在設定 rockmech_support_*。
--   岩栓：先用鑿岩機鑽孔，再拿岩栓對著鑽孔按右鍵裝進去（孔口一塊墊板）。
--   岩栓長度 = 裝進去的鑽孔孔深（手動鑿岩機對孔繼續按住可以加深，見 drilling.lua）。挖掉岩栓 → 變回鑽孔、岩栓退還。
--   岩栓經過的岩石被挖掉時，露出的岩面上看得到岩栓的斷面（小黑點），看得出岩栓打多深。
--   噴凝土：對岩面按右鍵，噴這一面 3×3 格（用掉一袋）；噴到的空氣格變成一層薄噴凝土，這格周圍的岩面都算噴到。
--     重複噴就加厚，最多 3 層（rockmech.SHOTCRETE_LAYERS），支護壓力 = 層數 × p_sc；孔、裝藥、岩栓都保留層數。
--     可以挖掉（不退還）；鑿岩機對著噴凝土鑽就是鑽後面的岩面（那格噴凝土會被孔取代）。
--   噴凝土岩栓：同一格同時是岩栓與噴凝土。對岩栓噴凝土、或把岩栓裝進噴凝土鑽孔就是這個方塊。
--   噴過凝土的孔（drilling.lua）：鑽孔、裝藥鑽孔、ANFO 鑽孔都有，功能同一般的孔，這格也算噴凝土。
--     對孔噴凝土、或鑽穿噴凝土就是這些方塊；之後裝藥、裝岩栓都維持噴過凝土。
--   支護後面的岩石沒了（挖掉、爆破、坍塌）就跟著消失；爆炸會直接炸掉。

local scfg = rockmech.cfg.support
local HOLE = "rockmech:drill_hole"
local LINING = "rockmech:shotcrete_lining"
local BOLT = "rockmech:rock_bolt_set"       -- 裝好的岩栓（方塊）
local BOLT_SC = "rockmech:rock_bolt_sprayed"  -- 噴了凝土的岩栓
local MAX_LAYERS = rockmech.SHOTCRETE_LAYERS
local LININGS, BOLTS_SC, BOLT_LAYERS = {}, {}, {}     -- 第 n 層的方塊；岩栓方塊 → 層數
for n = 1, MAX_LAYERS do
	local suffix = n > 1 and ("_" .. n) or ""
	LININGS[n], BOLTS_SC[n] = LINING .. suffix, BOLT_SC .. suffix
	BOLT_LAYERS[BOLTS_SC[n]] = n
	if n > 1 then rockmech.spray_next[LININGS[n - 1]] = LININGS[n] end
	rockmech.spray_next[n > 1 and BOLTS_SC[n - 1] or BOLT] = BOLTS_SC[n]
end
local BOLT_ITEM = "rockmech:rock_bolt"
local SHOTCRETE = "rockmech:shotcrete"
local function is_rock(name)
	local def = core.registered_nodes[name]
	return def and def.groups and (def.groups.rockmech_rock or 0) > 0
end
-- 岩栓斷面：岩栓經過的岩石被挖掉後，露出的岩面上（與岩栓垂直的那一面）看得到岩栓的斷面，一個小黑點。
-- 放在挖空的那格（貼壁方塊）：SEC1 只有貼著的那一面有點；SEC2 兩端都有（前後都是岩石）
local SEC1 = "rockmech:rock_bolt_section"
local SEC2 = "rockmech:rock_bolt_section2"
local function opposite(p2) return p2 % 2 == 0 and p2 + 1 or p2 - 1 end   -- 貼壁方向反過來（0↔1、2↔3、4↔5）

-- 岩栓的長度（= 孔深）與沿著岩栓的第 s 格
local function bolt_len(pos)
	local v = core.get_meta(pos):get_float("depth")
	return v > 0 and v or rockmech.cfg.blast.hole_depth
end
-- 長度 L 的錨定力 (kN)：min(握裹力 × L, 鋼材降伏)
local function capacity(L) return math.min(scfg.bolt_grip * L, scfg.bolt_yield) end
local function along(pos, param2, s)
	return vector.add(pos, vector.multiply(core.wallmounted_to_dir(param2), s))
end
local function is_rock_at(p) return is_rock(core.get_node(p).name) end
local function is_bolt(name) return name == BOLT or BOLT_LAYERS[name] ~= nil end
-- 岩栓經過、已經挖空的格子：前後（沿岩栓）在岩栓範圍內還是岩石的那一面畫斷面；拆掉岩栓時一起清掉
local function rods_update(pos, node)
	local n = math.ceil(bolt_len(pos) - 1e-6)
	-- 被挖斷：從孔口往裡第一個不是岩石的格子之前才有效（後面那截跟墊板分開了）
	local eff = n
	for s = 1, n do
		if not is_rock_at(along(pos, node.param2, s)) then eff = s - 1; break end
	end
	local meta = core.get_meta(pos)
	if meta:get_int("eff") ~= eff + 1 then
		meta:set_int("eff", eff + 1)
		meta:set_string("infotext", eff < n
			and ("岩栓（長 %g m，在 %d m 處被挖斷：只剩前 %d m 錨在岩石裡、錨定力 %d kN）"):format(bolt_len(pos), eff, eff, capacity(eff))
			or ("岩栓（長 %g m、錨定力 %d kN）"):format(bolt_len(pos), capacity(bolt_len(pos))))
	end
	for s = 1, n do
		local c = along(pos, node.param2, s)
		local cn = core.get_node(c).name
		if cn == "air" or cn == SEC1 or cn == SEC2 then
			local back = s > 1 and is_rock_at(along(pos, node.param2, s - 1))   -- 靠孔口那一側
			local deep = s < n and is_rock_at(along(pos, node.param2, s + 1))   -- 岩栓更深處那一側
			local want
			if back and deep then want = {name = SEC2, param2 = node.param2}
			elseif deep then want = {name = SEC1, param2 = node.param2}
			elseif back then want = {name = SEC1, param2 = opposite(node.param2)} end
			local cur = core.get_node(c)
			if want and (cur.name ~= want.name or cur.param2 ~= want.param2) then core.set_node(c, want)
			elseif not want and cn ~= "air" then core.remove_node(c) end
		end
	end
end
local function rods_remove(pos, param2, len)
	for s = 1, math.ceil(len - 1e-6) do
		local c = along(pos, param2, s)
		local cn = core.get_node(c).name
		if cn == SEC1 or cn == SEC2 then core.remove_node(c) end
	end
end
-- 斷面所屬的岩栓還在、而且長度涵蓋這一格？
local function section_owned(pos, node)
	for _, p2 in ipairs({node.param2, opposite(node.param2)}) do
		for s = 1, 20 do
			local b = along(pos, p2, -s)
			local bn = core.get_node(b)
			if is_bolt(bn.name) and (bn.param2 == node.param2 or bn.param2 == opposite(node.param2))
					and vector.equals(along(b, bn.param2, s), pos) and bolt_len(b) > s - 1e-6 then
				return true
			end
		end
	end
	return false
end

local function tell(player, msg)
	if player and player:is_player() then core.chat_send_player(player:get_player_name(), "[支護] " .. msg) end
end
local function creative(player)
	return core.is_creative_enabled(player and player:is_player() and player:get_player_name() or "")
end

-- 被碎石蓋住的噴凝土：一格只能有一個方塊，碎石會取代薄板。記下來（存在世界裡，鍵 "sc:x,y,z"），碎石清走時放回去。
-- 蓋住的期間沒有支護壓力，改由碎石的反力頂著
local SC_PREFIX = "sc:"
local buried = {}
core.register_on_mods_loaded(function()
	for k, v in pairs(rockmech.collapse.storage:to_table().fields) do
		if k:sub(1, #SC_PREFIX) == SC_PREFIX then buried[k:sub(#SC_PREFIX + 1)] = v end
	end
end)
local function bury(pos, name)
	core.after(0, function()
		if rockmech.rubble_level[core.get_node(pos).name] then
			local k = core.pos_to_string(pos)
			buried[k] = name
			rockmech.collapse.storage:set_string(SC_PREFIX .. k, name)
		end
	end)
end
-- pos 的碎石移走了：底下有噴凝土就放回去
function rockmech.shotcrete_uncover(pos)
	local k = core.pos_to_string(pos)
	local name = buried[k]
	if not name then return end
	local p = {x = pos.x, y = pos.y, z = pos.z}
	core.after(0, function()
		if core.get_node(p).name ~= "air" or buried[k] ~= name then return end
		buried[k] = nil
		rockmech.collapse.storage:set_string(SC_PREFIX .. k, "")
		core.set_node(p, {name = name})
		if rockmech.cfg.fem.drive then rockmech.fem_queue(p, 1, true) end
	end)
end

-- 噴凝土層：空氣格裡貼著相鄰岩面的薄板（connected nodebox，只畫有岩石的那幾面），層數越多越厚
for n = 1, MAX_LAYERS do
	local T = 0.06 * n
	local tex = "[fill:16x16:#a4a29c^[fill:2x2:3,4:#8e8c86^[fill:2x2:10,2:#b4b2ac^[fill:2x2:6,11:#8e8c86^[fill:2x2:12,9:#b4b2ac"
	core.register_node(LININGS[n], {
		description = ("噴凝土層 %d 層 Shotcrete lining"):format(n),
		drawtype = "nodebox", paramtype = "light", sunlight_propagates = true,
		node_box = {type = "connected", fixed = {},
			connect_top = {-0.5, 0.5 - T, -0.5, 0.5, 0.5, 0.5},
			connect_bottom = {-0.5, -0.5, -0.5, 0.5, -0.5 + T, 0.5},
			connect_front = {-0.5, -0.5, -0.5, 0.5, 0.5, -0.5 + T},
			connect_back = {-0.5, -0.5, 0.5 - T, 0.5, 0.5, 0.5},
			connect_left = {-0.5, -0.5, -0.5, -0.5 + T, 0.5, 0.5},
			connect_right = {0.5 - T, -0.5, -0.5, 0.5, 0.5, 0.5},
		},
		connects_to = {"group:rockmech_rock"},
		tiles = {tex},
		walkable = false, buildable_to = true, is_ground_content = false,
		drop = "", groups = {cracky = 3, not_in_creative_inventory = 1, shotcrete = n, shotcrete_lining = n},
		on_destruct = function(pos) bury(pos, LININGS[n]) end,
		after_dig_node = function(pos)
			if rockmech.cfg.fem.drive then rockmech.fem_queue(pos, 1) end
		end,
	})
end

-- 支護變了：重新解應力
local function resolve(pos)
	if rockmech.cfg.fem.drive then rockmech.fem_queue(pos, 1) end
end

-- 裝好的岩栓：孔口的方形墊板與螺帽（貼壁，param2 指向岩面）
do
	local steel, plate = "[fill:16x16:#8a8a86^[fill:4x4:6,6:#6a6a66", "[fill:16x16:#7a7a76"
	local PLATE = {-0.22, -0.5, -0.22, 0.22, -0.45, 0.22}
	local NUT = {-0.07, -0.45, -0.07, 0.07, -0.36, 0.07}
	local lining = "[fill:16x16:#a4a29c^[fill:2x2:3,4:#8e8c86^[fill:2x2:10,2:#b4b2ac^[fill:2x2:6,11:#8e8c86^[fill:2x2:12,9:#b4b2ac"
	local sprayed_top = lining .. "^[fill:10x10:3,3:#8a8a86^[fill:4x4:6,6:#6a6a66"    -- 墊板與螺帽同岩栓
	local sprayed_side = lining .. "^[fill:16x2:0,13:#7a7a76"
	local list = {{BOLT, "岩栓 Rock bolt (installed)", {PLATE, NUT}, {steel, plate, plate, plate, plate, plate}, -0.34}}
	for n = 1, MAX_LAYERS do
		local t = -0.5 + 0.06 * n
		list[#list + 1] = {BOLTS_SC[n], ("噴凝土岩栓 %d 層 Rock bolt with shotcrete"):format(n),
			{{-0.5, -0.5, -0.5, 0.5, t, 0.5}, {-0.22, t, -0.22, 0.22, t + 0.04, 0.22}, {-0.07, t + 0.04, -0.07, 0.07, t + 0.12, 0.07}},
			{sprayed_top, lining, sprayed_side, sprayed_side, sprayed_side, sprayed_side}, t + 0.14, n}
	end
	for _, v in ipairs(list) do
		core.register_node(v[1], {
			description = v[2],
			drawtype = "nodebox", paramtype = "light", paramtype2 = "wallmounted", sunlight_propagates = true,
			node_box = {type = "fixed", fixed = v[3]},
			selection_box = {type = "fixed", fixed = {{-0.25, -0.5, -0.25, 0.25, v[5], 0.25}}},
			tiles = v[4],
			walkable = false, is_ground_content = false,
			drop = "", groups = {dig_immediate = 2, not_in_creative_inventory = 1, shotcrete = v[6]},
			-- 拆掉：變回鑽孔（孔深不變；噴凝土岩栓變回噴凝土鑽孔），岩栓還給玩家
			on_dig = function(pos, node, digger)
				rods_remove(pos, node.param2, bolt_len(pos))
				core.swap_node(pos, {name = rockmech.hole_variant(HOLE, BOLT_LAYERS[node.name] or 0), param2 = node.param2})
				local meta = core.get_meta(pos)
				local len = meta:get_float("depth")
				meta:set_string("infotext", ("鑽孔（深 %g m）"):format(len > 0 and len or rockmech.cfg.blast.hole_depth))
				if digger and digger:is_player() and not creative(digger) then
					local left = digger:get_inventory():add_item("main", ItemStack(BOLT_ITEM))
					if not left:is_empty() then core.add_item(pos, left) end
				end
				resolve(pos)
				return true
			end,
		})
	end
end

-- 岩栓斷面（岩面上的小黑點）：貼壁方塊，點畫在貼著的那一面；SEC2 對面也有一點
do
	local DOT = {-0.07, -0.5, -0.07, 0.07, -0.49, 0.07}
	local tex = "[fill:16x16:#151515^[fill:16x2:0,0:#3a3a38^[fill:16x2:0,14:#3a3a38"
	for _, v in ipairs({{SEC1, {DOT}}, {SEC2, {DOT, {-0.07, 0.49, -0.07, 0.07, 0.5, 0.07}}}}) do
		core.register_node(v[1], {
			description = "岩栓斷面 Rock bolt section",
			drawtype = "nodebox", paramtype = "light", paramtype2 = "wallmounted", sunlight_propagates = true,
			node_box = {type = "fixed", fixed = v[2]},
			tiles = {tex},
			walkable = false, pointable = false, diggable = false, buildable_to = true, is_ground_content = false,
			drop = "", groups = {not_in_creative_inventory = 1},
		})
	end
end

-- 岩栓：對鑽孔按右鍵裝進去
core.register_craftitem(BOLT_ITEM, {
	description = ("岩栓 Rock bolt\n對鑽孔按右鍵裝進去（長度 = 孔深；錨定力 = 握裹力 %d kN/m × 長度，上限 %d kN）")
		:format(scfg.bolt_grip, scfg.bolt_yield),
	inventory_image = "[fill:16x16:#00000000^[fill:2x11:7,1:#a8a8a4^[fill:8x2:4,12:#6a6a66^[fill:4x2:6,10:#8a8a86",
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" then return itemstack end
		local p = pointed.under
		local node = core.get_node(p)
		if rockmech.hole_kind(node.name) ~= HOLE then
			tell(placer, "岩栓要裝進鑽孔（先用鑿岩機鑽孔，再對孔按右鍵）")
			return itemstack
		end
		local layers = core.get_item_group(node.name, "shotcrete")
		core.swap_node(p, {name = layers > 0 and BOLTS_SC[layers] or BOLT, param2 = node.param2})
		local meta = core.get_meta(p)
		local len = meta:get_float("depth")
		if len <= 0 then len = rockmech.cfg.blast.hole_depth end
		meta:set_string("infotext", ("岩栓（長 %g m、錨定力 %d kN）"):format(len, capacity(len)))
		if not creative(placer) then itemstack:take_item() end
		resolve(p)
		return itemstack
	end,
})

-- 噴凝土：對岩面按右鍵，噴這一面 3×3 格
core.register_craftitem(SHOTCRETE, {
	description = ("噴凝土 Shotcrete（一袋）\n對岩面按右鍵，噴這一面 3×3 格（支護壓力 %.2f MPa）\n重複噴可以加厚，最多 %d 層，壓力照層數累加")
		:format(scfg.shotcrete_p, MAX_LAYERS),
	inventory_image = "[fill:16x16:#00000000^[fill:10x12:3,3:#b8b6b0^[fill:10x2:3,3:#8e8c86^[fill:6x3:5,8:#5a6a8a",
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" then return itemstack end
		-- 岩面 rock 與往外的法向 n：指著岩石就是那一面；指著鑽孔、岩栓就是它貼著的岩面
		local rock, n = pointed.under, vector.subtract(pointed.above, pointed.under)
		local un = core.get_node(rock)
		if core.get_item_group(un.name, "shotcrete_lining") > 0 then
			-- 指著已經噴過的那層：噴它後面的岩面
			rock = vector.subtract(rock, n)
		elseif not is_rock(un.name) then
			local def = core.registered_nodes[un.name]
			if def and def.paramtype2 == "wallmounted" then
				local d = core.wallmounted_to_dir(un.param2)
				rock, n = vector.add(rock, d), vector.multiply(d, -1)
			end
		end
		if not is_rock(core.get_node(rock).name) then
			tell(placer, "噴凝土要噴在岩面上")
			return itemstack
		end
		local count = 0
		for u = -1, 1 do for v = -1, 1 do
			local off = n.x ~= 0 and {x = 0, y = u, z = v} or n.y ~= 0 and {x = u, y = 0, z = v} or {x = u, y = v, z = 0}
			local r = vector.add(rock, off)
			local a = vector.add(r, n)
			local an = core.get_node(a)
			-- 空氣格：第一層；噴過的格、這一面的岩栓、鑽孔、裝藥：再加一層（已經滿了就跳過）
			local nxt = rockmech.spray_next[an.name]
			local here = core.get_item_group(an.name, "shotcrete_lining") > 0
				or vector.equals(core.wallmounted_to_dir(an.param2), vector.multiply(n, -1))
			if is_rock(core.get_node(r).name) then
				if an.name == "air" then
					core.set_node(a, {name = LINING})
					count = count + 1
				elseif nxt and here then
					core.swap_node(a, {name = nxt, param2 = an.param2})
					count = count + 1
				end
			end
		end end
		if count == 0 then
			tell(placer, ("這裡已經噴滿 %d 層了（或岩面前面不是空的）"):format(MAX_LAYERS))
		elseif not creative(placer) then
			itemstack:take_item()
		end
		if count > 0 then resolve(rock) end
		return itemstack
	end,
})

-- 後面的岩石沒了：噴凝土（周圍沒有岩面）、岩栓（貼著的那格不是岩石）跟著消失；
-- 岩栓經過的格子被挖空 → 岩面上畫岩栓斷面；找不到自己的岩栓的斷面消失
core.register_abm({
	label = "rockmech: 支護跟著岩面消失",
	nodenames = (function()
		local t = {BOLT, SEC1, SEC2}
		for n = 1, MAX_LAYERS do t[#t + 1] = LININGS[n]; t[#t + 1] = BOLTS_SC[n] end
		return t
	end)(), interval = 2, chance = 1,
	action = function(pos, node)
		if is_bolt(node.name) then
			if not is_rock(core.get_node(along(pos, node.param2, 1)).name) then
				rods_remove(pos, node.param2, bolt_len(pos))
				core.remove_node(pos)
			else
				rods_update(pos, node)
			end
			return
		end
		if node.name == SEC1 or node.name == SEC2 then
			if not section_owned(pos, node) then core.remove_node(pos) end
			return
		end
		for _, d in ipairs({{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0}, {x = 0, y = 1, z = 0},
				{x = 0, y = -1, z = 0}, {x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1}}) do
			if is_rock(core.get_node(vector.add(pos, d)).name) then return end
		end
		core.remove_node(pos)
	end,
})

-- 判定用的方塊 id（collapse.read_grid 讀網格時找支護）
core.register_on_mods_loaded(function()
	local ids = {lining = {}, bolt = {[core.get_content_id(BOLT)] = true}}
	for name, def in pairs(core.registered_nodes) do
		local n = def.groups and def.groups.shotcrete
		if n then ids.lining[core.get_content_id(name)] = n end
		if BOLT_LAYERS[name] then ids.bolt[core.get_content_id(name)] = true end
	end
	rockmech.support_ids = ids
end)
