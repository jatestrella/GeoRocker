-- rockmech/woodwork.lua
-- 木工：樹木、砍樹、鋸木台、木工桌、木製建材。
--   表土和樹林：每條礦帶交界的山脊整片鋪表土（根系抓住，被擾動才變鬆土），上面稀疏種蘋果樹。樹苗種在滿格的土上會自己長。
--   砍樹：斧頭（工具室管理員）砍樹幹任何一格，整棵倒下：樹幹變成橫躺在地上的原木（倒向離砍的人遠的那邊），
--   樹葉拿掉，1–2 棵樹苗和蘋果進物品欄。經營模式的原木是大東西：不進背包，跟碎石一樣一次扛一根（career.lua），
--   左鍵地上的原木扛起來，右鍵放下、裝上車斗（1 根佔 1 m³）。
--   鋸木台（跟工具室管理員買）：扛著原木對它右鍵，選要鋸成什麼：2 根木柱、4 塊木板、8 塊木板半格。
--   木工桌（跟工具室管理員買，一張單純的木桌）：用木板做：木牆板、樓梯、門、活板門、柵欄、柵欄橫桿、梯子、木板半格。
--   這些都是建材，在岩石力學裡算空格（group rockmech_timber，見 collapse.lua、timber.lua），不能當剛性的墊支撐；
--   空手就挖得起來（樹幹要斧頭）。

local S = rockmech.S
local storage = rockmech.collapse.storage
local cfg = rockmech.cfg
if not core.get_modpath("default") then return end

local LOG = "default:tree"
local PLANK, SLAB, POST = "rockmech:timber_plank", "rockmech:timber_slab", "rockmech:timber_post"
local WALL = "rockmech:timber_wall"
local SAW, BENCH = "rockmech:sawbench", "rockmech:workbench"
local SAW_FORM, BENCH_FORM = "rockmech:sawbench", "rockmech:workbench"
local USE_R = 4             -- 離台子幾公尺內才能用

local function tell(name, msg) if name then rockmech.notify(name, S("[Woodwork] @1", msg)) end end

---------------------------------------------------------------------------
-- 遊戲內建的木製品：加進木材（岩石力學裡算空格），空手挖得起來；原木的說明改成中文
---------------------------------------------------------------------------

local BUILD = {"stairs:stair_wood", "stairs:stair_inner_wood", "stairs:stair_outer_wood", "stairs:slab_wood",
	"default:fence_wood", "default:fence_rail_wood", "default:ladder_wood", "default:wood",
	"doors:door_wood_a", "doors:door_wood_b", "doors:door_wood_c", "doors:door_wood_d", "doors:trapdoor", "doors:trapdoor_open"}
for _, name in ipairs(BUILD) do
	local def = core.registered_nodes[name]
	if def then
		local g = table.copy(def.groups or {})
		g.rockmech_timber, g.dig_immediate = 1, 2
		core.override_item(name, {groups = g})
	end
end
-- 樹：樹幹、樹葉、蘋果也是木材（不能撐岩石）；樹幹要斧頭
for _, name in ipairs({LOG, "default:leaves", "default:apple"}) do
	local def = core.registered_nodes[name]
	if def then
		local g = table.copy(def.groups or {})
		g.rockmech_timber = 1
		core.override_item(name, {groups = g})
	end
end
-- 原木：站著的是樹幹（param2 0–3，直立），橫躺的（param2 ≥ 4）是砍下來的原木
local CARRY = cfg.career and rockmech.carry_get ~= nil
local function lying(node) return node.name == LOG and node.param2 >= 4 end
core.override_item(LOG, {
	description = S("Log"),
	short_description = S("Timber log"),
	-- 經營模式：砍下來的原木不進背包（倒在地上，fell）；左鍵橫躺的原木就扛起來（不用斧頭）
	drop = CARRY and "" or nil,
	on_punch = CARRY and function(pos, node, puncher)
		if not (lying(node) and puncher and puncher:is_player()) then return end
		if rockmech.carry_get(puncher) then tell(puncher:get_player_name(), S("Your hands are full: right-click to put it down before carrying a log")); return end
		core.remove_node(pos)
		rockmech.carry_set(puncher, {log = true})
	end or nil,
})
-- 在 (x, z) 這一欄放一根橫躺的原木（axis "x"／"z"：順著哪個方向躺），從 y 往上找空位、再往下找落地處。成功回傳 true
local LAY_P2 = {x = 12, z = 4}     -- facedir：木頭軸朝 +X／+Z
local function free(n)
	local d = core.registered_nodes[n]
	return n == "air" or (d and d.buildable_to)
end
function rockmech.lay_log(x, z, y, axis)
	-- 倒進受料倉（破碎站、選礦場）：原木當廢石，變成一般碎石落進倉裡（破碎站收處理費）
	if rockmech.in_hopper and rockmech.in_hopper(x, z, y) and rockmech.vehicles and rockmech.vehicles.deposit_column then
		local L8 = rockmech.RUBBLE_LEVELS
		return rockmech.vehicles.deposit_column(x, z, y, rockmech.RUBBLE, L8) < L8
	end
	local yy = y
	while not free(core.get_node({x = x, y = yy, z = z}).name) do
		yy = yy + 1
		if yy > y + 4 then return false end
	end
	for _ = 1, 16 do
		if not free(core.get_node({x = x, y = yy - 1, z = z}).name) then break end
		yy = yy - 1
	end
	core.set_node({x = x, y = yy, z = z}, {name = LOG, param2 = LAY_P2[axis] or 4})
	return true
