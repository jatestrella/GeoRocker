-- rockmech/slurrytank.lua
-- 穩定液供應：儲槽 → 穩定液管 → 出液口（垂在溝槽上方），自動把溝槽液面補到設定高度。
--   實務：拌合廠的鋼製儲槽（約一個貨櫃大，30–40 m³）好幾個並排，泵浦經管線把穩定液打進溝裡，
--   液面保持在導溝頂下約 0.5 m（而且比地下水位高 1 m 以上）；抓斗挖走土、液面一降就補，不然溝壁會塌。
--
--   儲槽：3 寬 × 6 長 × 3 高的鋼槽，裝 40 m³。往放的人看的方向延伸；靠放的人那一端的底層中央是控制格，
--         槽壁伸出一段帶法蘭的短管（接管口），穩定液管只接這裡。
--         右鍵：拿著穩定液 → 存進去；空手 → 面板（存量、把背包裡的穩定液全部存入、取出 1／10 m³）。
--         挖控制格：拆掉整個儲槽，存量照整 m³ 退回背包。
--   穩定液管：一格一格鋪，自動跟旁邊的管、儲槽的接管口、出液口接起來（上下也接，地形有高低差時往上接）。
--   出液口：放在溝邊，管子朝放的人那一側伸出來、往下彎，管口垂在那一格（溝槽）上方。Shift＋右鍵、面板按鈕轉向。
--         目標液面 = 出液口那一格的地面往下 off m（0–3 m，每 0.5 m 一段，預設 0.5 m）。
--         每 TICK 秒：量管口那一欄的液面（空溝槽就從溝底開始灌），低於目標就補，每次最多 RATE 級（泵的能力），
--         從管線接到的儲槽裡扣（守恆），補進去的會慢慢流到整條溝槽。

local S = rockmech.S
local NL = 8
local TANK = "rockmech:slurry_tank"            -- 物品，也是控制格
local SHELL = "rockmech:slurry_tank_shell"     -- 儲槽的其他格
local PIPE = "rockmech:slurry_pipe"
local OUTLET = "rockmech:slurry_outlet"
local TICK = 2                -- 幾秒檢查一次 (s)
local RATE = 16               -- 每次最多補幾級（2 m³ / 2 s）
local DEPTH = 42              -- 管口往下找多深 (格)
local CAP = 40 * NL           -- 一個儲槽的容量（40 m³）
local L, H3 = 6, 3            -- 儲槽長、高（格；寬 3）
local NET_MAX = 400           -- 管線最多找幾格
local OFF_DEFAULT = 0.5

local function m3(lv) return ("%.1f"):format(lv / NL) end
local function may(pos, name)
	local owner = core.get_meta(pos):get_string("owner")
	return rockmech.owner_ok and rockmech.owner_ok(owner, name) or owner == "" or owner == name
end
local function horiz_facedir(player)
	local d = player and player.get_look_dir and player:get_look_dir() or {x = 0, y = 0, z = 1}
	return core.dir_to_facedir({x = d.x, y = 0, z = d.z})
end

