-- rockmech/woodwork.lua
-- 木工：樹木、砍樹、鋸木台、木工桌、木製建材。
--   表土和樹林：每條礦帶交界的山脊整片鋪表土（根系抓住，被擾動才變鬆土），上面稀疏種蘋果樹。樹苗種在滿格的土上會自己長。
--   砍樹：斧頭（工具室管理員）砍樹幹任何一格，整棵倒下：樹幹全部變成原木給砍的人，樹葉拿掉，掉 1–2 棵樹苗和蘋果。
--   鋸木台（營地中心東南邊的一張台子）：手上有原木，右鍵選要鋸成什麼：2 根木柱、4 塊木板、8 塊木板半格。
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
-- 樹倒下（原木、樹苗、蘋果掉在地上）：
--   1. 被埋：周圍 8 格的土面都比樹根（樹幹最下面那格的底）高出 1 m 以上。邊坡上下坡那側比較低，不會倒
--   2. 樹根的土流失：樹根底下那格的土不滿格或沒了（土壤以外的實心地面，例如岩石、草皮，照常站得住）；樹苗一樣
---------------------------------------------------------------------------

local SOIL = rockmech.RUBBLE_SOIL
local NLEV = rockmech.RUBBLE_LEVELS
-- 舊版的含土樹幹（試過、拿掉了）：載入時變回一般樹幹
for k = 1, NLEV do core.register_alias("rockmech:tree_soil_" .. k, LOG) end

