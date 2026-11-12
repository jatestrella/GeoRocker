-- rockmech/mixtrough.lua
-- 硝酸銨、柴油、拌和槽：沒有裝藥車的時候在拌和槽裡手拌 ANFO。
--   物品：1 公斤硝酸銨、1 L 柴油（數量就是公斤、公升，學生自己算配比）。
--   右鍵打開拌和槽，介面像合成台：左邊 3×3 格子放硝酸銨、柴油、ANFO（比例不同的也行），可以像箱子一樣拖放
--   （右鍵一次放一個、分一半都行）；按「翻拌」，翻拌 MIX_TIME 秒：格子裡的東西和右邊格子原有的 ANFO 全部拌在一起，
--   每份 ANFO 照它的比例拆成硝酸銨、柴油的重量，加總後重算比例；出 ANFO（1 個 = 1 kg，總重四捨五入）在右邊格子，不留餘料。
--   ANFO 的物品說明寫上重量比（硝酸銨 : 柴油）。meta f = 柴油比例、q = 相對能量（rockmech.anfo_power），
--   倒進孔裡記在孔上（drilling.lua，分次倒的也照重量平均），爆破半徑乘 q^(1/3)。標準配比 94:6（柴油 5.7 %）能量最大。
--   不寫配比說明：玩家要自己算（25 kg 硝酸銨配約 1.8 L 柴油），wiki 有公式。

local S = rockmech.S
local F = core.formspec_escape
local AN, DIESEL, ANFO = "rockmech:ammonium_nitrate", "rockmech:diesel", "rockmech:anfo"
local TROUGH = "rockmech:mix_trough"
local FO_KG_L = 0.84        -- 柴油密度 (kg/L)
local IDEAL = 0.057         -- 能量最大的柴油重量比例（氧平衡為零）
local MIX_TIME = 3          -- 翻拌幾秒
local INPUT = {[AN] = true, [DIESEL] = true, [ANFO] = true}      -- 3×3 格子放得進去的東西
local MAX_OUT = 1000        -- 槽裡（格子＋右邊格子）最多幾 kg

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
	inventory_image = "[fill:16x16:#00000000^[fill:10x12:3,3:#9a7c50^[fill:10x2:3,3:#7a6040^[fill:6x3:5,7:#2850a0",
	stack_max = 1000,
})
core.register_craftitem(DIESEL, {
	description = S("1 L diesel"),
	inventory_image = "[fill:16x16:#00000000^[fill:8x11:4,4:#b02818^[fill:4x2:5,2:#303030^[fill:6x1:5,8:#e0c040",
	stack_max = 200,
})

-- 外觀：槽底＋四面槽壁；裝了東西多一層內容物（白 = 只有硝酸銨或 ANFO、灰黃 = 倒了柴油還沒拌、粉紅 = 拌好的 ANFO）
local STEEL = "#6f7479"
local WALL = {{-0.5, -0.5, -0.5, 0.5, -0.4, 0.5}, {-0.5, -0.4, -0.5, 0.5, 0.1, -0.42}, {-0.5, -0.4, 0.42, 0.5, 0.1, 0.5},
	{-0.5, -0.4, -0.42, -0.42, 0.1, 0.42}, {0.42, -0.4, -0.42, 0.5, 0.1, 0.42}}
