-- rockmech/rubble_tool.lua
-- 清碴魔杖（rockmech:rubble_wand）：快速清除碎石（出碴）
--   左鍵：清除面前 3×3×3 的碎石（從指到的那一格往裡 3 層）
--   右鍵：清除與指到的碎石相連的所有碎石（26 方向相連，上限 MAX_FLOOD 格）
--   按住 Shift（潛行）：清掉的碎石收進物品欄（不滿格的碎石依級數累加，每 8 級 = 1 個）
-- 爆破魔杖（rockmech:blast_wand）：
--   左鍵：在指到的岩面前引爆一個 TNT（同原版 TNT 的爆炸，岩石依強度破碎，見 blasting.lua）
--   右鍵：一鍵清碴：指到的格子附近（±2 格）所有碎石，以及與它們相連的碎石
-- 只動碎石，不動岩石。以 VoxelManip 一次移除，再比照爆破觸發後續判定：
-- 記錄開挖（只算開挖造成的惡化）、緊貼岩石處的穩定判定與破壞檢查、
-- 周圍沒被清掉的碎石重新判定掉落／顆粒流。

local S = rockmech.S
local MAX_FLOOD = 4096
local NLEV = rockmech.RUBBLE_LEVELS

local rubble_cid, c_air
local function build_maps()
	if rubble_cid then return end
	rubble_cid = {}
	for _, n in ipairs(rockmech.rubble_nodes) do rubble_cid[core.get_content_id(n)] = n end
	c_air = core.get_content_id("air")
end