-- 樹根那一格：是樹幹，正下方和斜下方 8 格都沒有樹幹（樹枝是斜著接在樹幹上的，下面有樹幹）
local function root_cell(pos)
	if core.get_node(pos).name ~= LOG then return false end
	for dx = -1, 1 do for dz = -1, 1 do
		if core.get_node({x = pos.x + dx, y = pos.y - 1, z = pos.z + dz}).name == LOG then return false end
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
			if not seen[h] and n.y >= pos.y and core.get_node(n).name == LOG then seen[h] = true; q[#q + 1] = n end
		end
	end
	local logs, apples = 0, 0
	for i, p in ipairs(trunk) do
		if i > 1 or whole then core.remove_node(p); logs = logs + 1 end   -- 砍的那一格由引擎挖掉（照常掉一根原木）
		-- 這段樹幹周圍 2 格的樹葉、蘋果拿掉（樹距 3 m，不碰隔壁那棵）
		for _, l in ipairs(core.find_nodes_in_area(vector.subtract(p, 2), vector.add(p, 2), {"default:leaves", "default:apple"})) do
			if core.get_node(l).name == "default:apple" then apples = apples + 1 end
			core.remove_node(l)
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
			else topple(pos, "樹根底下的土流失了") end
			return
		end
		if sap then return end
		for dx = -1, 1 do for dz = -1, 1 do
			if (dx ~= 0 or dz ~= 0) and soil_above(pos.x + dx, pos.z + dz, pos) <= 1 then return end
		end end
		topple(pos, "被土埋超過 1 m")
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
-- 表土（有植物根系的土）：根系凝聚力讓它在陡坡上也站得住，所以不參與顆粒流（不是碎石）。
-- 一被擾動，根系就斷，變成一般的鬆土（nodes.lua 的土壤碎石），照安息角流動：
--   學生挖表土 → 挖起來的就是一份土（同撿碎石）
--   貼著的格子被挖掉、炸掉、坍塌 → 貼著的表土變鬆土；底下被掏空的表土變鬆土、掉下來
--   鬆土流走也算擾動：陡坡上一格鬆了流走，旁邊的表土跟著鬆、跟著流，連鎖成整片邊坡滑動；
--   緩坡上鬆掉的土在安息角內不流，連鎖自己停住
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
local NB6 = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
-- pos 被擾動（東西被拿掉）：貼著的表土變鬆土
local function disturb(pos)
	for _, d in ipairs(NB6) do loosen({x = pos.x + d[1], y = pos.y + d[2], z = pos.z + d[3]}) end
end
-- pos 變空了：正上方的表土失去支撐，變鬆土掉下來（鬆土流走也算，不然表土會懸空）
local function undercut(pos)
	local def = core.registered_nodes[core.get_node(pos).name]
	if def and def.walkable == false then loosen({x = pos.x, y = pos.y + 1, z = pos.z}) end
end

core.register_node(TOPSOIL, {
	description = "表土 Topsoil\n長著草和樹根的土：根系抓住，陡坡上也站得住；一挖、或旁邊被挖開，就變成鬆土照安息角流",
	tiles = {"default_grass.png", "default_dirt.png", {name = "default_dirt.png^default_grass_side.png", tileable_vertical = false}},
	is_ground_content = false, groups = {crumbly = 3, soil = 1},
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
		description = ("表土（%d/8 m）Topsoil"):format(k),
		drawtype = "nodebox", paramtype = "light",
		node_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.5 + k / NLEV, 0.5}},
		tiles = {"default_grass.png", "default_dirt.png", {name = "default_dirt.png^default_grass_side.png", tileable_vertical = false}},
		is_ground_content = false, groups = {crumbly = 3, soil = 1, not_in_creative_inventory = 1},
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
-- 鬆土、碎石從一格流出去（流掉一部分也算）：貼著的表土被拖動、跟著鬆掉（collapse.lua granular_settle 呼叫）
rockmech.granular_moved = disturb
-- 擾動的來源：玩家挖東西、坍塌／爆破／碎石和鬆土移動（都會排穩定判定）
core.register_on_dignode(function(pos, oldnode)
	disturb(pos)
	undercut(pos)
end)
do
	local col = rockmech.collapse
	local orig = col.queue_stability_check
	col.queue_stability_check = function(pos, prev)
		orig(pos, prev)
		local p = vector.round(pos)
		disturb(p)
		undercut(p)
	end
end

---------------------------------------------------------------------------
-- 山上的表土和樹林：每條礦帶交界的山脊，比地表高 1 m 以上、頂上是天然岩石的每一欄都鋪 1–3 m 的表土（有厚有薄）
-- （陡坡也鋪：根系抓住；2 m 才蓋得住 1 m 一階的岩石台階；屋頂、帳篷等建築上面不鋪），
-- 上面稀疏種蘋果樹；鋸木台、木工桌放在營地裡。
-- 2026-11-07 的教訓：蓋的時候絕不動岩石（換掉岩石等於開挖），而且用 VoxelManip 寫（不觸發破壞判定）
---------------------------------------------------------------------------

local RIDGE_X = 30           -- 山脊中線兩側各鋪幾公尺
local Z1, Z2 = -40, 160      -- 沿山脊鋪到哪裡（z）
local MIN_RISE = 1           -- 比地表高這麼多才算山坡（走廊、平地不鋪）
local TREE_GAP = 6           -- 樹距 (m)，再加隨機偏移、隨機跳過一些
local SOIL_MIN, SOIL_MAX = 1, 3   -- 表土厚度 (m)：平滑雜訊在這中間變化（平均 2 m，蓋得住 1 m 一階的岩石台階）
local DIRS8 = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}

-- 範圍內每一欄最高的非空氣格 h，和那一格是不是天然岩石 rock（建築、樹、土上面不鋪）
local function heightmap(x1, x2, z1, z2)
	local vm = core.get_voxel_manip()
	local e1, e2 = vm:read_from_map({x = x1, y = -20, z = z1}, {x = x2, y = 60, z = z2})
	local area = VoxelArea(e1, e2)
	local data = vm:get_data()
	local c_air, c_ign = core.CONTENT_AIR, core.CONTENT_IGNORE
	local is_rock = {}
	for name in pairs(rockmech.lith_of_node) do is_rock[core.get_content_id(name)] = true end
	local h, rock = {}, {}
	for z = z1, z2 do for x = x1, x2 do
		for y = 60, -20, -1 do
			local c = data[area:index(x, y, z)]
			if c ~= c_air and c ~= c_ign then h[x .. "," .. z] = y; rock[x .. "," .. z] = is_rock[c]; break end
		end
	end end
	return h, rock
end
local function rnd(x, z, seed)      -- 每個位置固定的 0..1 亂數
	local v = math.sin(x * 12.9898 + z * 78.233 + seed * 37.719) * 43758.5453
	return v - math.floor(v)
end

