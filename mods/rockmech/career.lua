-- rockmech/career.lua
-- 經營模式（rockmech_career = true，世界要關掉創造模式）：從一把免費的鎬子開始賺錢，再到帳篷下的供應商買設備。
--   徒手只敲得動礦石，一塊 rockmech_hand_ore_time 秒；鎬子什麼岩石都能挖，也很慢；鏟子只鏟碎石，最快。
--   敲開的岩石原地變成碎石；
--   挖碎石就是把它拿起來，人只能拿一塊（滿格），不進物品欄，右鍵放下，或對著車斗按右鍵裝上去。
--   世界不掉落岩石和碎石，礦都要實際搬到破碎站才換得到錢。
--   第一次進世界在出生點旁蓋好帳篷（供應商）和一座破碎站。

local cfg = rockmech.cfg
if not cfg.career then return end

local V = rockmech.vehicles
local storage = rockmech.collapse.storage
local NLEV = V.NLEV

local PICK = "rockmech:pick"
local SHOVEL = "rockmech:shovel"
local CARRY_KEY = "rockmech:carry"
local SITE_KEY = "career_site"
local VENDOR_SPOTS = "career_vendor_spots"   -- 三攤攤主的位置（build_market 記下，ensure_vendors 補人）
local SHOP = "rockmech:shop"
local VENDOR = "rockmech:vendor"
local CAMP_Z = 14           -- 破碎站在出生點北邊幾公尺
local CRUSHER_X = 22        -- 破碎站機身在東邊幾公尺；受料倉在機身西側，煤層往西露頭，機身才不擋運礦的路
local TENT_Z = -14          -- 帳篷在出生點南邊幾公尺，遠離往受料倉的路（卡車要在倉前掉頭倒車）
local OLD_TENT_Z = 14       -- 舊版的帳篷位置

-- 主選單的創造模式開關是全域設定，不見得跟著世界走：經營模式一律不是創造模式
-- 例外：開了 /god（godmode 存在玩家 meta）或有 creative 權限的人（老師）可以用創造模式的物品欄
function core.is_creative_enabled(name)
	if not name or name == "" then return false end
	if core.check_player_privs(name, {creative = true}) then return true end
	local p = core.get_player_by_name(name)
	return p ~= nil and p:get_meta():get_int("godmode:on") == 1
end

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
		local see = rockmech.can_see or function() return true end      -- 知識能力（knowledge.lua）
		text = ("手上：%s　%s%s"):format(see(name, "rockmass") and core.registered_nodes[c.base].description:gsub("\n.*", "") or "碎石",
			V.volume_text(c.lv, NLEV), ore and see(name, "grade") and ("　" .. rockmech.ore_text(ore, c.p2 / 255)) or "")
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
		carry_img[name] = player:hud_add({type = "image", position = {x = 0.5, y = 0.74}, alignment = {x = 0, y = 0},
			scale = {x = 4, y = 4}, text = img, z_index = 90})
	end
end
local function set_carried(player, c)
	player:get_meta():set_string(CARRY_KEY, c and core.serialize(c) or "")
	show_carry(player, c)
end

-- 雙手：拿碎石時從下方捧著，推車時伸向握把。引擎只畫右手，自己畫一對方塊手臂（畫面最下方往上、往中間斜），
-- 這時收起原本手上的東西。mode：nil、"carry"、"cart"
local SKIN, SLEEVE = "#d8a880", "#3a5a8a"
local ARM = ("[fill:24x40:#00000000^[fill:10x10:2,0:%s^[fill:10x10:5,10:%s^[fill:10x10:8,20:%s^[fill:10x10:11,30:%s"):format(
	SKIN, SKIN, SLEEVE, SLEEVE)
local ARM_X = {carry = 0.11, cart = 0.17}   -- 手臂離畫面中央多遠（畫面寬度的比例）；推車時對準握把進入畫面的位置
local ARM_LOOK = 0.3                        -- 推車時視線領先車子 1 rad，手臂在畫面上移多少（握把在畫面上跟著移）
local arms = {}             -- 玩家名稱 → {mode, left, right, shift}

-- shift：雙手一起左右移（畫面寬度的比例）
local function set_arms(player, mode, shift)
	local name = player:get_player_name()
	local a = arms[name]
	if not a then
		local function arm(tex)
			return player:hud_add({type = "image", position = {x = 0.5, y = 1}, alignment = {x = 0, y = -1},
				scale = {x = -14, y = -30}, text = tex, z_index = 95})
		end
		a = {left = arm(""), right = arm("")}
		arms[name] = a
	end
	shift = shift or 0
	if a.mode ~= mode then
		local had = a.mode
		a.mode = mode
		player:hud_change(a.left, "text", mode and ARM .. "^[transformFX" or "")
		player:hud_change(a.right, "text", mode and ARM or "")
		if mode then player:hud_set_flags({wielditem = false})
		elseif had and not player:get_attach() then player:hud_set_flags({wielditem = true}) end
		a.shift = nil
	end
	if not a.shift or math.abs(shift - a.shift) > 0.004 then
		a.shift = shift
		local dx = ARM_X[mode] or 0
		player:hud_change(a.left, "position", {x = 0.5 + shift - dx, y = 1})
		player:hud_change(a.right, "position", {x = 0.5 + shift + dx, y = 1})
	end
end

