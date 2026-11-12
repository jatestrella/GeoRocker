-- rockmech/mixtrough.lua
-- 硝酸銨、柴油、拌和槽：沒有裝藥車的時候在拌和槽裡手拌 ANFO。
--   物品：1 公斤硝酸銨、1 L 柴油（數量就是公斤、公升，學生自己算配比）。
--   右鍵打開拌和槽，介面像熔爐：左邊硝酸銨格（最多 MAX_KG kg）、柴油格（最多 MAX_L L），
--   可以像箱子一樣拖放（右鍵一次放一個、分一半都行），也可以打數字按「倒入」；
--   按「翻拌」，翻拌 MIX_TIME 秒：左邊的料全部拌成 ANFO（1 個 = 1 kg，總重四捨五入），出在右邊的格子，不留餘料。
--   ANFO 格：放進比例不對的 ANFO 一起重拌（可以補硝酸銨或柴油修正比例）。翻拌時槽裡所有 ANFO（ANFO 格、右邊原有的）
--   照各自的比例拆成硝酸銨、柴油的重量，跟新加的料加總後重算比例（背包裡比例不同的 ANFO 引擎不讓疊在一起）。
--   ANFO 的物品說明寫上重量比（硝酸銨 : 柴油）。meta f = 柴油比例、q = 相對能量（rockmech.anfo_power），
--   倒進孔裡記在孔上（drilling.lua，分次倒的也照重量平均），爆破半徑乘 q^(1/3)。標準配比 94:6（柴油 5.7 %）能量最大。
--   不寫配比說明：玩家要自己算（25 kg 硝酸銨配約 1.8 L 柴油），wiki 有公式。

local S = rockmech.S
local F = core.formspec_escape
local AN, DIESEL, ANFO = "rockmech:ammonium_nitrate", "rockmech:diesel", "rockmech:anfo"
local TROUGH = "rockmech:mix_trough"
local FO_KG_L = 0.84        -- 柴油密度 (kg/L)
local IDEAL = 0.057         -- 能量最大的柴油重量比例（氧平衡為零）
local MAX_KG, MAX_L = 250, 40
local MIX_TIME = 3          -- 翻拌幾秒
local SLOT = {an = {item = AN, cap = MAX_KG}, fo = {item = DIESEL, cap = MAX_L}, anfo = {item = ANFO, cap = MAX_KG}}

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

-- 外觀：槽底＋四面槽壁；裝了東西多一層內容物（白 = 硝酸銨、灰黃 = 倒了柴油還沒拌、粉紅 = 拌好的 ANFO）
local STEEL = "#6f7479"
local WALL = {{-0.5, -0.5, -0.5, 0.5, -0.4, 0.5}, {-0.5, -0.4, -0.5, 0.5, 0.1, -0.42}, {-0.5, -0.4, 0.42, 0.5, 0.1, 0.5},
	{-0.5, -0.4, -0.42, -0.42, 0.1, 0.42}, {0.42, -0.4, -0.42, 0.5, 0.1, 0.42}}
