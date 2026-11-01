-- rockmech/career.lua
-- 經營模式（rockmech_career = true，世界要關掉創造模式）：從一把免費的鎬子開始賺錢，再到帳篷下的供應商買設備。
--   徒手只敲得動礦石，一塊 rockmech_hand_ore_time 秒；鎬子什麼岩石都能挖，也很慢。敲開的岩石原地變成碎石；
--   挖碎石就是把它拿起來，人只能拿一塊（滿格），不進物品欄，右鍵放下，或對著車斗按右鍵裝上去。
--   世界不掉落岩石和碎石，礦都要實際搬到破碎站才換得到錢。
--   第一次進世界在出生點旁蓋好帳篷（供應商）和一座破碎站。

local cfg = rockmech.cfg
if not cfg.career then return end

local V = rockmech.vehicles
local storage = rockmech.collapse.storage
local NLEV = V.NLEV

local PICK = "rockmech:pick"
local CARRY_KEY = "rockmech:carry"
local SITE_KEY = "career_site"
local SHOP = "rockmech:shop"
local VENDOR = "rockmech:vendor"
local CAMP_Z = 14           -- 帳篷中心在出生點北邊幾公尺
local CRUSHER_X = 16        -- 破碎站機身在帳篷東邊幾公尺

-- 主選單的創造模式開關是全域設定，不見得跟著世界走：經營模式一律不是創造模式
function core.is_creative_enabled() return false end

---------------------------------------------------------------------------
-- 世界不掉落岩石和碎石
---------------------------------------------------------------------------

local function is_rock(name)
	return rockmech.lith_of_node[name] or rockmech.rubble_level[name] or rockmech.road_level[name]
		or core.get_item_group(name, "stone") > 0
end

