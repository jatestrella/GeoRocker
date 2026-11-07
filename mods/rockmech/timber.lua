-- rockmech/timber.lua
-- 木材：木柱（支撐、蓋房子）、木板、木板半格。都是小東西（10 個一捆，放背包）。
--   木柱：對地板按右鍵，從地板往上長到碰到頂板（最長 rockmech_support_post_max_len m），一根用掉一支。
--     頂到岩石頂板、站在實心地板上 → 支撐：承載力 P = min(壓碎, 尤拉挫屈) 換成柱頂 3×3 格頂板的 pᵢ（support.lua）。
--     上面碰不到東西就只放 1 m（當建材）。對牆面按右鍵 → 橫放當樑（1 m）。
--     挖掉：整根拆下來、退還一支，頂板重新判定。地板沒了（挖掉、炸掉、坍塌）→ 整根倒下，掉在地上。
--   木板、木板半格：建材，不做結構計算。
-- 木材在岩石力學的網格裡都算空格（group rockmech_timber，見 collapse.lua build_cid_maps），
-- 不能拿來當剛性的墊支撐；頂板只透過木柱的 P 感受到支撐。

local scfg = rockmech.cfg.support
local POST = "rockmech:timber_post"           -- 物品，也是柱身方塊
local POST_TOP = "rockmech:timber_post_top"   -- 柱頂（多一塊頂部墊木）
local BEAM = "rockmech:timber_beam"           -- 舊版的樑（facedir），載入時換成下面兩種
local BEAM_X = "rockmech:timber_beam_x"       -- 橫放的樑，順 x
local BEAM_Z = "rockmech:timber_beam_z"       -- 橫放的樑，順 z
local PLANK = "rockmech:timber_plank"
local SLAB = "rockmech:timber_slab"
local IS_POST = {[POST] = true, [POST_TOP] = true}

local function tell(player, msg)
	if player and player:is_player() then core.chat_send_player(player:get_player_name(), "[木材] " .. msg) end
end
local function creative(player)
	return core.is_creative_enabled(player and player:is_player() and player:get_player_name() or "")
end
local function is_rock(name)
	local def = core.registered_nodes[name]
	return def and def.groups and (def.groups.rockmech_rock or 0) > 0
end
-- 木柱可以站的地板：天然實心地層（岩石、土、礦）或夯實碎石；木材、鬆散碎石不算
local function is_floor(name)
	local def = core.registered_nodes[name]
	if not def or def.walkable == false then return false end
	local g = def.groups or {}
	if (g.rockmech_timber or 0) > 0 then return false end
	if rockmech.compacted[name] then return true end
	return def.is_ground_content ~= false and (g.rockmech_rubble or 0) == 0 and (g.falling_node or 0) == 0
end

local function capacity(L)
	return rockmech.support.post_capacity(L, scfg.post_d, scfg.post_ucs, scfg.post_e)
end
local function info(L, supporting)
	local P, mode, crush, buckle = capacity(L)
	return ("木柱（長 %d m、直徑 %d cm）\n承載力 %d kN（%s控制：壓碎 %d kN、挫屈 %d kN）%s"):format(
		L, math.floor(scfg.post_d * 100 + 0.5), P, mode == "buckle" and "挫屈" or "壓碎", crush, buckle,
		supporting and "" or "\n沒有頂到岩石頂板：不算支撐")
end

-- 柱頂在 (x, y, z) 的木柱長度（往下數連續的木柱格），沒有站在地板上回傳 nil（support.scan 用）
function rockmech.timber_post_len(x, y, z)
	local n = 0
	for yy = y, y - scfg.post_max_len - 1, -1 do
		local name = core.get_node({x = x, y = yy, z = z}).name
		if IS_POST[name] then n = n + 1
		else return n > 0 and is_floor(name) and n or nil end
	end
	return nil
end

-- 一根木柱的範圍：base 的 meta len = 長度（往上長出來的整根）。找 pos 所屬的那一根，沒有就是單獨的 1 m
local function post_of(pos)
	for s = 0, scfg.post_max_len - 1 do
		local b = {x = pos.x, y = pos.y - s, z = pos.z}
		if not IS_POST[core.get_node(b).name] then break end
		local len = core.get_meta(b):get_int("len")
		if len > s then return b, len end
	end
	return {x = pos.x, y = pos.y, z = pos.z}, 1
end