local planting = {}          -- 正在做的山脊（這次開機）
local function plant_ridge(xr)
	local key = "ridge_forest:" .. xr
	if storage:get_string(key) ~= "" or planting[xr] then return end
	planting[xr] = true
	local x1, x2 = xr - RIDGE_X, xr + RIDGE_X
	local h, rock = heightmap(x1 - 1, x2 + 1, Z1 - 1, Z2 + 1)
	local surface = cfg.surface_y or 0
	-- 表土（VoxelManip：不觸發破壞判定）
	local vm = core.get_voxel_manip()
	local e1, e2 = vm:read_from_map({x = x1, y = -20, z = Z1}, {x = x2, y = 61 + SOIL_MAX, z = Z2})
	local area = VoxelArea(e1, e2)
	local data = vm:get_data()
	local c_top = core.get_content_id(TOPSOIL)
	local c_thin = {}
	for k = 1, NLEV - 1 do c_thin[k] = core.get_content_id(TOPSOIL_THIN[k]) end
	-- 每一欄的厚度（八分之一公尺）：平滑雜訊，SOIL_MIN..SOIL_MAX m，看起來像自然堆積
	local thick = {}
	local noise = rockmech.stress.terrain_noise
	for x = x1, x2 do for z = Z1, Z2 do
		local y = h[x .. "," .. z]
		if y and y >= surface + MIN_RISE and rock[x .. "," .. z] then
			local n = noise(x / 14, z / 14, 41)
			thick[x .. "," .. z] = math.floor(NLEV * (SOIL_MIN + (SOIL_MAX - SOIL_MIN) * n) + 0.5)
		end
	end end
	-- 樹的位置先挑：稀疏（間距 TREE_GAP、隨機偏移、四成跳過），那一欄的厚度取整格（樹不長在薄片上），至少 2 m
	local trees = {}
	for gx = x1, x2, TREE_GAP do for gz = Z1, Z2, TREE_GAP do
		local x = gx + math.floor(rnd(gx, gz, 1) * 5) - 2
		local z = gz + math.floor(rnd(gx, gz, 2) * 5) - 2
		local t = thick[x .. "," .. z]
		if rnd(gx, gz, 3) > 0.4 and t then
			thick[x .. "," .. z] = math.max(2 * NLEV, t - t % NLEV)
			trees[#trees + 1] = {x = x, z = z}
		end
	end end
	local covered, n_soil = {}, 0     -- covered：鋪了幾整格
	for key, t in pairs(thick) do
		local x, z = key:match("^(-?%d+),(-?%d+)$")
		x, z = tonumber(x), tonumber(z)
		local y = h[key]
		local full, r = math.floor(t / NLEV), t % NLEV
		local done = 0
		for dy = 1, full + (r > 0 and 1 or 0) do
			local i = area:index(x, y + dy, z)
			if data[i] ~= core.CONTENT_AIR then break end
			data[i] = dy <= full and c_top or c_thin[r]
			n_soil = n_soil + 1
			if dy <= full then done = dy end
		end
		if done > 0 then covered[key] = done end
	end
	-- 坡腳：山腳平地上離有表土的地方 1、2、3 m 的那一圈，鋪 1 m、5/8 m、2/8 m 的表土（蓋住最下面那一階的岩石側面，
	-- 逐漸變薄接到平地）。只鋪在天然岩石上
	local APRON = {NLEV, 5, 2}
	local dist, frontier = {}, {}
	for key in pairs(covered) do dist[key] = 0; frontier[#frontier + 1] = key end
	for d = 1, #APRON do
		local nxt = {}
		for _, key in ipairs(frontier) do
			local cx, cz = key:match("^(-?%d+),(-?%d+)$")
			cx, cz = tonumber(cx), tonumber(cz)
			for _, dd in ipairs(DIRS8) do
				local x, z = cx + dd[1], cz + dd[2]
				local k2 = x .. "," .. z
				if not dist[k2] and x >= x1 and x <= x2 and z >= Z1 and z <= Z2 and rock[k2] and h[k2] then
					dist[k2] = d
					nxt[#nxt + 1] = k2
					local i = area:index(x, h[k2] + 1, z)
					if data[i] == core.CONTENT_AIR then
						local lv = APRON[d]
						data[i] = core.get_content_id(lv == NLEV and TOPSOIL or TOPSOIL_THIN[lv])
						n_soil = n_soil + 1
					end
				end
			end
		end
		frontier = nxt
	end
	vm:set_data(data)
	vm:write_to_map(true)
	-- 樹：種在挑好的位置（整格表土上）；周圍 8 格的地面都比樹根高 1 m 以上（窪地）不種
	local function ground(x, z)
		local y = h[x .. "," .. z]
		return y and (y + (covered[x .. "," .. z] or 0)) or nil
	end
	local n_tree = 0
	for _, tp in ipairs(trees) do
		local x, z = tp.x, tp.z
		if covered[x .. "," .. z] and covered[x .. "," .. z] * NLEV == thick[x .. "," .. z] then
			local g = ground(x, z)
			local buried = true
			for _, d in ipairs(DIRS8) do
				local gb = ground(x + d[1], z + d[2])
				if not gb or gb - g <= 1 then buried = false; break end
			end
			if not buried then
				default.grow_tree({x = x, y = g + 1, z = z}, true)
				n_tree = n_tree + 1
			end
		end
	end
	-- 做完、寫進地圖之後才記下來（中途關機的話下次重做）
	storage:set_string(key, "1")
	planting[xr] = nil
	core.log("action", ("[rockmech] 山脊 x = %d 鋪了 %d 格表土、種了 %d 棵樹"):format(xr, n_soil, n_tree))
end

-- 鋸木台、木工桌：營地中心往東南，交車區北邊（營地中心 (x0, 0)）
local function put_benches(x0)
	local function free(x, z)
		for y = 40, -30, -1 do
			local n = core.get_node({x = x, y = y, z = z}).name
			if n ~= "air" and n ~= "ignore" then
				local def = core.registered_nodes[n]
				return def and def.walkable ~= false and core.get_node({x = x, y = y + 1, z = z}).name == "air" and y + 1 or nil
			end
		end
	end
	local placed = 0
	for _, c in ipairs({{12, -9}, {14, -9}, {12, -7}, {14, -7}, {16, -9}, {16, -7}, {10, -9}, {10, -7}}) do
		if placed >= 2 then break end
		local x, z = x0 + c[1], c[2]
		local y = free(x, z)
		if y then
			core.set_node({x = x, y = y, z = z}, {name = placed == 0 and SAW or BENCH, param2 = 0})
			placed = placed + 1
		end
	end
end

local function flag_of(x0) return "grove_site:" .. x0 end
-- 營地 x0：鋸木台、木工桌，加上這條礦帶東西兩側的山脊（隔壁帶共用的那條種過就不再種）
function rockmech.career_build_grove(x0)
	local W = cfg.coal_seam and cfg.coal_seam.lane_w
	local c = x0 - (cfg.career_camp_dx or 0)
	core.emerge_area({x = x0 - 2, y = -30, z = -12}, {x = x0 + 20, y = 40, z = -4}, function(_, _, rem)
		if rem > 0 or storage:get_string(flag_of(x0)) ~= "" then return end
		put_benches(x0)
		storage:set_string(flag_of(x0), "1")
	end)
	if not W then return end
	for _, xr in ipairs({c - W / 2, c + W / 2}) do
		if storage:get_string("ridge_forest:" .. xr) == "" then
			core.emerge_area({x = xr - RIDGE_X - 2, y = -20, z = Z1 - 2}, {x = xr + RIDGE_X + 2, y = 61, z = Z2 + 2}, function(_, _, rem)
				if rem == 0 then plant_ridge(xr) end
			end)
		end
	end
end

-- 已經蓋好的營地補上
if cfg.career then
	core.after(5, function()
		local sites = {}
		if storage:get_string("career_site") == "2" then sites[#sites + 1] = cfg.career_camp_dx end
		if rockmech.team_site_x then
			for i = 1, cfg.career_teams do
				if storage:get_string("team_site:" .. i) == "1" then sites[#sites + 1] = rockmech.team_site_x(tostring(i)) end
			end
		end
		for _, x0 in ipairs(sites) do rockmech.career_build_grove(x0) end
	end)
end
