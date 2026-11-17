-- rockmech/slurrytank.lua
-- 穩定液儲槽（含泵）：放在溝槽旁的地面上，管子朝放的人那一側伸出來、管口垂在那一格（溝槽上方）。
-- 把買來的穩定液存進去，泵從管口把穩定液打進底下的溝槽，液面補到設定高度。
--   實務：拌合廠的儲槽用泵一直把穩定液打進溝裡，液面保持在導溝頂下約 0.5 m（而且比地下水位高 1 m 以上），
--   抓斗挖走土、液面一降就補，不然溝壁會塌。
--   目標液面 = 儲槽底（放儲槽那一格的地面）往下 off m（0–3 m，每 0.5 m 一段，預設 0.5 m）。
--   每 TICK 秒：量管口那一欄的液面（空溝槽就從溝底開始灌），低於目標就補，每次最多 RATE 級（泵的能力），
--   補多少扣多少存量（守恆）；補進去的會慢慢流到整條溝槽。
--   拿著穩定液對儲槽按右鍵：整疊存進去。拆掉儲槽：存量照整 m³ 退回背包（不滿 1 m³ 的沒了）。

local S = rockmech.S
local NL = 8
local TANK = "rockmech:slurry_tank"
local TICK = 2                -- 幾秒檢查一次 (s)
local RATE = 16               -- 每次最多補幾級（2 m³ / 2 s）
local DEPTH = 42              -- 管口往下找多深 (格)
local CAP = 200 * NL          -- 存量上限（200 m³）
local OFF_DEFAULT = 0.5

local function m3(lv) return ("%.1f"):format(lv / NL) end
local function off_of(meta)
	local s = meta:get_string("off")
	return s ~= "" and tonumber(s) or OFF_DEFAULT
end
local function info(pos)
	local meta = core.get_meta(pos)
	local st = meta:get_int("stock")
	local s = S("Slurry tank") .. "\n" .. S("Stock @1 m³", m3(st)) .. "\n"
		.. S("Target level: @1 m below the ground at the tank", ("%.1f"):format(off_of(meta)))
	local msg = meta:get_string("msg")
	if msg ~= "" then s = s .. "\n" .. msg end
	meta:set_string("infotext", s)
end
local function may(pos, name)
	local owner = core.get_meta(pos):get_string("owner")
	return rockmech.owner_ok and rockmech.owner_ok(owner, name) or owner == "" or owner == name
end

-- 管口：儲槽前方那一格（照 param2 的方向）
local function outlet(pos)
	local d = core.facedir_to_dir(core.get_node(pos).param2 % 32)
	return {x = pos.x + d.x, y = pos.y, z = pos.z + d.z}
end

local function pump(pos)
	local meta = core.get_meta(pos)
	local st = meta:get_int("stock")
	local H = pos.y - 0.5 - off_of(meta)
	local lvl = rockmech.slurry_level
	local o = outlet(pos)
	local used, msg = 0, ""
	local function at(p) local n = core.get_node(p).name; return n == "air" and 0 or lvl[n] end
	if not at(o) then
		msg = S("The pipe outlet is blocked")
	elseif not at({x = o.x, y = o.y - 1, z = o.z}) then
		msg = S("The pipe is not over a trench")
	else
		-- 管口那一欄：往下穿過空氣到液面（或溝底）
		local q = {x = o.x, y = o.y, z = o.z}
		for _ = 1, DEPTH do
			local below = {x = q.x, y = q.y - 1, z = q.z}
			local kb = at(below)
			if not kb or (at(q) or 0) > 0 then break end
			q = below
		end
		local k = at(q) or 0
		while k == NL and at({x = q.x, y = q.y + 1, z = q.z}) and at({x = q.x, y = q.y + 1, z = q.z}) > 0 do
			q.y = q.y + 1; k = at(q)
		end
		local surface = q.y - 0.5 + k / NL
		local need = math.floor((H - surface) * NL + 0.5)
		if need > 0 then
			local owner = meta:get_string("owner")
			if st <= 0 then msg = S("Out of slurry: the level is dropping")
			elseif core.is_protected(q, owner) then msg = S("The pipe outlet is blocked")
			else
				used = rockmech.slurry_pour(q, math.min(need, RATE, st), math.floor(H + 0.5), true)
				msg = S("Pumping")
			end
		end
	end
	meta:set_int("stock", st - used)
	if meta:get_string("msg") ~= msg or used > 0 then meta:set_string("msg", msg); info(pos) end
end

local function formspec(pos)
	local meta = core.get_meta(pos)
	local F = core.formspec_escape
	return ("formspec_version[6]size[7,3.8]label[0.5,0.6;%s]label[0.5,1.2;%s]"
		.. "button[0.5,1.8;1.2,0.8;dec;−]button[1.9,1.8;1.2,0.8;inc;+]button[3.5,1.8;2.2,0.8;turn;%s]button_exit[4.5,2.8;2,0.7;ok;%s]"):format(
		F(S("Stock @1 m³ (hold slurry and right-click to add)", m3(meta:get_int("stock")))),
		F(S("Target level: @1 m below the ground at the tank", ("%.1f"):format(off_of(meta)))),
		F(S("Turn the pipe")), F(S("Done")))
end
local editing = {}