local function resolve(pos, prev)
	rockmech.collapse.queue_stability_check(pos, prev)
	if rockmech.cfg.fem.drive then rockmech.fem_queue(pos, 1) end
end

-- 拆掉一根木柱（從 base 往上 len 格）；give：退還給誰（nil = 掉在地上）
local function remove_post(base, len, give)
	local top = {x = base.x, y = base.y + len - 1, z = base.z}
	for s = 0, len - 1 do
		local p = {x = base.x, y = base.y + s, z = base.z}
		if IS_POST[core.get_node(p).name] then core.remove_node(p) end
	end
	if give then
		if not creative(give) then
			local left = give:get_inventory():add_item("main", ItemStack(POST))
			if not left:is_empty() then core.add_item(base, left) end
		end
	else
		core.add_item(base, ItemStack(POST))
	end
	resolve(top, POST_TOP)
end

-- 外觀：圓木（兩個交叉的方柱近似），樹皮側面、年輪端面
local BARK = "[fill:16x16:#6e5032^[fill:1x16:3,0:#5a3f26^[fill:1x16:8,0:#5a3f26^[fill:1x16:12,0:#5a3f26^[fill:2x3:5,4:#80603e^[fill:2x3:10,10:#80603e"
local ENDS = "[fill:16x16:#c9a46a^[fill:10x10:3,3:#b8925a^[fill:6x6:5,5:#c9a46a^[fill:2x2:7,7:#9a7444"
local WOOD = "[fill:16x16:#b08850^[fill:16x1:0,3:#9a7444^[fill:16x1:0,7:#9a7444^[fill:16x1:0,11:#9a7444^[fill:16x1:0,15:#9a7444^[fill:1x3:5,0:#9a7444^[fill:1x4:11,4:#9a7444^[fill:1x3:3,8:#9a7444^[fill:1x4:9,12:#9a7444"
local BARK_H = BARK .. "^[transformR90"           -- 橫放的樑：木紋順著樑
-- 圓木斷面（兩個交叉的方柱近似直徑 20 cm），沿 x／y／z 從 a 到 b
local function xs(a, b) return {{a, -0.1, -0.06, b, 0.1, 0.06}, {a, -0.06, -0.1, b, 0.06, 0.1}} end
local function ys(a, b) return {{-0.1, a, -0.06, 0.1, b, 0.06}, {-0.06, a, -0.1, 0.06, b, 0.1}} end
local function zs(a, b) return {{-0.1, -0.06, a, 0.1, 0.06, b}, {-0.06, -0.1, a, 0.06, 0.1, b}} end
local SHAFT = ys(-0.5, 0.5)
local CAP = {-0.3, 0.42, -0.12, 0.3, 0.5, 0.12}   -- 柱頂墊木
-- 接合：柱身在格子中央，旁邊的樑從格子邊界開始，中間會空 40 cm。
-- 用 connected nodebox：碰到旁邊的木柱、樑時，從中央伸出一段同斷面的木頭接到格子邊界，兩邊剛好接上。
--   木柱：四個水平方向接樑。順 x 的樑：±z 接木柱與順 z 的樑、上下接木柱與順 z 的樑（疊成井字）；順 z 的樑同理。
local function connected(fixed, sides, connects_to)
	local nb = {type = "connected", fixed = fixed}
	local arms = {left = xs(-0.5, 0), right = xs(0, 0.5), bottom = ys(-0.5, 0), top = ys(0, 0.5),
		front = zs(-0.5, 0), back = zs(0, 0.5)}
	for _, s in ipairs(sides) do nb["connect_" .. s] = arms[s] end
	return {node_box = nb, connects_to = connects_to}
end
local sounds = core.get_modpath("default") and default.node_sound_wood_defaults() or nil
local G = {dig_immediate = 2, rockmech_timber = 1}
local G_HIDDEN = table.copy(G)
G_HIDDEN.not_in_creative_inventory = 1
local function groups(base, extra)
	local t = table.copy(base)
	for k, v in pairs(extra) do t[k] = v end
	return t
end
local HORIZ = {"left", "right", "front", "back"}
local POST_BOX = connected(SHAFT, HORIZ, {"group:timber_beam_x", "group:timber_beam_z"})
local POST_TOP_BOX = connected({SHAFT[1], SHAFT[2], CAP}, HORIZ, {"group:timber_beam_x", "group:timber_beam_z"})
local BEAM_X_BOX = connected(xs(-0.5, 0.5), {"front", "back", "top", "bottom"}, {"group:timber_post", "group:timber_beam_z"})
local BEAM_Z_BOX = connected(zs(-0.5, 0.5), {"left", "right", "top", "bottom"}, {"group:timber_post", "group:timber_beam_x"})