local handle_drops = core.handle_node_drops
function core.handle_node_drops(pos, drops, digger)
	local keep = {}
	for _, d in ipairs(drops) do
		if not is_rock(ItemStack(d):get_name()) then keep[#keep + 1] = d end
	end
	if #keep > 0 then handle_drops(pos, keep, digger) end
end

local add_item = core.add_item
function core.add_item(pos, item)
	if is_rock(ItemStack(item):get_name()) then return nil end
	return add_item(pos, item)
end

---------------------------------------------------------------------------
-- 拿在手上的碎石
---------------------------------------------------------------------------

local carry_hud = {}        -- 玩家名稱 → HUD id
local carry_img = {}        -- 玩家名稱 → 手上那塊碎石的 HUD id

-- 手上的碎石畫成畫面右下方的方塊，貼圖跟著種類與品位
local function cube(c)
	local t = V.rubble_tex(rockmech.rubble_with_level(c.base, NLEV, c.p2)):gsub("%^", "&")
	return ("[inventorycube{%s{%s{%s"):format(t, t, t)
end

local function carried(player)
	local s = player:get_meta():get_string(CARRY_KEY)
	return s ~= "" and core.deserialize(s) or nil
end
local function show_carry(player, c)
	local name = player:get_player_name()
	local text = ""
	if c then
		local ore = rockmech.ore_of_rubble[c.base]
		text = ("手上：%s　%d / %d 級%s"):format(core.registered_nodes[c.base].description:gsub("\n.*", ""), c.lv, NLEV,
			ore and ("　" .. rockmech.ore_text(ore, c.p2 / 255)) or "")
	end
	if carry_hud[name] then
		player:hud_change(carry_hud[name], "text", text)
	else
		carry_hud[name] = player:hud_add({type = "text", position = {x = 0.5, y = 0.8}, alignment = {x = 0, y = 0},
			number = 0xFFE080, text = text, z_index = 100})
	end
	local img = c and cube(c) or ""
	if carry_img[name] then
		player:hud_change(carry_img[name], "text", img)
	else
		carry_img[name] = player:hud_add({type = "image", position = {x = 0.74, y = 0.84}, alignment = {x = 0, y = 0},
			scale = {x = 5, y = 5}, text = img, z_index = 90})
	end
end
local function set_carried(player, c)
	player:get_meta():set_string(CARRY_KEY, c and core.serialize(c) or "")
	show_carry(player, c)
end

-- 手上的碎石裝上車：回傳有沒有裝。沒拿東西、或這台車沒有車斗就回 false，照常上車
function rockmech.career_load(player, self, def)
	local c = carried(player)
	if not c or (def.cap or 0) <= 0 then return false end
	local put = math.min(c.lv, def.cap - V.load_total(self))
	if put <= 0 then
		core.chat_send_player(player:get_player_name(), "車斗滿了")
		return true
	end
	V.load_put(self, c.base, put, c.p2)
	V.refresh(self)
	c.lv = c.lv - put
	set_carried(player, c.lv > 0 and c or nil)
	return true
end

-- 放下手上的碎石（落在 pos 這一欄，會往下掉，也會依安息角流開）
local function put_down(player, pos)
	local c = carried(player)
	if not c then return end
	local rest = V.deposit_column(pos.x, pos.z, pos.y, c.base, c.lv, nil, nil, c.p2)
	c.lv = rest
	set_carried(player, rest > 0 and c or nil)
end

local node_dig = core.node_dig
function core.node_dig(pos, node, digger)
	if not digger or not digger:is_player() then return node_dig(pos, node, digger) end
	if rockmech.rubble_level[node.name] then
		-- 挖碎石就是拿起來，人只拿得動一塊
		local c = carried(digger)
		local name = digger:get_player_name()
		local base = rockmech.rubble_base[node.name]
		if c and c.lv >= NLEV then
			core.chat_send_player(name, "手上拿滿了：右鍵放下，或對著車斗按右鍵裝上去")
			return false
		end
		if c and not rockmech.rubble_mixable(c.base, base) then
			core.chat_send_player(name, "手上是別種碎石，先放下")
			return false
		end
		local t, b, p2 = V.take_rubble(pos, NLEV - (c and c.lv or 0))
		if c then
			local nb, g = rockmech.rubble_merge(c.base, c.lv, c.p2, b, t, p2)
			c = {base = nb, lv = c.lv + t, p2 = g}
		else
			c = {base = b, lv = t, p2 = p2}
		end
		set_carried(digger, c)
		return true
	end
	if rockmech.lith_of_node[node.name] then
		-- 岩石挖開就是原地一格碎石，品位留著
		local rn, rp = rockmech.rubble_node(node)
		local ok = node_dig(pos, node, digger)
		if ok ~= false and core.get_node(pos).name == "air" then core.set_node(pos, {name = rn, param2 = rp}) end
		return ok
	end
	return node_dig(pos, node, digger)
end

-- 右鍵：點到方塊的右鍵功能優先，否則放下手上的碎石（鎬子和空手共用）
local function place(itemstack, placer, pointed)
	if pointed.type ~= "node" then return itemstack end
	local un = core.get_node(pointed.under)
	local def = core.registered_nodes[un.name]
	if def and def.on_rightclick and not placer:get_player_control().sneak then
		return def.on_rightclick(pointed.under, un, placer, itemstack, pointed)
	end
	put_down(placer, pointed.above)
	return itemstack
end

local function times(t) return {[1] = t * 2, [2] = t * 1.5, [3] = t} end
core.register_tool(PICK, {
	description = ("Pickaxe (挖礦鎬)\n挖岩石很慢，岩石會變成碎石\n挖碎石就是拿起來，一次一塊\n右鍵放下手上的碎石"),
	inventory_image = "[fill:16x16:#00000000^[fill:2x13:7,3:#7a5a30^[fill:12x2:2,2:#8a8a8a^[fill:2x2:2,4:#8a8a8a^[fill:2x2:12,4:#8a8a8a",
	tool_capabilities = {
		full_punch_interval = 1.2, max_drop_level = 0,
		groupcaps = {
			cracky = {times = times(cfg.pick_rock_time), uses = 0, maxlevel = 1},
			crumbly = {times = {[1] = cfg.pick_rubble_time, [2] = cfg.pick_rubble_time, [3] = cfg.pick_rubble_time}, uses = 0, maxlevel = 1},
		},
		damage_groups = {fleshy = 2},
	},
	on_place = place,
})

-- 徒手：只敲得動礦石，碎石拿得起來
core.register_on_mods_loaded(function()
	local t = cfg.hand_rubble_time
	core.override_item("", {
		tool_capabilities = {full_punch_interval = 1, max_drop_level = 0,
			groupcaps = {
				rockmech_ore = {times = {[1] = cfg.hand_ore_time}, uses = 0, maxlevel = 1},
				crumbly = {times = {[1] = t, [2] = t, [3] = t}, uses = 0, maxlevel = 1},
			},
			damage_groups = {fleshy = 1}},
		on_place = place,
	})
end)

---------------------------------------------------------------------------
-- 帳篷下的供應商
---------------------------------------------------------------------------

local function shop_form(name)
	local out = {"formspec_version[6]size[13.5,12]",
		("label[0.5,0.6;供應商　資金 $%.0f]"):format(rockmech.money(name))}
	local col, row = 0, 0
	for i, it in ipairs(cfg.shop) do
		local x, y = 0.5 + col * 6.5, 1.2 + row * 0.95
		local price = it.price == 0 and "免費" or ("$%d"):format(it.price)
		out[#out + 1] = ("item_image[%g,%g;0.8,0.8;%s]"):format(x, y, it.item)
		out[#out + 1] = ("label[%g,%g;%s%s]"):format(x + 1, y + 0.4, it.label, it.count and (" ×" .. it.count) or "")
		out[#out + 1] = ("button[%g,%g;2.2,0.8;buy_%d;%s]"):format(x + 3.9, y, i, core.formspec_escape(price))
		row = row + 1
		if row >= 11 then col, row = col + 1, 0 end
	end
	return table.concat(out)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= SHOP then return end
	local name = player:get_player_name()
	for key in pairs(fields) do
		local it = cfg.shop[tonumber(key:match("^buy_(%d+)$"))]
		if it then
			local stack = ItemStack(it.item .. " " .. (it.count or 1))
			local inv = player:get_inventory()
			if rockmech.money(name) < it.price then
				core.chat_send_player(name, ("[供應商] 錢不夠：%s 要 $%d"):format(it.label, it.price))
			elseif not inv:room_for_item("main", stack) then
				core.chat_send_player(name, "[供應商] 物品欄滿了")
			else
				inv:add_item("main", stack)
				rockmech.add_money(name, -it.price)
				core.chat_send_player(name, ("[供應商] 買了 %s"):format(it.label))
				core.show_formspec(name, SHOP, shop_form(name))
			end
		end
	end
	return true
end)

core.register_entity(VENDOR, {
	initial_properties = {
		physical = true, collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
		visual = "mesh", mesh = "character.b3d", textures = {"character.png"},
		nametag = "供應商（右鍵）", nametag_color = "#ffe080", static_save = true,
	},
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
		self.object:set_animation({x = 0, y = 79}, 30)
	end,
	on_rightclick = function(self, clicker)
		local name = clicker:get_player_name()
		core.show_formspec(name, SHOP, shop_form(name))
	end,
	on_punch = function() return true end,
})

local CANVAS = {"[fill:16x16:#d8c8a0^[fill:16x2:0,6:#c04030^[fill:16x2:0,13:#c04030"}
core.register_node("rockmech:tent_canvas", {
	description = "Tent canvas (帳篷布)", tiles = CANVAS, is_ground_content = false,
	groups = {not_in_creative_inventory = 1},
})
core.register_node("rockmech:tent_pole", {
	description = "Tent pole (帳篷柱)", tiles = {"[fill:16x16:#6a4a28"}, is_ground_content = false,
	drawtype = "nodebox", paramtype = "light", node_box = {type = "fixed", fixed = {-0.1, -0.5, -0.1, 0.1, 0.5, 0.1}},
	groups = {not_in_creative_inventory = 1},
})

local function ground_y(x, z)
	for y = 40, -30, -1 do
		local n = core.get_node({x = x, y = y, z = z}).name
		if n ~= "air" and n ~= "ignore" then return y end
	end
end

-- 帳篷（四根柱子撐三層布）、供應商、一座破碎站
local function build_camp(owner)
	local y = ground_y(0, CAMP_Z) or 0
	for _, s in ipairs({{-3, -3}, {3, -3}, {-3, 3}, {3, 3}}) do
		for h = 1, 3 do core.set_node({x = s[1], y = y + h, z = CAMP_Z + s[2]}, {name = "rockmech:tent_pole"}) end
	end
	for layer = 0, 2 do
		local r = 3 - layer
		for x = -r, r do for z = -r, r do
			core.set_node({x = x, y = y + 4 + layer, z = CAMP_Z + z}, {name = "rockmech:tent_canvas"})
		end end
	end
	core.add_entity({x = 0, y = y + 0.5, z = CAMP_Z}, VENDOR)
	if not rockmech.crusher_build({x = CRUSHER_X, y = (ground_y(CRUSHER_X, CAMP_Z) or y) + 1, z = CAMP_Z}, 0, -1, owner) then
		core.log("warning", "[rockmech] 起始破碎站蓋不起來：地形不平")
	end
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	show_carry(player, carried(player))
	if storage:get_string(SITE_KEY) == "" then
		storage:set_string(SITE_KEY, "1")
		rockmech.add_money(name, cfg.career_start)
		core.emerge_area({x = -8, y = -30, z = CAMP_Z - 16}, {x = CRUSHER_X + 8, y = 40, z = CAMP_Z + 8}, function(_, _, rem)
			if rem == 0 then build_camp(name) end
		end)
	end
end)
core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	carry_hud[name], carry_img[name] = nil, nil
end)