local STATES = {[""] = nil, an = "#f2f0ea", wet = "#cfc6ac", mix = "#e9c4c8"}
local function node_name(state) return state == "" and TROUGH or TROUGH .. "_" .. state end
local function is_trough(pos) return core.get_node(pos).name:sub(1, #TROUGH) == TROUGH end

local function get_inv(pos)
	local inv = core.get_meta(pos):get_inventory()
	if inv:get_size("in") == 0 then
		inv:set_size("in", 9); inv:set_size("out", 1)
		-- 舊版的槽：硝酸銨、柴油、ANFO 格搬進 3×3 格子
		for k, l in ipairs({"an", "fo", "anfo"}) do
			if inv:get_size(l) > 0 then inv:set_stack("in", k, inv:get_stack(l, 1)); inv:set_size(l, 0) end
		end
	end
	return inv
end
-- 槽裡：格子裡的硝酸銨 kg、柴油 L、ANFO kg，右邊的 ANFO kg
local function contents(pos)
	local inv = get_inv(pos)
	local an, fo, am = 0, 0, 0
	for _, st in ipairs(inv:get_list("in")) do
		local n = st:get_name()
		if n == AN then an = an + st:get_count() elseif n == DIESEL then fo = fo + st:get_count() elseif n == ANFO then am = am + st:get_count() end
	end
	return an, fo, inv:get_stack("out", 1):get_count(), am
end

-- ANFO 物品：n kg、柴油重量比例 f；meta f（比例）、q（威力）、description（寫上重量比）
local function anfo_f(stack)
	local f = tonumber(stack:get_meta():get_string("f"))
	return f or IDEAL
end
local function anfo_stack(n, f)
	local stack = ItemStack(ANFO .. " " .. n)
	local m = stack:get_meta()
	m:set_string("f", ("%.4f"):format(f))
	m:set_string("q", ("%.3f"):format(rockmech.anfo_power(f)))
	m:set_string("description", S("1 kg ANFO") .. "\n" .. S("Ammonium nitrate : diesel = @1 : @2", ("%.1f"):format(100 - 100 * f), ("%.1f"):format(100 * f)))
	return stack
end
rockmech.anfo_f = anfo_f
rockmech.anfo_stack = anfo_stack

local function refresh(pos)
	local meta = core.get_meta(pos)
	local an, fo, out, am = contents(pos)
	local state = an + fo > 0 and (fo > 0 and "wet" or "an") or (out + am > 0 and "mix" or "")
	local node = core.get_node(pos)
	local want = node_name(state)
	if node.name ~= want then core.swap_node(pos, {name = want, param2 = node.param2}) end
	local t = {}
	if an + fo > 0 then t[#t + 1] = S("Ammonium nitrate @1 kg, diesel @2 L", an, fo) end
	if out + am > 0 then t[#t + 1] = "ANFO " .. (out + am) .. " kg" end
	meta:set_string("infotext", table.concat(t, "\n"))
end

local function busy(pos) return core.get_meta(pos):get_float("until") > core.get_gametime() end

local ARROW = "gui_furnace_arrow_bg.png^[transformR270"
local ARROW_ON = "gui_furnace_arrow_fg.png^[transformR270"
local function formspec(pos)
	local spos = ("nodemeta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	return "formspec_version[6]size[10.75,9.4]"
		.. ("list[%s;in;0.9,0.4;3,3;]"):format(spos)
		.. ("image[5.1,1.65;1,1;%s]button[4.8,2.8;1.6,0.8;mix;%s]"):format(busy(pos) and ARROW_ON or ARROW, F(S("Mix")))
		.. ("list[%s;out;7.2,1.65;1,1;]"):format(spos)
		.. "list[current_player;main;0.4,4.2;8,4;]"
		.. ("listring[%s;out]listring[current_player;main]listring[%s;in]listring[current_player;main]"):format(spos, spos)
end
local open = {}      -- 玩家 → 打開的槽
local function show(pos, name)
	open[name] = pos
	core.show_formspec(name, "rockmech:mix_trough", formspec(pos))
end
local function reshow(pos)      -- 開著這個槽的人重畫介面
	for name, p in pairs(open) do
		if vector.equals(p, pos) and core.get_player_by_name(name) then show(pos, name) end
	end
end

-- 翻拌：格子裡所有東西加上右邊格子原有的 ANFO 全部拌在一起，不留餘料。
-- 每份 ANFO 照它的比例拆成硝酸銨和柴油的重量，加總後重算比例；總重四捨五入到 kg
local function mix_done(pos, name)
	if not is_trough(pos) then return end
	local inv = get_inv(pos)
	local m_an, m_fo = 0, 0        -- 硝酸銨 kg、柴油 kg
	local list = inv:get_list("in")
	list[#list + 1] = inv:get_stack("out", 1)
	for _, st in ipairs(list) do
		local n, c = st:get_name(), st:get_count()
		if n == AN then m_an = m_an + c
		elseif n == DIESEL then m_fo = m_fo + c * FO_KG_L
		elseif n == ANFO then m_an = m_an + c * (1 - anfo_f(st)); m_fo = m_fo + c * anfo_f(st) end
	end
	for k = 1, inv:get_size("in") do
		if INPUT[inv:get_stack("in", k):get_name()] then inv:set_stack("in", k, "") end
	end
	local n = math.floor(m_an + m_fo + 0.5)
	if n > 0 then
		local f = m_fo / (m_an + m_fo)
		inv:set_stack("out", 1, anfo_stack(n, f))
		core.log("action", ("[rockmech] %s 在拌和槽拌出 ANFO 共 %d kg（硝酸銨 %.1f kg、柴油 %.1f kg，比例 %.1f %%，能量 %.2f）")
			:format(name or "?", n, m_an, m_fo, 100 * f, rockmech.anfo_power(f)))
	else
		inv:set_stack("out", 1, "")
	end
	refresh(pos)
	reshow(pos)
end

-- 開始翻拌：左邊要有新放的東西，槽裡要有硝酸銨（或 ANFO）；右邊格子放得下
local function mix(pos, name)
	if busy(pos) then return false end
	local an, fo, out, am = contents(pos)
	if an + fo + am <= 0 or an + am + out <= 0 or out + an + fo * FO_KG_L + am > MAX_OUT + 0.5 then return false end
	core.get_meta(pos):set_float("until", core.get_gametime() + MIX_TIME)
	core.add_particlespawner({amount = 40, time = MIX_TIME, minpos = vector.offset(pos, -0.35, -0.1, -0.35), maxpos = vector.offset(pos, 0.35, 0.05, 0.35),
		minvel = {x = -0.6, y = 1.2, z = -0.6}, maxvel = {x = 0.6, y = 2.2, z = 0.6}, minacc = {x = 0, y = -9.8, z = 0}, maxacc = {x = 0, y = -9.8, z = 0},
		minexptime = 0.3, maxexptime = 0.6, minsize = 0.6, maxsize = 1.2, collisiondetection = true,
		texture = "[fill:2x2:" .. (fo > 0 and STATES.wet or STATES.an)})
	for k = 0, MIX_TIME - 1 do
		core.after(k, function() core.sound_play("default_dig_crumbly", {pos = pos, gain = 0.8, max_hear_distance = 16}, true) end)
	end
	core.after(MIX_TIME, mix_done, pos, name)
	reshow(pos)
	return true
end
rockmech.mix_trough_mix = mix          -- 測試用

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "rockmech:mix_trough" then return end
	local name = player:get_player_name()
	local pos = open[name]
	if fields.quit then open[name] = nil end
	if not pos or not is_trough(pos) or vector.distance(player:get_pos(), pos) > 10 then return true end
	if core.is_protected(pos, name) or busy(pos) then return true end
	if fields.mix then mix(pos, name) end
	return true
end)

local function rightclick(pos, node, clicker, itemstack)
	if not (clicker and clicker:is_player()) then return itemstack end
	local name = clicker:get_player_name()
	if core.is_protected(pos, name) then core.record_protection_violation(pos, name) return itemstack end
	show(pos, name)
	return itemstack
end

-- 放料：槽裡總重（格子＋右邊的 ANFO）最多 MAX_OUT kg，柴油照密度換算
local function slot_put(pos, listname, _, stack, player)
	if listname ~= "in" or not INPUT[stack:get_name()] or busy(pos) or core.is_protected(pos, player:get_player_name()) then return 0 end
	local an, fo, out, am = contents(pos)
	local room = MAX_OUT - (an + fo * FO_KG_L + out + am)
	local per = stack:get_name() == DIESEL and FO_KG_L or 1
	return math.max(0, math.min(stack:get_count(), math.floor(room / per + 1e-6)))
end
local function slot_take(pos, listname, _, stack, player)
	if (listname ~= "out" and busy(pos)) or core.is_protected(pos, player:get_player_name()) then return 0 end
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
		on_construct = function(pos) get_inv(pos) end,
		on_rightclick = rightclick,
		allow_metadata_inventory_put = slot_put,
		allow_metadata_inventory_take = slot_take,
		allow_metadata_inventory_move = function(pos, from, _, to, _, count, player)      -- 格子裡互相搬
			if from ~= "in" or to ~= "in" or busy(pos) or core.is_protected(pos, player:get_player_name()) then return 0 end
			return count
		end,
		on_metadata_inventory_put = slot_changed,
		on_metadata_inventory_take = slot_changed,
		-- 裡面還有東西不能拆
		can_dig = function(pos)
			local an, fo, out, am = contents(pos)
			return an + fo + out + am <= 0
		end,
	})
end