local function post_dig(pos, node, digger)
	local base, len = post_of(pos)
	remove_post(base, len, digger and digger:is_player() and digger or nil)
	return true
end

core.register_node(POST, {
	description = ("木柱 Timber post（直徑 %d cm）\n對地板按右鍵：往上長到碰到頂板，最長 %d m\n頂到岩石頂板 → 支撐：承載力 P = min(壓碎, 挫屈)，分給柱頂周圍 3×3 m² 的頂板\n2 m 約 %d kN、4 m 約 %d kN、6 m 約 %d kN（柱越長越容易挫屈）\n對牆面按右鍵：橫放當樑")
		:format(math.floor(scfg.post_d * 100 + 0.5), scfg.post_max_len, capacity(2), capacity(4), capacity(6)),
	drawtype = "nodebox", paramtype = "light", sunlight_propagates = true,
	node_box = POST_BOX.node_box, connects_to = POST_BOX.connects_to,
	selection_box = {type = "fixed", fixed = SHAFT},
	tiles = {ENDS, ENDS, BARK},
	inventory_image = "[fill:16x16:#00000000^[fill:4x14:6,1:#6e5032^[fill:1x14:7,1:#5a3f26^[fill:4x2:6,1:#c9a46a",
	wield_image = "[fill:16x16:#00000000^[fill:4x14:6,1:#6e5032^[fill:1x14:7,1:#5a3f26^[fill:4x2:6,1:#c9a46a",
	is_ground_content = false, groups = groups(G, {timber_post = 1}), sounds = sounds, drop = "",
	on_dig = post_dig,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" then return itemstack end
		local under, above = pointed.under, pointed.above
		-- 對著已經放好的東西右鍵（例如木板）：照一般規則
		local un = core.get_node(under)
		local udef = core.registered_nodes[un.name]
		if udef and udef.on_rightclick and not (placer and placer:get_player_control().sneak) then
			return udef.on_rightclick(under, un, placer, itemstack, pointed) or itemstack
		end
		local ab = core.registered_nodes[core.get_node(above).name]
		if not ab or not ab.buildable_to then return itemstack end
		local name = placer and placer:is_player() and placer:get_player_name() or ""
		if core.is_protected(above, name) then core.record_protection_violation(above, name); return itemstack end
		if above.y == under.y + 1 then
			-- 對地板：往上找頂板
			local n
			for s = 1, scfg.post_max_len do
				local p = {x = above.x, y = above.y + s - 1, z = above.z}
				local def = core.registered_nodes[core.get_node(p).name]
				if not def or not def.buildable_to then n = s - 1; break end
			end
			if n and n >= 1 then
				local roof = core.get_node({x = above.x, y = above.y + n, z = above.z}).name
				for s = 0, n - 1 do
					core.set_node({x = above.x, y = above.y + s, z = above.z}, {name = s == n - 1 and POST_TOP or POST})
				end
				local meta = core.get_meta(above)
				meta:set_int("len", n)
				local supporting = is_rock(roof) and is_floor(un.name)
				local txt = info(n, supporting)
				for s = 0, n - 1 do core.get_meta({x = above.x, y = above.y + s, z = above.z}):set_string("infotext", txt) end
				if supporting then
					local P, mode = capacity(n)
					tell(placer, ("木柱 %d m 頂住頂板：承載力 %d kN（%s控制）"):format(n, P, mode == "buckle" and "挫屈" or "壓碎"))
				end
				resolve({x = above.x, y = above.y + n - 1, z = above.z})
			else
				-- 上面 post_max_len 內碰不到東西：只放 1 m（建材）
				core.set_node(above, {name = POST})
				core.get_meta(above):set_string("infotext", info(1, false))
			end
		elseif above.y == under.y - 1 then
			core.set_node(above, {name = POST})
		else
			-- 對牆面：橫放當樑，樑的方向垂直於牆面
			local d = vector.subtract(above, under)
			core.set_node(above, {name = d.x ~= 0 and BEAM_X or BEAM_Z})
		end
		if not creative(placer) then itemstack:take_item() end
		return itemstack
	end,
})

