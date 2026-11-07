-- rockmech/plant.lua
-- 選礦場（選煤廠，coal preparation plant）：放在平地上，朝玩家的方向挖一個和破碎站一樣的受料倉（crusher.lua 的
-- rockmech.hopper_lib），機身左右各一座 6 m 高的儲料塔：一座出精煤、一座出矸石。
-- 分選（重介質分選的分配曲線簡化成兩個數）：原料裡的煤有 rockmech_plant_recovery 進精煤，
-- 矸石有 rockmech_plant_misplaced 混進精煤，其餘進矸石。品位 30% 的原料 → 精煤約 80%、矸石約 2%。
-- 放料臂（裝車溜槽）：每座塔頂外側一支會轉的放料臂，有斗的車（卡車、礦卡）停在 rockmech_plant_reach m 內不動，
-- 放料臂就轉過去、伸到車斗上方放料；附近沒有車就放到搆得到的皮帶上（conveyor.lua）。不會倒在地上或旁邊的漏斗，
-- 所以就算蓋在破碎站、廢石場旁邊，還是要用卡車或皮帶搬。兩座塔任何一座滿了就停止吃料。
-- 選礦場本身不收錢也不付錢：精煤載去破碎站賣，矸石載去廢石場（破碎站切換成廢石場）丟。

local cfg = rockmech.cfg
local S = rockmech.S
local V = rockmech.vehicles
local H = rockmech.hopper_lib
local NLEV = V.NLEV

local PLANT, CHUTE = "rockmech:plant", "rockmech:plant_chute"
local BIN = {p = "rockmech:plant_bin_p", r = "rockmech:plant_bin_r"}
local BIN_FULL = {p = "rockmech:plant_bin_p_full", r = "rockmech:plant_bin_r_full"}   -- 整層裝滿料
-- 存量顯示：每層再分 8 格（料位線），BIN_STAGE[side][e] 是裝了 e/8 的那一層（0 = 空、8 = 滿）
local FILL_STEPS = 8
local BIN_STAGE, IS_BIN = {}, {}
for _, k in ipairs({"p", "r"}) do
	BIN_STAGE[k], IS_BIN[k] = {[0] = BIN[k], [FILL_STEPS] = BIN_FULL[k]}, {}
	for e = 1, FILL_STEPS - 1 do BIN_STAGE[k][e] = BIN[k] .. "_" .. e end
	for e = 0, FILL_STEPS do IS_BIN[k][BIN_STAGE[k][e]] = true end
end
local TOWER_H = 6           -- 塔高 (m)，放料臂的轉軸在塔頂外側
local BOOM = "rockmech:plant_boom"
local BOOM_REST = 3         -- 沒車時放料臂朝外伸出多長 (m)
local STALL_T = 10          -- 連續停機多久才算停機 (s)
local TOWER_OFF = 4         -- 塔中心離機身中心（左右）
local SIDES = {{key = "p", s = 1, label = S("Clean coal")}, {key = "r", s = -1, label = S("Rejects")}}

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

-- 放料臂的樣子：一根從轉軸伸到 tip 的黃色方桿（實體，不存檔，計時器每一步補上、擺到位）
core.register_entity(BOOM, {
	initial_properties = {
		visual = "cube", visual_size = {x = 0.45, y = 0.45, z = 1},
		textures = (function()
			local t = "[fill:16x16:#c8a020^[fill:16x2:0,7:#303030"
			return {t, t, t, t, "[fill:16x16:#303030", "[fill:16x16:#303030"}
		end)(),
		physical = false, collide_with_objects = false, pointable = false, static_save = false,
	},
})
local booms = {}            -- 「機身座標:side」→ 放料臂實體
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

