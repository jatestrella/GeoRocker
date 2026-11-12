-- rockmech/mixtrough.lua
-- 硝酸銨、柴油、拌和槽：沒有裝藥車的時候在拌和槽裡手拌 ANFO。
--   物品：1 公斤硝酸銨、1 L 柴油（數量就是公斤、公升，學生自己算配比）。
--   右鍵（不拿鏟子）打開拌和槽：硝酸銨格（最多 MAX_KG kg）、柴油格（最多 MAX_L L），
--   可以像箱子一樣拖放（右鍵一次放一個、分一半都行），也可以打數字按「倒入」。
--   拿鏟子右鍵翻拌 MIX_TIME 秒：兩格裡的東西併進「拌好的料」。拌好的料按「取出 ANFO」：
--   一包 BAG_KG kg，包數 = 總重 ÷ BAG_KG（無條件捨去），餘料照比例留在槽裡，可以再加料、再拌。「倒掉」：拌好的料全部丟掉。
--   還沒拌的料直接從格子拿回來。
--   配比（柴油佔總重的比例）決定 ANFO 的相對能量（rockmech.anfo_power），存在每包 ANFO 的 meta q，
--   倒進孔裡記在孔上（drilling.lua），爆破半徑乘 q^(1/3)。標準配比 94:6（柴油 5.7 %）能量最大。
--   不寫配比說明：玩家要自己算（25 kg 硝酸銨配約 1.8 L 柴油），wiki 有公式。

local S = rockmech.S
local F = core.formspec_escape
local AN, DIESEL, ANFO = "rockmech:ammonium_nitrate", "rockmech:diesel", "rockmech:anfo"
local SHOVEL = "rockmech:shovel"
local TROUGH = "rockmech:mix_trough"
local BAG_KG = 25           -- 一包 ANFO (kg)
local FO_KG_L = 0.84        -- 柴油密度 (kg/L)
local IDEAL = 0.057         -- 能量最大的柴油重量比例（氧平衡為零）
local MAX_KG, MAX_L = 250, 40
local MIX_TIME = 3          -- 翻拌幾秒
local SLOT = {an = {item = AN, cap = MAX_KG}, fo = {item = DIESEL, cap = MAX_L}}

-- 柴油重量比例 → 相對能量：柴油不夠時往純硝酸銨（約 0.3）掉，太多時每多 1 % 少 3 %
function rockmech.anfo_power(fo)
	if fo <= IDEAL then return 0.3 + 0.7 * fo / IDEAL end
	return math.max(0.3, 1 - 3 * (fo - IDEAL))
end
-- kg 硝酸銨、L 柴油 → 柴油重量比例
local function fuel_frac(kg, litres)
	local fo = litres * FO_KG_L
	if kg + fo <= 0 then return 0 end
	return fo / (kg + fo)
end
rockmech.anfo_fuel_frac = fuel_frac

core.register_craftitem(AN, {
	description = S("1 kg ammonium nitrate"),
	inventory_image = "[fill:16x16:#00000000^[fill:10x12:3,3:#f4f2ec^[fill:10x2:3,3:#d0ccc0^[fill:6x3:5,8:#3060a0",
	stack_max = 1000,
})
core.register_craftitem(DIESEL, {
	description = S("1 L diesel"),
	inventory_image = "[fill:16x16:#00000000^[fill:8x11:4,4:#b02818^[fill:4x2:5,2:#303030^[fill:6x1:5,8:#e0c040",
	stack_max = 200,
})

local function give(player, pos, stack)
	local inv = player and player:is_player() and player:get_inventory()
	local left = inv and inv:add_item("main", stack) or stack
	if not left:is_empty() then core.add_item(vector.offset(pos, 0, 0.6, 0), left) end
end

