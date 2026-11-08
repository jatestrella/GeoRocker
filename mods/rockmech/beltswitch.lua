-- rockmech/beltswitch.lua
-- 輸送帶控制箱：放在輸送帶旁邊（同一層的前後左右），控制它貼著的那幾格輸送帶。
--   運轉：照常走。停止：那一格不動也不吸料，料過不去，上游跟著塞住停下（下游照常把料送完）。
--   依礦價：今天的礦價 ≥ 設定的價格才運轉，不然停止。
--   用法例：輸送帶從高處倒料堆成料堆，另一條埋在料堆底下的輸送帶吸料出去，出口接控制箱，
--   價格低時囤著、價格好時自動送去破碎站賣（輸送帶埋在料堆下面照樣會從頭頂吸料，見 conveyor.lua）。
--   設定存在 mod storage（輸送帶那塊區塊沒載入時也照樣判斷）；放的人（分了組就是整組）才能改、才能拆。

local S = rockmech.S
local E = core.formspec_escape
local cfg = rockmech.cfg
local storage = rockmech.collapse.storage

local ITEM = "rockmech:belt_switch"
local ITEM_OFF = "rockmech:belt_switch_off"     -- 停止中（紅燈）
local FORM = "rockmech:belt_switch"
local KEY = "belt_switches"

local list = core.deserialize(storage:get_string(KEY)) or {}    -- 位置字串 → {mode = "run"|"stop"|"price", price = $/t, owner}
local function save() storage:set_string(KEY, core.serialize(list)) end

local function main_ore() for _, ore in pairs(cfg.ores) do return ore end end
local function price_now()
	local ore = main_ore()
	return ore and rockmech.ore_price and rockmech.ore_price(ore) or 0
end
local function running(s)
	if s.mode == "stop" then return false end
	if s.mode == "price" then return price_now() >= (s.price or 0) end
	return true
end

-- 給 conveyor.lua：這一步停住的輸送帶格（位置 hash 的集合）
local stopped = {}
function rockmech.belt_stopped() return stopped end

local SIDES = {{x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1}}
local function refresh()
	stopped = {}
	for ps, s in pairs(list) do
		local p = core.string_to_pos(ps)
		local on = running(s)
		if p and not on then
			for _, d in ipairs(SIDES) do stopped[core.hash_node_position({x = p.x + d.x, y = p.y, z = p.z + d.z})] = true end
		end
		-- 燈號：載入了才換
		local n = p and core.get_node_or_nil(p)
		if n and (n.name == ITEM or n.name == ITEM_OFF) then
			local want = on and ITEM or ITEM_OFF
			if n.name ~= want then core.swap_node(p, {name = want, param2 = n.param2}) end
		end
	end
end
local t = 0
core.register_globalstep(function(dtime)
	t = t + dtime
	if t < 1 then return end
	t = 0
	refresh()
end)
core.after(0, refresh)

local function mode_text(s)
	if s.mode == "stop" then return S("Stopped") end
	if s.mode == "price" then
		return S("Runs when the price is at least $@1/t", ("%.0f"):format(s.price or 0)) .. "  " .. (running(s) and S("Running") or S("Stopped"))
	end
	return S("Running")
end
local function set_info(ps)
	local s, p = list[ps], core.string_to_pos(ps)
	if s and p then core.get_meta(p):set_string("infotext", S("Conveyor control box") .. "\n" .. mode_text(s)) end
end

