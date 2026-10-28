-- rockmech/groundsupport.lua
-- 支護：岩栓、噴凝土（隧道與邊坡都能用）。力學見 support.lua：換算成臨空面上的等效圍壓 pᵢ，
-- 進到軸差（Hoek-Brown σ3）、節理弱面（σn）與關鍵塊體／整體滑動的判定。參數在設定 rockmech_support_*。
--   岩栓：先用鑿岩機鑽孔，再拿岩栓對著鑽孔按右鍵裝進去（孔口一塊墊板）。
--   噴凝土：對岩面按右鍵，噴這一面 3×3 格（用掉一袋）；噴到的空氣格變成一層薄噴凝土，這格周圍的岩面都算噴到。
--     噴凝土不擋視線，可以隔著它挖、鑽孔（鑽孔的那格噴凝土會被孔取代）。
--   支護後面的岩石沒了（挖掉、爆破、坍塌）就跟著消失；爆炸會直接炸掉。

local scfg = rockmech.cfg.support
local HOLE = "rockmech:drill_hole"
local LINING = "rockmech:shotcrete_lining"
local BOLT = "rockmech:rock_bolt_set"       -- 裝好的岩栓（方塊）
local BOLT_ITEM = "rockmech:rock_bolt"
local SHOTCRETE = "rockmech:shotcrete"

local function is_rock(name)
	local def = core.registered_nodes[name]
	return def and def.groups and (def.groups.rockmech_rock or 0) > 0
end
local function tell(player, msg)
	if player and player:is_player() then core.chat_send_player(player:get_player_name(), "[支護] " .. msg) end
end
local function creative(player)
	return core.is_creative_enabled(player and player:is_player() and player:get_player_name() or "")
end

-- 噴凝土層：空氣格裡貼著相鄰岩面的薄板（connected nodebox，只畫有岩石的那幾面）
do
	local T = 0.06
	local tex = "[fill:16x16:#a4a29c^[fill:2x2:3,4:#8e8c86^[fill:2x2:10,2:#b4b2ac^[fill:2x2:6,11:#8e8c86^[fill:2x2:12,9:#b4b2ac"
	core.register_node(LINING, {
		description = "噴凝土層 Shotcrete lining",
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
		walkable = false, pointable = false, buildable_to = true, is_ground_content = false,
		drop = "", groups = {not_in_creative_inventory = 1},
	})
end

-- 裝好的岩栓：孔口的方形墊板與螺帽（貼壁，param2 指向岩面）
do
	local steel, plate = "[fill:16x16:#8a8a86^[fill:4x4:6,6:#6a6a66", "[fill:16x16:#7a7a76"
	core.register_node(BOLT, {
		description = "岩栓 Rock bolt (installed)",
		drawtype = "nodebox", paramtype = "light", paramtype2 = "wallmounted", sunlight_propagates = true,
		node_box = {type = "fixed", fixed = {
			{-0.22, -0.5, -0.22, 0.22, -0.45, 0.22},      -- 墊板
			{-0.07, -0.45, -0.07, 0.07, -0.36, 0.07},     -- 螺帽
		}},
		selection_box = {type = "fixed", fixed = {{-0.25, -0.5, -0.25, 0.25, -0.34, 0.25}}},
		tiles = {steel, plate, plate, plate, plate, plate},
		walkable = false, is_ground_content = false, diggable = false,
		drop = "", groups = {not_in_creative_inventory = 1},
	})
end

-- 岩栓：對鑽孔按右鍵裝進去
core.register_craftitem(BOLT_ITEM, {
	description = ("岩栓 Rock bolt\n對鑽孔按右鍵裝進去（長 %.1f m、錨定力 %d kN）"):format(scfg.bolt_l, scfg.bolt_t),
	inventory_image = "[fill:16x16:#00000000^[fill:2x11:7,1:#a8a8a4^[fill:8x2:4,12:#6a6a66^[fill:4x2:6,10:#8a8a86",
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" then return itemstack end
		local p = pointed.under
		local node = core.get_node(p)
		if node.name ~= HOLE then
			tell(placer, "岩栓要裝進鑽孔（先用鑿岩機鑽孔，再對孔按右鍵）")
			return itemstack
		end
		core.swap_node(p, {name = BOLT, param2 = node.param2})
		core.get_meta(p):set_string("infotext", ("岩栓（長 %.1f m、錨定力 %d kN）"):format(scfg.bolt_l, scfg.bolt_t))
		if not creative(placer) then itemstack:take_item() end
		return itemstack
	end,
})

-- 噴凝土：對岩面按右鍵，噴這一面 3×3 格
core.register_craftitem(SHOTCRETE, {
	description = ("噴凝土 Shotcrete（一袋）\n對岩面按右鍵，噴這一面 3×3 格（支護壓力 %.2f MPa）"):format(scfg.shotcrete_p),
	inventory_image = "[fill:16x16:#00000000^[fill:10x12:3,3:#b8b6b0^[fill:10x2:3,3:#8e8c86^[fill:6x3:5,8:#5a6a8a",
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" then return itemstack end
		-- 岩面 rock 與往外的法向 n：指著岩石就是那一面；指著鑽孔、岩栓就是它貼著的岩面
		local rock, n = pointed.under, vector.subtract(pointed.above, pointed.under)
		local un = core.get_node(rock)
		if not is_rock(un.name) then
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
			if is_rock(core.get_node(r).name) and core.get_node(a).name == "air" then
				core.set_node(a, {name = LINING})
				count = count + 1
			end
		end end
		if count == 0 then
			tell(placer, "這裡已經噴過了（或岩面前面不是空的）")
		elseif not creative(placer) then
			itemstack:take_item()
		end
		return itemstack
	end,
})

-- 後面的岩石沒了：噴凝土（周圍沒有岩面）、岩栓（貼著的那格不是岩石）跟著消失
core.register_abm({
	label = "rockmech: 支護跟著岩面消失",
	nodenames = {LINING, BOLT}, interval = 2, chance = 1,
	action = function(pos, node)
		if node.name == BOLT then
			if not is_rock(core.get_node(vector.add(pos, core.wallmounted_to_dir(node.param2))).name) then
				core.remove_node(pos)
			end
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
	rockmech.support_ids = {
		lining = {[core.get_content_id(LINING)] = true},
		bolt = {[core.get_content_id(BOLT)] = true},
	}
end)
