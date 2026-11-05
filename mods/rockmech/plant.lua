-- rockmech/plant.lua
-- 選礦場（選煤廠，coal preparation plant）：放在平地上，朝玩家的方向挖一個和破碎站一樣的受料倉（crusher.lua 的
-- rockmech.hopper_lib），機身左右各一座 6 m 高的儲料塔：一座出精煤、一座出矸石。
-- 分選（重介質分選的分配曲線簡化成兩個數）：原料裡的煤有 rockmech_plant_recovery 進精煤，
-- 矸石有 rockmech_plant_misplaced 混進精煤，其餘進矸石。品位 30% 的原料 → 精煤約 80%、矸石約 2%。
-- 放料口只裝車（裝車倉的閘門）：有斗的車（卡車、礦卡）停好、車斗在放料口正下方才放料，不會倒在地上或旁邊的漏斗，
-- 所以就算蓋在破碎站、廢石場旁邊，還是要用卡車搬。兩座塔任何一座滿了就停止吃料。
-- 選礦場本身不收錢也不付錢：精煤載去破碎站賣，矸石載去廢石場（破碎站切換成廢石場）丟。

local cfg = rockmech.cfg
local V = rockmech.vehicles
local H = rockmech.hopper_lib
local NLEV = V.NLEV

local PLANT, CHUTE = "rockmech:plant", "rockmech:plant_chute"
local BIN = {p = "rockmech:plant_bin_p", r = "rockmech:plant_bin_r"}
local TOWER_H = 6           -- 塔高 (m)，放料口在塔頂外側
local TOWER_OFF = 4         -- 塔中心離機身中心（左右）
local SIDES = {{key = "p", s = 1, label = "精煤"}, {key = "r", s = -1, label = "矸石"}}

-- 選礦場的主要礦種（只有一種礦：煤）
local function main_ore()
	for _, ore in pairs(cfg.ores) do return ore end
end

-- 機身 pos、受料倉朝 d：side s 的塔中心、放料口位置與朝外的方向
local function layout(pos, dx, dz, s)
	local px, pz = -dz * s, dx * s
	local tc = {x = pos.x + px * TOWER_OFF, y = pos.y, z = pos.z + pz * TOWER_OFF}
	local chute = {x = tc.x + px * 2, y = pos.y + TOWER_H - 1, z = tc.z + pz * 2}
	return tc, chute, {x = px, z = pz}
end
local function bin_cap() return cfg.plant_bin * NLEV end

-- 放料口下面停好、車斗在正下方、還裝得下的車
local function truck_under(chute)
	local ground = {x = chute.x, y = chute.y - TOWER_H + 1, z = chute.z}
	for _, o in ipairs(core.get_objects_inside_radius(ground, 10)) do
		local e = o:get_luaentity()
		local td = e and e.vkind and V.TYPES[e.vkind]
		if td and td.bed and not td.pushed and (td.cap or 0) > V.load_total(e) and not e.tip
				and vector.length(o:get_velocity()) < 0.3 then
			local bt = V.bed_target(e, chute)
			if math.sqrt((bt.x - chute.x) ^ 2 + (bt.z - chute.z) ^ 2) <= td.bed.size.x / 2 then return e end
		end
	end
end

local function info(meta)
	local cap = H.tons_of(bin_cap())
	local parts = {}
	for _, sd in ipairs(SIDES) do
		local lv, coal = meta:get_float(sd.key .. "_lv"), meta:get_float(sd.key .. "_coal")
		parts[#parts + 1] = ("%s倉 %.0f / %.0f t%s"):format(sd.label, H.tons_of(lv), cap,
			lv >= 1 and ("（品位 %.0f%%）"):format(100 * coal / lv) or "")   -- 不到 1 級的零頭放不出來，品位也沒意義
	end
	return parts
end