end
-- 樹苗只能種在滿格的土上：土壤有 8 級高度，種在不滿格的土上，長出來的樹會浮在空中
do
	local sdef = core.registered_items["default:sapling"]
	local orig_place = sdef and sdef.on_place
	core.override_item("default:sapling", {
		description = S("Sapling\nPlant it on full soil"),
		short_description = S("Sapling"),
		on_place = function(itemstack, placer, pointed)
			if pointed.type == "node" then
				local under = core.get_node(pointed.under).name
				local k = rockmech.rubble_level[under]
				if pointed.above.y ~= pointed.under.y + 1 or core.get_item_group(under, "soil") == 0
						or (k and k < rockmech.RUBBLE_LEVELS) then
					local def = core.registered_nodes[under]
					if def and def.on_rightclick then return def.on_rightclick(pointed.under, core.get_node(pointed.under), placer, itemstack, pointed) end
					tell(placer and placer:get_player_name(), S("Saplings must be planted on a full block of soil (on top of the soil)"))
					return itemstack
				end
			end
			if orig_place then return orig_place(itemstack, placer, pointed) end
			return core.item_place(itemstack, placer, pointed)
		end,
	})
end
core.override_item("default:axe_steel", {description = S("Axe"), short_description = S("Axe")})
-- 木板、半格改用內建的木頭貼圖，跟樓梯、門、柵欄一致
for _, name in ipairs({PLANK, SLAB}) do core.override_item(name, {tiles = {"default_wood.png"}}) end

-- 木牆板：1/8 格厚的直立板（貼在格子的後面，面向放的人）
core.register_node(WALL, {
	description = S("Wooden wall panel"),
	short_description = S("Wooden wall panel"),
	drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir", sunlight_propagates = true,
	node_box = {type = "fixed", fixed = {-0.5, -0.5, 0.375, 0.5, 0.5, 0.5}},
	tiles = {"default_wood.png"},
	is_ground_content = false, groups = {dig_immediate = 2, rockmech_timber = 1},
	sounds = default.node_sound_wood_defaults(),
})

---------------------------------------------------------------------------
-- 砍樹：斧頭砍樹幹任何一格，整棵倒下
---------------------------------------------------------------------------