core.register_node(POST_TOP, {
	description = "木柱（柱頂） Timber post top",
	drawtype = "nodebox", paramtype = "light", sunlight_propagates = true,
	node_box = POST_TOP_BOX.node_box, connects_to = POST_TOP_BOX.connects_to,
	selection_box = {type = "fixed", fixed = SHAFT},
	tiles = {ENDS, ENDS, BARK},
	is_ground_content = false, groups = groups(G_HIDDEN, {timber_post = 1}), sounds = sounds, drop = "",
	on_dig = post_dig,
})

-- 橫放的樑：順 x、順 z 各一種（connected nodebox 不跟著 facedir 轉，所以分成兩種方塊）
for _, v in ipairs({
	{BEAM_X, BEAM_X_BOX, xs(-0.5, 0.5), {BARK_H, BARK_H, ENDS, ENDS, BARK_H, BARK_H}, "timber_beam_x"},
	{BEAM_Z, BEAM_Z_BOX, zs(-0.5, 0.5), {BARK, BARK, BARK_H, BARK_H, ENDS, ENDS}, "timber_beam_z"},
}) do
	core.register_node(v[1], {
		description = "木樑 Timber beam",
		drawtype = "nodebox", paramtype = "light", sunlight_propagates = true,
		node_box = v[2].node_box, connects_to = v[2].connects_to,
		selection_box = {type = "fixed", fixed = v[3]},
		tiles = v[4],
		is_ground_content = false, groups = groups(G_HIDDEN, {[v[5]] = 1}), sounds = sounds, drop = POST,
	})
end
-- 舊版的樑（facedir 轉向的單一方塊）：換成順 x／順 z 的樑
core.register_node(BEAM, {
	description = "木樑（舊版）", drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
	node_box = {type = "fixed", fixed = SHAFT}, tiles = {ENDS, ENDS, BARK},
	is_ground_content = false, groups = table.copy(G_HIDDEN), sounds = sounds, drop = POST,
})
core.register_lbm({
	label = "rockmech: 舊版木樑換成順 x／順 z 的樑",
	name = "rockmech:timber_beam_axis",
	nodenames = {BEAM}, run_at_every_load = true,
	action = function(pos, node)
		local axis = math.floor(node.param2 / 4)          -- facedir 的軸：3、4 = ±x，1、2 = ±z
		core.swap_node(pos, {name = (axis == 3 or axis == 4) and BEAM_X or BEAM_Z})
	end,
})

core.register_node(PLANK, {
	description = "木板 Timber plank（建材，不算支撐）",
	tiles = {WOOD},
	is_ground_content = false, groups = table.copy(G), sounds = sounds,
})

core.register_node(SLAB, {
	description = "木板半格 Timber slab（建材，不算支撐）\n對頂面放是下半格、對底面放是上半格",
	drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
	node_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0, 0.5}},
	tiles = {WOOD},
	is_ground_content = false, groups = table.copy(G), sounds = sounds,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" then return core.item_place(itemstack, placer, pointed) end
		-- 對底面（或牆面上半）放：倒過來成上半格
		local up = pointed.above.y < pointed.under.y
		if pointed.above.y == pointed.under.y and placer and placer:is_player() then
			local fp = core.pointed_thing_to_face_pos(placer, pointed)
			up = fp and fp.y - pointed.under.y > 0
		end
		return core.item_place(itemstack, placer, pointed, up and 20 or 0)
	end,
})

-- 地板沒了：整根木柱倒下（拆掉、掉一支在地上）；只看 base（meta len）或單獨的柱身
core.register_abm({
	label = "rockmech: 木柱的地板沒了就倒",
	nodenames = {POST, POST_TOP}, interval = 2, chance = 1,
	action = function(pos)
		local below = {x = pos.x, y = pos.y - 1, z = pos.z}
		local bn = core.get_node(below).name
		if IS_POST[bn] or bn == "ignore" then return end
		local def = core.registered_nodes[bn]
		if def and def.walkable ~= false then return end
		local len = math.max(1, core.get_meta(pos):get_int("len"))
		remove_post(pos, len, nil)
	end,
})

-- 判定用的方塊 id（groundsupport.lua 建好 rockmech.support_ids 之後補上木柱）
core.register_on_mods_loaded(function()
	if rockmech.support_ids then
		rockmech.support_ids.post = {[core.get_content_id(POST)] = true, [core.get_content_id(POST_TOP)] = true}
	end
end)
