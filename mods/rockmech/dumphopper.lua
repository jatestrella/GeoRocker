-- rockmech/dumphopper.lua
-- 受料斗（dump hopper）：裝車料斗反過來用。4×4、高 2 m 的鋼斗，頂上是格柵。
--   進料：卡車、怪手在格柵 SNAP m 內倒料，自動對準倒在格柵上（vehicles.lua 的 V.dump_to_ground 問 rockmech.dump_hopper_cells），
--         格柵上的碎石每一步吃進斗裡，斗滿了就堆在格柵上等。
--   出料：放的時候面對的那一邊、中間那格是出料口；那裡接一條輸送帶的起點，斗裡的料照輸送帶的運量放上去
--         （先放最多的那一種，礦石碎石保留品位）。
--   放的人（分了組就是整組）擁有；挖控制箱拆掉整座，斗裡的料沒了。

local S = rockmech.S
local V = rockmech.vehicles
local NLEV = V.NLEV

local ITEM = "rockmech:dump_hopper"                -- 物品，也是控制箱（底層的一格）
local WALL, GRATE = "rockmech:dump_hopper_wall", "rockmech:dump_hopper_grate"
local CAP = 24                                     -- 容量 (m³)
local OUT_RATE = 4                                 -- 出料口每秒最多放幾 m³（實際受輸送帶運量限制）
local SNAP = 3                                     -- 倒料點離格柵多近（水平 m）就自動對準
local STEP = 1

local function tell(name, msg) if name then rockmech.notify(name, S("[Dump hopper]") .. " " .. msg) end end