core.register_node(TANK, {
	description = S("Slurry tank\nThe pipe points back at you: stand at the trench edge and place it on the far side; it keeps the level topped up. Shift + right-click turns it. Right-click with slurry to fill it"),
	short_description = S("Slurry tank"),
	tiles = {
		"[fill:16x16:#7a7f84^[fill:10x10:3,3:#8a7a5c",
		"[fill:16x16:#5a5f64",
		"[fill:16x16:#8c9196^[fill:16x1:0,4:#6a6f74^[fill:16x1:0,11:#6a6f74^[fill:3x5:11,10:#3a6ea8",
	},
	drawtype = "nodebox",
	-- 槽身＋泵＋管子（從前面伸出去、到前方那一格中央往下彎，管口垂在溝槽上方）
	node_box = {type = "fixed", fixed = {
		{-0.45, -0.5, -0.45, 0.45, 0.45, 0.45},          -- 槽身
		{-0.2, -0.5, 0.45, 0.2, -0.1, 0.62},             -- 泵
		{-0.07, 0.15, 0.45, 0.07, 0.29, 1.07},           -- 水平管
		{-0.07, -0.4, 0.93, 0.07, 0.29, 1.07},           -- 往下彎的管
		{-0.1, -0.45, 0.9, 0.1, -0.4, 1.1},              -- 管口
	}},
	selection_box = {type = "fixed", fixed = {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}, {-0.1, -0.45, 0.45, 0.1, 0.3, 1.1}}},
	collision_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}},
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = {cracky = 2, not_in_creative_inventory = 1},
	drop = "",
	on_construct = function(pos)
		core.get_node_timer(pos):start(TICK)
	end,
	after_place_node = function(pos, placer)
		-- 管子朝放的人那一側伸出來（站在溝邊、面向外放，管口就垂在溝槽上方）
		if placer and placer.get_look_dir then
			local d = placer:get_look_dir()
			core.swap_node(pos, {name = TANK, param2 = core.dir_to_facedir({x = -d.x, y = 0, z = -d.z})})
		end
		local meta = core.get_meta(pos)
		local acc = placer and rockmech.account_of and rockmech.account_of(placer:get_player_name()) or (placer and placer:get_player_name()) or ""
		meta:set_string("owner", acc)
		info(pos)
	end,
	on_timer = function(pos)
		pump(pos)
		return true
	end,
	on_rightclick = function(pos, node, clicker, itemstack)
		if not (clicker and clicker:is_player()) then return itemstack end
		local name = clicker:get_player_name()
		if not may(pos, name) then return itemstack end
		if itemstack:get_name() == rockmech.SLURRY_ITEM then
			local meta = core.get_meta(pos)
			local st = meta:get_int("stock")
			local n = math.min(itemstack:get_count(), math.floor((CAP - st) / NL))
			if n > 0 then
				meta:set_int("stock", st + n * NL)
				itemstack:take_item(n)
				info(pos)
			end
			return itemstack
		end
		if clicker:get_player_control().sneak then
			local node2 = core.get_node(pos)
			core.swap_node(pos, {name = TANK, param2 = (node2.param2 % 4 + 1) % 4})
			return itemstack
		end
		editing[name] = pos
		core.show_formspec(name, "rockmech:slurry_tank", formspec(pos))
		return itemstack
	end,
	can_dig = function(pos, player)
		return player and may(pos, player:get_player_name())
	end,
	on_dig = function(pos, node, digger)
		if not (digger and digger:is_player() and may(pos, digger:get_player_name())) then return false end
		local n = math.floor(core.get_meta(pos):get_int("stock") / NL)
		local inv = digger:get_inventory()
		local back = {ItemStack(TANK)}
		while n > 0 do
			local k = math.min(n, 99)
			back[#back + 1] = ItemStack(rockmech.SLURRY_ITEM .. " " .. k)
			n = n - k
		end
		core.remove_node(pos)
		for _, st in ipairs(back) do
			local left = inv and inv:add_item("main", st) or st
			if not left:is_empty() then core.add_item(pos, left) end
		end
		return true
	end,
})

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "rockmech:slurry_tank" then return end
	local name = player:get_player_name()
	local pos = editing[name]
	if not pos or core.get_node(pos).name ~= TANK or not may(pos, name) then return true end
	local meta = core.get_meta(pos)
	if fields.turn then
		local nd = core.get_node(pos)
		core.swap_node(pos, {name = TANK, param2 = (nd.param2 % 4 + 1) % 4})
	end
	if fields.dec then meta:set_string("off", tostring(math.max(0, off_of(meta) - 0.5))) end
	if fields.inc then meta:set_string("off", tostring(math.min(3, off_of(meta) + 0.5))) end
	info(pos)
	if fields.quit or fields.ok then editing[name] = nil
	else core.show_formspec(name, "rockmech:slurry_tank", formspec(pos)) end
	return true
end)

-- 載入時計時器沒在跑（舊地圖、被別的機制改過）就重新開
core.register_lbm({
	label = "rockmech: 穩定液儲槽計時器", name = "rockmech:slurry_tank_timer", nodenames = {TANK}, run_at_every_load = true,
	action = function(pos) if not core.get_node_timer(pos):is_started() then core.get_node_timer(pos):start(TICK) end end,
})
rockmech.SLURRY_TANK = TANK
rockmech.slurry_tank_pump = pump