local arm_t = 0
core.register_globalstep(function(dtime)
	arm_t = arm_t + dtime
	if arm_t < 0.1 then return end
	arm_t = 0
	for _, player in ipairs(core.get_connected_players()) do
		local parent = player:get_attach()
		local e = parent and parent:get_luaentity()
		local def = e and e.vkind and V.TYPES[e.vkind]
		if def and def.pushed then
			local rel = (player:get_look_horizontal() - parent:get_yaw()) % (2 * math.pi) - math.pi     -- 車斗在車尾那一側
			set_arms(player, "cart", rel * ARM_LOOK)
		elseif parent then set_arms(player, nil)
		else set_arms(player, carried(player) and "carry" or nil) end
	end
end)

-- 手上的碎石裝上車：回傳右鍵用掉了沒。沒拿東西、或這台車沒有車斗就回 false，照常上車。
-- 按住右鍵會連發：剛裝完 LOAD_HOLD 秒內的右鍵也算用掉，不然手一空就上車了
local LOAD_HOLD = 1
local loaded_at = {}
function rockmech.career_load(player, self, def)
	local name = player:get_player_name()
	local now = core.get_us_time() / 1e6
	local c = carried(player)
	if not c and now - (loaded_at[name] or -LOAD_HOLD) < LOAD_HOLD then return true end
	if not c or (def.cap or 0) <= 0 then return false end
	loaded_at[name] = now
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

-- 落點 LOAD_R 內有裝得下的車斗就裝上去：差一點沒點中車子，碎石不該掉在地上
local LOAD_R = 2.5
local function load_near(player, pos)
	for _, o in ipairs(core.get_objects_inside_radius(pos, LOAD_R + 3)) do
		local e = o:get_luaentity()
		local def = e and e.vkind and V.TYPES[e.vkind]
		-- 只找有車斗的車（卡車、礦卡、手推車）：怪手的鏟斗也有容量，但沒有車斗、也沒有車尾長度
		if def and def.bed and (def.cap or 0) > V.load_total(e) and not e.driver then
			local p = o:get_pos()
			local dir = core.yaw_to_dir(o:get_yaw())
			local bed = vector.add(p, vector.multiply(dir, -(def.rear or def.half) / 2))
			if vector.distance({x = bed.x, y = pos.y, z = bed.z}, pos) <= LOAD_R + def.half
					or vector.distance({x = p.x, y = pos.y, z = p.z}, pos) <= LOAD_R then
				return rockmech.career_load(player, e, def)
			end
		end
	end
	return false
end

-- 右鍵：點到方塊的右鍵功能優先，再來是旁邊的車斗，否則放下手上的碎石（鎬子和空手共用）
local function place(itemstack, placer, pointed)
	if pointed.type ~= "node" then return itemstack end
	local un = core.get_node(pointed.under)
	local def = core.registered_nodes[un.name]
	if def and def.on_rightclick and not placer:get_player_control().sneak then
		return def.on_rightclick(pointed.under, un, placer, itemstack, pointed)
	end
	if not (carried(placer) and load_near(placer, pointed.above)) then put_down(placer, pointed.above) end
	return itemstack
end

-- 對著天空按右鍵：看前方有沒有車斗
local function place_air(itemstack, player)
	if carried(player) then
		local eye = vector.add(player:get_pos(), {x = 0, y = 1.6, z = 0})
		load_near(player, vector.add(eye, vector.multiply(player:get_look_dir(), 3)))
	end
	return itemstack
end

local function times(t) return {[1] = t * 2, [2] = t * 1.5, [3] = t} end
core.register_tool(PICK, {
	description = ("Pickaxe (挖礦鎬)\n挖岩石很慢，岩石會變成碎石\n挖碎石就是拿起來，一次一塊\n右鍵放下手上的碎石"),
	inventory_image = "default_tool_steelpick.png",
	tool_capabilities = {
		full_punch_interval = 1.2, max_drop_level = 0,
		groupcaps = {
			cracky = {times = times(cfg.pick_rock_time), uses = 0, maxlevel = 1},
			crumbly = {times = {[1] = cfg.pick_rubble_time, [2] = cfg.pick_rubble_time, [3] = cfg.pick_rubble_time}, uses = 0, maxlevel = 1},
		},
		damage_groups = {fleshy = 2},
	},
	on_place = place,
	on_secondary_use = place_air,
})

core.register_tool(SHOVEL, {
	description = "Shovel (鏟子)\n很快把碎石鏟起來，一次一塊\n挖不動岩石\n右鍵放下手上的碎石",
	inventory_image = "default_tool_steelshovel.png",
	tool_capabilities = {
		full_punch_interval = 0.6, max_drop_level = 0,
		groupcaps = {crumbly = {times = {[1] = cfg.shovel_time, [2] = cfg.shovel_time, [3] = cfg.shovel_time}, uses = 0, maxlevel = 1}},
		damage_groups = {fleshy = 1},
	},
	on_place = place,
	on_secondary_use = place_air,
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
		on_secondary_use = place_air,
	})
end)

---------------------------------------------------------------------------
-- 帳篷下的供應商：三攤各賣一類（config.shop 的 shop 欄），舊世界的 VENDOR 什麼都賣
---------------------------------------------------------------------------

