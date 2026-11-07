-- rockmech/woodwork.lua
-- 木工：樹木、砍樹、鋸木台、木工桌、木製建材。
--   林地：每座營地研究帳篷東邊的平地上鋪一層土壤（土壤碎石，有重量），種幾棵蘋果樹（遊戲內建的樹）。樹苗種在土上會自己長。
--   砍樹：斧頭（工具室管理員）砍樹幹任何一格，整棵倒下：樹幹全部變成原木給砍的人，樹葉拿掉，掉 1–2 棵樹苗和蘋果。
--   鋸木台（營地裡的一張台子）：手上有原木，右鍵選要鋸成什麼：2 根木柱、4 塊木板、8 塊木板半格。
--   木工桌（營地裡一張單純的木桌）：用木板做：木牆板、樓梯、門、活板門、柵欄、柵欄橫桿、梯子、木板半格。
--   這些都是建材，在岩石力學裡算空格（group rockmech_timber，見 collapse.lua、timber.lua），不能當剛性的墊支撐；
--   空手就挖得起來（樹幹要斧頭）。

local storage = rockmech.collapse.storage
local cfg = rockmech.cfg
if not core.get_modpath("default") then return end

local LOG = "default:tree"
local PLANK, SLAB, POST = "rockmech:timber_plank", "rockmech:timber_slab", "rockmech:timber_post"
local WALL = "rockmech:timber_wall"
local SAW, BENCH = "rockmech:sawbench", "rockmech:workbench"
local SAW_FORM, BENCH_FORM = "rockmech:sawbench", "rockmech:workbench"
local USE_R = 4             -- 離台子幾公尺內才能用

local function tell(name, msg) if name then core.chat_send_player(name, "[木工] " .. msg) end end

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
core.override_item(LOG, {description = "原木 Log\n拿到營地的鋸木台鋸成木柱或木板"})
-- 樹苗只能種在滿格的土上：土壤有 8 級高度，種在不滿格的土上，長出來的樹會浮在空中
do
	local sdef = core.registered_items["default:sapling"]
	local orig_place = sdef and sdef.on_place
	core.override_item("default:sapling", {
		description = "樹苗 Sapling\n種在滿格的土上，過一陣子長成樹",
		on_place = function(itemstack, placer, pointed)
			if pointed.type == "node" then
				local under = core.get_node(pointed.under).name
				local k = rockmech.rubble_level[under]
				if pointed.above.y ~= pointed.under.y + 1 or core.get_item_group(under, "soil") == 0
						or (k and k < rockmech.RUBBLE_LEVELS) then
					local def = core.registered_nodes[under]
					if def and def.on_rightclick then return def.on_rightclick(pointed.under, core.get_node(pointed.under), placer, itemstack, pointed) end
					tell(placer and placer:get_player_name(), "樹苗要種在滿格的土上（土的上面）")
					return itemstack
				end
			end
			if orig_place then return orig_place(itemstack, placer, pointed) end
			return core.item_place(itemstack, placer, pointed)
		end,
	})
end
core.override_item("default:axe_steel", {description = "斧頭 Axe\n砍樹幹任何一格，整棵樹倒下變成原木"})
-- 木板、半格改用內建的木頭貼圖，跟樓梯、門、柵欄一致
for _, name in ipairs({PLANK, SLAB}) do core.override_item(name, {tiles = {"default_wood.png"}}) end