local function step(pos, dtime)
	local meta = core.get_meta(pos)
	local cap = bin_cap()
	local R, m = cfg.plant_recovery, cfg.plant_misplaced
	-- 1. 吃料、分選：兩座倉都還放得下才吃（每吃 1 級，每座倉最多多 1 級）
	local room = math.min(cap - meta:get_float("p_lv"), cap - meta:get_float("r_lv"))
	if room >= 1 then
		local add = {p_lv = 0, p_coal = 0, r_lv = 0, r_coal = 0}
		H.eat(pos, dtime, cfg.plant_rate, math.floor(room), function(t, base, p2)
			local g = rockmech.ore_of_rubble[base] and p2 / 255 or 0
			local coal = t * g
			local prod = R * coal + m * (t - coal)
			add.p_lv, add.p_coal = add.p_lv + prod, add.p_coal + R * coal
			add.r_lv, add.r_coal = add.r_lv + (t - prod), add.r_coal + (1 - R) * coal
		end)
		for k, v in pairs(add) do if v ~= 0 then meta:set_float(k, meta:get_float(k) + v) end end
	end
	-- 2. 放料：車斗停在放料口下面就裝
	local ore = main_ore()
	local per_step = math.max(1, math.floor(cfg.plant_load_rate * dtime / H.tons_of(1)))
	local dx, dz = meta:get_int("dx"), meta:get_int("dz")
	for _, sd in ipairs(SIDES) do
		local lv, coal = meta:get_float(sd.key .. "_lv"), meta:get_float(sd.key .. "_coal")
		if lv >= 1 then
			local _, chute = layout(pos, dx, dz, sd.s)
			local e = truck_under(chute)
			if e then
				local n = math.min(math.floor(lv), per_step, V.TYPES[e.vkind].cap - V.load_total(e))
				local g = coal / lv
				V.load_put(e, ore.rubble, n, math.floor(g * 255 + 0.5))
				meta:set_float(sd.key .. "_lv", lv - n)
				meta:set_float(sd.key .. "_coal", coal - n * g)
				rockmech.collapse.rubble_sound(chute, n)
				core.add_particlespawner({amount = 12, time = dtime, glow = 3,
					pos = {min = vector.subtract(chute, {x = 0.3, y = 0.6, z = 0.3}), max = vector.add(chute, {x = 0.3, y = -0.4, z = 0.3})},
					vel = {min = {x = -0.2, y = -6, z = -0.2}, max = {x = 0.2, y = -4, z = 0.2}}, exptime = 0.5, size = 3,
					texture = "default_gravel.png^[colorize:" .. (sd.key == "p" and ore.pure or ore.waste_color) .. ":160"})
			end
		end
	end
	meta:set_string("infotext", "選礦場（右鍵查看）\n" .. table.concat(info(meta), "\n"))
end

local function formspec(pos)
	local meta = core.get_meta(pos)
	local parts = info(meta)
	return table.concat({
		"formspec_version[6]size[9,5.4]",
		"label[0.5,0.6;選礦場（選煤廠）]",
		("label[0.5,1.2;處理能力：%g t/s　放料：%g t/s]"):format(cfg.plant_rate, cfg.plant_load_rate),
		("label[0.5,1.8;分選：煤 %.0f%% 進精煤，矸石 %.0f%% 混進精煤]"):format(cfg.plant_recovery * 100, cfg.plant_misplaced * 100),
		("label[0.5,2.5;%s]"):format(core.formspec_escape(parts[1])),
		("label[0.5,3.1;%s]"):format(core.formspec_escape(parts[2])),
		"label[0.5,3.7;卡車或礦卡倒車，讓車斗停在放料口正下方就會裝]",
		"button_exit[3,4.3;3,0.8;ok;關閉]",
	})
end

-- 塔和放料口的位置可以蓋嗎：塔腳下實心、塔身與放料口淨空
local function towers_ok(pos, dx, dz)
	local function solid(p) return not V.passable(core.get_node(p).name) end
	for _, sd in ipairs(SIDES) do
		local tc, chute = layout(pos, dx, dz, sd.s)
		for x = tc.x - 1, tc.x + 1 do for z = tc.z - 1, tc.z + 1 do
			if not solid({x = x, y = pos.y - 1, z = z}) then return false end
			for y = pos.y, pos.y + TOWER_H - 1 do
				if solid({x = x, y = y, z = z}) then return false end
			end
		end end
		if solid(chute) then return false end
	end
	return true
end

local function build(pos, dx, dz, name)
	if not (H.site_ok(pos, dx, dz) and towers_ok(pos, dx, dz)) then return false end
	core.set_node(pos, {name = PLANT})
	H.dig_hopper(pos, dx, dz)
	for _, sd in ipairs(SIDES) do
		local tc, chute = layout(pos, dx, dz, sd.s)
		for x = tc.x - 1, tc.x + 1 do for z = tc.z - 1, tc.z + 1 do
			for y = pos.y, pos.y + TOWER_H - 1 do core.set_node({x = x, y = y, z = z}, {name = BIN[sd.key]}) end
		end end
		core.set_node(chute, {name = CHUTE})
		local cm = core.get_meta(chute)
		local _, _, out = layout(pos, dx, dz, sd.s)
		cm:set_string("plant", core.pos_to_string(pos))
		cm:set_float("ux", out.x)
		cm:set_float("uz", out.z)
		cm:set_string("infotext", sd.label .. "放料口：車斗停在正下方")
	end
	local meta = core.get_meta(pos)
	meta:set_string("owner", name)
	meta:set_int("dx", dx)
	meta:set_int("dz", dz)
	core.get_node_timer(pos):start(H.STEP)
	H.keep_loaded(pos)
	step(pos, 0)
	return true