-- 外觀：槽底＋四面槽壁；裝了東西多一層內容物（白 = 硝酸銨、灰黃 = 倒了柴油還沒拌、粉紅 = 拌好的 ANFO）
local STEEL = "#6f7479"
local WALL = {{-0.5, -0.5, -0.5, 0.5, -0.4, 0.5}, {-0.5, -0.4, -0.5, 0.5, 0.1, -0.42}, {-0.5, -0.4, 0.42, 0.5, 0.1, 0.5},
	{-0.5, -0.4, -0.42, -0.42, 0.1, 0.42}, {0.42, -0.4, -0.42, 0.5, 0.1, 0.42}}
local STATES = {[""] = nil, an = "#f2f0ea", wet = "#cfc6ac", mix = "#e9c4c8"}
local function node_name(state) return state == "" and TROUGH or TROUGH .. "_" .. state end
local function is_trough(pos) return core.get_node(pos).name:sub(1, #TROUGH) == TROUGH end
local function num(v) return (("%.1f"):format(v):gsub("%.0$", "")) end

-- 槽裡：格子裡還沒拌的（kg、L）、拌好的料（mix_an kg、mix_fo L）
local function contents(pos)
	local meta = core.get_meta(pos)
	local inv = meta:get_inventory()
	return inv:get_stack("an", 1):get_count(), inv:get_stack("fo", 1):get_count(), meta:get_float("mix_an"), meta:get_float("mix_fo")
end

local function refresh(pos)
	local meta = core.get_meta(pos)
	local an, fo, man, mfo = contents(pos)
	if man + mfo * FO_KG_L < 0.05 then man, mfo = 0, 0; meta:set_float("mix_an", 0); meta:set_float("mix_fo", 0) end
	local state = an + fo == 0 and (man + mfo > 0 and "mix" or "") or fo > 0 and "wet" or "an"
	local node = core.get_node(pos)
	local want = node_name(state)
	if node.name ~= want then core.swap_node(pos, {name = want, param2 = node.param2}) end
	local t = {}
	if an + fo > 0 then t[#t + 1] = S("Ammonium nitrate @1 kg, diesel @2 L", an, fo) end
	if man + mfo > 0 then t[#t + 1] = S("Mixed ANFO @1 kg", num(man + mfo * FO_KG_L)) end
	meta:set_string("infotext", table.concat(t, "\n"))
end

local function busy(pos) return core.get_meta(pos):get_float("until") > core.get_gametime() end

local function formspec(pos)
	local spos = ("nodemeta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	local _, _, man, mfo = contents(pos)
	local mixed = man + mfo * FO_KG_L
	local row = function(y, key, label, unit, cap)
		return ("label[0.4,%.2f;%s]list[%s;%s;0.4,%.2f;1,1;]field[1.8,%.2f;1.8,0.8;n_%s;;]label[3.7,%.2f;%s]button[4.4,%.2f;1.8,0.8;pour_%s;%s]label[6.5,%.2f;≤ %d %s]")
			:format(y, F(label), spos, key, y + 0.3, y + 0.4, key, y + 0.8, unit, y + 0.4, key, F(S("Pour")), y + 0.8, cap, unit)
	end
	return "formspec_version[6]size[10.75,11.6]"
		.. row(0.3, "an", S("Ammonium nitrate"), "kg", MAX_KG)
		.. row(1.9, "fo", S("Diesel"), "L", MAX_L)
		.. ("label[0.4,3.9;%s]"):format(F(S("Mixed ANFO @1 kg", num(mixed))))
		.. ("button[4.4,3.5;2.6,0.8;take;%s]button[7.2,3.5;2.2,0.8;dump;%s]"):format(F(S("Take out ANFO")), F(S("Dump")))
		.. "list[current_player;main;0.4,4.9;8,4;]"
		.. ("listring[%s;an]listring[current_player;main]listring[%s;fo]listring[current_player;main]"):format(spos, spos)
end
local open = {}      -- 玩家 → 打開的槽
local function show(pos, name)
	local inv = core.get_meta(pos):get_inventory()
	if inv:get_size("an") == 0 then inv:set_size("an", 1); inv:set_size("fo", 1) end      -- 舊版放下的槽
	open[name] = pos
	core.show_formspec(name, "rockmech:mix_trough", formspec(pos))
end

-- 拌好的料取出 ANFO：一包 BAG_KG kg，餘料照比例留下
local function take_anfo(pos, player)
	local meta = core.get_meta(pos)
	local _, _, man, mfo = contents(pos)
	local total = man + mfo * FO_KG_L
	local bags = math.floor(total / BAG_KG + 1e-6)
	if bags < 1 then return end
	local q = rockmech.anfo_power(fuel_frac(man, mfo))
	local stack = ItemStack(ANFO .. " " .. bags)
	stack:get_meta():set_string("q", ("%.3f"):format(q))
	give(player, pos, stack)
	core.log("action", ("[rockmech] %s 從拌和槽取出 ANFO %d 包（硝酸銨 %.1f kg、柴油 %.1f L，比例 %.1f %%，能量 %.2f）")
		:format(player:get_player_name(), bags, man, mfo, 100 * fuel_frac(man, mfo), q))
	local keep = 1 - bags * BAG_KG / total
	meta:set_float("mix_an", man * keep); meta:set_float("mix_fo", mfo * keep)
end

-- 打數字倒入：從玩家背包拿 n 個放進格子（受格子容量限制）
local function pour(pos, player, key, n)
	local s = SLOT[key]
	local inv = core.get_meta(pos):get_inventory()
	local have = inv:get_stack(key, 1):get_count()
	n = math.floor(math.min(n, s.cap - have))
	if n <= 0 then return end
	local got = core.is_creative_enabled(player:get_player_name()) and n
		or player:get_inventory():remove_item("main", ItemStack(s.item .. " " .. n)):get_count()
	if got <= 0 then return end
	inv:set_stack(key, 1, ItemStack(s.item .. " " .. (have + got)))
	core.sound_play(key == "an" and "default_dig_crumbly" or "default_water_footstep", {pos = pos, gain = 0.6, max_hear_distance = 12}, true)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "rockmech:mix_trough" then return end
	local name = player:get_player_name()
	local pos = open[name]
	if fields.quit then open[name] = nil end
	if not pos or not is_trough(pos) or vector.distance(player:get_pos(), pos) > 10 then return true end
	if core.is_protected(pos, name) then return true end
	if busy(pos) then return true end
	local changed = false
	for key in pairs(SLOT) do
		local n = tonumber(fields["n_" .. key])
		if (fields["pour_" .. key] or (fields.key_enter_field == "n_" .. key)) and n and n > 0 then
			pour(pos, player, key, n); changed = true
		end
	end
	if fields.take then take_anfo(pos, player); changed = true end
	if fields.dump then
		local meta = core.get_meta(pos)
		meta:set_float("mix_an", 0); meta:set_float("mix_fo", 0); changed = true
		core.sound_play("default_dig_crumbly", {pos = pos, gain = 0.6, max_hear_distance = 12}, true)
	end
	if changed then
		refresh(pos)
		if not fields.quit then show(pos, name) end
	end
	return true
end)

local function mix(pos)
	local meta = core.get_meta(pos)
	local an, fo = contents(pos)
	meta:set_float("until", core.get_gametime() + MIX_TIME)
	core.add_particlespawner({amount = 40, time = MIX_TIME, minpos = vector.offset(pos, -0.35, -0.1, -0.35), maxpos = vector.offset(pos, 0.35, 0.05, 0.35),
		minvel = {x = -0.6, y = 1.2, z = -0.6}, maxvel = {x = 0.6, y = 2.2, z = 0.6}, minacc = {x = 0, y = -9.8, z = 0}, maxacc = {x = 0, y = -9.8, z = 0},
		minexptime = 0.3, maxexptime = 0.6, minsize = 0.6, maxsize = 1.2, collisiondetection = true,
		texture = "[fill:2x2:" .. (fo > 0 and STATES.wet or STATES.an)})
	for k = 0, MIX_TIME - 1 do
		core.after(k, function() core.sound_play("default_dig_crumbly", {pos = pos, gain = 0.8, max_hear_distance = 16}, true) end)
	end
	core.after(MIX_TIME, function()
		if not is_trough(pos) then return end
		local m = core.get_meta(pos)
		local inv = m:get_inventory()
		local a, f = inv:get_stack("an", 1):get_count(), inv:get_stack("fo", 1):get_count()
		m:set_float("mix_an", m:get_float("mix_an") + a)
		m:set_float("mix_fo", m:get_float("mix_fo") + f)
		inv:set_stack("an", 1, ""); inv:set_stack("fo", 1, "")
		refresh(pos)
	end)
	return an, fo
end
rockmech.mix_trough_mix = mix          -- 測試用
rockmech.mix_trough_take = take_anfo   -- 測試用

local function rightclick(pos, node, clicker, itemstack)
	if not (clicker and clicker:is_player()) then return itemstack end
	local name = clicker:get_player_name()
	if core.is_protected(pos, name) then core.record_protection_violation(pos, name) return itemstack end
	if busy(pos) then return itemstack end
	if itemstack:get_name() == SHOVEL then
		local an, fo, man = contents(pos)
		if an + fo > 0 and an + man > 0 then mix(pos) end      -- 翻拌：要有新加的料，而且有硝酸銨
	else
		show(pos, name)
	end
	return itemstack
end

local function slot_put(pos, listname, _, stack, player)
	local s = SLOT[listname]
	if not s or stack:get_name() ~= s.item or busy(pos) or core.is_protected(pos, player:get_player_name()) then return 0 end
	local have = core.get_meta(pos):get_inventory():get_stack(listname, 1):get_count()
	return math.max(0, math.min(stack:get_count(), s.cap - have))
end
local function slot_take(pos, _, _, stack, player)
	if busy(pos) or core.is_protected(pos, player:get_player_name()) then return 0 end
	return stack:get_count()
end
local function slot_changed(pos) refresh(pos) end

for state, color in pairs({[""] = false, an = STATES.an, wet = STATES.wet, mix = STATES.mix}) do
	local boxes = table.copy(WALL)
	if color then boxes[#boxes + 1] = {-0.42, -0.4, -0.42, 0.42, -0.05, 0.42} end
	local top = "[fill:16x16:" .. STEEL .. (color and ("^[fill:14x14:1,1:" .. color) or "^[fill:14x14:1,1:#4a4e52")
	core.register_node(node_name(state), {
		description = S("Mixing trough"),
		drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
		node_box = {type = "fixed", fixed = boxes},
		selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0.1, 0.5}},
		tiles = {top, "[fill:16x16:" .. STEEL, "[fill:16x16:" .. STEEL},
		inventory_image = state == "" and "[fill:16x16:#00000000^[fill:14x6:1,8:" .. STEEL .. "^[fill:12x3:2,8:#4a4e52" or nil,
		groups = {cracky = 2, oddly_breakable_by_hand = 1, not_in_creative_inventory = state == "" and 0 or 1},
		is_ground_content = false,
		drop = TROUGH,
		sounds = default.node_sound_metal_defaults(),
		on_construct = function(pos)
			local inv = core.get_meta(pos):get_inventory()
			inv:set_size("an", 1); inv:set_size("fo", 1)
		end,
		on_rightclick = rightclick,
		allow_metadata_inventory_put = slot_put,
		allow_metadata_inventory_take = slot_take,
		allow_metadata_inventory_move = function() return 0 end,
		on_metadata_inventory_put = slot_changed,
		on_metadata_inventory_take = slot_changed,
		-- 裡面還有東西不能拆
		can_dig = function(pos)
			local an, fo, man, mfo = contents(pos)
			return an + fo + man + mfo <= 0
		end,
	})
end