-- 木牆板：1/8 格厚的直立板（貼在格子的後面，面向放的人）
core.register_node(WALL, {
	description = "木牆板 Wooden wall panel（建材，不算支撐）\n直立的薄板，做牆壁用",
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
-- 含土樹幹（像 Minecraft 的含水柱子）：樹幹最下面那一格可以同時裝 1–8 級的土（土壤碎石）。
-- 顆粒流把它當成那一格的土（rubble_level k、rubble_base 土壤）：旁邊的土流得進來（rubble_host）、也流得出去、
-- 鏟得走；土拿光變回一般樹幹。寫入格子的地方很多（流動、鏟土、車、破碎站…），所以在 set_node／swap_node／
-- remove_node 這一層統一轉換：對最下面那格樹幹寫土 → 含土樹幹；含土樹幹寫空氣或少了土 → 一般樹幹／較少的土。
-- 只有倒樹（felling）時才真的拿掉樹幹，留下的土照舊是土。
-- 樹倒下：
--   1. 樹那一格裝滿 1 m 的土，旁邊的土面還比它高出 tan(安息角) × 1 m 以上（土要往樹幹第二格流）→ 被埋超過 1 m
--   2. 樹根底下那一格的土流失（不滿格或沒了）
---------------------------------------------------------------------------

local SOIL = rockmech.RUBBLE_SOIL
local NLEV = rockmech.RUBBLE_LEVELS
local COMBO, IS_COMBO = {}, {}
do
	local tdef = core.registered_nodes[LOG]
	local g = table.copy(tdef.groups or {})
	g.rockmech_timber, g.rockmech_rubble, g.rockmech_tree_soil, g.not_in_creative_inventory = nil, 1, 1, 1
	for k = 1, NLEV do
		local name = "rockmech:tree_soil_" .. k
		local side = ("default_tree.png^[lowpart:%d:default_dirt.png"):format(math.floor(k * 100 / NLEV + 0.5))
		core.register_node(name, {
			description = ("原木（埋在土裡 %d/8）"):format(k),
			tiles = {"default_tree_top.png", "default_dirt.png", side},
			groups = table.copy(g), sounds = tdef.sounds, is_ground_content = false, drop = LOG,
		})
		COMBO[k], IS_COMBO[name] = name, k
		rockmech.rubble_level[name] = k
		rockmech.rubble_base[name] = SOIL
		rockmech.rubble_nodes[#rockmech.rubble_nodes + 1] = name
	end
end
local function is_trunk(name) return name == LOG or IS_COMBO[name] ~= nil end
-- 樹幹最下面那一格（下面不是樹幹）
-- 樹根那一格：是樹幹，正下方和斜下方 8 格都沒有樹幹（樹枝是斜著接在樹幹上的，下面有樹幹）
local function bottom_trunk(pos, name)
	if not is_trunk(name or core.get_node(pos).name) then return false end
	for dx = -1, 1 do for dz = -1, 1 do
		if is_trunk(core.get_node({x = pos.x + dx, y = pos.y - 1, z = pos.z + dz}).name) then return false end
	end end
	return true
end
-- 顆粒流（collapse.lua neighbor_surface）：最下面那格一般樹幹可以裝土
function rockmech.rubble_host(p, name, base)
	return name == LOG and base == SOIL and bottom_trunk(p, name)
end

local felling = false
local raw_set, raw_swap, raw_remove = core.set_node, core.swap_node, core.remove_node
-- 要寫進 pos 的 node：pos 是樹幹最下面那格時換成含土樹幹／一般樹幹
local function remap(pos, node)
	if felling then return node end
	local cur = core.get_node(pos)
	local ck = IS_COMBO[cur.name]
	if not ck and cur.name ~= LOG then return node end
	local new = node.name
	local nk = rockmech.rubble_level[new]
	if nk and rockmech.rubble_base[new] == SOIL then
		if ck or bottom_trunk(pos, cur.name) then return {name = COMBO[math.min(NLEV, nk)]} end
	elseif new == "air" and ck then
		return {name = LOG}
	end
	return node
end
function core.set_node(pos, node) return raw_set(pos, remap(pos, node)) end
core.add_node = core.set_node
function core.swap_node(pos, node) return raw_swap(pos, remap(pos, node)) end
function core.remove_node(pos)
	if not felling and IS_COMBO[core.get_node(pos).name] then return raw_swap(pos, {name = LOG}) end
	return raw_remove(pos)
end

-- whole：連 pos 那一格也拿掉（自然倒下；砍的時候那一格由引擎挖掉）
local function fell(pos, digger, whole)
	if felling then return end
	felling = true
	-- 相連的樹幹（含斜的樹枝），往上、往旁邊找，最多 64 格；pos 正下方是含土樹幹也算進來
	local start = {x = pos.x, y = pos.y, z = pos.z}
	local below = {x = pos.x, y = pos.y - 1, z = pos.z}
	local trunk = {}
	if IS_COMBO[core.get_node(below).name] then start = below; trunk[1] = below end
	local seen, q, head = {[core.hash_node_position(start)] = true, [core.hash_node_position(pos)] = true}, {pos}, 1
	while q[head] and #trunk < 64 do
		local p = q[head]; head = head + 1
		trunk[#trunk + 1] = p
		for _, d in ipairs(NB) do
			local n = {x = p.x + d[1], y = p.y + d[2], z = p.z + d[3]}
			local h = core.hash_node_position(n)
			if not seen[h] and n.y >= pos.y and is_trunk(core.get_node(n).name) then seen[h] = true; q[#q + 1] = n end
		end
	end
	local logs, apples = 0, 0
	for _, p in ipairs(trunk) do
		local name = core.get_node(p).name
		local ck = IS_COMBO[name]
		if ck then
			raw_swap(p, {name = rockmech.rubble_with_level(SOIL, ck)}); logs = logs + 1      -- 樹幹拿掉，土留著
		elseif is_trunk(name) and (whole or not vector.equals(p, pos)) then
			raw_remove(p); logs = logs + 1                      -- 砍的那一格由引擎挖掉（照常掉一根原木）
		end
		-- 這段樹幹周圍 2 格的樹葉、蘋果拿掉（樹距 3 m，不碰隔壁那棵）
		for _, l in ipairs(core.find_nodes_in_area(vector.subtract(p, 2), vector.add(p, 2), {"default:leaves", "default:apple"})) do
			if core.get_node(l).name == "default:apple" then apples = apples + 1 end
			raw_remove(l)
		end
	end
	felling = false
	local give = {ItemStack(LOG .. " " .. logs), ItemStack("default:sapling " .. math.random(1, 2))}
	if apples > 0 then give[#give + 1] = ItemStack("default:apple " .. apples) end
	local inv = digger and digger:is_player() and digger:get_inventory()
	for _, s in ipairs(give) do
		if not s:is_empty() then
			local left = inv and inv:add_item("main", s) or s
			if not left:is_empty() then core.add_item(pos, left) end
		end
	end
	core.add_particlespawner({amount = 60, time = 0.5, minpos = vector.subtract(pos, {x = 2, y = 0, z = 2}),
		maxpos = vector.add(pos, {x = 2, y = 6, z = 2}), minvel = {x = -1, y = -2, z = -1}, maxvel = {x = 1, y = 0, z = 1},
		minexptime = 1, maxexptime = 2, minsize = 1, maxsize = 2, texture = "[fill:4x4:#3a7a2a"})
	core.sound_play("default_dig_choppy", {pos = pos, gain = 1.0, max_hear_distance = 32}, true)
	if digger and digger:is_player() then tell(digger:get_player_name(), ("樹倒了：原木 %d 根"):format(logs + (whole and 0 or 1))) end
	-- 留下的土照安息角流
	core.after(0, function() rockmech.collapse.granular_settle(start) end)
end
core.register_on_dignode(function(pos, oldnode, digger)
	if oldnode.name == LOG and digger and digger:is_player() then fell(pos, digger) end
end)

local function topple(base, why)
	fell(base, nil, true)
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), base) <= 32 then
			tell(pl:get_player_name(), ("%s 的樹倒了：%s"):format(core.pos_to_string(base), why))
		end
	end
	core.log("action", ("[rockmech] 樹倒下 %s：%s"):format(core.pos_to_string(base), why))
end
local TAN = math.tan(math.rad(rockmech.cfg.slope.angle))
-- 樹幹最下面那一格（或樹苗）每幾秒檢查一次
core.register_abm({
	label = "rockmech: 樹被土埋超過 1 m、或樹根的土流失就倒",
	nodenames = {LOG, "default:sapling", "group:rockmech_tree_soil"}, interval = 3, chance = 1,
	action = function(pos, node)
		local sap = node.name == "default:sapling"
		if not sap and not bottom_trunk(pos, node.name) then return end
		-- 2. 樹根底下的土流失：不滿格的土，或是空的（土壤以外的實心地面，例如岩石、草皮，照常站得住）
		local bn = core.get_node({x = pos.x, y = pos.y - 1, z = pos.z}).name
		local bk = rockmech.rubble_level[bn]
		local bdef = core.registered_nodes[bn]
		if (bk and bk < NLEV) or (bdef and bdef.walkable == false) then
			if sap then
				raw_remove(pos); core.add_item(pos, "default:sapling")
			else
				topple(pos, "樹根底下的土流失了")
			end
			return
		end
		-- 1. 被埋超過 1 m：旁邊的土面比樹根（這格的底）高出 1 m + tan(安息角) × 1 m 以上 —— 這格裝滿 1 m 的土，
		--    旁邊還比它高出安息角撐得住的高度，土要往樹幹第二格流。（不等土真的流進這格：四周堆得比這格高很多時，
		--    顆粒流只從土堆頂上流，不會先灌進下面的樹幹格）
		if sap then return end
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			local h = 0
			for y = pos.y, pos.y + 4 do
				local k = rockmech.rubble_level[core.get_node({x = pos.x + d[1], y = y, z = pos.z + d[2]}).name]
				if not k then break end
				h = (y - pos.y) + k / NLEV
			end
			if h > 1 + TAN then topple(pos, "被土埋超過 1 m"); return end
		end
	end,
})

---------------------------------------------------------------------------
-- 鋸木台、木工桌：單純的台子，右鍵開選單；材料從手上／物品欄拿
---------------------------------------------------------------------------

local SAW_RECIPES = {
	{give = POST, n = 2, label = "木柱"},
	{give = PLANK, n = 4, label = "木板"},
	{give = SLAB, n = 8, label = "木板半格"},
}
local BENCH_RECIPES = {
	{give = WALL, n = 4, need = 1, label = "木牆板"},
	{give = SLAB, n = 2, need = 1, label = "木板半格"},
	{give = "stairs:stair_wood", n = 1, need = 1, label = "樓梯"},
	{give = "default:fence_wood", n = 2, need = 1, label = "柵欄"},
	{give = "default:fence_rail_wood", n = 2, need = 1, label = "柵欄橫桿"},
	{give = "default:ladder_wood", n = 3, need = 1, label = "梯子"},
	{give = "doors:door_wood", n = 1, need = 2, label = "門"},
	{give = "doors:trapdoor", n = 1, need = 2, label = "活板門"},
}

local function count(inv, item)
	local n = 0
	for _, s in ipairs(inv:get_list("main") or {}) do if s:get_name() == item then n = n + s:get_count() end end
	return n
end

local using = {}            -- 玩家名稱 → 台子位置
local function saw_form(player)
	local n = count(player:get_inventory(), LOG)
	local out = {"formspec_version[6]size[10,5.6]",
		"label[0.5,0.6;鋸木台]",
		("label[0.5,1.2;%s]"):format(core.formspec_escape(("物品欄裡的原木：%d 根（一次鋸一根）"):format(n)))}
	for i, r in ipairs(SAW_RECIPES) do
		out[#out + 1] = ("item_image[0.5,%g;0.8,0.8;%s]"):format(1.7 + (i - 1) * 1.0, r.give)
		out[#out + 1] = ("button[1.5,%g;5,0.8;r_%d;%s]"):format(1.7 + (i - 1) * 1.0, i,
			core.formspec_escape(("原木 1 根 → %s ×%d"):format(r.label, r.n)))
	end
	out[#out + 1] = "button_exit[7,4.7;2.5,0.7;close;關閉]"
	return table.concat(out)
end
local function bench_form(player)
	local n = count(player:get_inventory(), PLANK)
	local out = {"formspec_version[6]size[13,8]",
		"label[0.5,0.6;木工桌]",
		("label[0.5,1.2;%s]"):format(core.formspec_escape(("物品欄裡的木板：%d 塊（木板在鋸木台用原木鋸，或向工具室管理員買）"):format(n)))}
	for i, r in ipairs(BENCH_RECIPES) do
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		local x, y = 0.5 + col * 6.2, 1.8 + row * 1.2
		out[#out + 1] = ("item_image[%g,%g;0.8,0.8;%s]"):format(x, y, r.give)
		out[#out + 1] = ("button[%g,%g;5,0.8;r_%d;%s]"):format(x + 1, y, i,
			core.formspec_escape(("木板 %d → %s ×%d"):format(r.need, r.label, r.n)))
	end
	out[#out + 1] = "button_exit[10,7.1;2.5,0.7;close;關閉]"
	return table.concat(out)
end

local function make(player, need_item, need_n, give, n)
	local name = player:get_player_name()
	local inv = player:get_inventory()
	if count(inv, need_item) < need_n then tell(name, "材料不夠"); return end
	local stack = ItemStack(give .. " " .. n)
	if not inv:room_for_item("main", stack) then tell(name, "物品欄滿了"); return end
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
		tell(name, "離台子太遠了"); core.close_formspec(name, formname); using[name] = nil; return true
	end
	for k in pairs(fields) do
		local i = tonumber(k:match("^r_(%d+)$"))
		if i then
			if formname == SAW_FORM then
				local r = SAW_RECIPES[i]
				if r then make(player, LOG, 1, r.give, r.n) end
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

local function table_node(name, desc, boxes, tiles, form, form_fn)
	core.register_node(name, {
		description = desc, drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
		node_box = {type = "fixed", fixed = boxes}, selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0.45, 0.5}},
		tiles = tiles, is_ground_content = false, groups = {not_in_creative_inventory = 0, rockmech_timber = 1, choppy = 3},
		sounds = default.node_sound_wood_defaults(),
		on_rightclick = function(pos, node, clicker, itemstack)
			if not (clicker and clicker:is_player()) then return itemstack end
			if vector.distance(clicker:get_pos(), pos) > USE_R then tell(clicker:get_player_name(), "走近一點"); return itemstack end
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
	table_node(BENCH, "木工桌 Workbench\n右鍵：用木板做木牆板、樓梯、門、柵欄、梯子…", b,
		{"default_wood.png"}, BENCH_FORM, bench_form)
end
-- 鋸木台：矮的木架，台面中間一片圓鋸片
do
	local b = LEGS(0.15)
	b[#b + 1] = {-0.5, 0.15, -0.3, 0.5, 0.3, 0.3}
	b[#b + 1] = {-0.02, 0.3, -0.25, 0.02, 0.5, 0.25}          -- 鋸片
	table_node(SAW, "鋸木台 Saw bench\n右鍵：把原木鋸成木柱、木板或木板半格", b,
		{"default_wood.png^[fill:2x16:7,0:#b0b4b8", "default_wood.png", "default_wood.png"}, SAW_FORM, saw_form)
end

---------------------------------------------------------------------------
-- 營地的林地：研究帳篷東邊一塊草地（10 × 10 m），種幾棵蘋果樹；旁邊放鋸木台、木工桌
---------------------------------------------------------------------------

local GROVE_DX, GROVE_Z = 36, -20      -- 林地西南角（營地中心往東、z）；研究帳篷在 office_dx（27）± 3、z −19..−13
local GROVE_W = 11
local function ground_y(x, z)
	for y = 40, -30, -1 do
		local n = core.get_node({x = x, y = y, z = z}).name
		if n ~= "air" and n ~= "ignore" and core.get_item_group(n, "rockmech_timber") == 0 then return y end
	end
end
-- 林地：在岩盤上面鋪一層土壤（nodes.lua 的土壤碎石：有重量、照安息角流動，跟碎石一樣），樹種在土上。
-- 蓋林地絕不動岩石：換掉岩石等於開挖，邊坡會垮（2026-11-07 真的垮過）
local SOIL = rockmech.RUBBLE_SOIL
local function flag_of(x0) return "grove_site:" .. x0 end
function rockmech.career_build_grove(x0)
	storage:set_string(flag_of(x0), "1")
	local x1, z1 = x0 + GROVE_DX, GROVE_Z
	-- 只鋪在平坦的地方：取範圍內最常見的地面高度，高度不同的格子（邊坡）跳過；上面要是空的
	local hist, ys = {}, {}
	for x = x1, x1 + GROVE_W - 1 do for z = z1, z1 + GROVE_W - 1 do
		local y = ground_y(x, z)
		ys[x .. "," .. z] = y
		if y then hist[y] = (hist[y] or 0) + 1 end
	end end
	local base, best = nil, 0
	for y, c in pairs(hist) do if c > best then base, best = y, c end end
	if not base then return end
	local soil = {}
	for x = x1, x1 + GROVE_W - 1 do for z = z1, z1 + GROVE_W - 1 do
		local p = {x = x, y = base + 1, z = z}
		if ys[x .. "," .. z] == base and core.get_node(p).name == "air" then
			core.set_node(p, {name = SOIL})
			soil[x .. "," .. z] = true
		end
	end end
	-- 蘋果樹：間隔 3 m（最多 9 棵）
	local n = 0
	-- 只種在四周 8 格都是土的內側：最外圈的土會照安息角流掉一點，樹根的土流失樹就倒
	local function inner(x, z)
		for dx = -1, 1 do for dz = -1, 1 do if not soil[(x + dx) .. "," .. (z + dz)] then return false end end end
		return true
	end
	for x = x1 + 2, x1 + GROVE_W - 3, 3 do for z = z1 + 2, z1 + GROVE_W - 3, 3 do
		-- grow_tree：樹幹就長在這一格（蘋果樹的範本放下去會偏移）
		if inner(x, z) then default.grow_tree({x = x, y = base + 2, z = z}, true); n = n + 1 end
	end end
	-- 鋸木台、木工桌：林地西邊（靠研究帳篷那側）
	local function put(x, z, name)
		local y = ground_y(x, z)
		local p = y and {x = x, y = y + 1, z = z}
		if p and core.get_node(p).name == "air" then core.set_node(p, {name = name, param2 = 1}) end
	end
	put(x1 - 2, z1 + 3, SAW)
	put(x1 - 2, z1 + 6, BENCH)
	core.log("action", ("[rockmech] 營地 x = %d 加上林地（%d 棵樹）、鋸木台、木工桌"):format(x0, n))
end

-- 已經蓋好的營地補上林地
if cfg.career then
	core.after(5, function()
		local sites = {}
		if storage:get_string("career_site") == "2" then sites[#sites + 1] = cfg.career_camp_dx end
		if rockmech.team_site_x then
			for i = 1, cfg.career_teams do
				if storage:get_string("team_site:" .. i) == "1" then sites[#sites + 1] = rockmech.team_site_x(tostring(i)) end
			end
		end
		for _, x0 in ipairs(sites) do
			if storage:get_string(flag_of(x0)) == "" then
				core.emerge_area({x = x0 + GROVE_DX - 4, y = -30, z = GROVE_Z - 4},
					{x = x0 + GROVE_DX + GROVE_W + 4, y = 40, z = GROVE_Z + GROVE_W + 4}, function(_, _, rem)
					if rem > 0 or storage:get_string(flag_of(x0)) ~= "" then return end
					rockmech.career_build_grove(x0)
				end)
			end
		end
	end)
end