end

-- 拆掉：塔、放料口一起拆（倉裡的料沒了），格柵變回碎石，放掉強制載入
local function remove_towers(pos, meta)
	local dx, dz = meta:get_int("dx"), meta:get_int("dz")
	for _, sd in ipairs(SIDES) do
		local tc, chute = layout(pos, dx, dz, sd.s)
		for x = tc.x - 1, tc.x + 1 do for z = tc.z - 1, tc.z + 1 do
			for y = pos.y, pos.y + TOWER_H - 1 do
				local p = {x = x, y = y, z = z}
				if core.get_node(p).name == BIN[sd.key] then core.remove_node(p) end
			end
		end end
		if core.get_node(chute).name == CHUTE then core.remove_node(chute) end
	end
end

-- 無人駕駛（vehicle_ahs.lua）：p 附近 r m 內的放料口，回傳 {x, y, z, u = 朝外的方向}；沒有回傳 nil
function rockmech.plant_chute_near(p, r)
	local c = core.find_node_near(p, r, CHUTE, true)
	if not c then return nil end
	local cm = core.get_meta(c)
	return {x = c.x, y = c.y, z = c.z, u = {x = cm:get_float("ux"), z = cm:get_float("uz")}}
end

local BODY = "[fill:16x16:#2f7f8f^[fill:16x2:0,0:#303030^[fill:16x2:0,14:#303030"
local function bin_tex(c) return ("[fill:16x16:%s^[fill:16x1:0,0:#303030^[fill:1x16:0,0:#303030"):format(c) end
core.register_node(BIN.p, {
	description = "Plant bin (選礦場精煤塔)", tiles = {bin_tex("#3c6a3c")}, groups = {not_in_creative_inventory = 1},
	diggable = false, is_ground_content = false, drop = "",
})
core.register_node(BIN.r, {
	description = "Plant bin (選礦場矸石塔)", tiles = {bin_tex("#7a5a3c")}, groups = {not_in_creative_inventory = 1},
	diggable = false, is_ground_content = false, drop = "",
})
core.register_node(CHUTE, {
	description = "Plant chute (選礦場放料口)",
	drawtype = "nodebox", paramtype = "light",
	node_box = {type = "fixed", fixed = {{-0.5, 0, -0.5, 0.5, 0.5, 0.5}, {-0.3, -0.5, -0.3, 0.3, 0, 0.3}}},
	tiles = {"[fill:16x16:#404040^[fill:16x2:0,7:#c0a020"},
	groups = {not_in_creative_inventory = 1}, diggable = false, is_ground_content = false, drop = "",
})

core.register_node(PLANT, {
	description = ("Ore plant (選礦場)\n對著平地按右鍵放置：朝自己的方向挖 %d×%d m 受料倉，機身左右各一座儲料塔\n"
		.. "分選成精煤和矸石；卡車或礦卡停在放料口下面裝料"):format(H.SIZE, H.SIZE),
	drawtype = "nodebox",
	paramtype = "light",
	node_box = {type = "fixed", fixed = {-1.45, -0.5, -1.45, 1.45, 2.4, 1.45}},
	tiles = {BODY},
	inventory_image = BODY,
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
			core.chat_send_player(name, ("[選礦場] 要放在平地上：機身 3×3 m、前方 %d×%d m 受料倉、左右兩座塔（各 3×3 m、高 %d m）"
				.. "要平坦、地下是實心、上方淨空"):format(H.SIZE, H.SIZE, TOWER_H))
			return itemstack
		end
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	on_rightclick = function(pos, node, clicker)
		core.show_formspec(clicker:get_player_name(), PLANT, formspec(pos))
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
		remove_towers(pos, meta)
		if meta:get_int("forceload") == 1 then H.each_block(pos, function(p) core.forceload_free_block(p, false) end) end
	end,
})
rockmech.plant_build = build   -- 測試用