---------------------------------------------------------------------------
-- 儲槽
---------------------------------------------------------------------------
-- 儲槽的格子：控制格 pos、方向 param2（往前延伸 L 格、左右各 1 格、往上 H3 格）
local function tank_cells(pos, param2)
	local d = core.facedir_to_dir(param2 % 4)
	local r = {x = d.z, z = -d.x}
	local out = {}
	for i = 0, L - 1 do for j = -1, 1 do for y = 0, H3 - 1 do
		out[#out + 1] = {x = pos.x + d.x * i + r.x * j, y = pos.y + y, z = pos.z + d.z * i + r.z * j}
	end end end
	return out
end
-- 液位計：接管口正上方兩格（靠放的人那一端的中間）是透明的玻璃管，裡面的穩定液高度 = 存量比例（2 格共 32 像素）
local GAUGE = "rockmech:slurry_tank_gauge_"
local IS_SHELL = {[SHELL] = true}
for k = 0, 16 do IS_SHELL[GAUGE .. k] = true end
local function update_gauge(pos)
	local p2 = core.get_node(pos).param2 % 4
	local f = math.max(0, math.min(1, core.get_meta(pos):get_int("stock") / CAP))
	local px = math.floor(f * 32 + 0.5)
	for i, fill in ipairs({math.min(16, px), math.max(0, px - 16)}) do
		local g = {x = pos.x, y = pos.y + i, z = pos.z}
		local n = core.get_node(g)
		local want = GAUGE .. fill
		if IS_SHELL[n.name] and (n.name ~= want or n.param2 ~= p2) then
			core.swap_node(g, {name = want, param2 = p2})       -- swap_node 保留 meta（所屬的儲槽）
		end
	end
end
local function tank_info(pos)
	local meta = core.get_meta(pos)
	meta:set_string("infotext", S("Slurry tank") .. "\n" .. S("Stock @1 / @2 m³", m3(meta:get_int("stock")), CAP / NL))
	update_gauge(pos)
end
-- 這一格屬於哪個儲槽（控制格的位置）
local function tank_of(p)
	local n = core.get_node(p).name
	if n == TANK then return p end
	if IS_SHELL[n] then
		local s = core.get_meta(p):get_string("tank")
		local c = s ~= "" and core.string_to_pos(s)
		if c and core.get_node(c).name == TANK then return c end
	end
end

local STEEL = "[fill:16x16:#8c9196^[fill:16x1:0,0:#6a6f74^[fill:1x16:0,0:#6a6f74"
local STEEL_TOP = "[fill:16x16:#7a7f84^[fill:16x1:0,0:#6a6f74^[fill:1x16:0,0:#6a6f74^[fill:6x6:5,5:#5a5f64"
local PORT = STEEL .. "^[fill:16x3:0,13:#3a6ea8"

local function tank_formspec(pos)
	local F = core.formspec_escape
	local st = core.get_meta(pos):get_int("stock")
	return ("formspec_version[6]size[8,3.6]label[0.5,0.6;%s]label[0.5,1.1;%s]"
		.. "button[0.5,1.6;3.4,0.8;put;%s]button[4.1,1.6;1.6,0.8;take1;%s]button[5.9,1.6;1.6,0.8;take10;%s]button_exit[5.5,2.6;2,0.7;ok;%s]"):format(
		F(S("Stock @1 / @2 m³", m3(st), CAP / NL)),
		F(S("Connect a slurry pipe to the valve on the blue side")),
		F(S("Put in all slurry")), F(S("Take 1 m³")), F(S("Take 10 m³")), F(S("Done")))
end
local tank_editing = {}
-- 手上拿著方塊（穩定液管…）：照常放下去，不開面板（右鍵點設施時放東西）
local function place_held(itemstack, clicker, pointed)
	-- 儲槽本身（多格，有自己的 on_place）不在這裡放：按 Shift 放
	if pointed and core.registered_nodes[itemstack:get_name()] and itemstack:get_name() ~= TANK then
		return core.item_place_node(itemstack, clicker, pointed) or itemstack, true
	end
	return itemstack, false
end

local function store(pos, clicker, itemstack)
	local c = tank_of(pos)
	if not c then return itemstack end
	local meta = core.get_meta(c)
	local st = meta:get_int("stock")
	local n = math.min(itemstack:get_count(), math.floor((CAP - st) / NL))
	if n > 0 then
		meta:set_int("stock", st + n * NL)
		itemstack:take_item(n)
		tank_info(c)
	elseif clicker then
		rockmech.notify(clicker:get_player_name(), S("The slurry tank is full"))
	end
	return itemstack
end

core.register_node(SHELL, {
	description = S("Slurry tank"),
	tiles = {STEEL_TOP, STEEL, STEEL},
	is_ground_content = false, diggable = false, drop = "",
	groups = {not_in_creative_inventory = 1},
	on_rightclick = function(pos, node, clicker, itemstack, pointed)
		local c = tank_of(pos)
		if not (c and clicker and clicker:is_player() and may(c, clicker:get_player_name())) then return itemstack end
		if itemstack:get_name() == rockmech.SLURRY_ITEM then return store(pos, clicker, itemstack) end
		local st, placed = place_held(itemstack, clicker, pointed)
		if placed then return st end
		tank_editing[clicker:get_player_name()] = c
		core.show_formspec(clicker:get_player_name(), "rockmech:slurry_tank", tank_formspec(c))
		return itemstack
	end,
})

-- 液位計的格子：跟槽壁一樣，只是正面（朝放的人）有一條玻璃管，刻度每 1/4
do
	local base = table.copy(core.registered_nodes[SHELL])
	for k = 0, 16 do
		local front = STEEL .. "^[fill:6x16:5,0:#3a3f44^[fill:4x16:6,0:#b8ccd6"
			.. (k > 0 and ("^[fill:4x" .. k .. ":6," .. (16 - k) .. ":#8a7a5c") or "")
			.. "^[fill:2x1:2,0:#3a3f44^[fill:2x1:2,8:#3a3f44"
		local d = table.copy(base)
		d.tiles = {STEEL_TOP, STEEL, STEEL, STEEL, STEEL, front}
		d.paramtype2 = "facedir"
		d.on_rightclick = base.on_rightclick
		core.register_node(GAUGE .. k, d)
	end
end

core.register_node(TANK, {
	description = S("Slurry tank\n40 m³ steel tank, 3 × 6 × 3 m, built in the direction you look. Connect it to a slurry outlet with slurry pipes. Right-click with slurry to fill it"),
	short_description = S("Slurry tank"),
	tiles = {STEEL_TOP, STEEL, STEEL, STEEL, STEEL, PORT},
	drawtype = "nodebox",
	-- 槽身這一格＋往放的人那側（−z）伸出來的接管口：短管、法蘭
	node_box = {type = "fixed", fixed = {
		{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
		{-0.1, -0.5, -0.85, 0.1, -0.28, -0.5},          -- 短管（跟穩定液管同高）
		{-0.2, -0.5, -0.62, 0.2, -0.1, -0.56},          -- 法蘭
		{-0.04, -0.28, -0.75, 0.04, -0.12, -0.67},      -- 閥桿
		{-0.16, -0.12, -0.78, 0.16, -0.08, -0.64},      -- 閥輪
	}},
	selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}},
	collision_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}},
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = {cracky = 2, not_in_creative_inventory = 1},
	drop = "",
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local name = placer:get_player_name()
		local un = core.get_node(pointed.under)
		local udef = core.registered_nodes[un.name]
		if udef and udef.on_rightclick and not placer:get_player_control().sneak then
			return udef.on_rightclick(pointed.under, un, placer, itemstack, pointed) or itemstack
		end
		local pos = vector.copy(pointed.above)
		local p2 = horiz_facedir(placer)
		local cells = tank_cells(pos, p2)
		local passable = rockmech.vehicles.passable
		for _, c in ipairs(cells) do
			local cn = core.get_node(c).name
			local free = passable(cn) and not (rockmech.slurry_level and rockmech.slurry_level[cn]) and not core.is_protected(c, name)
			local ground = c.y ~= pos.y or not passable(core.get_node({x = c.x, y = c.y - 1, z = c.z}).name)
			if not free or not ground then
				rockmech.notify(name, S("[Slurry tank] Needs 3 × 6 m of level, clear ground (3 m high)"))
				return itemstack
			end
		end
		local foot = {}
		for _, c in ipairs(cells) do if c.y == pos.y then foot[#foot + 1] = {c.x, c.z} end end
		local who = rockmech.cells_blocked and rockmech.cells_blocked(foot, pos.y - 1, pos.y + H3 - 1, placer)
		if who then rockmech.notify(name, S("[Slurry tank] There is @1 in the way: move it first", who)); return itemstack end
		local ps = core.pos_to_string(pos)
		for _, c in ipairs(cells) do
			if not vector.equals(c, pos) then
				core.set_node(c, {name = SHELL})
				core.get_meta(c):set_string("tank", ps)
			end
		end
		core.set_node(pos, {name = TANK, param2 = p2})
		local meta = core.get_meta(pos)
		meta:set_string("owner", rockmech.account_of and rockmech.account_of(name) or name)
		meta:set_int("built", 1)
		tank_info(pos)
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	on_rightclick = function(pos, node, clicker, itemstack, pointed)
		if not (clicker and clicker:is_player() and may(pos, clicker:get_player_name())) then return itemstack end
		if itemstack:get_name() == rockmech.SLURRY_ITEM then return store(pos, clicker, itemstack) end
		local st, placed = place_held(itemstack, clicker, pointed)
		if placed then return st end
		tank_editing[clicker:get_player_name()] = pos
		core.show_formspec(clicker:get_player_name(), "rockmech:slurry_tank", tank_formspec(pos))
		return itemstack
	end,
	can_dig = function(pos, player)
		return player and may(pos, player:get_player_name())
	end,
	on_dig = function(pos, node, digger)
		if not (digger and digger:is_player() and may(pos, digger:get_player_name())) then return false end
		local n = math.floor(core.get_meta(pos):get_int("stock") / NL)
		local back = {ItemStack(TANK)}
		while n > 0 do
			local k = math.min(n, 99)
			back[#back + 1] = ItemStack(rockmech.SLURRY_ITEM .. " " .. k)
			n = n - k
		end
		for _, c in ipairs(tank_cells(pos, node.param2)) do
			if IS_SHELL[core.get_node(c).name] then core.remove_node(c) end
		end
		core.remove_node(pos)
		local inv = digger:get_inventory()
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
	local pos = tank_editing[name]
	if not pos or core.get_node(pos).name ~= TANK or not may(pos, name) then return true end
	local meta = core.get_meta(pos)
	local inv = player:get_inventory()
	local ITEM = rockmech.SLURRY_ITEM
	if fields.put and inv then
		local st = meta:get_int("stock")
		local have = 0
		for _, s in ipairs(inv:get_list("main")) do if s:get_name() == ITEM then have = have + s:get_count() end end
		local n = math.min(have, math.floor((CAP - st) / NL))
		if n > 0 then
			inv:remove_item("main", ItemStack(ITEM .. " " .. n))
			meta:set_int("stock", st + n * NL)
		end
	end
	for key, want in pairs({take1 = 1, take10 = 10}) do
		if fields[key] and inv then
			local st = meta:get_int("stock")
			local n = math.min(want, math.floor(st / NL))
			if n > 0 then
				local left = inv:add_item("main", ItemStack(ITEM .. " " .. n))
				n = n - left:get_count()
				meta:set_int("stock", st - n * NL)
			end
		end
	end
	tank_info(pos)
	if fields.quit or fields.ok then tank_editing[name] = nil
	else core.show_formspec(name, "rockmech:slurry_tank", tank_formspec(pos)) end
	return true
end)

---------------------------------------------------------------------------
-- 穩定液管
---------------------------------------------------------------------------
do
	local r = 0.09
	local lo, hi = -0.5, -0.5 + 2 * r + 0.04     -- 貼地
	core.register_node(PIPE, {
		description = S("Slurry pipe\nConnects slurry tanks to a slurry outlet"),
		short_description = S("Slurry pipe"),
		drawtype = "nodebox",
		paramtype = "light",
		sunlight_propagates = true,
		tiles = {"[fill:16x16:#3a3f44^[fill:16x2:0,6:#5a5f64"},
		inventory_image = "[fill:16x16:#00000000^[fill:16x4:0,6:#3a3f44^[fill:16x1:0,7:#5a5f64",
		node_box = {
			type = "connected",
			fixed = {-r, lo, -r, r, hi, r},
			connect_front = {-r, lo, -0.5, r, hi, -r},
			connect_back = {-r, lo, r, r, hi, 0.5},
			connect_left = {-0.5, lo, -r, -r, hi, r},
			connect_right = {r, lo, -r, 0.5, hi, r},
			connect_top = {-r, lo, -r, r, 0.5, r},
		},
		connects_to = {PIPE, TANK, OUTLET},
		is_ground_content = false,
		walkable = false,
		groups = {cracky = 3, oddly_breakable_by_hand = 2, not_in_creative_inventory = 1},
	})
end

---------------------------------------------------------------------------
-- 出液口
---------------------------------------------------------------------------
local function off_of(meta)
	local s = meta:get_string("off")
	return s ~= "" and tonumber(s) or OFF_DEFAULT
end
-- 管線接到的儲槽（控制格位置，不重複）
local NB6 = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
local function tanks_of(pos)
	local seen, queue, tanks, got = {[core.hash_node_position(pos)] = true}, {pos}, {}, {}
	local i = 1
	while queue[i] and #queue < NET_MAX do
		local c = queue[i]; i = i + 1
		for _, d in ipairs(NB6) do
			local n = {x = c.x + d[1], y = c.y + d[2], z = c.z + d[3]}
			local h = core.hash_node_position(n)
			if not seen[h] then
				seen[h] = true
				local name = core.get_node(n).name
				if name == PIPE then
					queue[#queue + 1] = n
				else
					local t = name == TANK and n
					if t then
						local k = core.hash_node_position(t)
						if not got[k] then got[k] = true; tanks[#tanks + 1] = t end
					end
				end
			end
		end
	end
	return tanks
end
local function outlet_info(pos, tanks)
	local meta = core.get_meta(pos)
	tanks = tanks or tanks_of(pos)
	local st = 0
	for _, t in ipairs(tanks) do st = st + core.get_meta(t):get_int("stock") end
	local s = S("Slurry outlet") .. "\n" .. S("Target level: @1 m below the ground here", ("%.1f"):format(off_of(meta))) .. "\n"
		.. S("Connected tanks: @1, stock @2 m³", #tanks, m3(st))
	local msg = meta:get_string("msg")
	if msg ~= "" then s = s .. "\n" .. msg end
	meta:set_string("infotext", s)
end
-- 管口：出液口前方那一格（照 param2 的方向）
local function mouth(pos)
	local d = core.facedir_to_dir(core.get_node(pos).param2 % 4)
	return {x = pos.x + d.x, y = pos.y, z = pos.z + d.z}
end

local function pump(pos)
	local meta = core.get_meta(pos)
	local H = pos.y - 0.5 - off_of(meta)
	local lvl = rockmech.slurry_level
	local o = mouth(pos)
	local tanks = tanks_of(pos)
	local st = 0
	for _, t in ipairs(tanks) do st = st + core.get_meta(t):get_int("stock") end
	local used, msg = 0, ""
	local function at(p) local n = core.get_node(p).name; return n == "air" and 0 or lvl[n] end
	if #tanks == 0 then
		msg = S("Not connected to a slurry tank")
	elseif not at(o) then
		msg = S("The pipe outlet is blocked")
	elseif not at({x = o.x, y = o.y - 1, z = o.z}) then
		msg = S("The pipe is not over a trench")
	else
		-- 管口那一欄：往下穿過空氣到液面（或溝底）
		local q = {x = o.x, y = o.y, z = o.z}
		for _ = 1, DEPTH do
			local below = {x = q.x, y = q.y - 1, z = q.z}
			if not at(below) or (at(q) or 0) > 0 then break end
			q = below
		end
		local k = at(q) or 0
		while k == NL and (at({x = q.x, y = q.y + 1, z = q.z}) or 0) > 0 do
			q.y = q.y + 1; k = at(q)
		end
		local need = math.floor((H - (q.y - 0.5 + k / NL)) * NL + 0.5)
		if need > 0 then
			if st <= 0 then msg = S("Out of slurry: the level is dropping")
			elseif core.is_protected(q, meta:get_string("owner")) then msg = S("The pipe outlet is blocked")
			else
				used = rockmech.slurry_pour(q, math.min(need, RATE, st), math.floor(H + 0.5), true)
				msg = S("Pumping")
				-- 從接到的儲槽扣（先扣存量多的）
				table.sort(tanks, function(a, b) return core.get_meta(a):get_int("stock") > core.get_meta(b):get_int("stock") end)
				local left = used
				for _, t in ipairs(tanks) do
					if left <= 0 then break end
					local tm = core.get_meta(t)
					local take = math.min(left, tm:get_int("stock"))
					tm:set_int("stock", tm:get_int("stock") - take)
					left = left - take
					tank_info(t)
				end
			end
		end
	end
	meta:set_string("msg", msg)
	outlet_info(pos, tanks)
end

local function turn(pos)
	local nd = core.get_node(pos)
	core.swap_node(pos, {name = OUTLET, param2 = (nd.param2 % 4 + 1) % 4})
end
local function formspec(pos)
	local meta = core.get_meta(pos)
	local F = core.formspec_escape
	return ("formspec_version[6]size[7,3.2]label[0.5,0.6;%s]"
		.. "button[0.5,1.2;1.2,0.8;dec;−]button[1.9,1.2;1.2,0.8;inc;+]button[3.5,1.2;2.2,0.8;turn;%s]button_exit[4.5,2.2;2,0.7;ok;%s]"):format(
		F(S("Target level: @1 m below the ground here", ("%.1f"):format(off_of(meta)))),
		F(S("Turn the pipe")), F(S("Done")))
end
local editing = {}

core.register_node(OUTLET, {
	description = S("Slurry outlet\nThe pipe points back at you: stand at the trench edge and place it on the far side. Connect it to slurry tanks with slurry pipes; keeps the trench level topped up. Shift + right-click turns it"),
	short_description = S("Slurry outlet"),
	tiles = {"[fill:16x16:#3a6ea8^[fill:8x8:4,4:#2a4e78", "[fill:16x16:#3a3f44", "[fill:16x16:#4a7eb8^[fill:16x1:0,8:#2a4e78"},
	drawtype = "nodebox",
	-- 閥箱＋管子（從前面伸出去、到前方那一格中央往下彎，管口垂在溝槽上方）＋後面接管線的短管
	node_box = {type = "fixed", fixed = {
		{-0.3, -0.5, -0.3, 0.3, 0.1, 0.3},               -- 閥箱
		{-0.07, -0.1, 0.3, 0.07, 0.04, 1.07},            -- 水平管
		{-0.07, -0.4, 0.93, 0.07, 0.04, 1.07},           -- 往下彎的管
		{-0.1, -0.45, 0.9, 0.1, -0.4, 1.1},              -- 管口
		{-0.09, -0.5, -0.5, 0.09, -0.28, -0.3},          -- 接管線
	}},
	selection_box = {type = "fixed", fixed = {{-0.3, -0.5, -0.3, 0.3, 0.1, 0.3}, {-0.1, -0.45, 0.3, 0.1, 0.05, 1.1}}},
	collision_box = {type = "fixed", fixed = {-0.3, -0.5, -0.3, 0.3, 0.1, 0.3}},
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	groups = {cracky = 2, not_in_creative_inventory = 1},
	on_construct = function(pos) core.get_node_timer(pos):start(TICK) end,
	after_place_node = function(pos, placer)
		-- 管子朝放的人那一側伸出來（站在溝邊、往外放，管口就垂在溝槽上方）
		if placer and placer.get_look_dir then
			local d = placer:get_look_dir()
			core.swap_node(pos, {name = OUTLET, param2 = core.dir_to_facedir({x = -d.x, y = 0, z = -d.z})})
		end
		local meta = core.get_meta(pos)
		meta:set_string("owner", placer and rockmech.account_of and rockmech.account_of(placer:get_player_name()) or (placer and placer:get_player_name()) or "")
		outlet_info(pos)
	end,
	on_timer = function(pos)
		pump(pos)
		return true
	end,
	on_rightclick = function(pos, node, clicker, itemstack, pointed)
		if not (clicker and clicker:is_player()) then return itemstack end
		local name = clicker:get_player_name()
		local st, placed = place_held(itemstack, clicker, pointed)
		if placed then return st end
		if not may(pos, name) then return itemstack end
		if clicker:get_player_control().sneak then turn(pos); return itemstack end
		editing[name] = pos
		core.show_formspec(name, "rockmech:slurry_outlet", formspec(pos))
		return itemstack
	end,
	can_dig = function(pos, player) return player and may(pos, player:get_player_name()) end,
})

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "rockmech:slurry_outlet" then return end
	local name = player:get_player_name()
	local pos = editing[name]
	if not pos or core.get_node(pos).name ~= OUTLET or not may(pos, name) then return true end
	local meta = core.get_meta(pos)
	if fields.turn then turn(pos) end
	if fields.dec then meta:set_string("off", tostring(math.max(0, off_of(meta) - 0.5))) end
	if fields.inc then meta:set_string("off", tostring(math.min(3, off_of(meta) + 0.5))) end
	outlet_info(pos)
	if fields.quit or fields.ok then editing[name] = nil
	else core.show_formspec(name, "rockmech:slurry_outlet", formspec(pos)) end
	return true
end)

-- 載入時計時器沒在跑就重新開；舊版的單格儲槽（沒有槽身）換成出液口
core.register_lbm({
	label = "rockmech: 穩定液出液口計時器", name = "rockmech:slurry_outlet_timer", nodenames = {OUTLET, TANK}, run_at_every_load = true,
	action = function(pos, node)
		if node.name == TANK then
			if core.get_meta(pos):get_int("built") == 1 then update_gauge(pos); return end
			core.swap_node(pos, {name = OUTLET, param2 = node.param2})
		end
		if not core.get_node_timer(pos):is_started() then core.get_node_timer(pos):start(TICK) end
	end,
})
rockmech.SLURRY_TANK, rockmech.SLURRY_OUTLET, rockmech.SLURRY_PIPE = TANK, OUTLET, PIPE
rockmech.slurry_outlet_pump = pump
rockmech.slurry_tanks_of = tanks_of