local NB = {}
for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
	if dx ~= 0 or dy ~= 0 or dz ~= 0 then NB[#NB + 1] = {dx, dy, dz} end
end end end
---------------------------------------------------------------------------
-- 樹倒下（原木、樹苗、蘋果掉在地上）：
--   1. 被埋：周圍 8 格的土面都比樹根（樹幹最下面那格的底）高出 1 m 以上。邊坡上下坡那側比較低，不會倒
--   2. 樹根的土流失：樹根底下那格的土不滿格或沒了（土壤以外的實心地面，例如岩石、草皮，照常站得住）；樹苗一樣
---------------------------------------------------------------------------

local SOIL = rockmech.RUBBLE_SOIL
local NLEV = rockmech.RUBBLE_LEVELS
-- 舊版的含土樹幹（試過、拿掉了）：載入時變回一般樹幹
for k = 1, NLEV do core.register_alias("rockmech:tree_soil_" .. k, LOG) end

-- 樹根那一格：是樹幹，正下方和斜下方 8 格都沒有樹幹（樹枝是斜著接在樹幹上的，下面有樹幹）
local function standing(p)
	local n = core.get_node(p)
	return n.name == LOG and n.param2 < 4
end
local function root_cell(pos)
	if not standing(pos) then return false end
	for dx = -1, 1 do for dz = -1, 1 do
		if standing({x = pos.x + dx, y = pos.y - 1, z = pos.z + dz}) then return false end
	end end
	return true
end

local felling = false
-- whole：連 pos 那一格也拿掉（自然倒下；砍的時候那一格由引擎挖掉）
local function fell(pos, digger, whole)
	if felling then return end
	felling = true
	-- 相連的樹幹（含斜的樹枝），往上、往旁邊找，最多 64 格
	local trunk, seen, q, head = {}, {[core.hash_node_position(pos)] = true}, {pos}, 1
	while q[head] and #trunk < 64 do
		local p = q[head]; head = head + 1
		trunk[#trunk + 1] = p
		for _, d in ipairs(NB) do
			local n = {x = p.x + d[1], y = p.y + d[2], z = p.z + d[3]}
			local h = core.hash_node_position(n)
			if not seen[h] and n.y >= pos.y and standing(n) then seen[h] = true; q[#q + 1] = n end
		end
	end
	local logs, apples = 0, 0
	for i, p in ipairs(trunk) do
		if i > 1 or whole then core.remove_node(p); logs = logs + 1 end   -- 砍的那一格由引擎挖掉
		-- 這段樹幹周圍 2 格的樹葉、蘋果拿掉（樹距 3 m，不碰隔壁那棵）
		for _, l in ipairs(core.find_nodes_in_area(vector.subtract(p, 2), vector.add(p, 2), {"default:leaves", "default:apple"})) do
			if core.get_node(l).name == "default:apple" then apples = apples + 1 end
			core.remove_node(l)
		end
	end
	felling = false
	local fx = function()
		core.add_particlespawner({amount = 60, time = 0.5, minpos = vector.subtract(pos, {x = 2, y = 0, z = 2}),
			maxpos = vector.add(pos, {x = 2, y = 6, z = 2}), minvel = {x = -1, y = -2, z = -1}, maxvel = {x = 1, y = 0, z = 1},
			minexptime = 1, maxexptime = 2, minsize = 1, maxsize = 2, texture = "[fill:4x4:#3a7a2a"})
		core.sound_play("default_dig_choppy", {pos = pos, gain = 1.0, max_hear_distance = 32}, true)
	end
	-- 不是砍的（土流失、被埋、崩塌沖倒）：樹整棵毀掉，不留原木、樹苗、蘋果。只有用斧頭砍才有原木
	if not (digger and digger:is_player()) then fx(); return end
	local give = {ItemStack("default:sapling " .. math.random(1, 2))}
	if CARRY then
		-- 經營模式：整棵樹的原木（含砍的那一格）一根接一根橫躺在地上，倒向離砍的人遠的那邊
		local n = logs + (whole and 0 or 1)
		local dx, dz = 0, 0
		local who = digger and digger:is_player() and digger:get_pos()
		if who then
			local vx, vz = pos.x - who.x, pos.z - who.z
			if math.abs(vx) > math.abs(vz) then dx = vx > 0 and 1 or -1 else dz = vz > 0 and 1 or -1 end
		else
			local r = math.random(4)
			dx, dz = ({1, -1, 0, 0})[r], ({0, 0, 1, -1})[r]
		end
		local axis = dx ~= 0 and "x" or "z"
		local placed = 0
		for i = 1, n + 4 do
			if placed >= n then break end
			if rockmech.lay_log(pos.x + dx * i, pos.z + dz * i, pos.y + 1, axis) then placed = placed + 1 end
		end
		for _ = placed + 1, n do rockmech.lay_log(pos.x, pos.z, pos.y, axis) end      -- 倒的方向擋住：堆在樹樁上
	else
		give[#give + 1] = ItemStack(LOG .. " " .. logs)   -- 砍的那一格引擎照常掉一根
	end
	if apples > 0 then give[#give + 1] = ItemStack("default:apple " .. apples) end
	local inv = digger and digger:is_player() and digger:get_inventory()
	for _, s in ipairs(give) do
		if not s:is_empty() then
			local left = inv and inv:add_item("main", s) or s
			if not left:is_empty() then core.add_item(pos, left) end
		end
	end
	fx()
	if digger and digger:is_player() then
		local nlog = tostring(logs + (whole and 0 or 1))
		tell(digger:get_player_name(), CARRY and S("The tree fell: @1 logs lie on the ground (left-click to carry them, one at a time)", nlog)
			or S("The tree fell: @1 logs", nlog))
	end
end
core.register_on_dignode(function(pos, oldnode, digger)
	if oldnode.name == LOG and oldnode.param2 < 4 and digger and digger:is_player() then fell(pos, digger) end
end)

-- why：log 用的原因，why_s：給玩家看的（翻譯過）
local function topple(base, why, why_s)
	fell(base, nil, true)
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), base) <= 32 then
			tell(pl:get_player_name(), S("The tree at @1 fell (destroyed, no logs): @2", core.pos_to_string(base), why_s))
		end
	end
	core.log("action", ("[rockmech] 樹倒下 %s：%s"):format(core.pos_to_string(base), why))
end
-- 一欄的土面比樹根（base 那格的底）高多少 (m)：從 base 往上找連續的碎石／土
local function soil_above(x, z, base)
	local h = 0
	for y = base.y, base.y + 4 do
		local k = rockmech.rubble_level[core.get_node({x = x, y = y, z = z}).name]
		if not k then break end
		h = (y - base.y) + k / NLEV
	end
	return h
end
core.register_abm({
	label = "rockmech: 樹被土埋超過 1 m、或樹根的土流失就倒",
	nodenames = {LOG, "default:sapling"}, interval = 3, chance = 1,
	action = function(pos, node)
		local sap = node.name == "default:sapling"
		if not sap and not root_cell(pos) then return end
		local bn = core.get_node({x = pos.x, y = pos.y - 1, z = pos.z}).name
		local bk = rockmech.rubble_level[bn]
		local bdef = core.registered_nodes[bn]
		if (bk and bk < NLEV) or (bdef and bdef.walkable == false) then
			if sap then core.remove_node(pos); core.add_item(pos, "default:sapling")
			else topple(pos, "樹根底下的土流失了", S("the soil under its roots washed away")) end
			return
		end
		if sap then return end
		for dx = -1, 1 do for dz = -1, 1 do
			if (dx ~= 0 or dz ~= 0) and soil_above(pos.x + dx, pos.z + dz, pos) <= 1 then return end
		end end
		topple(pos, "被土埋超過 1 m", S("buried by more than 1 m of soil"))
	end,
})

---------------------------------------------------------------------------
-- 鋸木台、木工桌：單純的台子，右鍵開選單；材料從手上／物品欄拿
---------------------------------------------------------------------------

local SAW_RECIPES = {
	{give = POST, n = 2, label = S("Timber post")},
	{give = PLANK, n = 4, label = S("Timber plank")},
	{give = SLAB, n = 8, label = S("Timber slab")},
}
local BENCH_RECIPES = {
	{give = WALL, n = 4, need = 1, label = S("Wooden wall panel")},
	{give = SLAB, n = 2, need = 1, label = S("Timber slab")},
	{give = "stairs:stair_wood", n = 1, need = 1, label = S("Stairs")},
	{give = "default:fence_wood", n = 2, need = 1, label = S("Fence")},
	{give = "default:fence_rail_wood", n = 2, need = 1, label = S("Fence rail")},
	{give = "default:ladder_wood", n = 3, need = 1, label = S("Ladder")},
	{give = "doors:door_wood", n = 1, need = 2, label = S("Door")},
	{give = "doors:trapdoor", n = 1, need = 2, label = S("Trapdoor")},
}

local function count(inv, item)
	local n = 0
	for _, s in ipairs(inv:get_list("main") or {}) do if s:get_name() == item then n = n + s:get_count() end end
	return n
end

local using = {}            -- 玩家名稱 → 台子位置
local function carried_log(player)
	local c = rockmech.carry_get and rockmech.carry_get(player)
	return c and c.log
end
local function saw_form(player)
	local text
	if CARRY then text = carried_log(player) and S("You are carrying a log") or S("You have no log: go and carry one over from the ground (left-click)")
	else text = S("Logs in inventory: @1 (one sawn at a time)", tostring(count(player:get_inventory(), LOG))) end
	local out = {"formspec_version[6]size[10,5.6]",
		"label[0.5,0.6;" .. core.formspec_escape(S("Saw bench")) .. "]",
		("label[0.5,1.2;%s]"):format(core.formspec_escape(text))}
	for i, r in ipairs(SAW_RECIPES) do
		out[#out + 1] = ("item_image[0.5,%g;0.8,0.8;%s]"):format(1.7 + (i - 1) * 1.0, r.give)
		out[#out + 1] = ("button[1.5,%g;5,0.8;r_%d;%s]"):format(1.7 + (i - 1) * 1.0, i,
			core.formspec_escape(S("1 log → @1 ×@2", r.label, tostring(r.n))))
	end
	out[#out + 1] = "button_exit[7,4.7;2.5,0.7;close;" .. core.formspec_escape(S("Close")) .. "]"
	return table.concat(out)
end
local function bench_form(player)
	local n = count(player:get_inventory(), PLANK)
	local out = {"formspec_version[6]size[13,8]",
		"label[0.5,0.6;" .. core.formspec_escape(S("Workbench")) .. "]",
		("label[0.5,1.2;%s]"):format(core.formspec_escape(S("Planks in inventory: @1 (saw logs into planks at a saw bench, or buy them from the toolroom keeper)", tostring(n))))}
	for i, r in ipairs(BENCH_RECIPES) do
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		local x, y = 0.5 + col * 6.2, 1.8 + row * 1.2
		out[#out + 1] = ("item_image[%g,%g;0.8,0.8;%s]"):format(x, y, r.give)
		out[#out + 1] = ("button[%g,%g;5,0.8;r_%d;%s]"):format(x + 1, y, i,
			core.formspec_escape(S("@1 planks → @2 ×@3", tostring(r.need), r.label, tostring(r.n))))
	end
	out[#out + 1] = "button_exit[10,7.1;2.5,0.7;close;" .. core.formspec_escape(S("Close")) .. "]"
	return table.concat(out)
end

local function make(player, need_item, need_n, give, n)
	local name = player:get_player_name()
	local inv = player:get_inventory()
	if count(inv, need_item) < need_n then tell(name, S("Not enough materials")); return end
	local stack = ItemStack(give .. " " .. n)
	if not inv:room_for_item("main", stack) then tell(name, S("Your inventory is full")); return end
	inv:remove_item("main", ItemStack(need_item .. " " .. need_n))
	inv:add_item("main", stack)
	core.sound_play("default_dig_choppy", {pos = player:get_pos(), gain = 0.6, max_hear_distance = 16}, true)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= SAW_FORM and formname ~= BENCH_FORM then return end
	local name = player:get_player_name()
	local pos = using[name]
	if fields.quit then using[name] = nil; return true end
	if not pos or vector.distance(player:get_pos(), pos) > USE_R + 1 then
		tell(name, S("You are too far from the bench")); core.close_formspec(name, formname); using[name] = nil; return true
	end
	for k in pairs(fields) do
		local i = tonumber(k:match("^r_(%d+)$"))
		if i then
			if formname == SAW_FORM then
				local r = SAW_RECIPES[i]
				if r and CARRY then
					-- 用手上扛的那根原木
					local stack = ItemStack(r.give .. " " .. r.n)
					local inv = player:get_inventory()
					if not carried_log(player) then tell(name, S("You are not carrying a log"))
					elseif not inv:room_for_item("main", stack) then tell(name, S("Your inventory is full"))
					else
						rockmech.carry_set(player, nil)
						inv:add_item("main", stack)
						core.sound_play("default_dig_choppy", {pos = player:get_pos(), gain = 0.6, max_hear_distance = 16}, true)
					end
				elseif r then make(player, LOG, 1, r.give, r.n) end
				core.show_formspec(name, SAW_FORM, saw_form(player))
			else
				local r = BENCH_RECIPES[i]
				if r then make(player, PLANK, r.need, r.give, r.n) end
				core.show_formspec(name, BENCH_FORM, bench_form(player))
			end
			return true
		end
	end
	return true
end)
core.register_on_leaveplayer(function(player) using[player:get_player_name()] = nil end)

local function table_node(name, desc, short, boxes, tiles, form, form_fn)
	core.register_node(name, {
		description = desc, short_description = short, drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
		node_box = {type = "fixed", fixed = boxes}, selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0.45, 0.5}},
		tiles = tiles, is_ground_content = false, groups = {not_in_creative_inventory = 0, rockmech_timber = 1, choppy = 3},
		sounds = default.node_sound_wood_defaults(),
		on_rightclick = function(pos, node, clicker, itemstack)
			if not (clicker and clicker:is_player()) then return itemstack end
			if vector.distance(clicker:get_pos(), pos) > USE_R then tell(clicker:get_player_name(), S("Come closer")); return itemstack end
			using[clicker:get_player_name()] = vector.copy(pos)
			core.show_formspec(clicker:get_player_name(), form, form_fn(clicker))
			return itemstack
		end,
	})
end
local LEGS = function(top)
	return {{-0.45, -0.5, -0.45, -0.35, top, -0.35}, {0.35, -0.5, -0.45, 0.45, top, -0.35},
		{-0.45, -0.5, 0.35, -0.35, top, 0.35}, {0.35, -0.5, 0.35, 0.45, top, 0.45}}
end
-- 木工桌：一張單純的木桌（桌面＋四支腳）
do
	local b = LEGS(0.3)
	b[#b + 1] = {-0.5, 0.3, -0.5, 0.5, 0.45, 0.5}
	table_node(BENCH, S("Workbench\nRight-click: make wall panels, stairs, doors, fences, ladders… from planks"), S("Workbench"), b,
		{"default_wood.png"}, BENCH_FORM, bench_form)
end
-- 鋸木台：矮的木架，台面中間一片圓鋸片
do
	local b = LEGS(0.15)
	b[#b + 1] = {-0.5, 0.15, -0.3, 0.5, 0.3, 0.3}
	b[#b + 1] = {-0.02, 0.3, -0.25, 0.02, 0.5, 0.25}          -- 鋸片
	table_node(SAW, S("Saw bench\nRight-click: saw a log into posts, planks or slabs"), S("Saw bench"), b,
		{"default_wood.png^[fill:2x16:7,0:#b0b4b8", "default_wood.png", "default_wood.png"}, SAW_FORM, saw_form)
end

---------------------------------------------------------------------------
-- 表土（有植物根系的土）：根系凝聚力讓它在陡坡上也站得住，所以不參與顆粒流（不是碎石）。
-- 一被擾動，根系就斷，變成一般的鬆土（nodes.lua 的土壤碎石），照安息角流動：
--   學生挖表土 → 挖起來的就是一份土（同撿碎石）
--   底下被掏空的表土變鬆土、掉下來
--   旁邊被挖開（挖、炸、坍塌、鬆土流走）：根系有凝聚力，臨空面不超過自立高度 H_c 就站得住；超過才鬆掉、照安息角流，
--   流走又讓上面的表土臨空，坡腳切太高就連鎖成整片邊坡滑動
-- 不是岩體（is_ground_content = false）：應力解、崩落判定都不算它；樹苗種得活（group soil）
---------------------------------------------------------------------------

local TOPSOIL = "rockmech:topsoil"
local TOPSOIL_K = {[TOPSOIL] = NLEV}     -- 表土 → 厚度（八分之一公尺）；薄的表土在下面註冊
local function loosen(p)
	local k = TOPSOIL_K[core.get_node(p).name]
	if not k then return false end
	core.swap_node(p, {name = rockmech.rubble_with_level(SOIL, k)})
	core.after(0, function() rockmech.collapse.check_cell(p) end)     -- 底下空了就掉、陡了就流
	return true
end
---------------------------------------------------------------------------
-- 蓋東西時的地面整理：不滿一格的土石（薄的表土、不滿格的碎石／鬆土）上面放東西會架空（看起來浮著）。分兩類：
--   建築物（破碎站、選礦場、裝車料斗）：範圍內的土石直接清掉。地面那一層的薄片清掉，整片都是薄片
--     就往下一格蓋（rockmech.clear_site）
--   營地：先把範圍裡的平地整成一層平整的整格表土，建築、家具蓋在土上面（rockmech.level_camp_soil）
--   設施（置物櫃、鋸木台、木工桌、木柱、一般方塊…）：對著薄片的上面放，薄片推到旁邊一欄（推不下才移除），
--     設施直接放進那一格（rockmech.settle_pointed；core.item_place_node 都會經過）
---------------------------------------------------------------------------
function rockmech.is_thin_ground(name)
	local k = rockmech.rubble_level[name] or TOPSOIL_K[name]
	return k ~= nil and k < NLEV
end
local DIR4 = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
-- 把 p 那片薄片拿掉：碎石、土推到旁邊一欄（落在那欄的地面上），推不下就移除
local function push_aside(p, push)
	local node = core.get_node(p)
	local k = rockmech.rubble_level[node.name] or TOPSOIL_K[node.name]
	if not k or k >= NLEV then return end
	local base = rockmech.rubble_base[node.name] or SOIL
	core.swap_node(p, {name = "air"})
	if not push then return end
	local V = rockmech.vehicles
	if not (V and V.deposit_column) then return end
	-- 下一個 tick 才推：先讓設施放進空出來的那一格，推出去的土才不會又流回來
	core.after(0, function()
	local s = math.random(4)
	for j = 0, 3 do
		local d = DIR4[(s + j - 1) % 4 + 1]
		local q = {x = p.x + d[1], y = p.y, z = p.z + d[2]}
		local qn = core.get_node(q).name
		-- 旁邊也是薄的表土：鬆成同樣厚度的鬆土，推過去的跟它合併
		if TOPSOIL_K[qn] and TOPSOIL_K[qn] < NLEV then rockmech.loosen_under(q, qn); qn = core.get_node(q).name end
		local qk = rockmech.rubble_level[qn]
		if qn == "air" or (qk and qk < NLEV) then
			k = V.deposit_column(q.x, q.z, p.y, base, k, 2, nil, node.param2)
			if k <= 0 then return end
		end
	end
	end)
end
-- cells = {{x, z}, …}，pos = 要蓋的位置（地面在 pos.y − 1）。地面那一層的薄片清掉；整片都是薄片就把 pos 往下一格（直接改 pos）
function rockmech.clear_site(cells, pos)
	local all = #cells > 0
	for _, c in ipairs(cells) do
		local p = {x = c[1], y = pos.y - 1, z = c[2]}
		if rockmech.is_thin_ground(core.get_node(p).name) then push_aside(p, false) else all = false end
		local p2 = {x = c[1], y = pos.y, z = c[2]}
		if rockmech.is_thin_ground(core.get_node(p2).name) then push_aside(p2, false) end
	end
	if all then pos.y = pos.y - 1 end
	return pos
end
-- 營地範圍（a..b）裡，岩盤頂在地表 sy 的欄：上面的表土、鬆土整成剛好 CAMP_SOIL 格整格的表土（地面平整在 sy + CAMP_SOIL），
-- 營地的建築、家具蓋在土上面（career.lua 的 ground_y 會找到土的頂面）
local CAMP_SOIL = 1
function rockmech.level_camp_soil(a, b, sy)
	for x = a.x, b.x do for z = a.z, b.z do
		local top
		for y = sy + 4, sy - 2, -1 do
			local n = core.get_node({x = x, y = y, z = z}).name
			if n ~= "air" and n ~= "ignore" and not TOPSOIL_K[n] and rockmech.rubble_base[n] ~= SOIL then top = y; break end
		end
		if top == sy then
			for y = sy + 1, sy + 4 do
				local p = {x = x, y = y, z = z}
				local n = core.get_node(p).name
				if y <= sy + CAMP_SOIL then
					if n == "air" or TOPSOIL_K[n] or rockmech.rubble_base[n] == SOIL then core.set_node(p, {name = TOPSOIL}) end
				elseif TOPSOIL_K[n] or rockmech.rubble_base[n] == SOIL then core.swap_node(p, {name = "air"}) end
			end
		end
	end end
end

-- 設施：對著薄片的上面放 → 薄片推到旁邊，回傳改放進那一格的 pointed_thing（其他情況原樣回傳）
function rockmech.settle_pointed(pt)
	if pt and pt.type == "node" and pt.above and pt.under and pt.above.y == pt.under.y + 1
			and pt.above.x == pt.under.x and pt.above.z == pt.under.z
			and rockmech.is_thin_ground(core.get_node(pt.under).name) then
		push_aside(pt.under, true)
		return {type = "node", under = {x = pt.under.x, y = pt.under.y - 1, z = pt.under.z}, above = vector.copy(pt.under)}
	end
	return pt
end
do
	local orig = core.item_place_node
	function core.item_place_node(itemstack, placer, pt, ...)
		return orig(itemstack, placer, rockmech.settle_pointed(pt), ...)
	end
end

-- 挖土機的鏟斗挖到表土：變成同樣厚度的鬆土（之後當碎石挖起來）。回傳有沒有換
function rockmech.dig_topsoil(p)
	local k = TOPSOIL_K[core.get_node(p).name]
	if not k then return false end
	core.swap_node(p, {name = rockmech.rubble_with_level(SOIL, k)})
	return true
end

-- 薄的表土上面壓了碎石、鬆土：變成同樣厚度的鬆土，讓上面的往下倒進來合併（collapse.lua granular_settle 呼叫）
function rockmech.loosen_under(p, name)
	local k = TOPSOIL_K[name]
	if not k or k >= NLEV then return false end
	core.swap_node(p, {name = rockmech.rubble_with_level(SOIL, k)})
	return true
end
-- 表土的凝聚力（根系，rockmech_topsoil_c）→ 自立高度 H_c = 4c/γ·tan(45° + φ/2)：表土旁邊挖開的臨空面不超過 H_c 就站得住。
-- γ 用非岩性格的單位重，φ 用安息角（鬆土沒有凝聚力，就是安息角）。c = 5 kPa、γ = 20、φ = 35° → H_c ≈ 1.9 m
local HC = rockmech.mix.standing_height(cfg.topsoil_c, cfg.failure.gamma_other, cfg.slope.angle)
rockmech.topsoil_hc = HC
-- 下雨時的自立高度：凝聚力 c × (1 − rain_c_loss × L)，L = 時雨量 / rain_max（weather.lua）；H_c 跟 c 成正比
local function hc_now()
	local L = rockmech.rain_level and rockmech.rain_level() or 0
	return HC * math.max(0, 1 - (cfg.slope.rain_c_loss or 0) * L)
end
rockmech.topsoil_hc_now = hc_now
local NB4 = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
-- (x, z) 這一欄從 y 往下的地面高度（m）：空氣、植物、不滿格的碎石／鬆土／薄表土往下找，最多 8 格
local function ground_below(x, y, z)
	for yy = y, y - 8, -1 do
		local n = core.get_node({x = x, y = yy, z = z}).name
		local k = rockmech.rubble_level[n] or TOPSOIL_K[n]
		if k then return yy - 0.5 + k / NLEV end
		local def = core.registered_nodes[n]
		if not def or def.walkable ~= false then return yy + 0.5 end
	end
	return y - 8.5
end
-- pos 變空了（被挖、炸掉、坍塌，或碎石／鬆土流走一部分）：
--   正上方的表土失去支撐 → 變鬆土掉下來
--   旁邊四格的表土：從它的頂面到 pos 這一欄地面的落差（臨空面高度）超過 H_c → 凝聚力撐不住，變鬆土
-- 臨空面不到 H_c 就站得住：山坡上挖一兩格只是一個小坑，坡腳切出高過 H_c 的陡壁才會一路往上滑
-- 地上橫躺的原木：底下空了（崩塌、土流走）就毀掉消失，不會懸空，也不會變成可以撿的原木
local function unsupported(pos)
	local n = core.get_node({x = pos.x, y = pos.y - 1, z = pos.z}).name
	if n == "ignore" then return false end
	local def = core.registered_nodes[n]
	local k = rockmech.rubble_level[n]
	return (def and def.walkable == false) or (k and k < NLEV) or false
end
local function check_log(pos)
	local node = core.get_node(pos)
	if node.name == LOG and node.param2 >= 4 and unsupported(pos) then
		core.remove_node(pos)
		core.add_particlespawner({amount = 20, time = 0.3, minpos = vector.subtract(pos, 0.4), maxpos = vector.add(pos, 0.4),
			minvel = {x = -1, y = -1, z = -1}, maxvel = {x = 1, y = 1, z = 1}, minexptime = 0.5, maxexptime = 1,
			minsize = 1, maxsize = 2, texture = "[fill:4x4:#5a4020"})
	end
end
local function disturb(pos)
	local n = core.get_node(pos).name
	local def = core.registered_nodes[n]
	local k = rockmech.rubble_level[n]
	if (def and def.walkable == false) or (k and k < NLEV) then
		loosen({x = pos.x, y = pos.y + 1, z = pos.z})
		check_log({x = pos.x, y = pos.y + 1, z = pos.z})
	end
	local g
	for _, d in ipairs(NB4) do
		local p = {x = pos.x + d[1], y = pos.y, z = pos.z + d[2]}
		local tk = TOPSOIL_K[core.get_node(p).name]
		if tk then
			-- 臨空面從這一疊表土的頂量起（上面疊著的表土也靠這一格撐著）
			local top, y = p.y - 0.5 + tk / NLEV, p.y
			while tk == NLEV do
				y = y + 1
				tk = TOPSOIL_K[core.get_node({x = p.x, y = y, z = p.z}).name]
				if not tk then break end
				top = y - 0.5 + tk / NLEV
			end
			g = g or ground_below(pos.x, pos.y, pos.z)
			if top - g > hc_now() then loosen(p) end
		end
	end
end

core.register_node(TOPSOIL, {
	description = S("Topsoil"),
	short_description = S("Topsoil"),
	tiles = {"default_grass.png", "default_dirt.png", {name = "default_dirt.png^default_grass_side.png", tileable_vertical = false}},
	is_ground_content = false, groups = {crumbly = 3, soil = 1, rockmech_topsoil = 1},
	sounds = default.node_sound_dirt_defaults(), drop = SOIL,
	-- 挖：先變成鬆土再挖（經營模式就是撿起一份土），旁邊的表土也被擾動
	on_dig = function(pos, node, digger)
		core.swap_node(pos, {name = SOIL})
		local ok = core.node_dig(pos, {name = SOIL}, digger)
		disturb(pos)
		return ok
	end,
})
-- 薄的表土（1/8 … 7/8 m）：山腳那一圈逐漸變薄的坡腳用。一樣有草、不流動；被擾動變成同樣厚度的鬆土
local TOPSOIL_THIN = {}
for k = 1, NLEV - 1 do
	local name = TOPSOIL .. "_" .. k
	core.register_node(name, {
		description = S("Topsoil (@1/8 m)", tostring(k)),
		drawtype = "nodebox", paramtype = "light",
		node_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.5 + k / NLEV, 0.5}},
		tiles = {"default_grass.png", "default_dirt.png", {name = "default_dirt.png^default_grass_side.png", tileable_vertical = false}},
		is_ground_content = false, groups = {crumbly = 3, soil = 1, rockmech_topsoil = 1, not_in_creative_inventory = 1},
		sounds = default.node_sound_dirt_defaults(), drop = "",
		on_dig = function(pos, node, digger)
			local loose = rockmech.rubble_with_level(SOIL, k)
			core.swap_node(pos, {name = loose})
			local ok = core.node_dig(pos, {name = loose}, digger)
			disturb(pos)
			return ok
		end,
	})
	TOPSOIL_THIN[k], TOPSOIL_K[name] = name, k
end
-- 鬆土放久了長草變回表土：滿格、沒被壓實、上面是空的而且照得到光（平均約 10 分鐘）
core.register_abm({
	label = "rockmech: 鬆土長草變回表土",
	nodenames = {SOIL}, interval = 60, chance = 10,
	action = function(pos)
		local above = {x = pos.x, y = pos.y + 1, z = pos.z}
		if core.get_node(above).name ~= "air" or (core.get_node_light(above, 0.5) or 0) < 9 then return end
		core.swap_node(pos, {name = TOPSOIL})
	end,
})
-- 懸空的表土：大規模崩塌、爆破用 VoxelManip 寫入，不會通知表土底下空了。
-- 這些寫入都會通知 jointmesh.dirty_box：在那個範圍（往上多看幾格，表土最厚 3 m）找表土檢查，
-- 正下方是空的（或不滿格的碎石、鬆土）就變鬆土掉下來。另外低頻率抽查露在外面的表土補漏（不能每格都常掃：山上幾萬格）
local function check_topsoil(pos)
	local b = {x = pos.x, y = pos.y - 1, z = pos.z}
	local n = core.get_node(b).name
	if n == "ignore" then return end
	local def = core.registered_nodes[n]
	local k = rockmech.rubble_level[n]
	if (def and def.walkable == false) or (k and k < NLEV) then loosen(pos) return end
	-- 薄的表土上面壓著碎石、鬆土（掉下來架在薄片上）：鬆掉，上面的往下倒進來合併
	local tk = TOPSOIL_K[core.get_node(pos).name]
	if tk and tk < NLEV and rockmech.rubble_level[core.get_node({x = pos.x, y = pos.y + 1, z = pos.z}).name] then
		rockmech.loosen_under(pos, core.get_node(pos).name)
		-- 整欄往下倒：每一格從上面那格補滿（上面疊好幾格也一路補上去）
		for y = pos.y, pos.y + 16 do
			local a, b = {x = pos.x, y = y, z = pos.z}, {x = pos.x, y = y + 1, z = pos.z}
			local na, nb = core.get_node(a), core.get_node(b)
			local ka, kb = rockmech.rubble_level[na.name], rockmech.rubble_level[nb.name]
			local ba, bb = rockmech.rubble_base[na.name], rockmech.rubble_base[nb.name]
			if not (ka and kb) or not rockmech.rubble_mixable(ba, bb) then break end
			local put = math.min(NLEV - ka, kb)
			if put > 0 then
				local b2, g2 = rockmech.rubble_merge(ba, ka, na.param2, bb, put, nb.param2)
				core.swap_node(a, {name = rockmech.rubble_with_level(b2, ka + put, g2), param2 = g2})
				if kb - put > 0 then core.swap_node(b, {name = rockmech.rubble_with_level(bb, kb - put, nb.param2), param2 = nb.param2})
				else core.swap_node(b, {name = "air"}) end
			end
		end
	end
end
core.register_abm({
	label = "rockmech: 懸空的表土掉下來（抽查）",
	nodenames = {"group:rockmech_topsoil"}, neighbors = {"air"},
	interval = 10, chance = 20, catch_up = false,
	action = check_topsoil,
})
-- 下雨時：表土的凝聚力降低，自立高度 H_c 跟著降。抽查露出來的表土：這一疊表土頂到旁邊較低那欄地面的落差
-- 超過當下的 H_c 就鬆掉（照安息角流，流走又讓上面的表土臨空，可能連成邊坡滑動）。沒下雨不跑
core.register_abm({
	label = "rockmech: 下雨時表土陡壁鬆動（抽查）",
	nodenames = {"group:rockmech_topsoil"}, neighbors = {"air"},
	interval = 5, chance = 8, catch_up = false,
	action = function(pos)
		if not (rockmech.raining_now and (rockmech.rain_level() or 0) > 0) then return end
		local tk = TOPSOIL_K[core.get_node(pos).name]
		if not tk then return end
		-- 這一疊表土的頂
		local top, y = pos.y - 0.5 + tk / NLEV, pos.y
		while tk == NLEV do
			y = y + 1
			tk = TOPSOIL_K[core.get_node({x = pos.x, y = y, z = pos.z}).name]
			if not tk then break end
			top = y - 0.5 + tk / NLEV
		end
		local hc = hc_now()
		for _, d in ipairs(NB4) do
			local q = {x = pos.x + d[1], y = pos.y, z = pos.z + d[2]}
			local def = core.registered_nodes[core.get_node(q).name]
			if def and def.walkable == false and top - ground_below(q.x, q.y, q.z) > hc then
				loosen(pos)
				return
			end
		end
	end,
})
core.register_abm({
	label = "rockmech: 懸空的原木毀掉（抽查）",
	nodenames = {LOG}, neighbors = {"air"},
	interval = 10, chance = 5, catch_up = false,
	action = check_log,
})
core.register_on_mods_loaded(function()
	local jm = rockmech.jointmesh
	if not jm then return end
	local orig = jm.dirty_box
	jm.dirty_box = function(a, b)
		orig(a, b)
		local p1 = {x = math.min(a.x, b.x) - 1, y = math.min(a.y, b.y), z = math.min(a.z, b.z) - 1}
		local p2 = {x = math.max(a.x, b.x) + 1, y = math.max(a.y, b.y) + 4, z = math.max(a.z, b.z) + 1}
		core.after(0.5, function()
			for _, q in ipairs(core.find_nodes_in_area(p1, p2, {"group:rockmech_topsoil"})) do check_topsoil(q) end
			for _, q in ipairs(core.find_nodes_in_area(p1, p2, {LOG})) do check_log(q) end
		end)
	end
end)
-- 鬆土、碎石從一格流出去（流掉一部分也算）：貼著的表土被拖動、跟著鬆掉（collapse.lua granular_settle 呼叫）
rockmech.granular_moved = disturb
-- 擾動的來源：玩家挖東西、坍塌／爆破／碎石和鬆土移動（都會排穩定判定）
core.register_on_dignode(function(pos, oldnode)
	disturb(pos)
end)
do
	local col = rockmech.collapse
	local orig = col.queue_stability_check
	col.queue_stability_check = function(pos, prev)
		orig(pos, prev)
		-- 等下一個 tick 再看：on_destruct 裡呼叫的時候，被移除的那一格還在（表土會以為底下還撐著）
		local p = vector.round(pos)
		core.after(0, disturb, p)
	end
end

---------------------------------------------------------------------------
-- 山上的表土和樹林：產生地圖的時候鋪（mapgen.lua），任何世界、任何地形都一樣，不綁礦帶、營地
---------------------------------------------------------------------------