local NB26 = {}
for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
	if dx ~= 0 or dy ~= 0 or dz ~= 0 then NB26[#NB26 + 1] = {dx, dy, dz} end
end end end
local NB6 = {{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1}}

local function key(x, y, z) return x .. "," .. y .. "," .. z end

-- 要清除的格子：3×3×3。n = 指入方向（under − above）
local function cube_cells(under, n)
	local c = vector.add(under, n)
	local cells = {}
	for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
		cells[#cells + 1] = {x = c.x + dx, y = c.y + dy, z = c.z + dz}
	end end end
	return cells, vector.subtract(c, 2), vector.add(c, 2)
end

-- 從 starts（一格或多格）出發的相連碎石（直接查 node；上限 MAX_FLOOD）
local function flood_cells(starts)
	if starts.x then starts = {starts} end
	local cells, seen, stack = {}, {}, {}
	for _, s in ipairs(starts) do
		seen[key(s.x, s.y, s.z)] = true
		stack[#stack + 1] = s
	end
	local capped = false
	while #stack > 0 do
		local p = table.remove(stack)
		cells[#cells + 1] = p
		if #cells >= MAX_FLOOD then capped = true; break end
		for _, d in ipairs(NB26) do
			local q = {x = p.x + d[1], y = p.y + d[2], z = p.z + d[3]}
			local k = key(q.x, q.y, q.z)
			if not seen[k] then
				seen[k] = true
				local nn = core.get_node_or_nil(q)
				if nn and rockmech.is_rubble(nn.name) then stack[#stack + 1] = q end
			end
		end
	end
	local a = {x = math.huge, y = math.huge, z = math.huge}
	local b = {x = -math.huge, y = -math.huge, z = -math.huge}
	for _, p in ipairs(cells) do
		for _, k in ipairs({"x", "y", "z"}) do
			a[k] = math.min(a[k], p[k]); b[k] = math.max(b[k], p[k])
		end
	end
	return cells, vector.subtract(a, 1), vector.add(b, 1), capped
end

-- 移除 cells 中的碎石（p1..p2 需涵蓋 cells 與其鄰格）。回傳移除數與各種碎石的級數
-- any = true：碎石以外的方塊也移除（挖洞魔杖；不可挖的方塊除外）
local function clear(cells, p1, p2, pname, any)
	build_maps()
	local vm = core.get_voxel_manip()
	local e1, e2 = vm:read_from_map(p1, p2)
	local area = VoxelArea(e1, e2)
	local data = vm:get_data()

	local removed, changes, levels = {}, {}, {}
	local gone = {}
	for _, p in ipairs(cells) do
		local vi = area:index(p.x, p.y, p.z)
		local name = rubble_cid[data[vi]]
		local is_rubble = name ~= nil
		if not name and any and data[vi] ~= c_air then
			local nn = core.get_name_from_content_id(data[vi])
			local def = core.registered_nodes[nn]
			if def and nn ~= "ignore" and def.diggable ~= false and not (def.groups and (def.groups.unbreakable or def.groups.shotcrete_hole)) then
				name = nn
			end
		end
		if name and not core.is_protected(p, pname) then
			data[vi] = c_air
			removed[#removed + 1] = p
			changes[#changes + 1] = {pos = p, name = name}
			gone[key(p.x, p.y, p.z)] = true
			if is_rubble then
				local base = rockmech.rubble_base[name] or name
				levels[base] = (levels[base] or 0) + (rockmech.rubble_level[name] or NLEV)
			end
		end
	end
	if #removed == 0 then vm:close(); return 0, levels end
	vm:set_data(data)
	vm:write_to_map(true)
	if rockmech.jointmesh then rockmech.jointmesh.dirty_box(p1, p2) end
	for _, p in ipairs(removed) do rockmech.shotcrete_uncover(p) end

	-- 鄰格：緊貼岩石（或其他實心非碎石）的移除點 → 穩定判定與破壞檢查；
	-- 沒被清掉的鄰近碎石 → 重新判定掉落／顆粒流
	local touch, rest, rest_seen = {}, {}, {}
	for i, p in ipairs(removed) do
		local rock = false
		for _, d in ipairs(NB6) do
			local x, y, z = p.x + d[1], p.y + d[2], p.z + d[3]
			local cid = data[area:index(x, y, z)]
			if rubble_cid[cid] then
				local k = key(x, y, z)
				if not gone[k] and not rest_seen[k] then
					rest_seen[k] = true
					rest[#rest + 1] = {x = x, y = y, z = z}
				end
			elseif cid ~= c_air then
				local def = core.registered_nodes[core.get_name_from_content_id(cid)]
				if def and def.walkable ~= false then rock = true end
			end
		end
		if rock then touch[#touch + 1] = changes[i] end
	end
	vm:close()

	local col = rockmech.collapse
	col.record_changes(changes)
	-- 破壞檢查的盒子：緊貼岩石的移除點每 3 m 取一個代表點（盒子半徑 6 m，彼此重疊）
	local picked = {}
	for _, c in ipairs(touch) do
		local p = c.pos
		col.queue_stability_check(p, c.name)
		local k = key(math.floor(p.x / 3), math.floor(p.y / 3), math.floor(p.z / 3))
		if not picked[k] then
			picked[k] = true
			col.queue_failure_check(p, c.name)
		end
	end
	table.sort(rest, function(u, v) return u.y < v.y end)
	core.after(0.1, function()
		for _, p in ipairs(rest) do col.check_cell(p) end
	end)

	-- 視覺與聲音：最多 12 處碎屑
	local step = math.max(1, math.floor(#removed / 12))
	for i = 1, #removed, step do
		local p = removed[i]
		col.debris(p, changes[i].name, 4)
	end
	local snd = core.registered_nodes[rockmech.RUBBLE].sounds
	if snd and snd.dug then core.sound_play(snd.dug, {pos = removed[1], max_hear_distance = 16}, true) end
	return #removed, levels
end

-- 收進物品欄：每 8 級 = 1 個；放不下的丟在玩家腳邊
local function collect(player, levels)
	local inv = player:get_inventory()
	local parts = {}
	for base, lv in pairs(levels) do
		local n = math.floor(lv / NLEV + 0.5)
		if n > 0 then
			local left = inv:add_item("main", ItemStack(base .. " " .. n))
			local dropped = left:get_count()
			if dropped > 0 then core.add_item(player:get_pos(), left) end
			local desc = rockmech.desc_short(base)
			parts[#parts + 1] = dropped > 0
				and S("@1 ×@2 (@3 didn't fit, dropped at your feet)", desc, tostring(n), tostring(dropped))
				or S("@1 ×@2", desc, tostring(n))
		end
	end
	return table.concat(parts, ", ")
end

-- flood = "near"：從指到的格子附近 ±2 格內的所有碎石出發
local function use(player, pointed_thing, flood, tag)
	if not player or not player:is_player() or pointed_thing.type ~= "node" then return end
	tag = tag or S("Rubble wand")
	local pname = player:get_player_name()
	local under = pointed_thing.under
	local cells, p1, p2, capped
	if flood == "near" then
		local starts = core.find_nodes_in_area(vector.subtract(under, 2), vector.add(under, 2),
			{"group:rockmech_rubble"})
		if #starts == 0 then
			rockmech.notify(pname, S("[@1] No rubble within 2 blocks", tag))
			return
		end
		cells, p1, p2, capped = flood_cells(starts)
	elseif flood then
		if not rockmech.is_rubble(core.get_node(under).name) then
			rockmech.notify(pname, S("[Rubble wand] Right-click must point at rubble"))
			return
		end
		cells, p1, p2, capped = flood_cells(under)
	else
		local n = vector.subtract(under, pointed_thing.above)
		cells, p1, p2 = cube_cells(under, n)
	end
	local t0 = core.get_us_time()
	local count, levels = clear(cells, p1, p2, pname)
	if count == 0 then return end
	local msg = capped
		and S("[@1] Cleared @2 rubble blocks (limit of @3 reached, click again for the rest)", tag, tostring(count), tostring(MAX_FLOOD))
		or S("[@1] Cleared @2 rubble blocks", tag, tostring(count))
	if player:get_player_control().sneak then
		local got = collect(player, levels)
		if got ~= "" then msg = S("@1, collected into inventory: @2", msg, got) end
	end
	rockmech.notify(pname, msg)
	core.log("action", ("[rockmech] %s 清碴 %s %s：%d 格（%.1f ms）"):format(pname,
		flood and "相連" or "3×3×3", core.pos_to_string(under), count,
		(core.get_us_time() - t0) / 1000))
end

core.register_tool("rockmech:rubble_wand", {
	description = S("Rubble wand\nLeft-click: clear 3×3×3 rubble in front of you\nRight-click: clear all connected rubble\nHold Shift: put the cleared rubble into your inventory"),
	short_description = S("Rubble wand"),
	inventory_image = "[fill:16x16:#00000000^[fill:2x2:13,1:#ffffff" ..
		"^[fill:4x4:11,1:#b070ff^[fill:2x2:12,2:#ffffff" ..
		"^[fill:2x2:9,5:#8b5a2b^[fill:2x2:7,7:#8b5a2b^[fill:2x2:5,9:#8b5a2b" ..
		"^[fill:2x2:3,11:#8b5a2b^[fill:2x2:1,13:#6b4020",
	stack_max = 1,
	on_use = function(itemstack, user, pointed_thing)
		use(user, pointed_thing, false)
		return nil
	end,
	on_place = function(itemstack, placer, pointed_thing)
		use(placer, pointed_thing, true)
		return nil
	end,
})

-- 爆破魔杖：左鍵引爆（同原版 TNT），右鍵一鍵清碴
local function blast_at(player, pointed_thing)
	if not player or not player:is_player() or pointed_thing.type ~= "node" then return end
	if not (tnt and tnt.boom) then
		rockmech.notify(player:get_player_name(), S("[Blast wand] The tnt mod is not loaded"))
		return
	end
	-- 炸藥放在岩面前那一格（同把 TNT 放在岩面上點燃）；explode_center：該格算一個 TNT
	local pos = pointed_thing.above
	local r = tonumber(core.settings:get("tnt_radius") or 3) or 3
	tnt.boom(pos, {radius = r, damage_radius = r * 2, explode_center = true})
	core.log("action", ("[rockmech] %s 爆破魔杖 %s R=%d"):format(player:get_player_name(),
		core.pos_to_string(pos), r))
end

core.register_tool("rockmech:blast_wand", {
	description = S("Blast wand\nLeft-click: detonate TNT (rock breaks according to its strength)\nRight-click: one-click mucking (nearby and connected rubble)\nShift + right-click: put the cleared rubble into your inventory"),
	short_description = S("Blast wand"),
	inventory_image = "[fill:16x16:#00000000^[fill:2x2:13,1:#fff3a0" ..
		"^[fill:4x4:11,1:#ff5020^[fill:2x2:12,2:#ffe060" ..
		"^[fill:2x2:9,5:#5a3a2a^[fill:2x2:7,7:#5a3a2a^[fill:2x2:5,9:#5a3a2a" ..
		"^[fill:2x2:3,11:#5a3a2a^[fill:2x2:1,13:#3a2418",
	stack_max = 1,
	on_use = function(itemstack, user, pointed_thing)
		blast_at(user, pointed_thing)
		return nil
	end,
	on_place = function(itemstack, placer, pointed_thing)
		use(placer, pointed_thing, "near", S("Blast wand"))
		return nil
	end,
})

-- 挖洞魔杖：左鍵直接移除以指到的格為中心的 3×3×3（任何可挖的方塊，算玩家開挖：記錄開挖、觸發破壞與穩定判定），
-- 右鍵一鍵清碴（同爆破魔杖）
core.register_tool("rockmech:dig_wand", {
	description = S("Dig wand\nLeft-click: remove the 3×3×3 centered on the pointed block (rock, rubble, etc.)\nRight-click: one-click mucking (nearby and connected rubble)\nShift + right-click: put the cleared rubble into your inventory"),
	short_description = S("Dig wand"),
	inventory_image = "[fill:16x16:#00000000^[fill:2x2:13,1:#e0fff0" ..
		"^[fill:4x4:11,1:#20c070^[fill:2x2:12,2:#e0fff0" ..
		"^[fill:2x2:9,5:#707070^[fill:2x2:7,7:#707070^[fill:2x2:5,9:#707070" ..
		"^[fill:2x2:3,11:#707070^[fill:2x2:1,13:#505050",
	stack_max = 1,
	on_use = function(itemstack, user, pointed_thing)
		if not user or not user:is_player() or pointed_thing.type ~= "node" then return nil end
		local under = pointed_thing.under
		-- 以指到的那一格為中心的 3×3×3（cube_cells 的中心 = under + 0）
		local cells, p1, p2 = cube_cells(under, {x = 0, y = 0, z = 0})
		local t0 = core.get_us_time()
		local count = clear(cells, p1, p2, user:get_player_name(), true)
		if count > 0 then
			core.log("action", ("[rockmech] %s 挖洞魔杖 %s：移除 %d 格（%.1f ms）"):format(user:get_player_name(),
				core.pos_to_string(under), count, (core.get_us_time() - t0) / 1000))
		end
		return nil
	end,
	on_place = function(itemstack, placer, pointed_thing)
		use(placer, pointed_thing, "near", S("Dig wand"))
		return nil
	end,
})