local editing = {}       -- 玩家名稱 → 位置字串
local function form(ps)
	local s = list[ps] or {mode = "run"}
	local ore = main_ore()
	local function btn(x, key, label, on)
		return ("style[%s;bgcolor=%s]button[%g,1.9;3,0.8;%s;%s]"):format(key, on and "#3f8f4f" or "#3a3e44", x, key, E(label))
	end
	return table.concat({
		"formspec_version[6]size[10.4,4.6]",
		("label[0.5,0.6;%s]"):format(E(S("Conveyor control box"))),
		("label[0.5,1.2;%s]"):format(E(ore and S("Today's @1 price $@2/t", S(ore.label), ("%.0f"):format(price_now())) or "")),
		btn(0.5, "run", S("Run"), s.mode == "run"),
		btn(3.7, "stop", S("Stop"), s.mode == "stop"),
		btn(6.9, "price", S("By ore price"), s.mode == "price"),
		("field[0.5,3.5;3,0.8;p;%s;%s]"):format(E(S("Run at or above $/t")), ("%.0f"):format(s.price or (ore and ore.price) or 0)),
		"field_close_on_enter[p;false]",
		("button[3.7,3.5;3,0.8;setp;%s]"):format(E(S("Set price"))),
	})
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	local name = player:get_player_name()
	local ps = editing[name]
	local s = ps and list[ps]
	if not s then return true end
	if fields.quit then editing[name] = nil; return true end
	if not (rockmech.owner_ok and not rockmech.owner_ok(s.owner or "", name)) then
		local v = tonumber(fields.p)
		if v then s.price = math.max(0, v) end
		if fields.run then s.mode = "run" elseif fields.stop then s.mode = "stop"
		elseif fields.price or fields.setp then s.mode = "price" end
		save(); refresh(); set_info(ps)
	end
	core.show_formspec(name, FORM, form(ps))
	return true
end)
core.register_on_leaveplayer(function(player) editing[player:get_player_name()] = nil end)

-- 外觀：灰色配電箱，正面一顆燈（綠：運轉、紅：停止）
local function face(lamp)
	return "[fill:16x16:#8a9096^[fill:14x14:1,1:#7a8086^[fill:6x2:5,3:#2a2a2a^[fill:4x4:6,8:#202020^[fill:2x2:7,9:" .. lamp
end
local SIDE = "[fill:16x16:#7a8086^[fill:16x1:0,0:#5a6066"
for _, v in ipairs({{ITEM, "#40e060", false}, {ITEM_OFF, "#e04040", true}}) do
	core.register_node(v[1], {
		description = S("Conveyor control box\nPlace it next to a belt; right-click to set run, stop or run by ore price"),
		short_description = S("Conveyor control box"),
		drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
		node_box = {type = "fixed", fixed = {{-0.3, -0.5, -0.1, 0.3, 0.1, 0.3}, {-0.05, -0.5, 0.3, 0.05, -0.2, 0.4}}},
		tiles = {SIDE, SIDE, SIDE, SIDE, SIDE, face(v[2])},
		inventory_image = "[fill:16x16:#00000000^[fill:10x12:3,2:#7a8086^[fill:2x2:7,5:#40e060^[fill:4x1:6,9:#2a2a2a",
		groups = {dig_immediate = 2, not_in_creative_inventory = v[3] and 1 or 0},     -- 徒手、拿什麼都拿得起來
		drop = ITEM,
		is_ground_content = false,
		after_place_node = function(pos, placer)
			local ps = core.pos_to_string(pos)
			local name = placer and placer:get_player_name() or ""
			list[ps] = {mode = "run", owner = rockmech.account_of and name ~= "" and rockmech.account_of(name) or name}
			local ore = main_ore()
			list[ps].price = ore and ore.price or 0
			save(); set_info(ps)
		end,
		on_rightclick = function(pos, node, clicker)
			if not (clicker and clicker:is_player()) then return end
			local ps = core.pos_to_string(pos)
			if not list[ps] then list[ps] = {mode = "run", owner = ""}; save() end
			editing[clicker:get_player_name()] = ps
			core.show_formspec(clicker:get_player_name(), FORM, form(ps))
		end,
		can_dig = function(pos, player)
			local s = list[core.pos_to_string(pos)]
			return player and (not (s and rockmech.owner_ok) or rockmech.owner_ok(s.owner or "", player:get_player_name()))
		end,
		on_destruct = function(pos)
			list[core.pos_to_string(pos)] = nil
			save()
			core.after(0, refresh)
		end,
		on_blast = function() end,     -- 炸不壞（跟營地設施一樣，免得囤的料被別人炸開關）
	})
end

-- 測試用：直接改設定
function rockmech.belt_switch_set(pos, mode, price)
	local s = list[core.pos_to_string(pos)]
	if s then s.mode = mode; s.price = price or s.price; save(); refresh() end
end