local STATES = {[""] = nil, an = "#f2f0ea", wet = "#cfc6ac", mix = "#e9c4c8"}
local function node_name(state) return state == "" and TROUGH or TROUGH .. "_" .. state end
local function is_trough(pos) return core.get_node(pos).name:sub(1, #TROUGH) == TROUGH end

local function get_inv(pos)
	local inv = core.get_meta(pos):get_inventory()
	if inv:get_size("anfo") == 0 then      -- 舊版放下的槽
		inv:set_size("an", 1); inv:set_size("fo", 1); inv:set_size("anfo", 1); inv:set_size("out", 1)
	end
	return inv
end
-- 槽裡：左邊格子（硝酸銨 kg、柴油 L、要重拌的 ANFO kg）、右邊的 ANFO（kg）
local function contents(pos)
	local inv = get_inv(pos)
	return inv:get_stack("an", 1):get_count(), inv:get_stack("fo", 1):get_count(), inv:get_stack("out", 1):get_count(),
		inv:get_stack("anfo", 1):get_count()
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
	local row = function(y, key, unit, cap)
		return ("list[%s;%s;0.4,%.2f;1,1;]field[1.65,%.2f;1.5,0.8;n_%s;;]label[3.25,%.2f;%s]button[3.85,%.2f;1.5,0.8;pour_%s;%s]tooltip[%s;≤ %d %s]")
			:format(spos, key, y, y + 0.1, key, y + 0.5, unit, y + 0.1, key, F(S("Pour")), key, cap, unit)
	end
	return "formspec_version[6]size[10.75,10.2]"
		.. row(0.5, "an", "kg", MAX_KG) .. row(1.8, "fo", "L", MAX_L)
		.. ("list[%s;anfo;0.4,3.1;1,1;]tooltip[0.4,3.1;1,1;ANFO ≤ %d kg]"):format(spos, MAX_KG)
		.. ("image[5.9,1.15;1,1;%s]button[5.6,2.3;1.6,0.8;mix;%s]"):format(busy(pos) and ARROW_ON or ARROW, F(S("Mix")))
		.. ("list[%s;out;7.6,1.15;1,1;]"):format(spos)
		.. "list[current_player;main;0.4,4.7;8,4;]"
		.. ("listring[%s;out]listring[current_player;main]listring[%s;an]listring[current_player;main]"):format(spos, spos)
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

-- 翻拌：槽裡所有東西（左邊的硝酸銨、柴油、要重拌的 ANFO，加上右邊格子原有的 ANFO）全部拌在一起，不留餘料。
-- 每份 ANFO 照它的比例拆成硝酸銨和柴油的重量，加總後重算比例；總重四捨五入到 kg
local function mix_done(pos, name)
	if not is_trough(pos) then return end
	local inv = get_inv(pos)
	local an, fo = inv:get_stack("an", 1):get_count(), inv:get_stack("fo", 1):get_count()
	local a, o = inv:get_stack("anfo", 1), inv:get_stack("out", 1)
	inv:set_stack("an", 1, ""); inv:set_stack("fo", 1, ""); inv:set_stack("anfo", 1, "")
	local m_an = an + a:get_count() * (1 - anfo_f(a)) + o:get_count() * (1 - anfo_f(o))     -- 硝酸銨 kg
	local m_fo = fo * FO_KG_L + a:get_count() * anfo_f(a) + o:get_count() * anfo_f(o)        -- 柴油 kg
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
	if an + fo + am <= 0 or an + am + out <= 0 or out + an + fo + am > 1000 then return false end
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

-- 打數字倒入：從玩家背包拿 n 個放進格子（受格子容量限制）
local function pour(pos, player, key, n)
	local s = SLOT[key]
	local inv = get_inv(pos)
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
	if core.is_protected(pos, name) or busy(pos) then return true end
	local changed = false
	for key in pairs(SLOT) do
		local n = tonumber(fields["n_" .. key])
		if (fields["pour_" .. key] or fields.key_enter_field == "n_" .. key) and n and n > 0 then
			pour(pos, player, key, n); changed = true
		end
	end
	if fields.mix then mix(pos, name) end
	if changed then
		refresh(pos)
		if not fields.quit then show(pos, name) end
	end
	return true
end)

local function rightclick(pos, node, clicker, itemstack)
	if not (clicker and clicker:is_player()) then return itemstack end
	local name = clicker:get_player_name()
	if core.is_protected(pos, name) then core.record_protection_violation(pos, name) return itemstack end
	show(pos, name)
	return itemstack
end

local function slot_put(pos, listname, _, stack, player)
	local s = SLOT[listname]
	if not s or stack:get_name() ~= s.item or busy(pos) or core.is_protected(pos, player:get_player_name()) then return 0 end
	local have = get_inv(pos):get_stack(listname, 1):get_count()
	return math.max(0, math.min(stack:get_count(), s.cap - have))
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
		allow_metadata_inventory_move = function() return 0 end,
		on_metadata_inventory_put = slot_changed,
		on_metadata_inventory_take = slot_changed,
		-- 裡面還有東西不能拆
		can_dig = function(pos)
			local an, fo, out, am = contents(pos)
			return an + fo + out + am <= 0
		end,
	})
end