-- 4×4 的範圍：控制箱 pos 在 (0, 0)，往 −1..+2 延伸；出料方向 (dx, dz)
local function cells_of(pos)
	local c = {}
	for x = pos.x - 1, pos.x + 2 do for z = pos.z - 1, pos.z + 2 do c[#c + 1] = {x = x, z = z} end end
	return c
end
local function outlet(pos, dx, dz)
	local x = dx > 0 and pos.x + 3 or dx < 0 and pos.x - 2 or pos.x
	local z = dz > 0 and pos.z + 3 or dz < 0 and pos.z - 2 or pos.z
	return {x = x, y = pos.y, z = z}
end

local function bin_of(meta) return core.deserialize(meta:get_string("bin")) or {} end
local function total(bin)
	local n = 0
	for _, v in pairs(bin) do n = n + v.lv end
	return n
end

local function info(meta, bin)
	local owner = meta:get_string("owner")
	meta:set_string("infotext", S("Dump hopper (@1)", rockmech.account_label and rockmech.account_label(owner) or owner) .. "\n"
		.. S("Stock @1 / @2 m³", ("%.1f"):format(total(bin) / NLEV), tostring(CAP)))
end

local function is_belt(p) return core.get_node(p).name:find("^rockmech:belt_%d") ~= nil end

local function step(pos)
	local meta = core.get_meta(pos)
	local bin = bin_of(meta)
	local top = pos.y + 1                       -- 格柵那一層
	-- 1. 進料：格柵上面（往上 3 格）的碎石
	local room = CAP * NLEV - total(bin)
	local inflow = 0
	for _, c in ipairs(cells_of(pos)) do
		for y = top + 3, top + 1, -1 do
			if room < 1 then break end
			local p = {x = c.x, y = y, z = c.z}
			if rockmech.rubble_level[core.get_node(p).name] then
				local t, base, p2 = V.take_rubble(p, math.floor(room))
				if t > 0 then
					local v = bin[base] or {lv = 0, q = 0}
					v.lv, v.q = v.lv + t, v.q + t * (rockmech.mix_of[base] and p2 or 0)
					bin[base] = v
					room, inflow = room - t, inflow + t
				end
			end
		end
	end
	if inflow > 0 then rockmech.collapse.rubble_sound({x = pos.x + 0.5, y = top, z = pos.z + 0.5}, inflow) end
	-- 2. 出料：出料口有輸送帶就放上去
	local out = outlet(pos, meta:get_int("dx"), meta:get_int("dz"))
	if is_belt(out) and rockmech.belt_put then
		local best, bl
		for base, v in pairs(bin) do if v.lv >= 1 and (not bl or v.lv > bl) then best, bl = base, v.lv end end
		if best then
			local v = bin[best]
			local g = v.q / v.lv
			local k = math.min(math.floor(v.lv), math.max(1, math.floor(OUT_RATE * NLEV * STEP)))
			local put = rockmech.belt_put(out, best, k, math.floor(g + 0.5))
			if put > 0 then
				v.lv, v.q = v.lv - put, v.q - put * g
				if v.lv < 1e-6 then bin[best] = nil end
			end
		end
	end
	meta:set_string("bin", core.serialize(bin))
	info(meta, bin)
end

-- 自動對準（V.dump_to_ground）：倒料的那幾欄中心離格柵 SNAP m 內，改倒在格柵上
function rockmech.dump_hopper_cells(cells, ytop)
	if not cells or #cells == 0 then return nil end
	local cx, cz = 0, 0
	for _, c in ipairs(cells) do cx, cz = cx + c.x, cz + c.z end
	cx, cz = cx / #cells, cz / #cells
	local cy = ytop - 1
	local found = core.find_nodes_in_area({x = cx - SNAP - 1, y = cy - 4, z = cz - SNAP - 1},
		{x = cx + SNAP + 1, y = cy + 4, z = cz + SNAP + 1}, {GRATE})
	local best, bd
	for _, g in ipairs(found) do
		local d = math.max(math.abs(g.x - cx), math.abs(g.z - cz))
		if d <= SNAP and (not bd or d < bd) then best, bd = g, d end
	end
	if not best then return nil end
	local pos = core.string_to_pos(core.get_meta(best):get_string("hopper"))
	if not pos or core.get_node(pos).name ~= ITEM then return nil end
	local out = {}
	for _, c in ipairs(cells_of(pos)) do out[#out + 1] = {x = c.x, y = pos.y + 1, z = c.z} end
	return out, pos.y + 2, pos
end

-- 對準了：車上的料直接進斗（倒在格柵上會從邊上流掉），放不下的才堆在格柵上
function rockmech.dump_hopper_accept(pos, e)
	local meta = core.get_meta(pos)
	local bin = bin_of(meta)
	local room = math.floor(CAP * NLEV - total(bin))
	local took = 0
	for base, lv in pairs(e.load or {}) do
		if room < 1 then break end
		if rockmech.rubble_level and base ~= "default:tree" then
			local k = math.min(lv, room)
			local g = V.load_grade(e, base) or 0
			local v = bin[base] or {lv = 0, q = 0}
			v.lv, v.q = v.lv + k, v.q + k * (rockmech.mix_of[base] and g or 0)
			bin[base] = v
			V.load_keep(e, base, lv - k)
			room, took = room - k, took + k
		end
	end
	if took > 0 then
		meta:set_string("bin", core.serialize(bin))
		info(meta, bin)
		rockmech.collapse.rubble_sound({x = pos.x + 0.5, y = pos.y + 1, z = pos.z + 0.5}, took)
	end
	return took
end

local function site_ok(pos)
	local function solid(p) return not V.passable(core.get_node(p).name) end
	for _, c in ipairs(cells_of(pos)) do
		if not solid({x = c.x, y = pos.y - 1, z = c.z}) then return false end
		for y = pos.y, pos.y + 3 do if solid({x = c.x, y = y, z = c.z}) then return false end end
	end
	return true
end

local function build(pos, dx, dz, owner)
	local ps = core.pos_to_string(pos)
	for _, c in ipairs(cells_of(pos)) do
		if not (c.x == pos.x and c.z == pos.z) then core.set_node({x = c.x, y = pos.y, z = c.z}, {name = WALL}) end
		local g = {x = c.x, y = pos.y + 1, z = c.z}
		core.set_node(g, {name = GRATE})
		core.get_meta(g):set_string("hopper", ps)
	end
	core.set_node(pos, {name = ITEM})
	local meta = core.get_meta(pos)
	meta:set_string("owner", owner)
	meta:set_int("dx", dx)
	meta:set_int("dz", dz)
	core.get_node_timer(pos):start(STEP)
	step(pos)
end
rockmech.dump_hopper_build = build      -- 測試用
local function remove(pos)
	for _, c in ipairs(cells_of(pos)) do
		for y = pos.y, pos.y + 1 do
			local p = {x = c.x, y = y, z = c.z}
			local nm = core.get_node(p).name
			if nm == WALL or nm == GRATE then core.remove_node(p) end
		end
	end
end

local STEEL = "[fill:16x16:#7a7e82^[fill:16x1:0,0:#4a4e52^[fill:1x16:0,0:#4a4e52^[fill:16x2:0,11:#c8a020"
local GRID = "[fill:16x16:#181818^[fill:16x2:0,2:#8a8a8a^[fill:16x2:0,10:#8a8a8a^[fill:2x16:2,0:#8a8a8a^[fill:2x16:10,0:#8a8a8a"
core.register_node(WALL, {
	description = S("Dump hopper"), tiles = {STEEL}, is_ground_content = false, diggable = false, drop = "",
	groups = {not_in_creative_inventory = 1},
})
core.register_node(GRATE, {
	description = S("Dump hopper grate"), tiles = {GRID, STEEL, STEEL}, is_ground_content = false, diggable = false, drop = "",
	groups = {not_in_creative_inventory = 1},
})
core.register_node(ITEM, {
	description = S("Dump hopper"),
	tiles = {STEEL, STEEL, STEEL .. "^[fill:6x5:5,3:#303030^[fill:4x2:6,4:#40c040"},
	inventory_image = "[fill:16x16:#00000000^[fill:14x6:1,4:#7a7e82^[fill:14x2:1,4:#181818^[fill:2x2:3,4:#8a8a8a^[fill:2x2:7,4:#8a8a8a^[fill:2x2:11,4:#8a8a8a"
		.. "^[fill:14x1:1,8:#c8a020^[fill:4x3:12,11:#303030^[fill:3x1:13,14:#202020",
	is_ground_content = false, groups = {cracky = 2},
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local name = placer:get_player_name()
		local pos = vector.copy(pointed.above)
		local look = placer:get_look_dir()
		local dx, dz = 0, 0
		if math.abs(look.x) > math.abs(look.z) then dx = look.x > 0 and 1 or -1 else dz = look.z > 0 and 1 or -1 end
		if rockmech.clear_site then
			local sc = {}
			for _, c in ipairs(cells_of(pos)) do sc[#sc + 1] = {c.x, c.z} end
			rockmech.clear_site(sc, pos)
		end
		if not site_ok(pos) then
			tell(name, S("Build it on flat ground: 4×4 m of level ground"))
			return itemstack
		end
		local sc = {}
		for _, c in ipairs(cells_of(pos)) do sc[#sc + 1] = {c.x, c.z} end
		local who = rockmech.cells_blocked and rockmech.cells_blocked(sc, pos.y - 1, pos.y + 2, placer)
		if who then tell(name, S("There is @1 in the construction area: move it first", who)); return itemstack end
		build(pos, dx, dz, rockmech.account_of and rockmech.account_of(name) or name)
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	can_dig = function(pos, player)
		return player and (not rockmech.owner_ok or rockmech.owner_ok(core.get_meta(pos):get_string("owner"), player:get_player_name()))
	end,
	on_destruct = function(pos) remove(pos) end,
	on_timer = function(pos)
		step(pos)
		return true
	end,
})
core.register_abm({
	label = "rockmech: 受料斗計時器", nodenames = {ITEM}, interval = 5, chance = 1,
	action = function(pos)
		local t = core.get_node_timer(pos)
		if not t:is_started() then t:start(STEP) end
	end,
})
