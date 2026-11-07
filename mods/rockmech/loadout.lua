-- rockmech/loadout.lua
-- 裝車料斗（loadout bin）：3×3 的料倉塔，頂上一層格柵，側邊高處一支會轉的放料臂（同選礦場）。
--   進料：落在頂上格柵的碎石（輸送帶頭倒下來的、卡車怪手倒上去的）每一步吃進倉裡，倉滿就不吃，料堆在格柵上、
--         輸送帶前面堵住就停（conveyor.lua 的規則）。
--   出料：有斗的車（卡車、礦卡）停在放料臂 rockmech_plant_reach m 內不動，放料臂轉過去裝，每秒 LOAD_RATE m³。
--   無人卡車：裝載點設在放料臂附近，就在那裡等著裝（跟選礦場的放料臂同一套，vehicle_ahs.lua 透過
--         rockmech.plant_chute_near／plant_chute_state 找到它）。輸送帶 → 料斗 → 無人卡車 → 破碎站可以整條自動跑。
--   倉裡的料照種類分開記（礦石碎石記品位），裝車時先放最多的那一種。
--   用施工單蓋（機械設備課長，delivery.lua），整組共用；挖掉控制箱就拆掉整座（倉裡的料沒了）。

local cfg = rockmech.cfg
local V = rockmech.vehicles
local NLEV = V.NLEV
local storage = rockmech.collapse.storage

local ITEM = "rockmech:loadout"                 -- 物品，也是控制箱（塔最下面中央那一格）
local WALL, WALL_FULL = "rockmech:loadout_wall", "rockmech:loadout_wall_full"
local GRATE = "rockmech:loadout_grate"
local CHUTE = "rockmech:loadout_chute"
local BOOM = "rockmech:plant_boom"             -- 放料臂的樣子跟選礦場共用
local BIN_H = 4                                -- 塔高 (m)，頂上再一層格柵
local CAP = 36                                 -- 容量 (m³)
local LOAD_RATE = 4                            -- 放料 (m³/s)
local STEP = 1
local STALL_T = 10                             -- 這麼久沒進料、倉也空了：在臂下等的無人卡車半車以上就先走
local BOOM_REST = 3

local function tell(name, msg) if name then core.chat_send_player(name, "[裝車料斗] " .. msg) end end

-- 料斗的格子（控制箱在 pos，放料臂朝 (dx, dz)）
local function parts(pos, dx, dz)
	return {
		chute = {x = pos.x + dx * 2, y = pos.y + BIN_H - 1, z = pos.z + dz * 2},
		top = pos.y + BIN_H,                   -- 格柵那一層
	}
end

-- 倉裡的料：meta "bin" = {[碎石種類] = {lv = 級, q = Σ 級 × 品位}}
local function bin_of(meta) return core.deserialize(meta:get_string("bin")) or {} end
local function total(bin)
	local n = 0
	for _, v in pairs(bin) do n = n + v.lv end
	return n
end

-- 放料臂（實體，不存檔，每一步補上、擺到位）
local booms = {}
local function place_boom(key, pivot, tip)
	local o = booms[key]
	if not (o and o:get_pos()) then
		o = core.add_entity(pivot, BOOM)
		booms[key] = o
		if not o then return end
	end
	local d = vector.subtract(tip, pivot)
	o:set_pos(vector.add(pivot, vector.multiply(d, 0.5)))
	o:set_properties({visual_size = {x = 0.45, y = 0.45, z = math.max(0.5, vector.length(d))}})
	o:set_rotation(vector.dir_to_rotation(d))
end
-- 放料臂搆得到、停著不動、還裝得下的車（最近的那台）：回傳 車, 車斗上離轉軸最近的那一點
local function truck_in_reach(pivot)
	local best, bp, bd
	for _, o in ipairs(core.get_objects_inside_radius(pivot, cfg.plant_reach + 8)) do
		local e = o:get_luaentity()
		local td = e and e.vkind and V.TYPES[e.vkind]
		if td and td.bed and not td.pushed and (td.cap or 0) > V.load_total(e) and not e.tip
				and vector.length(o:get_velocity()) < 0.3 then
			local bt = V.bed_target(e, pivot)
			local d = math.sqrt((bt.x - pivot.x) ^ 2 + (bt.z - pivot.z) ^ 2)
			if d <= cfg.plant_reach and bt.y < pivot.y + 0.5 and (not bd or d < bd) then best, bp, bd = e, bt, d end
		end
	end
	return best, bp
