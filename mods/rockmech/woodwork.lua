-- rockmech/woodwork.lua
-- 木工：樹木、砍樹、鋸木台、木工桌、木製建材。
--   林地：每座營地研究帳篷東邊一塊草地，種幾棵蘋果樹（遊戲內建的樹）。樹苗種在土上會自己長（default 的樹苗計時器）。
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
core.override_item("default:sapling", {description = "樹苗 Sapling\n種在草地或土上，過一陣子長成樹"})
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
local felling = false
local function fell(pos, digger)
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
		if i > 1 then core.remove_node(p) end      -- 砍的那一格由引擎挖掉（照常掉一根原木）
		logs = logs + (i > 1 and 1 or 0)
		-- 這段樹幹周圍 2 格的樹葉、蘋果拿掉（樹距 3 m，不碰隔壁那棵）
		for _, l in ipairs(core.find_nodes_in_area(vector.subtract(p, 2), vector.add(p, 2), {"default:leaves", "default:apple"})) do
			if core.get_node(l).name == "default:apple" then apples = apples + 1 end
			core.remove_node(l)
		end
	end
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
	if digger and digger:is_player() then tell(digger:get_player_name(), ("樹倒了：原木 %d 根"):format(logs + 1)) end
	felling = false
end
core.register_on_dignode(function(pos, oldnode, digger)
	if oldnode.name == LOG and digger and digger:is_player() then fell(pos, digger) end
end)

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
local GROVE_W = 10
local function ground_y(x, z)
	for y = 40, -30, -1 do
		local n = core.get_node({x = x, y = y, z = z}).name
		if n ~= "air" and n ~= "ignore" and core.get_item_group(n, "rockmech_timber") == 0 then return y end
	end
end
local function flag_of(x0) return "grove_site:" .. x0 end
function rockmech.career_build_grove(x0)
	storage:set_string(flag_of(x0), "1")
	local x1, z1 = x0 + GROVE_DX, GROVE_Z
	-- 草地：表層換成草皮，下面兩層土
	for x = x1, x1 + GROVE_W - 1 do for z = z1, z1 + GROVE_W - 1 do
		local y = ground_y(x, z)
		if y then
			core.set_node({x = x, y = y, z = z}, {name = "default:dirt_with_grass"})
			for d = 1, 2 do core.set_node({x = x, y = y - d, z = z}, {name = "default:dirt"}) end
		end
	end end
	-- 蘋果樹：間隔 3 m（9 棵）
	local n = 0
	for x = x1 + 1, x1 + GROVE_W - 2, 3 do for z = z1 + 1, z1 + GROVE_W - 2, 3 do
		local y = ground_y(x, z)
		if y then default.grow_new_apple_tree({x = x, y = y + 1, z = z}); n = n + 1 end
	end end
	-- 鋸木台、木工桌：林地西邊（靠研究帳篷那側）
	local function put(x, z, name)
		local y = ground_y(x, z)
		if y then core.set_node({x = x, y = y + 1, z = z}, {name = name, param2 = 1}) end
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
