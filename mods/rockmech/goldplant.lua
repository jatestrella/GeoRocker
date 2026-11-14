-- rockmech/goldplant.lua
-- 提金廠（碳浸法 CIL：氰化物溶出金、活性碳吸附、電解、熔鑄）：褐鐵礦裡的金是細粒金，包在氧化鐵裡，重力選選不出來，要用化學法。
-- 3×3 的廠房，頂上一層格柵：輸送帶頭倒在格柵上進料（卡車、怪手倒上去也行），每秒 rockmech_plant_rate 噸。
-- 每噸料：金回收 cfg.elements.au.cil_recovery，營運費 cil_op，藥劑費隨有害雜質增加（硫、砷會吃掉氰化物：每 1% 多 cil_reagent/100）。
-- 提出來的金是背包物品「金」（1 個 = 1 g），存在機器裡，或切換成放進旁邊的箱子。
-- 提完的料（尾礦：鐵和有害雜質還在、金只剩一點）從機身後面吐出來堆著，堆滿了就停機，要用怪手清走。
-- 金價每個交易日浮動（跟礦價同一套均值回歸），營地的貴金屬商收購。

local cfg = rockmech.cfg
local S = rockmech.S
local V = rockmech.vehicles
local H = rockmech.hopper_lib
local A = rockmech.assay
local storage = rockmech.collapse.storage
local NLEV = V.NLEV

local GOLD_PLANT, GOLD = "rockmech:gold_plant", "rockmech:gold"
local E = cfg.elements.au
local TAIL_CAP = 8 * NLEV           -- 機器裡最多積幾級尾礦（後面堆不下時）
local TAIL_H = 6                    -- 尾礦堆最高幾格
local SLOTS = 4                     -- 存金的格數（每格 1000 g）

---------------------------------------------------------------------------
-- 金價：每個交易日開盤走一步（均值回歸，跟 crusher.lua 的礦價同一組參數）
---------------------------------------------------------------------------
local GP, GP_PREV, GP_DAY = "price:gold", "price_prev:gold", "price_day:gold"
local function gold_factor() return storage:contains(GP) and storage:get_float(GP) or 1 end
function rockmech.gold_price() return E.price * gold_factor() end
local function gauss()
	return math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
end
local function gold_market()
	local today = rockmech.market_day()
	if not storage:contains(GP_DAY) then storage:set_int(GP_DAY, today); return end
	local days = today - storage:get_int(GP_DAY)
	if days <= 0 then return end
	storage:set_int(GP_DAY, today)
	storage:set_float(GP_PREV, gold_factor())
	local lo, hi = math.log(cfg.price_min), math.log(cfg.price_max)
	for _ = 1, math.min(days, 30) do
		local x = math.log(gold_factor())
		x = math.max(lo, math.min(hi, x - cfg.price_revert * x + cfg.price_vol * gauss()))
		storage:set_float(GP, math.exp(x))
	end
end
local mt = 0
core.register_globalstep(function(dtime)
	mt = mt + dtime
	if mt < 5 then return end
	mt = 0
	gold_market()
end)
local function gold_change()
	local prev = storage:contains(GP_PREV) and storage:get_float(GP_PREV) or 1
	return gold_factor() / prev - 1
end

---------------------------------------------------------------------------
-- 物品：金（1 個 = 1 g）
---------------------------------------------------------------------------
core.register_craftitem(GOLD, {
	description = S("Gold (1 g)"),
	short_description = S("Gold"),
	inventory_image = "[fill:16x16:#00000000^[fill:12x6:2,6:#b8860b^[fill:10x4:3,6:#ffd34d^[fill:4x1:4,7:#fff3b0",
	stack_max = 1000,
})