-- 存量用 m³（跟車斗一樣），括號附噸數
local function info(meta)
	local parts = {}
	for _, sd in ipairs(SIDES) do
		local lv, coal = meta:get_float(sd.key .. "_lv"), meta:get_float(sd.key .. "_coal")
		local a, b, t = ("%.0f"):format(lv / NLEV), ("%.0f"):format(cfg.plant_bin), ("%.0f"):format(H.tons_of(lv))
		parts[#parts + 1] = lv >= 1 and S("@1 bin @2 / @3 m³ (@4 t, grade @5%)", sd.label, a, b, t, ("%.0f"):format(100 * coal / lv))
			or S("@1 bin @2 / @3 m³ (@4 t)", sd.label, a, b, t)   -- 不到 1 級的零頭放不出來，品位也沒意義
	end
	return parts
end

-- 塔身顯示存量：塔高 TOWER_H 層、每層 FILL_STEPS 格，料位線從底下往上漲（有變才換）
local function show_fill(pos, meta, sd)
	local lv = meta:get_float(sd.key .. "_lv")
	local steps = TOWER_H * FILL_STEPS
	local k = lv < 1 and 0 or math.max(1, math.min(steps, math.ceil(lv / bin_cap() * steps)))
	if meta:get_int(sd.key .. "_shown") == k + 1 then return end      -- 存 k + 1：0 是還沒畫過
	local tc = layout(pos, meta:get_int("dx"), meta:get_int("dz"), sd.s)
	for i = 0, TOWER_H - 1 do
		local want = BIN_STAGE[sd.key][math.max(0, math.min(FILL_STEPS, k - i * FILL_STEPS))]
		for x = tc.x - 1, tc.x + 1 do for z = tc.z - 1, tc.z + 1 do
			local p = {x = x, y = pos.y + i, z = z}
			local n = core.get_node(p).name
			if n ~= want and IS_BIN[sd.key][n] then core.swap_node(p, {name = want}) end
		end end
	end
	meta:set_int(sd.key .. "_shown", k + 1)
end

local function step(pos, dtime)
	local meta = core.get_meta(pos)
	local cap = bin_cap()
	local owner = meta:get_string("owner")
	local R, m = rockmech.eff_plant_recovery(owner), rockmech.eff_plant_misplaced(owner)    -- 研究（research.lua）
	-- 1. 吃料、分選：兩座倉都還放得下才吃（每吃 1 級，每座倉最多多 1 級）
	local room = math.min(cap - meta:get_float("p_lv"), cap - meta:get_float("r_lv"))
	local eaten = 0
	local stopped = meta:get_int("stopped") == 1     -- 右鍵選單按「停止」：不吃料也不放料
	if room >= 1 and not stopped then
		local add = {p_lv = 0, p_coal = 0, r_lv = 0, r_coal = 0}
		eaten = H.eat(pos, dtime, cfg.plant_rate, math.floor(room), function(t, base, p2)
			local g = rockmech.ore_of_rubble[base] and p2 / 255 or 0
			local coal = t * g
			local prod = R * coal + m * (t - coal)
			add.p_lv, add.p_coal = add.p_lv + prod, add.p_coal + R * coal
			add.r_lv, add.r_coal = add.r_lv + (t - prod), add.r_coal + (1 - R) * coal
		end)
		for k, v in pairs(add) do if v ~= 0 then meta:set_float(k, meta:get_float(k) + v) end end
	end
	-- 停機（受料倉沒料，或有一座倉滿了）連續 STALL_T 秒：在放料臂下等的車看到這個，車上有半車以上就先走（vehicle_ahs.lua）。
	-- 要連續停：倉裡零星的殘料一點一點流下來時會停停走走，車子不該每次只裝一點就跑
	if dtime > 0 then meta:set_float("stall_t", eaten == 0 and meta:get_float("stall_t") + dtime or 0) end
	-- 2. 放料：車斗停在放料口下面就裝
	local ore = main_ore()
	local per_step = math.max(1, math.floor(cfg.plant_load_rate * dtime / H.tons_of(1)))
	local dx, dz = meta:get_int("dx"), meta:get_int("dz")
	for _, sd in ipairs(SIDES) do
		local lv, coal = meta:get_float(sd.key .. "_lv"), meta:get_float(sd.key .. "_coal")
		local _, chute, out = layout(pos, dx, dz, sd.s)
		local key = core.pos_to_string(pos) .. sd.key
		local e, bt
		if not stopped then e, bt = truck_in_reach(chute) end
		-- 沒有車：放到搆得到的皮帶上（conveyor.lua）
		local belt, by
		if not e and not stopped and rockmech.belt_near then belt, by = rockmech.belt_near(chute, cfg.plant_reach) end
		local tip = e and {x = bt.x, y = bt.y + 0.4, z = bt.z}          -- 伸到車斗上方
			or belt and {x = belt.x, y = by + 0.4, z = belt.z}
		place_boom(key, chute, tip or {x = chute.x + out.x * BOOM_REST, y = chute.y - 0.8, z = chute.z + out.z * BOOM_REST})
		if lv >= 1 then
			if tip then
				local n = math.min(math.floor(lv), per_step)
				local g = coal / lv
				local gi = math.floor(g * 255 + 0.5)
				if e then
					n = math.min(n, V.TYPES[e.vkind].cap - V.load_total(e))
					V.load_put(e, ore.rubble, n, gi)
				else
					-- 一格皮帶裝不下這一步的量：往旁邊幾格也放（belt_near 只找還有空位的格子）
					local put, b = 0, belt
					for _ = 1, 4 do
						put = put + rockmech.belt_put(b, ore.rubble, n - put, gi)
						if put >= n then break end
						b = rockmech.belt_near(chute, cfg.plant_reach)
						if not b then break end
					end
					n = put
				end
				meta:set_float(sd.key .. "_lv", lv - n)
				meta:set_float(sd.key .. "_coal", coal - n * g)
				rockmech.collapse.rubble_sound(tip, n)
				core.add_particlespawner({amount = 12, time = dtime, glow = 3,
					pos = {min = vector.subtract(tip, {x = 0.3, y = 0.3, z = 0.3}), max = vector.add(tip, {x = 0.3, y = 0, z = 0.3})},
					vel = {min = {x = -0.2, y = -6, z = -0.2}, max = {x = 0.2, y = -4, z = 0.2}}, exptime = 0.5, size = 3,
					texture = "default_gravel.png^[colorize:" .. (sd.key == "p" and ore.pure or ore.waste_color) .. ":160"})
			end
		end
	end
	for _, sd in ipairs(SIDES) do show_fill(pos, meta, sd) end
	meta:set_string("infotext", (stopped and S("Ore plant (stopped) (right-click to view)") or S("Ore plant (right-click to view)"))
		.. "\n" .. table.concat(info(meta), "\n"))
end

local function formspec(pos)
	local meta = core.get_meta(pos)
	local parts = info(meta)
	local stopped = meta:get_int("stopped") == 1
	return table.concat({
		"formspec_version[6]size[9,5.4]",
		("label[0.5,0.6;%s]"):format(core.formspec_escape(stopped and S("Ore plant (coal preparation plant)   Stopped")
			or S("Ore plant (coal preparation plant)   Running"))),
		("button[6,0.2;2.6,0.8;toggle;%s]"):format(core.formspec_escape(stopped and S("Start") or S("Stop"))),
		("label[0.5,1.2;%s]"):format(core.formspec_escape(S("Capacity: @1 t/s   Loading: @2 t/s", ("%g"):format(cfg.plant_rate), ("%g"):format(cfg.plant_load_rate)))),
		("label[0.5,1.8;%s]"):format(core.formspec_escape(S("Separation: @1% of the coal goes to clean coal, @2% of the waste is misplaced into clean coal",
			("%.0f"):format(rockmech.eff_plant_recovery(meta:get_string("owner")) * 100),
			("%.0f"):format(rockmech.eff_plant_misplaced(meta:get_string("owner")) * 100)))),
		("label[0.5,2.5;%s]"):format(core.formspec_escape(parts[1])),
		("label[0.5,3.1;%s]"):format(core.formspec_escape(parts[2])),
		("label[0.5,3.7;%s]"):format(core.formspec_escape(S("When a truck or haul truck stands still within @1 m of a loading boom, the boom swings over and loads it", ("%g"):format(cfg.plant_reach)))),
		"button_exit[3,4.3;3,0.8;ok;" .. core.formspec_escape(S("Close")) .. "]",
	})
end

-- 右鍵選單：停止／開始運轉
local form_pos = {}         -- 玩家名稱 → 正在看的選礦場
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= PLANT then return end
	local name = player:get_player_name()
	local pos = form_pos[name]
	if fields.quit then form_pos[name] = nil end
	if not (fields.toggle and pos and core.get_node(pos).name == PLANT) then return true end
	local meta = core.get_meta(pos)
	meta:set_int("stopped", meta:get_int("stopped") == 1 and 0 or 1)
	step(pos, 0)            -- 放料臂馬上收回、狀態文字更新
	core.show_formspec(name, PLANT, formspec(pos))
	return true
end)
core.register_on_leaveplayer(function(player) form_pos[player:get_player_name()] = nil end)

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

