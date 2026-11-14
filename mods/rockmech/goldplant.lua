-- rockmech/goldplant.lua
-- 提金廠（碳浸法 CIL：氰化物溶出金、活性碳吸附、電解、熔鑄）：褐鐵礦裡的金是細粒金，包在氧化鐵裡，重力選選不出來，要用化學法。
-- 放在平地上，前面挖一個跟破碎站一樣的受料倉（crusher.lua 的 rockmech.hopper_lib），卡車、輸送帶倒進去。
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
-- 提金廠
---------------------------------------------------------------------------
local function tails_of(meta) return core.deserialize(meta:get_string("tails")) or {} end
local function tails_total(t) local n = 0; for _, v in pairs(t) do n = n + (v.lv or 0) end; return n end
-- 尾礦口：機身後面（受料倉的反方向）
local function outlet(pos, meta)
	return {x = pos.x - meta:get_int("dx") * 3, y = pos.y, z = pos.z - meta:get_int("dz") * 3}
end
-- 旁邊的箱子（機身四周一圈、同一層或上一層，有 main 這個物品欄的方塊）
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
-- 整克的金放出去：存機器裡，或放進旁邊的箱子（箱子滿了留在機器裡）
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
	-- 2. 吃料、提金
	local room = math.floor(TAIL_CAP - tails_total(tails))
	local stopped = meta:get_int("stopped") == 1
	local tons, au_in, gold, cost = 0, 0, 0, 0
	if room >= 1 and not stopped then
		H.eat(pos, dtime, cfg.plant_rate, room, function(t, base, p2, ca)
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

local function formspec(pos)
	local meta = core.get_meta(pos)
	local spos = ("nodemeta:%d,%d,%d"):format(pos.x, pos.y, pos.z)
	local stopped = meta:get_int("stopped") == 1
	local t, au = meta:get_float("total_t"), meta:get_float("total_au")
	local queue = H.hopper_levels(H.hopper_center(meta))
	local status = stopped and S("Stopped") or meta:get_float("stall") > 0 and S("Tailings pile full: clear it behind the plant") or S("Running")
	local chest = meta:get_string("mode") == "chest"
	local L = function(x, y, s) return ("label[%g,%g;%s]"):format(x, y, core.formspec_escape(s)) end
	return table.concat({
		"formspec_version[6]size[11.2,11]",
		L(0.5, 0.6, S("Gold plant") .. "   " .. status),
		("button[8,0.2;2.7,0.8;toggle;%s]"):format(core.formspec_escape(stopped and S("Start") or S("Stop"))),
		L(0.5, 1.3, S("Feed: dump into the hopper in front   Queue @1 t", ("%.1f"):format(H.tons_of(queue)))),
		L(0.5, 1.9, S("Recovery @1%   Running cost $@2/t   Reagents +$@3/t per 1% harmful impurities",
			("%.0f"):format(E.cil_recovery * 100), ("%g"):format(E.cil_op), ("%g"):format(E.cil_reagent / 100))),
		L(0.5, 2.6, S("Processed @1 t, average gold @2 g/t", ("%.0f"):format(t), ("%.2f"):format(t > 0 and au / t or 0))),
		L(0.5, 3.2, S("Gold recovered @1 g, costs $@2", ("%.0f"):format(meta:get_float("total_gold")), ("%.0f"):format(meta:get_float("total_cost")))),
		L(0.5, 3.8, S("Tailings come out behind the plant")),
		"image[5.5,4.6;1,1;gui_furnace_arrow_bg.png^[transformR270]",
		L(0.5, 5.1, S("Gold")),
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

local function build(pos, dx, dz, name)
	if rockmech.clear_site and rockmech.facility_cells then rockmech.clear_site(rockmech.facility_cells(GOLD_PLANT, pos, dx, dz), pos) end
	if not H.site_ok(pos, dx, dz) then return false end
	core.set_node(pos, {name = GOLD_PLANT})
	H.dig_hopper(pos, dx, dz)
	local meta = core.get_meta(pos)
	meta:set_string("owner", rockmech.account_of(name))
	meta:set_int("dx", dx)
	meta:set_int("dz", dz)
	meta:get_inventory():set_size("gold", SLOTS)
	core.get_node_timer(pos):start(H.STEP)
	H.keep_loaded(pos)
	step(pos, 0)
	return true
end

local BODY = "[fill:16x16:#6a6a62^[fill:16x3:0,0:#c9a227^[fill:16x2:0,14:#303030^[fill:4x4:6,7:#3a3a3a"
core.register_node(GOLD_PLANT, {
	description = S("Gold plant\nRight-click on flat ground to build"),
	short_description = S("Gold plant"),
	drawtype = "nodebox",
	paramtype = "light",
	node_box = {type = "fixed", fixed = {{-1.45, -0.5, -1.45, 1.45, 1.6, 1.45}, {-0.9, 1.6, -0.9, 0.9, 2.8, 0.9}}},
	tiles = {BODY},
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
			rockmech.notify(name, S("[Gold plant] Place it on flat ground: the 3×3 m plant and the @1×@2 m receiving hopper in front need level ground and solid rock below",
				tostring(H.SIZE), tostring(H.SIZE)))
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
		step(pos, math.min(elapsed, 5 * H.STEP))
		return true
	end,
	on_destruct = function(pos)
		local meta = core.get_meta(pos)
		for _, c in ipairs(H.grate_cells(meta)) do
			if core.get_node(c).name == H.GRATE then core.swap_node(c, {name = rockmech.RUBBLE}) end
		end
		if meta:get_int("forceload") == 1 then H.each_block(pos, function(p) core.forceload_free_block(p, false) end) end
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