-- kind → 攤位：名牌（職稱）、顏色、坐著還是站著
local BOOTHS = {
	vehicle = {entity = "rockmech:vendor_vehicle", title = "機械設備課長", sells = "車輛・破碎站・輸送帶",
		color = "#80b0ff", tint = "#2050a0", sit = true},
	blast = {entity = "rockmech:vendor_blast", title = "爆破主任", sells = "鑽孔・炸藥・裝藥",
		color = "#ff8060", tint = "#c03020", sit = false},
	tools = {entity = "rockmech:vendor_tools", title = "工具室管理員", sells = "手工具・支護・儀器",
		color = "#a0e080", tint = "#407020", sit = true},
}
local shop_kind = {}        -- 玩家名稱 → 正在看哪一攤（nil：全部）
-- 給 research.lua：其他 NPC（研究員）也登記到 BOOTHS，由 ensure_vendors 一起補人；帳篷的 z、攤主位置的 storage 鍵
rockmech.career_npcs = BOOTHS
rockmech.career_tent_z = TENT_Z
rockmech.career_vendor_spots = VENDOR_SPOTS

local function shop_form(name, kind)
	local booth = BOOTHS[kind]
	local who = booth and booth.title or "供應商"
	local team = rockmech.team_of(name)
	local head = team and ("%s　第 %s 組資金 $%.0f"):format(who, team, rockmech.money(name))
		or rockmech.has_account(name) and ("%s　資金 $%.0f"):format(who, rockmech.money(name))
		or who .. "　你還沒分組，請老師分組後才有資金"
	local out = {"formspec_version[6]size[13.5,13.2]", ("label[0.5,0.6;%s]"):format(core.formspec_escape(head))}
	local col, row = 0, 0
	for i, it in ipairs(cfg.shop) do
		if not kind or it.shop == kind then
			local x, y = 0.5 + col * 6.5, 1.2 + row * 0.95
			local price = it.price == 0 and "免費" or ("$%d"):format(it.price)
			out[#out + 1] = ("item_image[%g,%g;0.8,0.8;%s]"):format(x, y, it.item)
			out[#out + 1] = ("label[%g,%g;%s%s]"):format(x + 1, y + 0.4, it.label, it.count and (" ×" .. it.count) or "")
			out[#out + 1] = ("button[%g,%g;2.2,0.8;buy_%d;%s]"):format(x + 3.9, y, i, core.formspec_escape(price))
			row = row + 1
			if row >= 12 then col, row = col + 1, 0 end
		end
	end
	return table.concat(out)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= SHOP then return end
	local name = player:get_player_name()
	local kind = shop_kind[name]
	for key in pairs(fields) do
		local it = cfg.shop[tonumber(key:match("^buy_(%d+)$"))]
		if it and (not kind or it.shop == kind) then
			local stack = ItemStack(it.item .. " " .. (it.count or 1))
			local inv = player:get_inventory()
			if rockmech.money(name) < it.price then
				core.chat_send_player(name, ("[供應商] 錢不夠：%s 要 $%d"):format(it.label, it.price))
			elseif not inv:room_for_item("main", stack) then
				core.chat_send_player(name, "[供應商] 物品欄滿了")
			else
				inv:add_item("main", stack)
				rockmech.add_money(name, -it.price)
				local acc = rockmech.account_of(name)
				if acc ~= name then
					-- 整組共用的錢：組員都看得到誰買了什麼
					for _, m in ipairs(rockmech.account_members(acc)) do
						core.chat_send_player(m, ("[%s] %s 買了 %s（$%d）"):format(rockmech.account_label(acc), name, it.label, it.price))
					end
					core.log("action", ("[rockmech] %s (%s) bought %s for $%d"):format(name, acc, it.key, it.price))
				else
					core.chat_send_player(name, ("[供應商] 買了 %s"):format(it.label))
				end
				if it.final then
					-- 終極目標：全服廣播
					core.chat_send_all(("★★★ %s 購入「%s」！ ★★★"):format(rockmech.account_label(acc), it.label))
					core.log("action", ("[rockmech] FINAL: %s (%s) bought %s"):format(name, acc, it.key))
					for _, p in ipairs(core.get_connected_players()) do
						core.sound_play("rockmech_coin", {to_player = p:get_player_name(), gain = 1.0}, true)
					end
				end
				core.show_formspec(name, SHOP, shop_form(name, kind))
			end
		end
	end
	return true
end)

local function open_shop(clicker, kind)
	local name = clicker:get_player_name()
	shop_kind[name] = kind
	core.show_formspec(name, SHOP, shop_form(name, kind))
end

-- 舊版：一個人什麼都賣（舊世界的帳篷）
core.register_entity(VENDOR, {
	initial_properties = {
		physical = true, collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
		visual = "mesh", mesh = "character.b3d", textures = {"character.png"},
		nametag = "供應商（右鍵）", nametag_color = "#ffe080", static_save = true,
	},
	on_activate = function(self)
		if math.abs(self.object:get_pos().z - TENT_Z) > 3 then self.object:remove(); return end     -- 舊版位置的 NPC
		self.object:set_armor_groups({immortal = 1})
		self.object:set_animation({x = 0, y = 79}, 30)
	end,
	on_rightclick = function(self, clicker) open_shop(clicker) end,
	on_punch = function() return true end,
})

-- 三攤的攤主：坐著的用坐姿（character.b3d 第 81–160 格），臉朝北（+z，營地中心）
for kind, b in pairs(BOOTHS) do
	core.register_entity(b.entity, {
		initial_properties = {
			physical = true, collisionbox = b.sit and {-0.3, 0, -0.3, 0.3, 1.2, 0.3} or {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
			visual = "mesh", mesh = "character.b3d", textures = {"character.png^[colorize:" .. b.tint .. ":70"},
			nametag = b.title, nametag_color = b.color, static_save = false,
		},
		on_activate = function(self)
			self.object:set_armor_groups({immortal = 1})
			self.object:set_yaw(0)
			if b.sit then self.object:set_animation({x = 81, y = 160}, 30)
			else self.object:set_animation({x = 0, y = 79}, 30) end
		end,
		on_rightclick = function(self, clicker) open_shop(clicker, kind) end,
		on_punch = function() return true end,
	})
end

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

-- 三攤各自的棚布
local CANVASES = {
	vehicle = "[fill:16x16:#3060b0^[fill:16x2:0,6:#e0e8f0^[fill:16x2:0,13:#e0e8f0",
	blast = "[fill:16x16:#e8e0d0^[fill:16x4:0,0:#c02020^[fill:16x4:0,8:#c02020",
	tools = "[fill:16x16:#4a7a3a^[fill:16x2:0,6:#d8c8a0^[fill:16x2:0,13:#d8c8a0",
}
for kind, tex in pairs(CANVASES) do
	core.register_node("rockmech:tent_canvas_" .. kind, {
		description = "Tent canvas (帳篷布)", tiles = {tex}, is_ground_content = false,
		groups = {not_in_creative_inventory = 1},
	})
end

-- 攤位的擺設（裝飾用，挖不掉）
local WOOD, DARK = "default_wood.png", "[fill:16x16:#2a2a2a"
local function prop(name, def)
	def.drawtype = "nodebox"
	def.paramtype = "light"
	def.paramtype2 = "facedir"
	def.is_ground_content = false
	def.sunlight_propagates = true
	def.groups = {not_in_creative_inventory = 1}
	def.selection_box = def.node_box
	core.register_node("rockmech:camp_" .. name, def)
end
prop("table", {description = "桌子", tiles = {WOOD}, node_box = {type = "fixed", fixed = {
	{-0.5, 0.3, -0.5, 0.5, 0.45, 0.5},
	{-0.45, -0.5, -0.45, -0.35, 0.3, -0.35}, {0.35, -0.5, -0.45, 0.45, 0.3, -0.35},
	{-0.45, -0.5, 0.35, -0.35, 0.3, 0.45}, {0.35, -0.5, 0.35, 0.45, 0.3, 0.45}}}})
-- 椅子：椅背在南邊（−z），坐的人臉朝北
prop("chair", {description = "椅子", tiles = {WOOD}, node_box = {type = "fixed", fixed = {
	{-0.35, -0.05, -0.35, 0.35, 0.05, 0.35},
	{-0.35, 0.05, -0.35, 0.35, 0.8, -0.25},
	{-0.35, -0.5, -0.35, -0.25, -0.05, -0.25}, {0.25, -0.5, -0.35, 0.35, -0.05, -0.25},
	{-0.35, -0.5, 0.25, -0.25, -0.05, 0.35}, {0.25, -0.5, 0.25, 0.35, -0.05, 0.35}}}})
prop("crate", {description = "木箱",
	tiles = {WOOD .. "^[fill:16x1:0,0:#5a3a18^[fill:16x1:0,15:#5a3a18^[fill:1x16:0,0:#5a3a18^[fill:1x16:15,0:#5a3a18"},
	node_box = {type = "fixed", fixed = {-0.45, -0.5, -0.45, 0.45, 0.35, 0.45}}})
prop("explosives", {description = "炸藥箱",
	tiles = {"[fill:16x16:#b02020^[fill:16x3:0,6:#f0d020^[fill:16x1:0,0:#601010^[fill:16x1:0,15:#601010"},
	node_box = {type = "fixed", fixed = {-0.4, -0.5, -0.3, 0.4, 0.1, 0.3}}})
prop("barrel", {description = "油桶", tiles = {"[fill:16x16:#2a5a9a^[fill:16x1:0,3:#18385a^[fill:16x1:0,12:#18385a"},
	node_box = {type = "fixed", fixed = {{-0.35, -0.5, -0.25, 0.35, 0.45, 0.25}, {-0.25, -0.5, -0.35, 0.25, 0.45, 0.35}}}})
prop("tires", {description = "輪胎", tiles = {DARK .. "^[fill:6x6:5,5:#555555"},
	node_box = {type = "fixed", fixed = {{-0.45, -0.5, -0.3, 0.45, 0.45, 0.3}, {-0.3, -0.5, -0.45, 0.3, 0.45, 0.45}}}})
prop("cone", {description = "三角錐", tiles = {"[fill:16x16:#f07010^[fill:16x2:0,7:#f0f0f0"},
	node_box = {type = "fixed", fixed = {{-0.3, -0.5, -0.3, 0.3, -0.4, 0.3}, {-0.15, -0.4, -0.15, 0.15, 0.0, 0.15},
		{-0.08, 0.0, -0.08, 0.08, 0.3, 0.08}}}})
-- 工具架：正面（+z）擺著工具
prop("shelf", {description = "工具架",
	tiles = {WOOD, WOOD, WOOD, WOOD, WOOD .. "^default_tool_steelpick.png^default_tool_steelshovel.png", WOOD},
	node_box = {type = "fixed", fixed = {{-0.5, -0.5, -0.5, 0.5, 0.5, -0.3}, {-0.5, -0.5, -0.5, -0.4, 0.5, 0.2},
		{0.4, -0.5, -0.5, 0.5, 0.5, 0.2}, {-0.5, -0.1, -0.5, 0.5, 0.0, 0.2}, {-0.5, 0.4, -0.5, 0.5, 0.5, 0.2},
		{-0.5, -0.5, -0.5, 0.5, -0.4, 0.2}}}})
prop("toolbox", {description = "工具箱", tiles = {"[fill:16x16:#c03020^[fill:16x2:0,5:#202020"},
	node_box = {type = "fixed", fixed = {{-0.3, -0.5, -0.15, 0.3, -0.2, 0.15}, {-0.1, -0.2, -0.03, 0.1, -0.1, 0.03}}}})
prop("papers", {description = "文件",
	tiles = {"[fill:16x16:#f0f0e8^[fill:12x1:2,4:#8090a0^[fill:12x1:2,8:#8090a0^[fill:8x1:2,12:#8090a0"},
	node_box = {type = "fixed", fixed = {{-0.25, -0.5, -0.2, 0.15, -0.45, 0.2}, {-0.05, -0.45, -0.15, 0.3, -0.42, 0.15}}}})
prop("helmets", {description = "安全帽", tiles = {"[fill:16x16:#f0c020"},
	node_box = {type = "fixed", fixed = {{-0.4, -0.5, -0.15, -0.05, -0.3, 0.15}, {-0.32, -0.3, -0.1, -0.13, -0.22, 0.1},
		{0.05, -0.5, -0.15, 0.4, -0.3, 0.15}, {0.13, -0.3, -0.1, 0.32, -0.22, 0.1}}}})

local function ground_y(x, z)
	for y = 40, -30, -1 do
		local n = core.get_node({x = x, y = y, z = z}).name
		if n ~= "air" and n ~= "ignore" then return y end
	end
end

-- 帳篷（四根柱子撐三層布）和供應商。x0：營地中心（出生點是 0，各組的礦帶見 team.lua）
local function build_tent(x0)
	x0 = x0 or 0
	local y = ground_y(x0, TENT_Z) or 0
	for _, s in ipairs({{-3, -3}, {3, -3}, {-3, 3}, {3, 3}}) do
		for h = 1, 3 do core.set_node({x = x0 + s[1], y = y + h, z = TENT_Z + s[2]}, {name = "rockmech:tent_pole"}) end
	end
	for layer = 0, 2 do
		local r = 3 - layer
		for x = -r, r do for z = -r, r do
			core.set_node({x = x0 + x, y = y + 4 + layer, z = TENT_Z + z}, {name = "rockmech:tent_canvas"})
		end end
	end
	core.add_entity({x = x0, y = y + 0.5, z = TENT_Z}, VENDOR)
end

-- 營地南邊（z = TENT_Z）一間貨櫃辦公室，三個攤位並排：機械設備課長、爆破主任、工具室管理員。
-- 每攤前面（北邊）一排桌子，攤主在桌子後面（坐的有椅子），後面和兩側擺設。
-- 擺設：{dx, dz, 高度層, 節點}，高度層 1 是地面上第一格
local BOOTH_X = {vehicle = -4, blast = 0, tools = 4}   -- 三位攤主在貨櫃辦公室裡的位置（離中心）
-- 擺設：{dx, dz, 高度層, 節點}，dx 離攤主、dz 離辦公室中心線（正面窗口在 dz = 3，櫃台在 2，攤主在 1，後牆在 −3）
local BOOTH_PROPS = {
	vehicle = {     -- 機械設備課長：坐在辦公桌後，後面堆輪胎、油桶
		{-1, 2, 1, "table"}, {0, 2, 1, "table"}, {1, 2, 1, "table"}, {0, 2, 2, "papers"}, {0, 1, 1, "chair"},
		{-1, -2, 1, "tires"}, {-1, -2, 2, "tires"}, {-1, -1, 1, "tires"}, {0, -2, 1, "barrel"}, {1, -2, 1, "barrel"},
	},
	blast = {       -- 爆破主任：站著，後面一排炸藥箱
		{-1, 2, 1, "table"}, {0, 2, 1, "table"}, {1, 2, 1, "table"}, {1, 2, 2, "helmets"}, {-1, 2, 2, "papers"},
		{-1, -2, 1, "crate"}, {-1, -2, 2, "explosives"}, {0, -2, 1, "explosives"}, {1, -2, 1, "crate"}, {1, -2, 2, "explosives"},
	},
	tools = {       -- 工具室管理員：坐著，後面兩層工具架
		{-1, 2, 1, "table"}, {0, 2, 1, "table"}, {1, 2, 1, "table"}, {-1, 2, 2, "toolbox"}, {0, 1, 1, "chair"},
		{-1, -2, 1, "shelf"}, {0, -2, 1, "shelf"}, {1, -2, 1, "shelf"}, {-1, -2, 2, "shelf"}, {1, -2, 2, "shelf"},
	},
}

-- 貨櫃辦公室：兩個 40 呎貨櫃併成一間（外部 13×7 m、室內高 3 m），米白波浪鋼板、深灰角柱與底樑、灰色屋頂。
-- 正面（北邊，朝營地）三個櫃台窗口，上面各一片條紋遮陽棚（攤位的識別色）；東側木門，背面、西側玻璃窗，
-- 西側牆外一台冷氣室外機；室內地板、天花板燈。在窗口外面就能右鍵攤主買東西，也可以從門走進去。
local MARKET_RX, MARKET_RZ = 6, 3          -- 外牆離中心（x：東西兩端、z：南北兩面）
local AWNING = {vehicle = "#2f6fbf", blast = "#c03020", tools = "#3f8a3a"}
local WALL = "[fill:16x16:#e6e0cf^[fill:2x16:1,0:#c8c2b0^[fill:2x16:6,0:#c8c2b0^[fill:2x16:11,0:#c8c2b0"
local function plain(name, desc, tiles, extra)
	local def = {description = desc, tiles = tiles, is_ground_content = false, groups = {not_in_creative_inventory = 1}}
	for k, v in pairs(extra or {}) do def[k] = v end
	core.register_node("rockmech:" .. name, def)
end
plain("office_wall", "貨櫃屋外牆", {WALL})
plain("office_wall_base", "貨櫃屋外牆（底樑）", {WALL .. "^[fill:16x4:0,12:#4a4e52"})
plain("office_post", "貨櫃屋角柱", {"[fill:16x16:#4a4e52^[fill:4x4:6,6:#2a2c2e"})
plain("office_roof", "貨櫃屋屋頂", {"[fill:16x16:#9a9ea2^[fill:16x1:0,0:#7a7e82^[fill:16x1:0,8:#7a7e82",
	"[fill:16x16:#d8d4c8", "[fill:16x16:#4a4e52", "[fill:16x16:#4a4e52", "[fill:16x16:#4a4e52", "[fill:16x16:#4a4e52"})
plain("office_floor", "貨櫃屋地板", {"[fill:16x16:#7a6a58^[fill:16x1:0,4:#6a5a48^[fill:16x1:0,12:#6a5a48"})
plain("camp_lamp", "天花板燈", {"[fill:16x16:#fff8d8"}, {drawtype = "nodebox", paramtype = "light",
	node_box = {type = "fixed", fixed = {-0.4, 0.4, -0.15, 0.4, 0.5, 0.15}}, light_source = 13,
	sunlight_propagates = true, walkable = false})
-- 冷氣室外機：灰白機殼、正面圓形風扇格柵
plain("office_ac", "冷氣室外機", {"[fill:16x16:#d0d0cc", "[fill:16x16:#d0d0cc", "[fill:16x16:#d0d0cc", "[fill:16x16:#d0d0cc",
	"[fill:16x16:#d0d0cc^[fill:10x10:3,3:#505458^[fill:10x1:3,6:#808488^[fill:10x1:3,9:#808488", "[fill:16x16:#d0d0cc"},
	{drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
	node_box = {type = "fixed", fixed = {{-0.45, -0.5, -0.25, 0.45, 0.35, 0.25}, {-0.4, -0.5, -0.3, -0.3, -0.4, 0.3}, {0.3, -0.5, -0.3, 0.4, -0.4, 0.3}}}})
for kind, c in pairs(AWNING) do
	-- 遮陽棚：從牆頂往外斜下來的條紋布（攤位識別色＋白）
	plain("office_awning_" .. kind, "遮陽棚", {("[fill:16x16:#f0f0f0^[fill:4x16:0,0:%s^[fill:4x16:8,0:%s"):format(c, c)},
		{drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir", sunlight_propagates = true,
		node_box = {type = "fixed", fixed = {{-0.5, 0.35, -0.5, 0.5, 0.45, -0.1}, {-0.5, 0.15, -0.1, 0.5, 0.3, 0.3},
			{-0.5, -0.05, 0.3, 0.5, 0.1, 0.5}}}})
end

-- 營地的建築都面向西（礦區那邊），跟破碎站排成一排：建築的本地座標 dx 沿長邊（往右）、dz 朝正面，
-- 轉成世界座標：正面 +dz → 西（−x），右手 +dx → 北（+z）。facedir 的方塊跟著轉 90°（+3），攤主的 yaw = π/2
local FACE_YAW = math.pi / 2
function rockmech.career_placer(cx, cz, y)
	local function at(dx, h, dz) return {x = cx - dz, y = y + h, z = cz + dx} end
	local function set(dx, h, dz, node, p2) core.set_node(at(dx, h, dz), {name = node, param2 = ((p2 or 0) + 3) % 4}) end
	return set, at
end
local OFFICE_DX, OFFICE_Z = 27, 0          -- 貨櫃辦公室中心：營地中心往東、南北位置（破碎站在往東 CRUSHER_X、z = CAMP_Z）
rockmech.career_office_dx = OFFICE_DX

local function build_market(x0)
	local cx, cz = x0 + OFFICE_DX, OFFICE_Z
	local y = ground_y(cx, cz) or 0
	local set, at = rockmech.career_placer(cx, cz, y)
	local RX, RZ = MARKET_RX, MARKET_RZ
	-- 外殼：角柱、牆（最下一層是底樑）、屋頂、室內地板
	for dx = -RX, RX do
		for dz = -RZ, RZ do
			local edge_x, edge_z = math.abs(dx) == RX, math.abs(dz) == RZ
			for h = 1, 3 do
				if edge_x and edge_z then set(dx, h, dz, "rockmech:office_post")
				elseif edge_x or edge_z then set(dx, h, dz, h == 1 and "rockmech:office_wall_base" or "rockmech:office_wall")
				else set(dx, h, dz, "air") end
			end
			set(dx, 4, dz, "rockmech:office_roof")
			if not edge_x and not edge_z then set(dx, 0, dz, "rockmech:office_floor") end
		end
	end
	for kind, bx in pairs(BOOTH_X) do
		-- 正面：攤主前面的櫃台窗口（3 寬、h 2–3，h 1 的牆當櫃台），外面一片遮陽棚
		for dx = -1, 1 do
			for h = 2, 3 do set(bx + dx, h, RZ, "air") end
			set(bx + dx, 4, RZ + 1, "rockmech:office_awning_" .. kind)          -- 高的一邊貼著牆（南），往北斜下
		end
		set(bx, 3, 0, "rockmech:camp_lamp")
	end
	-- 背面高處一排玻璃窗、西側一扇玻璃窗
	for _, dx in ipairs({-5, -4, -3, 3, 4, 5}) do set(dx, 3, -RZ, "default:glass") end
	set(-RX, 2, -1, "default:glass"); set(-RX, 2, 0, "default:glass")
	-- 東側木門（朝東開），門外兩個三角錐；西側牆外冷氣室外機
	set(RX, 1, 0, "doors:door_wood_a", 3)
	set(RX, 2, 0, "doors:hidden", 3)
	set(RX + 1, 1, 2, "rockmech:camp_cone"); set(RX + 1, 1, -2, "rockmech:camp_cone")
	set(-RX - 1, 1, 1, "rockmech:office_ac", 3)       -- facedir 3：風扇朝西
	local list = core.deserialize(storage:get_string(VENDOR_SPOTS)) or {}
	for kind, bx in pairs(BOOTH_X) do
		for _, p in ipairs(BOOTH_PROPS[kind]) do set(bx + p[1], p[3], p[2], "rockmech:camp_" .. p[4]) end
		-- 坐著的攤主在椅面上（椅面比地面高 0.55 m），站著的在地面。攤主不存進地圖：記下位置，有人走近時才放（見下面）
		local p = at(bx, 0, 1)
		list[#list + 1] = {kind = kind, pos = {x = p.x, y = y + (BOOTHS[kind].sit and 1.05 or 0.5), z = p.z}, yaw = FACE_YAW}
	end
	storage:set_string(VENDOR_SPOTS, core.serialize(list))
end

-- 攤主：地圖剛生成、附近沒有人時放的 entity 不一定留得住，所以改成玩家走到 VENDOR_NEAR 公尺內、
-- 攤主不在就補一個（entity 不存檔，離開後跟著地圖區塊一起卸下，回來再補）
local VENDOR_NEAR = 32
local vendor_obj = {}       -- 攤位序號 → entity
local function ensure_vendors(force)
	local list = core.deserialize(storage:get_string(VENDOR_SPOTS)) or {}
	local players = core.get_connected_players()
	for i, spot in ipairs(list) do
		local o = vendor_obj[i]
		if not (o and o:get_pos()) then
			local near = force
			for _, p in ipairs(players) do
				if vector.distance(p:get_pos(), spot.pos) < VENDOR_NEAR then near = true; break end
			end
			if near then
				vendor_obj[i] = core.add_entity(spot.pos, BOOTHS[spot.kind].entity)
				if vendor_obj[i] and spot.yaw then vendor_obj[i]:set_yaw(spot.yaw) end
			end
		end
	end
end
rockmech.career_ensure_vendors = ensure_vendors
function rockmech.career_reset_vendors()      -- 攤主位置清單換了（營地搬移）：已經放的攤主收掉，重新補
	for _, o in pairs(vendor_obj) do if o and o:get_pos() then o:remove() end end
	vendor_obj = {}
end
local vendor_t = 0
core.register_globalstep(function(dtime)
	vendor_t = vendor_t + dtime
	if vendor_t < 2 then return end
	vendor_t = 0
	ensure_vendors()
end)

-- 組號看板：大帳篷南邊，面向南邊的走廊，白底大數字（3×5 點陣放大 2 倍）；背面是木板
local DIGITS = {
	["0"] = {"111", "101", "101", "101", "111"}, ["1"] = {"010", "110", "010", "010", "111"},
	["2"] = {"111", "001", "111", "100", "111"}, ["3"] = {"111", "001", "111", "001", "111"},
	["4"] = {"101", "101", "111", "001", "001"}, ["5"] = {"111", "100", "111", "001", "111"},
	["6"] = {"111", "100", "111", "101", "111"}, ["7"] = {"111", "001", "001", "001", "001"},
	["8"] = {"111", "101", "111", "101", "111"}, ["9"] = {"111", "101", "111", "001", "111"},
}
for _, n in ipairs({{"board", "#f0f0e8", "看板"}, {"digit", "#203a80", "看板數字"}, {"back", "#6a4a28", "看板背面"}}) do
	core.register_node("rockmech:sign_" .. n[1], {
		description = n[3], tiles = {"[fill:16x16:" .. n[2]}, is_ground_content = false,
		groups = {not_in_creative_inventory = 1},
	})
end
local function build_sign(x0, text)
	local glyph = DIGITS[text]
	if not glyph then return end
	local zf = TENT_Z - 6                        -- 正面（南），背面在北邊一格
	local y = ground_y(x0, zf) or 0
	local x1, x2, top = x0 - 4, x0 + 3, y + 14   -- 寬 8、高 12（y+3..y+14），下面兩根柱子
	for _, px in ipairs({x1, x2}) do
		for h = 1, 2 do
			core.set_node({x = px, y = y + h, z = zf + 1}, {name = "rockmech:tent_pole"})
		end
	end
	for x = x1, x2 do
		for yy = y + 3, top do
			core.set_node({x = x, y = yy, z = zf}, {name = "rockmech:sign_board"})
			core.set_node({x = x, y = yy, z = zf + 1}, {name = "rockmech:sign_back"})
		end
	end
	-- 從南邊看過來：往北看時東（+x）在右手邊，所以第 c 欄就是 x 由小到大，不會左右顛倒
	for r = 0, 4 do
		for c = 0, 2 do
			if glyph[r + 1]:sub(c + 1, c + 1) == "1" then
				for dx = 0, 1 do for dy = 0, 1 do
					core.set_node({x = x1 + 1 + 2 * c + dx, y = top - 1 - 2 * r - dy, z = zf}, {name = "rockmech:sign_digit"})
				end end
			end
		end
	end
end

local function build_camp(owner, x0)
	x0 = x0 or 0
	storage:set_string("camp_layout2:" .. x0, "1")       -- 新配置（建築在破碎站那一排、面向西）
	build_market(x0)
	if rockmech.career_build_research then rockmech.career_build_research(x0) end      -- 研究帳篷（research.lua）
	if rockmech.career_build_professor then rockmech.career_build_professor(x0) end    -- 大學教授的講堂（knowledge.lua）
	local team = owner:match("^team:(%d)$")
	if team then build_sign(x0, team) end
	local y = ground_y(x0 + CRUSHER_X, CAMP_Z) or 0
	if not rockmech.crusher_build({x = x0 + CRUSHER_X, y = y + 1, z = CAMP_Z}, -1, 0, owner) then
		core.log("warning", ("[rockmech] 營地 x = %d 的破碎站蓋不起來：地形不平"):format(x0))
	end
end

-- 營地要用到的範圍
local function camp_area(x0)
	return {x = x0 - 22, y = -30, z = TENT_Z - 12}, {x = x0 + OFFICE_DX + 10, y = 40, z = CAMP_Z + 8}
end

-- 在 x0 蓋一座營地（帳篷、供應商、破碎站掛在 owner 的帳戶），地圖生成完才蓋；done(spawn) 拿到營地中心的落腳點
function rockmech.career_build_camp(owner, x0, done)
	local a, b = camp_area(x0)
	core.emerge_area(a, b, function(_, _, rem)
		if rem > 0 then return end
		build_camp(owner, x0)
		if done then done(rockmech.career_spawn(x0)) end
	end)
end

-- 舊配置（貨櫃辦公室在營地中心南邊、研究帳篷在它西邊、都面向北）搬到新配置：拆掉舊的建築（地板換回下面的岩石），
-- 清掉舊的攤主位置，在新位置蓋貨櫃辦公室和研究帳篷。資金、研究、地圖其他地方都不動
function rockmech.career_relayout(x0)
	storage:set_string("camp_layout2:" .. x0, "1")
	local fy
	for y = 40, -30, -1 do
		if core.get_node({x = x0, y = y, z = TENT_Z}).name == "rockmech:office_floor" then fy = y; break end
	end
	fy = fy or ground_y(x0 - 20, TENT_Z) or 0
	for x = x0 - 17, x0 + 8 do
		for z = TENT_Z - 4, TENT_Z + 4 do
			for h = 1, 7 do
				local p = {x = x, y = fy + h, z = z}
				local n = core.get_node(p).name
				if n:find("^rockmech:office_") or n:find("^rockmech:camp_") or n:find("^rockmech:tent_") or n:find("^doors:")
						or n == "default:glass" then
					core.remove_node(p)
				end
			end
			local f = {x = x, y = fy, z = z}
			if core.get_node(f).name == "rockmech:office_floor" then
				core.set_node(f, core.get_node({x = x, y = fy - 1, z = z}))
			end
		end
	end
	-- 舊的攤主、研究員位置（舊配置都在 z = TENT_Z 附近、x0 − 17 … x0 + 8）
	local list = core.deserialize(storage:get_string(VENDOR_SPOTS)) or {}
	local keep = {}
	for _, s in ipairs(list) do
		if not (math.abs(s.pos.z - TENT_Z) <= 3 and s.pos.x >= x0 - 17 and s.pos.x <= x0 + 8) then keep[#keep + 1] = s end
	end
	storage:set_string(VENDOR_SPOTS, core.serialize(keep))
	rockmech.career_reset_vendors()
	build_market(x0)
	if rockmech.career_build_research then rockmech.career_build_research(x0) end
	core.log("action", ("[rockmech] 營地 x = %d 改成新配置（建築在破碎站那一排、面向西）"):format(x0))
end
rockmech.career_area = camp_area

-- 營地中心（帳篷和破碎站之間）的落腳點；地圖還沒生成就先給地面高度附近
function rockmech.career_spawn(x0)
	local y = ground_y(x0, 0)
	return {x = x0, y = (y or 10) + 1, z = 0}
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	show_carry(player, carried(player))
	local site = storage:get_string(SITE_KEY)
	local a, b = camp_area(0)
	if site == "" then
		-- 世界第一次有人進來：出生點的營地。分了組的玩家另有自己組的營地（team.lua），這座歸第一個進來的人
		local owner = rockmech.team_of(name) and "camp:spawn" or name
		rockmech.add_money(owner, rockmech.team_of(name) and 0 or cfg.career_start)
		rockmech.career_build_camp(owner, cfg.career_camp_dx)
	elseif site == "1" then
		-- 舊版的世界：帳篷搬走（NPC 在 on_activate 自己消失）
		core.emerge_area(a, b, function(_, _, rem)
			if rem > 0 then return end
			for _, p in ipairs(core.find_nodes_in_area({x = -4, y = -30, z = OLD_TENT_Z - 4}, {x = 4, y = 40, z = OLD_TENT_Z + 4},
					{"rockmech:tent_pole", "rockmech:tent_canvas"})) do
				core.remove_node(p)
			end
			for _, o in ipairs(core.get_objects_inside_radius({x = 0, y = 1, z = OLD_TENT_Z}, 8)) do
				local e = o:get_luaentity()
				if e and e.name == VENDOR then o:remove() end
			end
			build_tent()
		end)
	end
	storage:set_string(SITE_KEY, "2")
end)
core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	carry_hud[name], carry_img[name], arms[name], loaded_at[name] = nil, nil, nil, nil
end)