end

-- 塔身顯示存量：BIN_H 層，下面幾層換成「有料」的牆
local function show_fill(pos, n)
	local k = math.ceil(n / (CAP * NLEV) * BIN_H - 1e-9)
	for i = 0, BIN_H - 1 do
		local want = i < k and WALL_FULL or WALL
		for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do
			local p = {x = x, y = pos.y + i, z = z}
			local nm = core.get_node(p).name
			if (nm == WALL or nm == WALL_FULL) and nm ~= want then core.swap_node(p, {name = want}) end
		end end
	end
end

local function info(pos, meta, bin)
	local n = total(bin)
	local lines = {("裝車料斗（%s）"):format(rockmech.account_label and rockmech.account_label(meta:get_string("owner")) or meta:get_string("owner")),
		("存量 %.1f / %d m³（%.0f t）"):format(n / NLEV, CAP, rockmech.hopper_lib.tons_of(n))}
	for base, v in pairs(bin) do
		if v.lv >= 1 then
			local ore = rockmech.ore_of_rubble[base]
			local d = core.registered_nodes[base]
			lines[#lines + 1] = ("・%s %.1f m³%s"):format(d and d.description:gsub("\n.*", "") or base, v.lv / NLEV,
				rockmech.mix_of[base] and ("（%s）"):format(rockmech.mix_text(base, v.q / v.lv)) or "")
		end
	end
	lines[#lines + 1] = ("卡車或礦卡停在放料臂 %g m 內不動就裝；頂上的格柵接輸送帶"):format(cfg.plant_reach)
	meta:set_string("infotext", table.concat(lines, "\n"))
end

local function step(pos, dtime)
	local meta = core.get_meta(pos)
	local bin = bin_of(meta)
	local n = total(bin)
	local dx, dz = meta:get_int("dx"), meta:get_int("dz")
	local P = parts(pos, dx, dz)
	-- 1. 進料：格柵上面（往上 3 格）的碎石，倉放得下就吃
	local room = CAP * NLEV - n
	local inflow = 0
	if room >= 1 then
		for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do
			for y = P.top + 3, P.top + 1, -1 do
				if room < 1 then break end
				local p = {x = x, y = y, z = z}
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
		end end
	end
	if inflow > 0 then
		meta:set_float("last_in", core.get_gametime() or 0)
		rockmech.collapse.rubble_sound({x = pos.x, y = P.top, z = pos.z}, inflow)
	end
	-- 2. 出料：放料臂搆得到的車（先放最多的那一種）
	local key = core.pos_to_string(pos)
	local e, bt = truck_in_reach(P.chute)
	local tip = e and {x = bt.x, y = bt.y + 0.4, z = bt.z}
	place_boom(key, P.chute, tip or {x = P.chute.x + dx * BOOM_REST, y = P.chute.y - 0.8, z = P.chute.z + dz * BOOM_REST})
	if e and total(bin) >= 1 then
		local best, bl
		for base, v in pairs(bin) do if v.lv >= 1 and (not bl or v.lv > bl) then best, bl = base, v.lv end end
		if best then
			local v = bin[best]
			local per = math.max(1, math.floor(LOAD_RATE * NLEV * dtime))
			local k = math.min(math.floor(v.lv), per, V.TYPES[e.vkind].cap - V.load_total(e))
			if k > 0 then
				local g = v.q / v.lv
				V.load_put(e, best, k, math.floor(g + 0.5))
				if V.update_hud then V.update_hud(e) end
				v.lv, v.q = v.lv - k, v.q - k * g
				if v.lv < 1e-6 then bin[best] = nil end
				rockmech.collapse.rubble_sound(tip, k)
				core.add_particlespawner({amount = 12, time = math.max(0.2, dtime), glow = 3,
					pos = {min = vector.subtract(tip, {x = 0.3, y = 0.3, z = 0.3}), max = vector.add(tip, {x = 0.3, y = 0, z = 0.3})},
					vel = {min = {x = -0.2, y = -6, z = -0.2}, max = {x = 0.2, y = -4, z = 0.2}}, exptime = 0.5, size = 3,
					texture = "default_gravel.png^[colorize:#5a5048:120"})
			end
		end
	end
	meta:set_string("bin", core.serialize(bin))
	show_fill(pos, total(bin))
	info(pos, meta, bin)
end

-- 無人駕駛（vehicle_ahs.lua）：跟選礦場的放料臂同一套介面
do
	local near, state = rockmech.plant_chute_near, rockmech.plant_chute_state
	function rockmech.plant_chute_near(p, r)
		local a = near and near(p, r)
		local c = core.find_node_near(p, r, CHUTE, true)
		if c and (not a or vector.distance(c, p) < vector.distance(a, p)) then
			local cm = core.get_meta(c)
			return {x = c.x, y = c.y, z = c.z, u = {x = cm:get_float("ux"), z = cm:get_float("uz")}}
		end
		return a
	end
	function rockmech.plant_chute_state(c)
		if core.get_node(c).name ~= CHUTE then return state and state(c) end
		local pos = core.string_to_pos(core.get_meta(c):get_string("loadout"))
		if not pos or core.get_node(pos).name ~= ITEM then return nil end
		local meta = core.get_meta(pos)
		local idle = (core.get_gametime() or 0) - meta:get_float("last_in") >= STALL_T
		return {lv = total(bin_of(meta)), stalled = idle}
	end
end

-- 蓋：控制箱在 pos（地面上一格），放料臂朝 (dx, dz)
local function site_ok(pos, dx, dz)
	local function solid(p) return not V.passable(core.get_node(p).name) end
	for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do
		if not solid({x = x, y = pos.y - 1, z = z}) then return false end
		for y = pos.y, pos.y + BIN_H + 1 do
			if solid({x = x, y = y, z = z}) then return false end
		end
	end end
	return not solid(parts(pos, dx, dz).chute)
end
local function build(pos, dx, dz, owner)
	local P = parts(pos, dx, dz)
	for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do
		for y = pos.y, pos.y + BIN_H - 1 do
			if not (x == pos.x and y == pos.y and z == pos.z) then core.set_node({x = x, y = y, z = z}, {name = WALL}) end
		end
		core.set_node({x = x, y = P.top, z = z}, {name = GRATE})
	end end
	core.set_node(pos, {name = ITEM})
	core.set_node(P.chute, {name = CHUTE})
	local cm = core.get_meta(P.chute)
	cm:set_string("loadout", core.pos_to_string(pos))
	cm:set_float("ux", dx)
	cm:set_float("uz", dz)
	cm:set_string("infotext", ("裝車料斗的放料臂：卡車停在 %g m 內就裝"):format(cfg.plant_reach))
	local meta = core.get_meta(pos)
	meta:set_string("owner", owner)
	meta:set_int("dx", dx)
	meta:set_int("dz", dz)
	-- 區塊一直載入（人走遠了輸送帶、料斗、無人卡車照常跑）；一座一次，拆掉時放掉
	local bp = {x = math.floor(pos.x / 16) * 16, y = math.floor(pos.y / 16) * 16, z = math.floor(pos.z / 16) * 16}
	core.forceload_block(bp, false, -1)
	meta:set_int("forceload", 1)
	core.get_node_timer(pos):start(STEP)
	step(pos, 0)
end
local function remove(pos)
	local meta = core.get_meta(pos)
	local dx, dz = meta:get_int("dx"), meta:get_int("dz")
	local P = parts(pos, dx, dz)
	for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do
		for y = pos.y, P.top do
			local p = {x = x, y = y, z = z}
			local nm = core.get_node(p).name
			if nm == WALL or nm == WALL_FULL or nm == GRATE then core.remove_node(p) end
		end
	end end
	if core.get_node(P.chute).name == CHUTE then core.remove_node(P.chute) end
	local o = booms[core.pos_to_string(pos)]
	if o and o:get_pos() then o:remove() end
	if meta:get_int("forceload") == 1 then
		core.forceload_free_block({x = math.floor(pos.x / 16) * 16, y = math.floor(pos.y / 16) * 16, z = math.floor(pos.z / 16) * 16}, false)
	end
end

local STEEL = "[fill:16x16:#8a8e92^[fill:16x1:0,0:#5a5e62^[fill:1x16:0,0:#5a5e62^[fill:16x2:0,7:#c8a020"
local FULL = "[fill:16x16:#4a4440^[fill:16x1:0,0:#5a5e62^[fill:1x16:0,0:#5a5e62^[fill:16x2:0,7:#c8a020"
for _, w in ipairs({{WALL, STEEL, "裝車料斗"}, {WALL_FULL, FULL, "裝車料斗（有料）"}}) do
	core.register_node(w[1], {
		description = w[3], tiles = {w[2]}, is_ground_content = false, diggable = false, drop = "",
		groups = {not_in_creative_inventory = 1},
	})
end
core.register_node(GRATE, {
	description = "裝車料斗格柵",
	tiles = {"[fill:16x16:#181818^[fill:16x3:0,1:#8a8a8a^[fill:16x3:0,9:#8a8a8a^[fill:3x16:1,0:#8a8a8a^[fill:3x16:9,0:#8a8a8a", STEEL},
	is_ground_content = false, diggable = false, drop = "", groups = {not_in_creative_inventory = 1},
})
core.register_node(CHUTE, {
	description = "裝車料斗放料口",
	drawtype = "nodebox", paramtype = "light",
	node_box = {type = "fixed", fixed = {{-0.5, 0, -0.5, 0.5, 0.5, 0.5}, {-0.3, -0.5, -0.3, 0.3, 0, 0.3}}},
	tiles = {"[fill:16x16:#404040^[fill:16x2:0,7:#c0a020"},
	groups = {not_in_creative_inventory = 1}, diggable = false, is_ground_content = false, drop = "",
})

local editing = {}
core.register_node(ITEM, {
	description = ("裝車料斗 Loadout bin\n%d m³ 的料倉，頂上格柵接輸送帶（或卡車、怪手倒上去），放料臂裝 %g m 內停著的卡車、礦卡\n"
		.. "無人卡車的裝載點設在放料臂附近就會在那裡等著裝\n對著平地按右鍵蓋：3×3 m、高 %d m，放料臂朝自己這邊"):format(CAP, cfg.plant_reach, BIN_H + 1),
	tiles = {STEEL, STEEL, STEEL .. "^[fill:6x6:5,5:#303030^[fill:4x2:6,6:#40c040"},
	inventory_image = "[fill:16x16:#00000000^[fill:10x8:3,2:#8a8e92^[fill:10x1:3,5:#c8a020^[fill:2x6:3,10:#5a5e62^[fill:2x6:11,10:#5a5e62^[fill:3x3:12,7:#404040",
	is_ground_content = false, groups = {cracky = 2},
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" or not placer then return itemstack end
		local name = placer:get_player_name()
		local pos = pointed.above
		local look = placer:get_look_dir()
		local dx, dz = 0, 0
		if math.abs(look.x) > math.abs(look.z) then dx = look.x > 0 and -1 or 1 else dz = look.z > 0 and -1 or 1 end
		if rockmech.clear_site then
			pos = vector.copy(pos)
			local sc = {}
			for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do sc[#sc + 1] = {x, z} end end
			rockmech.clear_site(sc, pos)
		end
		if not site_ok(pos, dx, dz) then
			tell(name, ("要蓋在平地上：3×3 m 地面平坦、上方 %d m 淨空"):format(BIN_H + 2))
			return itemstack
		end
		local cells = {}
		for x = pos.x - 1, pos.x + 1 do for z = pos.z - 1, pos.z + 1 do cells[#cells + 1] = {x, z} end end
		local who = rockmech.cells_blocked and rockmech.cells_blocked(cells, pos.y - 1, pos.y + BIN_H, placer)
		if who then tell(name, ("施工範圍裡有%s：先移開"):format(who)); return itemstack end
		build(pos, dx, dz, rockmech.account_of and rockmech.account_of(name) or name)
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	can_dig = function(pos, player)
		return player and (not rockmech.owner_ok or rockmech.owner_ok(core.get_meta(pos):get_string("owner"), player:get_player_name()))
	end,
	on_destruct = function(pos) remove(pos) end,
	on_timer = function(pos, elapsed)
		step(pos, math.min(elapsed, 5 * STEP))
		return true
	end,
})
-- 計時器停了（例如區塊沒存到）就重新啟動
core.register_abm({
	label = "rockmech: 裝車料斗計時器", nodenames = {ITEM}, interval = 5, chance = 1,
	action = function(pos)
		local t = core.get_node_timer(pos)
		if not t:is_started() then t:start(STEP) end
	end,
})