-- 放置預覽（preview.lua）：能不能蓋、兩座塔的中心
function rockmech.plant_site_ok(pos, dx, dz) return H.site_ok(pos, dx, dz) and towers_ok(pos, dx, dz) end
function rockmech.plant_towers(pos, dx, dz)
	local out = {}
	for _, sd in ipairs(SIDES) do out[#out + 1] = (layout(pos, dx, dz, sd.s)) end
	return out, TOWER_H
end

local function build(pos, dx, dz, name)
	if rockmech.clear_site and rockmech.facility_cells then rockmech.clear_site(rockmech.facility_cells(PLANT, pos, dx, dz), pos) end
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
		cm:set_string("infotext", S("@1 loading boom: loads trucks stopped within @2 m", sd.label, ("%g"):format(cfg.plant_reach)))
	end
	local meta = core.get_meta(pos)
	meta:set_string("owner", rockmech.account_of(name))     -- 分組時歸整組
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
				local n = core.get_node(p).name
				if IS_BIN[sd.key][n] then core.remove_node(p) end
			end
		end end
		if core.get_node(chute).name == CHUTE then core.remove_node(chute) end
		local o = booms[core.pos_to_string(pos) .. sd.key]
		if o and o:get_pos() then o:remove() end
	end
end

-- 無人駕駛（vehicle_ahs.lua）：放料臂 c 那座倉的存量（級）、選礦場是不是停機了；找不到選礦場回傳 nil
function rockmech.plant_chute_state(c)
	local pos = core.string_to_pos(core.get_meta(c):get_string("plant"))
	if not pos or core.get_node(pos).name ~= PLANT then return nil end
	local meta = core.get_meta(pos)
	for _, sd in ipairs(SIDES) do
		local _, chute = layout(pos, meta:get_int("dx"), meta:get_int("dz"), sd.s)
		if chute.x == c.x and chute.y == c.y and chute.z == c.z then
			-- 停止中：當成停機、倉是空的（半車以上的車先走，不在臂下乾等）
			if meta:get_int("stopped") == 1 then return {lv = 0, stalled = true} end
			return {lv = meta:get_float(sd.key .. "_lv"), stalled = meta:get_float("stall_t") >= STALL_T}
		end
	end
end
-- 無人駕駛（vehicle_ahs.lua）：p 附近 r m 內的放料臂轉軸，回傳 {x, y, z, u = 朝外的方向}；沒有回傳 nil
function rockmech.plant_chute_near(p, r)
	local c = core.find_node_near(p, r, CHUTE, true)
	if not c then return nil end
	local cm = core.get_meta(c)
	return {x = c.x, y = c.y, z = c.z, u = {x = cm:get_float("ux"), z = cm:get_float("uz")}}
end

local BODY = "[fill:16x16:#2f7f8f^[fill:16x2:0,0:#303030^[fill:16x2:0,14:#303030"
local function bin_tex(c) return ("[fill:16x16:%s^[fill:16x1:0,0:#303030^[fill:1x16:0,0:#303030"):format(c) end
-- 裝了料的那幾層：料的顏色（精煤黑、矸石灰），框線用塔原本的顏色
local function full_tex(material, paint) return ("[fill:16x16:%s^[fill:16x2:0,0:%s^[fill:2x16:0,0:%s"):format(material, paint, paint) end
local PAINT = {p = "#3c6a3c", r = "#7a5a3c"}
local MATERIAL = {p = main_ore().pure, r = main_ore().waste_color}
for _, sd in ipairs(SIDES) do
	local k = sd.key
	for e = 0, FILL_STEPS do
		-- 側面從底下塗料的顏色到 e/8 高（料位線），頂面空的是塔的顏色、滿的是料的顏色
		local side = e == 0 and bin_tex(PAINT[k]) or e == FILL_STEPS and full_tex(MATERIAL[k], PAINT[k])
			or ("[fill:16x16:%s^[fill:16x%d:0,%d:%s^[fill:16x1:0,0:#303030^[fill:1x16:0,0:#303030"):format(PAINT[k],
				16 * e / FILL_STEPS, 16 - 16 * e / FILL_STEPS, MATERIAL[k])
		local top = e == FILL_STEPS and full_tex(MATERIAL[k], PAINT[k]) or bin_tex(PAINT[k])
		core.register_node(BIN_STAGE[k][e], {
			description = e > 0 and S("Ore plant @1 tower, @2/8 full", sd.label, tostring(e)) or S("Ore plant @1 tower", sd.label),
			tiles = {top, side, side, side, side, side}, groups = {not_in_creative_inventory = 1},
			diggable = false, is_ground_content = false, drop = "",
		})
	end
end
core.register_node(CHUTE, {
	description = S("Ore plant chute"),
	drawtype = "nodebox", paramtype = "light",
	node_box = {type = "fixed", fixed = {{-0.5, 0, -0.5, 0.5, 0.5, 0.5}, {-0.3, -0.5, -0.3, 0.3, 0, 0.3}}},
	tiles = {"[fill:16x16:#404040^[fill:16x2:0,7:#c0a020"},
	groups = {not_in_creative_inventory = 1}, diggable = false, is_ground_content = false, drop = "",
})

core.register_node(PLANT, {
	description = S("Ore plant\nRight-click on flat ground to build"),
	short_description = S("Ore plant"),
	drawtype = "nodebox",
	paramtype = "light",
	node_box = {type = "fixed", fixed = {-1.45, -0.5, -1.45, 1.45, 2.4, 1.45}},
	tiles = {BODY},
	inventory_image = "rockmech_icon_plant.png",      -- devtools/make_icons.py
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
			rockmech.notify(name, S("[Ore plant] Place it on flat ground: the 3×3 m machine, the @1×@2 m receiving hopper in front and the two towers on the sides (each 3×3 m, @3 m tall) need level ground, solid rock below and clear space above",
				tostring(H.SIZE), tostring(H.SIZE), tostring(TOWER_H)))
			return itemstack
		end
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	can_dig = function(pos, player)
		return player and rockmech.owner_ok(core.get_meta(pos):get_string("owner"), player:get_player_name())
	end,
	on_rightclick = function(pos, node, clicker)
		local name = clicker:get_player_name()
		form_pos[name] = pos
		core.show_formspec(name, PLANT, formspec(pos))
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