---------------------------------------------------------------------------
-- 提金廠：3×3 的廠房（高 BODY_H），頂上一層格柵；控制箱在最下面中央（物品放下去的那一格）
---------------------------------------------------------------------------
local BODY_H = 3                    -- 廠房高 (m)，頂上再一層格柵
local WALL, GRATE, RIM, RIM_C = "rockmech:gold_plant_wall", "rockmech:gold_plant_grate", "rockmech:gold_plant_rim", "rockmech:gold_plant_rim_corner"
-- 料斗：格柵外圍一圈 1 m 高、往內 45° 的斜面（3×3 的小料斗），輸送帶倒下來的料不會從格柵邊流到地上。
-- 邊是斜楔（模型的高邊在 +z，照 param2 轉到朝外），四個角是內凹的角（高邊在 +x、+z）
local function rim_cells(pos)
	local out, y = {}, pos.y + BODY_H + 1
	for x = pos.x - 2, pos.x + 2 do for z = pos.z - 2, pos.z + 2 do
		if math.abs(x - pos.x) == 2 or math.abs(z - pos.z) == 2 then out[#out + 1] = {x = x, y = y, z = z} end
	end end
	return out
end
local function top_of(pos) return pos.y + BODY_H end        -- 格柵那一層
local function tails_of(meta) return core.deserialize(meta:get_string("tails")) or {} end
local function tails_total(t) local n = 0; for _, v in pairs(t) do n = n + (v.lv or 0) end; return n end
-- 尾礦口：廠房後面（背對蓋的人）緊貼牆外那一欄
local function outlet(pos, meta)
	return {x = pos.x - meta:get_int("dx") * 2, y = pos.y, z = pos.z - meta:get_int("dz") * 2}
end
-- 旁邊的置物箱（廠房四周一圈、地面那層或上一層，有 main 這個物品欄的方塊）
local function chest_near(pos)
	for x = pos.x - 2, pos.x + 2 do for z = pos.z - 2, pos.z + 2 do for y = pos.y, pos.y + 1 do
		if math.abs(x - pos.x) == 2 or math.abs(z - pos.z) == 2 then
			local p = {x = x, y = y, z = z}
			local n = core.get_node(p).name
			if n ~= "air" and n ~= "ignore" then
				local inv = core.get_meta(p):get_inventory()
				if inv:get_size("main") > 0 then return p, inv end
			end
		end
	end end end
end
-- 整克的金放出去：存機器裡，或放進旁邊的置物箱（滿了留在機器裡）
local function put_gold(pos, meta, grams)
	if grams <= 0 then return end
	local st = ItemStack(GOLD .. " " .. grams)
	if meta:get_string("mode") == "chest" then
		local _, inv = chest_near(pos)
		if inv then st = inv:add_item("main", st) end
	end
	if not st:is_empty() then st = meta:get_inventory():add_item("gold", st) end
	if not st:is_empty() then meta:set_float("frac", meta:get_float("frac") + st:get_count()) end     -- 都滿了：先記著
end
-- 格柵上的碎石（往上 3 格）：輸送帶頭倒下來的、卡車怪手倒上去的
local function intake(pos, want, take)
	local top = top_of(pos)
	local got = 0
	for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do
		for y = top + 3, top + 1, -1 do
			if want - got < 1 then return got end
			local p = {x = x, y = y, z = z}
			if rockmech.rubble_level[core.get_node(p).name] then
				local t, base, p2, ca = V.take_rubble(p, math.floor(want - got))
				if t > 0 then got = got + t; take(t, base, p2, ca) end
			end
		end
	end end
	return got
end

local function step(pos, dtime)
	local meta = core.get_meta(pos)
	local owner = meta:get_string("owner")
	local tails = tails_of(meta)
	-- 1. 尾礦吐到後面
	local out = outlet(pos, meta)
	for base, v in pairs(tails) do
		local k = math.floor(v.lv)
		if k >= 1 then
			local left = V.deposit_column(out.x, out.z, out.y + TAIL_H, base, k, TAIL_H, nil, A.bin_comp(v, base))
			A.bin_take(v, k - left)
		end
		if v.lv < 1e-6 then tails[base] = nil end
	end
	-- 2. 吃料、提金（每秒 rockmech_plant_rate 噸）
	local room = math.floor(TAIL_CAP - tails_total(tails))
	local stopped = meta:get_int("stopped") == 1
	local tons, au_in, gold, cost = 0, 0, 0, 0
	if room >= 1 and not stopped then
		local budget = meta:get_float("carry") + cfg.plant_rate * dtime / H.tons_of(1)
		local want = math.min(math.floor(budget), room)
		local got = intake(pos, want, function(t, base, p2, ca)
			ca = A.c(ca)
			local tn = H.tons_of(t)
			local au, harm = ca.au or 0, ca.harm or 0
			local g = tn * au * 1e6
			tons, au_in = tons + tn, au_in + g
			gold = gold + g * E.cil_recovery
			cost = cost + tn * (E.cil_op + E.cil_reagent * harm)
			local tc = A.copy(ca)
			if tc.au then tc.au = au * (1 - E.cil_recovery) end
			tails[base] = A.bin_put(tails[base] or {lv = 0, q = 0}, base, t, tc)
		end)
		meta:set_float("carry", got > 0 and budget - math.floor(budget) or 0)
		if got > 0 then rockmech.collapse.rubble_sound({x = pos.x, y = top_of(pos), z = pos.z}, got) end
	end
	meta:set_string("tails", core.serialize(tails))
	if tons > 0 then
		rockmech.add_money(owner, -cost)
		for k, v in pairs({total_t = tons, total_au = au_in, total_gold = gold, total_cost = cost}) do
			meta:set_float(k, meta:get_float(k) + v)
		end
		local f = meta:get_float("frac") + gold
		local whole = math.floor(f)
		meta:set_float("frac", f - whole)
		put_gold(pos, meta, whole)
	end
	meta:set_float("stall", (tons == 0 and room < 1) and 1 or 0)
	meta:set_string("infotext", S("Gold plant") .. (stopped and ("  " .. S("Stopped")) or ""))
end

local function queue_levels(pos)
	local top, n = top_of(pos), 0
	for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do for y = top + 1, top + 3 do
		n = n + (rockmech.rubble_level[core.get_node({x = x, y = y, z = z}).name] or 0)
	end end end
	return n
end

local function formspec(pos)
	local meta = core.get_meta(pos)
	local spos = ("nodemeta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	local stopped = meta:get_int("stopped") == 1
	local t, au = meta:get_float("total_t"), meta:get_float("total_au")
	local status = stopped and S("Stopped") or meta:get_float("stall") > 0 and S("Tailings pile full: clear it behind the plant") or S("Running")
	local chest = meta:get_string("mode") == "chest"
	local L = function(x, y, s) return ("label[%g,%g;%s]"):format(x, y, core.formspec_escape(s)) end
	return table.concat({
		"formspec_version[6]size[11.2,11]",
		L(0.5, 0.6, S("Gold plant") .. "   " .. status),
		("button[8,0.2;2.7,0.8;toggle;%s]"):format(core.formspec_escape(stopped and S("Start") or S("Stop"))),
		L(0.5, 1.3, S("Feed: a conveyor belt onto the grating on top   On the grating @1 t", ("%.1f"):format(H.tons_of(queue_levels(pos))))),
		L(0.5, 1.9, S("Recovery @1%   Running cost $@2/t   Reagents +$@3/t per 1% harmful impurities",
			("%.0f"):format(E.cil_recovery * 100), ("%g"):format(E.cil_op), ("%g"):format(E.cil_reagent / 100))),
		L(0.5, 2.6, S("Processed @1 t, average gold @2 g/t", ("%.0f"):format(t), ("%.2f"):format(t > 0 and au / t or 0))),
		L(0.5, 3.2, S("Gold recovered @1 g, costs $@2", ("%.0f"):format(meta:get_float("total_gold")), ("%.0f"):format(meta:get_float("total_cost")))),
		L(0.5, 3.8, S("Tailings come out behind the plant")),
		"image[5.5,4.6;1,1;gui_furnace_arrow_bg.png^[transformR270]",
		("list[%s;gold;6.8,4.4;%d,1;]"):format(spos, SLOTS),
		("button[0.5,4.4;4.5,0.8;mode;%s]"):format(core.formspec_escape(chest and S("Gold goes into the chest beside the plant") or S("Gold is kept in the plant"))),
		"list[current_player;main;0.6,6;8,4;]",
		("listring[%s;gold]listring[current_player;main]"):format(spos),
	})
end

local form_pos = {}
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= GOLD_PLANT then return end
	local name = player:get_player_name()
	local pos = form_pos[name]
	if fields.quit then form_pos[name] = nil; return true end
	if not (pos and core.get_node(pos).name == GOLD_PLANT) then return true end
	local meta = core.get_meta(pos)
	if not rockmech.owner_ok(meta:get_string("owner"), name) then return true end
	if fields.toggle then meta:set_int("stopped", meta:get_int("stopped") == 1 and 0 or 1) end
	if fields.mode then meta:set_string("mode", meta:get_string("mode") == "chest" and "" or "chest") end
	step(pos, 0)
	core.show_formspec(name, GOLD_PLANT, formspec(pos))
	return true
end)
core.register_on_leaveplayer(function(player) form_pos[player:get_player_name()] = nil end)

-- 能不能蓋：3×3 地面平、底下實心，廠房和格柵上面淨空
local function site_ok(pos)
	for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do
		if V.passable(core.get_node({x = x, y = pos.y - 1, z = z}).name) then return false end
		for y = pos.y, top_of(pos) + 3 do
			local n = core.get_node({x = x, y = y, z = z}).name
			if not (x == pos.x and y == pos.y and z == pos.z) and not V.passable(n) then return false end
		end
	end end
	for _, p in ipairs(rim_cells(pos)) do if not V.passable(core.get_node(p).name) then return false end end
	return true
end
rockmech.gold_plant_site_ok = site_ok

local function build(pos, dx, dz, name)
	if not site_ok(pos) then return false end
	for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do
		for y = pos.y, top_of(pos) - 1 do
			if not (x == pos.x and y == pos.y and z == pos.z) then core.set_node({x = x, y = y, z = z}, {name = WALL}) end
		end
		core.set_node({x = x, y = top_of(pos), z = z}, {name = GRATE})
	end end
	for _, p in ipairs(rim_cells(pos)) do
		local ox, oz = p.x - pos.x, p.z - pos.z
		if math.abs(ox) == 2 and math.abs(oz) == 2 then
			-- 角：找轉向 f，讓模型的 +z（facedir_to_dir(f)）和 +x（facedir_to_dir(f + 1)）都朝外
			for f = 0, 3 do
				local a, b = core.facedir_to_dir(f), core.facedir_to_dir((f + 1) % 4)
				if a.x + b.x == ox / 2 and a.z + b.z == oz / 2 then core.set_node(p, {name = RIM_C, param2 = f}); break end
			end
		else
			local o = {x = math.abs(ox) == 2 and ox / 2 or 0, y = 0, z = math.abs(oz) == 2 and oz / 2 or 0}
			core.set_node(p, {name = RIM, param2 = core.dir_to_facedir(o)})
		end
	end
	core.set_node(pos, {name = GOLD_PLANT})
	local meta = core.get_meta(pos)
	meta:set_string("owner", rockmech.account_of(name))
	meta:set_int("dx", dx)
	meta:set_int("dz", dz)
	meta:get_inventory():set_size("gold", SLOTS)
	-- 區塊一直載入（人走遠了輸送帶、提金廠照常跑）；拆掉時放掉
	local bp = {x = math.floor(pos.x / 16) * 16, y = math.floor(pos.y / 16) * 16, z = math.floor(pos.z / 16) * 16}
	core.forceload_block(bp, false, -1)
	meta:set_int("forceload", 1)
	core.get_node_timer(pos):start(1)
	step(pos, 0)
	return true
end

local BODY = "[fill:16x16:#6a6a62^[fill:16x3:0,0:#c9a227^[fill:16x2:0,14:#303030"
local FRONT = BODY .. "^[fill:6x5:5,6:#2a2a2a^[fill:4x1:6,8:#40c040"
core.register_node(WALL, {
	description = S("Gold plant"),
	tiles = {BODY}, groups = {not_in_creative_inventory = 1}, diggable = false, is_ground_content = false, drop = "",
})
core.register_node(GRATE, {
	description = S("Gold plant"),
	tiles = {"[fill:16x16:#181818^[fill:16x3:0,1:#8a8a8a^[fill:16x3:0,9:#8a8a8a^[fill:3x16:1,0:#8a8a8a^[fill:3x16:9,0:#8a8a8a", BODY},
	groups = {not_in_creative_inventory = 1}, diggable = false, is_ground_content = false, drop = "",
})
-- 斜面的碰撞：四階（人站上去不會浮著）
local side_box, corner_box = {}, {}
for i = 0, 3 do
	local y1, t = -0.5 + (i + 1) * 0.25, -0.5 + i * 0.25
	side_box[#side_box + 1] = {-0.5, -0.5, t, 0.5, y1, 0.5}
	corner_box[#corner_box + 1] = {-0.5, -0.5, t, 0.5, y1, 0.5}
	corner_box[#corner_box + 1] = {t, -0.5, -0.5, 0.5, y1, 0.5}
end
local STEEL = "[fill:16x16:#8a8478^[fill:16x1:0,0:#6a645a^[fill:16x1:0,8:#6a645a"
for _, d in ipairs({{RIM, "rockmech_hopper_side.obj", side_box}, {RIM_C, "rockmech_hopper_corner.obj", corner_box}}) do
	core.register_node(d[1], {
		description = S("Gold plant"),
		drawtype = "mesh", mesh = d[2], paramtype = "light", paramtype2 = "facedir",
		tiles = {{name = STEEL, backface_culling = false}},
		collision_box = {type = "fixed", fixed = d[3]}, selection_box = {type = "fixed", fixed = d[3]},
		groups = {not_in_creative_inventory = 1}, diggable = false, is_ground_content = false, drop = "",
	})
end
core.register_node(GOLD_PLANT, {
	description = S("Gold plant\nRight-click on flat ground to build"),
	short_description = S("Gold plant"),
	tiles = {BODY, BODY, FRONT, FRONT, FRONT, FRONT},
	groups = {cracky = 2},
	is_ground_content = false,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local pos = pointed.above
		local look = placer:get_look_dir()
		local dx, dz = 0, 0
		if math.abs(look.x) > math.abs(look.z) then dx = look.x > 0 and -1 or 1
		else dz = look.z > 0 and -1 or 1 end
		local name = placer:get_player_name()
		if not build(pos, dx, dz, name) then
			rockmech.notify(name, S("[Gold plant] Place it on flat ground: 3×3 m, solid below and @1 m clear above", tostring(BODY_H + 4)))
			return itemstack
		end
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	can_dig = function(pos, player)
		if not player then return false end
		local meta = core.get_meta(pos)
		if not rockmech.owner_ok(meta:get_string("owner"), player:get_player_name()) then return false end
		if not meta:get_inventory():is_empty("gold") then
			rockmech.notify(player:get_player_name(), S("[Gold plant] Take the gold out first"))
			return false
		end
		return true
	end,
	on_rightclick = function(pos, node, clicker)
		local name = clicker:get_player_name()
		form_pos[name] = pos
		step(pos, 0)
		core.show_formspec(name, GOLD_PLANT, formspec(pos))
	end,
	allow_metadata_inventory_put = function() return 0 end,
	allow_metadata_inventory_move = function() return 0 end,
	allow_metadata_inventory_take = function(pos, listname, index, stack, player)
		if not player or not rockmech.owner_ok(core.get_meta(pos):get_string("owner"), player:get_player_name()) then return 0 end
		return stack:get_count()
	end,
	on_timer = function(pos, elapsed)
		step(pos, math.min(elapsed, 5))
		return true
	end,
	on_destruct = function(pos)
		local meta = core.get_meta(pos)
		for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do for y = pos.y, top_of(pos) do
			local p = {x = x, y = y, z = z}
			local n = core.get_node(p).name
			if n == WALL or n == GRATE then core.remove_node(p) end
		end end end
		for _, p in ipairs(rim_cells(pos)) do
			local n = core.get_node(p).name
			if n == RIM or n == RIM_C then core.remove_node(p) end
		end
		if meta:get_int("forceload") == 1 then
			core.forceload_free_block({x = math.floor(pos.x / 16) * 16, y = math.floor(pos.y / 16) * 16, z = math.floor(pos.z / 16) * 16}, false)
		end
	end,
})
core.register_abm({
	label = "rockmech: 提金廠的計時器停了就重新啟動",
	nodenames = {GOLD_PLANT}, interval = 5, chance = 1,
	action = function(pos)
		local t = core.get_node_timer(pos)
		if not t:is_started() then t:start(1) end
	end,
})
rockmech.gold_plant_build = build   -- 測試用
rockmech.gold_plant_step = step

---------------------------------------------------------------------------
-- 貴金屬商：營地研究帳篷後面（經濟分析師旁邊），收購金。只在有褐鐵礦的地圖（斑岩銅礦）出現
---------------------------------------------------------------------------
local has_gold = cfg.strata and cfg.strata.body ~= nil
local WHO, ENTITY, FORM = "dealer", "rockmech:npc_dealer", "rockmech:dealer"

local function count_gold(inv)
	local n = 0
	for _, st in ipairs(inv:get_list("main") or {}) do if st:get_name() == GOLD then n = n + st:get_count() end end
	return n
end
local function dealer_form(name)
	local player = core.get_player_by_name(name)
	local have = player and count_gold(player:get_inventory()) or 0
	local p, c = rockmech.gold_price(), gold_change()
	local L = function(x, y, s) return ("label[%g,%g;%s]"):format(x, y, core.formspec_escape(s)) end
	return table.concat({
		"formspec_version[6]size[9,4.6]",
		L(0.5, 0.6, S("Precious Metals Dealer")),
		L(0.5, 1.3, S("Gold today $@1/g (@2 @3%)", ("%.1f"):format(p), c >= 0 and "▲" or "▼", ("%.0f"):format(math.abs(c) * 100))),
		L(0.5, 1.9, S("You have @1 g of gold (worth $@2)", tostring(have), ("%.0f"):format(have * p))),
		"button[0.5,2.8;3.8,0.8;sell10;" .. core.formspec_escape(S("Sell @1 g", 10)) .. "]",
		"button[4.7,2.8;3.8,0.8;sellall;" .. core.formspec_escape(S("Sell all")) .. "]",
	})
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	local name = player:get_player_name()
	local want = fields.sellall and math.huge or fields.sell10 and 10
	if want then
		local inv = player:get_inventory()
		local n = math.min(want, count_gold(inv))
		if n > 0 then
			inv:remove_item("main", ItemStack(GOLD .. " " .. n))
			local money = n * rockmech.gold_price()
			rockmech.add_money(name, money)
			rockmech.notify(name, S("[Precious Metals Dealer] Bought @1 g of gold: $@2", tostring(n), ("%.0f"):format(money)))
			core.sound_play("rockmech_coin", {to_player = name, gain = 0.8}, true)
		end
		core.show_formspec(name, FORM, dealer_form(name))
	end
	return true
end)

local npc = {entity = ENTITY, title = S("Precious Metals Dealer"), sells = S("Buys gold"), color = "#ffe080", tint = "#7a5a10", sit = false}
core.register_entity(ENTITY, {
	initial_properties = {
		physical = true, collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
		visual = "mesh", mesh = "character.b3d", textures = {"character.png"},     -- 皮膚在 on_activate 換（npc_skins.lua 比這個檔案晚載入）
		nametag = npc.title, nametag_color = npc.color, static_save = false,
	},
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
		self.object:set_properties({textures = {rockmech.npc_skin(WHO)}})
		rockmech.npc_dress(self.object, WHO)
		self.object:set_animation({x = 0, y = 79}, 30)
	end,
	on_rightclick = function(self, clicker)
		if rockmech.hand_first and rockmech.hand_first(clicker) then return end
		if clicker and clicker:is_player() then
			local name = clicker:get_player_name()
			core.show_formspec(name, FORM, dealer_form(name))
		end
	end,
	on_punch = function() return true end,
})
-- 營地的 NPC 名冊、研究帳篷在後面的檔案（career.lua、research.lua）：全部載入完再登記
core.register_on_mods_loaded(function()
	if not (has_gold and rockmech.career_npcs) then return end
	rockmech.career_npcs[WHO] = npc
	-- 站在研究帳篷後面、經濟分析師旁邊（帳篷本地座標 dx 2、dz −2，面向北）；新蓋的帳篷一起放，舊的營地補上
	local RES_DX, RES_Z = 23, -28      -- 跟 research.lua 一樣
	local function flag_of(x0) return "dealer_site:" .. x0 end
	local function add_spot(x0, y)
		storage:set_string(flag_of(x0), "1")
		local _, at, yaw = rockmech.career_placer(x0 + RES_DX, RES_Z, y, "north")
		local p = at(2, 0, -2)
		local key = rockmech.career_vendor_spots
		local list = core.deserialize(storage:get_string(key)) or {}
		list[#list + 1] = {kind = WHO, pos = {x = p.x, y = y + 0.5, z = p.z}, yaw = yaw}
		storage:set_string(key, core.serialize(list))
	end
	local function ground(x, z)
		for yy = 40, -30, -1 do
			local n = core.get_node({x = x, y = yy, z = z}).name
			if n ~= "air" and n ~= "ignore" and n ~= "rockmech:tent_pole" and not n:find("canvas") then return yy end
		end
	end
	local build_research = rockmech.career_build_research
	if build_research then
		function rockmech.career_build_research(x0)
			build_research(x0)
			local y = ground(x0 + RES_DX - 3, RES_Z - 3)
			if y and storage:get_string(flag_of(x0)) == "" then add_spot(x0, y) end
		end
	end
	core.after(3, function()
		local sites = {}
		if storage:get_string("career_site") == "2" then sites[#sites + 1] = cfg.career_camp_dx end
		if rockmech.team_site_x then
			for i = 1, cfg.career_teams or 0 do
				if storage:get_string("team_site:" .. i) == "1" then sites[#sites + 1] = rockmech.team_site_x(tostring(i)) end
			end
		end
		for _, x0 in ipairs(sites) do
			if storage:get_string("research_site:" .. x0) == "1" and storage:get_string(flag_of(x0)) == "" then
				local p = {x = x0 + RES_DX - 3, y = 0, z = RES_Z - 3}
				core.emerge_area(vector.offset(p, 0, -30, 0), vector.offset(p, 0, 40, 0), function(_, _, rem)
					if rem > 0 or storage:get_string(flag_of(x0)) ~= "" then return end
					local y = ground(p.x, p.z)
					if y then add_spot(x0, y) end
				end)
			end
		end
	end)
end)
