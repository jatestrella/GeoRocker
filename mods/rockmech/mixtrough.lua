-- rockmech/mixtrough.lua
-- 硝酸銨、柴油、拌和槽：沒有裝藥車的時候在拌和槽裡手拌 ANFO。
--   拿硝酸銨（一袋 BAG_KG kg）右鍵倒一袋進去，拿柴油（1 L）右鍵倒 1 L，拿鏟子右鍵翻拌 MIX_TIME 秒，拌好空手右鍵取出 ANFO（袋數 = 硝酸銨袋數）。
--   還沒拌就空手右鍵：硝酸銨收回來，柴油已經滲進去，倒掉。
--   配比（柴油佔總重的比例）決定 ANFO 的相對能量（rockmech.anfo_power），存在每袋 ANFO 的 meta q，
--   倒進孔裡記在孔上（drilling.lua），爆破半徑乘 q^(1/3)。標準配比 94:6（柴油 5.7 %）能量最大。
--   不寫配比說明：玩家要自己算（一袋 25 kg 硝酸銨配約 1.9 L 柴油），wiki 有公式。

local S = rockmech.S
local AN, DIESEL, ANFO = "rockmech:ammonium_nitrate", "rockmech:diesel", "rockmech:anfo"
local SHOVEL = "rockmech:shovel"
local TROUGH = "rockmech:mix_trough"
local BAG_KG = 25           -- 一袋硝酸銨 (kg)
local FO_KG_L = 0.84        -- 柴油密度 (kg/L)
local IDEAL = 0.057         -- 能量最大的柴油重量比例（氧平衡為零）
local MAX_BAGS, MAX_L = 10, 40
local MIX_TIME = 3          -- 翻拌幾秒

-- 柴油重量比例 → 相對能量：柴油不夠時往純硝酸銨（約 0.3）掉，太多時每多 1 % 少 3 %
function rockmech.anfo_power(fo)
	if fo <= IDEAL then return 0.3 + 0.7 * fo / IDEAL end
	return math.max(0.3, 1 - 3 * (fo - IDEAL))
end
local function fuel_frac(bags, litres)
	local fo = litres * FO_KG_L
	return fo / (bags * BAG_KG + fo)
end
rockmech.anfo_fuel_frac = fuel_frac

core.register_craftitem(AN, {
	description = S("Ammonium nitrate"),
	inventory_image = "[fill:16x16:#00000000^[fill:10x12:3,3:#f4f2ec^[fill:10x2:3,3:#d0ccc0^[fill:6x3:5,8:#3060a0",
})
core.register_craftitem(DIESEL, {
	description = S("Diesel"),
	inventory_image = "[fill:16x16:#00000000^[fill:8x11:4,4:#b02818^[fill:4x2:5,2:#303030^[fill:6x1:5,8:#e0c040",
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

local function refresh(pos)
	local meta = core.get_meta(pos)
	local an, fo, mixed = meta:get_int("an"), meta:get_int("fo"), meta:get_int("mixed") == 1
	local state = an == 0 and fo == 0 and "" or mixed and "mix" or fo > 0 and an > 0 and "wet" or an > 0 and "an" or "wet"
	local node = core.get_node(pos)
	local want = node_name(state)
	if node.name ~= want then core.swap_node(pos, {name = want, param2 = node.param2}) end
	meta:set_string("infotext", (an > 0 or fo > 0) and S("Ammonium nitrate @1 bags, diesel @2 L", an, fo) or "")
end

local function busy(pos) return core.get_meta(pos):get_float("until") > core.get_gametime() end

local function rightclick(pos, node, clicker, itemstack)
	if not (clicker and clicker:is_player()) then return itemstack end
	local name = clicker:get_player_name()
	if core.is_protected(pos, name) then core.record_protection_violation(pos, name) return itemstack end
	local meta = core.get_meta(pos)
	local an, fo, mixed = meta:get_int("an"), meta:get_int("fo"), meta:get_int("mixed") == 1
	local item = itemstack:get_name()
	local creative = core.is_creative_enabled(name)
	if busy(pos) then return itemstack end
	if item == AN or item == DIESEL then
		if mixed then return itemstack end
		if item == AN then
			if an >= MAX_BAGS then return itemstack end
			meta:set_int("an", an + 1)
			core.sound_play("default_dig_crumbly", {pos = pos, gain = 0.6, max_hear_distance = 12}, true)
		else
			if fo >= MAX_L then return itemstack end
			meta:set_int("fo", fo + 1)
			core.sound_play("default_water_footstep", {pos = pos, gain = 0.6, max_hear_distance = 12}, true)
		end
		if not creative then itemstack:take_item() end
		refresh(pos)
	elseif item == SHOVEL then
		if mixed or an == 0 then return itemstack end
		-- 翻拌：MIX_TIME 秒，粒料翻動
		meta:set_float("until", core.get_gametime() + MIX_TIME)
		core.add_particlespawner({amount = 40, time = MIX_TIME, minpos = vector.offset(pos, -0.35, -0.1, -0.35), maxpos = vector.offset(pos, 0.35, 0.05, 0.35),
			minvel = {x = -0.6, y = 1.2, z = -0.6}, maxvel = {x = 0.6, y = 2.2, z = 0.6}, minacc = {x = 0, y = -9.8, z = 0}, maxacc = {x = 0, y = -9.8, z = 0},
			minexptime = 0.3, maxexptime = 0.6, minsize = 0.6, maxsize = 1.2, collisiondetection = true,
			texture = "[fill:2x2:" .. (fo > 0 and STATES.wet or STATES.an)})
		for k = 0, MIX_TIME - 1 do
			core.after(k, function() core.sound_play("default_dig_crumbly", {pos = pos, gain = 0.8, max_hear_distance = 16}, true) end)
		end
		core.after(MIX_TIME, function()
			local m = core.get_meta(pos)
			if core.get_node(pos).name:sub(1, #TROUGH) ~= TROUGH or m:get_int("an") == 0 then return end
			m:set_int("mixed", 1)
			refresh(pos)
		end)
	else
		if an == 0 and fo == 0 then return itemstack end
		if mixed then
			local stack = ItemStack(ANFO .. " " .. an)
			local q = rockmech.anfo_power(fuel_frac(an, fo))
			stack:get_meta():set_string("q", ("%.3f"):format(q))
			give(clicker, pos, stack)
			core.log("action", ("[rockmech] %s 從拌和槽取出 ANFO %d 袋（柴油 %d L，比例 %.1f %%，能量 %.2f）"):format(name, an, fo, 100 * fuel_frac(an, fo), q))
		elseif an > 0 then
			give(clicker, pos, ItemStack(AN .. " " .. an))      -- 還沒拌：硝酸銨收回，柴油倒掉
		end
		meta:set_int("an", 0); meta:set_int("fo", 0); meta:set_int("mixed", 0)
		refresh(pos)
	end
	return itemstack
end

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
		on_rightclick = rightclick,
		-- 裡面還有東西不能拆
		can_dig = function(pos)
			local m = core.get_meta(pos)
			return m:get_int("an") == 0 and m:get_int("fo") == 0
		end,
	})
end
