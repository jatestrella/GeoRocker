-- rockmech/batching.lua
-- 拌合廠（單機版）：自己拌混凝土，跟預拌車叫料（vehicle_mixer.lua）並行。
--   實務：大壩、隧道、礦山這種偏遠的工地常在現場設拌合廠，骨材用自己破碎的石頭；城市工地多半叫預拌廠的車。
--   擺法跟排矸站（plant.lua）一樣：平地上，朝玩家的方向挖受料倉（crusher.lua 的 rockmech.hopper_lib），
--   機身左右各一座 6 m 高的塔：一座水泥筒倉、一座拌合樓（側面有出料口）。
--   骨材：卡車、怪手、推土機把碎石倒進受料倉，一格碎石（1 m³，孔隙約 35%）拌 1 m³ 混凝土。
--     收一般碎石、花崗岩碎石（還有硬的礦石：大理岩、銅礦，單壓強度 ≥ rockmech_aggregate_ucs）；
--     混了一成以上的土、煤、建築廢棄物就不適合：吃進去就丟掉，照破碎站的矸石處理費收錢。
--   水泥：商店的「水泥（1 t）」，拿著右鍵拌合廠（機身、筒倉）存進筒倉。
--   水：用水管接小鎮的給水栓（slurrytank.lua，收水費），或把抽水機的出水口對著拌合廠（坑水，免費，groundwater.lua）。
--   水灰比 w/c（面板上調，0.40–0.70）：用水量固定 0.18 m³/m³，水泥 0.18/(w/c) t/m³；
--     強度照 Abrams 定律（concretecurve.lua：0.50 = 28 MPa，跟預拌車一樣；0.40 約 38、0.70 約 15 MPa），記在每一格混凝土上。
--   裝車：預拌車倒車到出料口旁邊，按空白鍵就從拌合廠裝料（每 m³ 約 3 秒，不付錢；材料不夠就停）。

local cfg = rockmech.cfg
local S = rockmech.S
local V = rockmech.vehicles
local H = rockmech.hopper_lib
local CC = dofile(rockmech.modpath .. "/concretecurve.lua")
local NLEV = V.NLEV

local BATCH = "rockmech:batch_plant"
local SILO = "rockmech:batch_silo"             -- 水泥筒倉（料位 SILO_STAGE）
local MIXT = "rockmech:batch_tower"            -- 拌合樓
local SPOUT = "rockmech:batch_spout"           -- 出料口
local CEMENT = "rockmech:cement"
local WPIPE = "rockmech:water_pipe"
local TOWER_H = 6
local TOWER_OFF = 4
local SPOUT_H = 3            -- 出料口離地高 (m)：預拌車的進料斗約 2.5 m
local LOAD_R = 4.5           -- 預拌車進料斗離出料口多遠以內裝得到 (m)
local AGG_CAP = 40           -- 骨材倉 (m³)
local CEM_CAP = 60           -- 水泥筒倉 (t)
local WATER_CAP = 20         -- 水箱 (m³，抽水機打進來的坑水)
local WC_MIN, WC_MAX, WC_STEP = 0.40, 0.70, 0.05
local PIPE_R = 7             -- 機身這麼近以內的水管都算接到拌合廠
local FILL_STEPS = 8
local SIDES = {{key = "silo", s = 1}, {key = "mix", s = -1}}

local function f1(x) return ("%.1f"):format(x) end
local function f2(x) return ("%.2f"):format(x) end
local function wc_of(meta)
	local s = meta:get_string("wc")
	return s ~= "" and tonumber(s) or CC.WC_REF
end

-- 機身 pos、受料倉朝 d：side s 的塔中心、出料口、朝外的方向
local function layout(pos, dx, dz, s)
	local px, pz = -dz * s, dx * s
	local tc = {x = pos.x + px * TOWER_OFF, y = pos.y, z = pos.z + pz * TOWER_OFF}
	local spout = {x = tc.x + px * 2, y = pos.y + SPOUT_H, z = tc.z + pz * 2}
	return tc, spout, {x = px, z = pz}
end
local function spout_of(pos, meta)
	local _, sp = layout(pos, meta:get_int("dx"), meta:get_int("dz"), -1)
	return sp
end

-- 筒倉的料位
local SILO_STAGE, IS_SILO = {}, {}
for e = 0, FILL_STEPS do SILO_STAGE[e] = e == 0 and SILO or SILO .. "_" .. e; IS_SILO[SILO_STAGE[e]] = true end
local function show_silo(pos, meta)
	local f = meta:get_float("cement") / CEM_CAP
	local steps = TOWER_H * FILL_STEPS
	local k = f <= 0 and 0 or math.max(1, math.min(steps, math.ceil(f * steps)))
	if meta:get_int("silo_shown") == k + 1 then return end
	local tc = layout(pos, meta:get_int("dx"), meta:get_int("dz"), 1)
	for i = 0, TOWER_H - 1 do
		local want = SILO_STAGE[math.max(0, math.min(FILL_STEPS, k - i * FILL_STEPS))]
		for x = tc.x - 1, tc.x + 1 do for z = tc.z - 1, tc.z + 1 do
			local p = {x = x, y = pos.y + i, z = z}
			if IS_SILO[core.get_node(p).name] and core.get_node(p).name ~= want then core.swap_node(p, {name = want}) end
		end end
	end
	meta:set_int("silo_shown", k + 1)
end

-- 接得到給水栓嗎（機身附近的水管，沿著水管找）
local function on_tap(pos)
	local pipes = core.find_nodes_in_area(vector.subtract(pos, {x = PIPE_R, y = 2, z = PIPE_R}), vector.add(pos, {x = PIPE_R, y = 2, z = PIPE_R}), {WPIPE})
	if #pipes == 0 or not rockmech.water_hydrant_of then return false end
	return rockmech.water_hydrant_of(pipes) ~= nil
end

local function owner_of(meta) return meta:get_string("owner") end
-- 可以當骨材的碎石：一般碎石、花崗岩碎石；混了土、建築廢棄物、軟的礦石（煤：岩性單壓強度 < rockmech_aggregate_ucs）
-- 超過 BAD_MAX 就不行（碎石只記成分種類，不記原本是砂岩還是頁岩，一般碎石都收）
local BAD_MAX = 0.1
local function weak(comp)
	if comp == rockmech.RUBBLE or comp == rockmech.RUBBLE_GRANITE then return false end
	local key = type(comp) == "string" and comp:match("^ore:(.+)$")
	if key then
		local ore = cfg.ores[key]
		local lith = ore and ore.lith and cfg.lithologies[ore.lith]
		return not (lith and (lith.ucs or 0) >= cfg.aggregate_ucs)
	end
	return true      -- 土、建築廢棄物
end
local function aggregate_ok(base, p2, ca)
	if not base then return false end
	if base == rockmech.RUBBLE or base == rockmech.RUBBLE_GRANITE then return true end
	local mix = rockmech.mix_of[base]
	if not mix then return false end
	-- 第一種成分的體積比例：礦石碎石是 w，其他混合碎石是 g（0..255，assay.lua）
	local fa = (mix.ore and (type(ca) == "table" and ca.w or 255) or (type(ca) == "table" and ca.g or p2 or 0)) / 255
	local bad = (weak(mix.a) and fa or 0) + (weak(mix.b) and (1 - fa) or 0)
	return bad <= BAD_MAX
end

local function lines(pos, meta)
	local wc = wc_of(meta)
	local water = meta:get_float("water")
	local tap = on_tap(pos)
	local t = {
		S("Aggregate @1 / @2 m³", f1(meta:get_float("agg") / NLEV), AGG_CAP),
		S("Cement @1 / @2 t", f1(meta:get_float("cement")), CEM_CAP),
		tap and S("Water: on the town supply ($@1/m³)", ("%d"):format(cfg.water_fee or 0))
			or S("Water @1 / @2 m³ (pump water in, or connect a water pipe)", f1(water), WATER_CAP),
		S("w/c @1: strength @2 MPa, cement @3 t/m³", f2(wc), ("%.0f"):format(28 * CC.abrams(wc)), f2(CC.cement_per_m3(wc))),
	}
	if meta:get_float("rej") > 0 then
		t[#t + 1] = S("Rejected (not fit for aggregate): @1 t", ("%.0f"):format(H.tons_of(meta:get_float("rej"))))
	end
	return t
end
local function info(pos)
	local meta = core.get_meta(pos)
	meta:set_string("infotext", (meta:get_int("stopped") == 1 and S("Batching plant, stopped. Right-click to view") or S("Batching plant. Right-click to view"))
		.. "\n" .. table.concat(lines(pos, meta), "\n"))
end

local function step(pos, dtime)
	local meta = core.get_meta(pos)
	if meta:get_int("stopped") ~= 1 then
		local room = math.floor(AGG_CAP * NLEV - meta:get_float("agg"))
		if room >= 1 then
			local good, bad = 0, 0
			H.eat(pos, dtime, cfg.plant_rate, room, function(t, base, p2, ca)
				if aggregate_ok(base, p2, ca) then good = good + t else bad = bad + t end
			end)
			if good > 0 then meta:set_float("agg", meta:get_float("agg") + good) end
			if bad > 0 then
				meta:set_float("rej", meta:get_float("rej") + bad)
				local fee = H.tons_of(bad) * (cfg.crusher_fee or 0)
				local owner = owner_of(meta)
				if fee > 0 then rockmech.add_money(owner, -fee) end
				-- 通知（同一座 10 秒最多一次）
				local now = core.get_us_time() / 1e6
				if now - (meta:get_float("rej_note") or 0) > 10 then
					meta:set_float("rej_note", now)
					for _, m in ipairs(rockmech.account_members(rockmech.account_of(owner))) do
						rockmech.notify(m, S("[Batching plant] Not fit for aggregate (soil, coal, construction waste): thrown away, disposal fee $@1 per t",
							("%d"):format(cfg.crusher_fee or 0)))
					end
				end
			end
		end
	end
	show_silo(pos, meta)
	info(pos)
end

-- 拌 1 m³：回傳 配比強度比例 wq；材料不夠回傳 nil, 原因
function rockmech.batch_make(pos)
	if core.get_node(pos).name ~= BATCH then return nil, S("The batching plant is gone") end
	local meta = core.get_meta(pos)
	if meta:get_int("stopped") == 1 then return nil, S("The batching plant is stopped") end
	local wc = wc_of(meta)
	local cem = CC.cement_per_m3(wc)
	if meta:get_float("agg") < NLEV then return nil, S("Not enough aggregate: dump crushed rock into the hopper") end
	if meta:get_float("cement") < cem - 1e-6 then return nil, S("Not enough cement: right-click the silo with cement") end
	local water = meta:get_float("water")
	local owner = owner_of(meta)
	if water >= CC.WATER - 1e-6 then
		meta:set_float("water", water - CC.WATER)
	elseif on_tap(pos) then
		local fee = CC.WATER * (cfg.water_fee or 0)
		if fee > 0 then
			if rockmech.money(owner) < fee then return nil, S("Not enough money for the water") end
			rockmech.add_money(owner, -fee)
		end
	else
		return nil, S("No water: connect a water pipe from the water supply, or pump water into the plant")
	end
	meta:set_float("agg", meta:get_float("agg") - NLEV)
	meta:set_float("cement", meta:get_float("cement") - cem)
	meta:set_float("made", meta:get_float("made") + 1)
	show_silo(pos, meta)
	info(pos)
	return CC.abrams(wc)
end
-- 預拌車的進料斗 p 附近的拌合廠（出料口水平 LOAD_R m 內）：回傳 機身位置、出料口
function rockmech.batch_near(p)
	for _, b in ipairs(core.find_nodes_in_area(vector.subtract(p, {x = 12, y = 6, z = 12}), vector.add(p, {x = 12, y = 6, z = 12}), {BATCH})) do
		local sp = spout_of(b, core.get_meta(b))
		if math.sqrt((sp.x - p.x) ^ 2 + (sp.z - p.z) ^ 2) <= LOAD_R and math.abs(sp.y - p.y) <= 4 then return b, sp end
	end
end
-- 這一格屬於哪座拌合廠（機身、塔、出料口）
local function plant_of(p)
	if core.get_node(p).name == BATCH then return p end
	for _, b in ipairs(core.find_nodes_in_area(vector.subtract(p, {x = 7, y = TOWER_H, z = 7}), vector.add(p, {x = 7, y = 1, z = 7}), {BATCH})) do
		local m = core.get_meta(b)
		for _, sd in ipairs(SIDES) do
			local tc, sp = layout(b, m:get_int("dx"), m:get_int("dz"), sd.s)
			if (math.abs(p.x - tc.x) <= 1 and math.abs(p.z - tc.z) <= 1 and p.y >= b.y and p.y < b.y + TOWER_H) or vector.equals(p, sp) then
				return b
			end
		end
	end
end

-- 抽水機的出水口對著拌合廠（groundwater.lua）：坑水進水箱，回傳收了幾級
rockmech.water_sinks = rockmech.water_sinks or {}
local function sink(p, levels)
	local b = plant_of(p)
	if not b then return 0 end
	local meta = core.get_meta(b)
	local room = math.floor((WATER_CAP - meta:get_float("water")) * NLEV)
	local n = math.max(0, math.min(levels, room))
	if n > 0 then meta:set_float("water", meta:get_float("water") + n / NLEV) end
	return n
end

-- 存水泥
local function store_cement(pos, clicker, itemstack)
	local b = plant_of(pos)
	if not b then return itemstack end
	local meta = core.get_meta(b)
	local n = math.min(itemstack:get_count(), math.floor(CEM_CAP - meta:get_float("cement") + 1e-6))
	local name = clicker and clicker:get_player_name() or ""
	if n <= 0 then rockmech.notify(name, S("[Batching plant] The cement silo is full")); return itemstack end
	meta:set_float("cement", meta:get_float("cement") + n)
	itemstack:take_item(n)
	show_silo(b, meta)
	info(b)
	return itemstack
end

local function formspec(pos)
	local meta = core.get_meta(pos)
	local F = core.formspec_escape
	local L = lines(pos, meta)
	local stopped = meta:get_int("stopped") == 1
	local fs = {"formspec_version[6]size[9.5,6.4]",
		("label[0.5,0.6;%s]"):format(F(stopped and S("Batching plant   Stopped") or S("Batching plant   Running"))),
		("button[6.6,0.2;2.4,0.8;toggle;%s]"):format(F(stopped and S("Start") or S("Stop")))}
	for i, l in ipairs(L) do fs[#fs + 1] = ("label[0.5,%.1f;%s]"):format(0.7 + i * 0.55, F(l)) end
	local y = 0.9 + (#L + 1) * 0.55
	fs[#fs + 1] = ("label[0.5,%.2f;%s]button[3.2,%.2f;1,0.7;wc_dec;−]button[4.4,%.2f;1,0.7;wc_inc;+]"):format(y + 0.35,
		F(S("w/c @1", f2(wc_of(meta)))), y, y)
	fs[#fs + 1] = ("label[0.5,%.2f;%s]"):format(y + 1.2, F(S("Less water: stronger, but more cement per m³")))
	fs[#fs + 1] = ("label[0.5,%.2f;%s]"):format(y + 1.75, F(S("Back a concrete mixer truck up to the spout and press Space to load")))
	fs[#fs + 1] = ("button_exit[7,%.2f;2,0.7;ok;%s]"):format(y + 2.3, F(S("Done")))
	return table.concat(fs)
end
local form_pos = {}
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= BATCH then return end
	local name = player:get_player_name()
	local pos = form_pos[name]
	if fields.quit then form_pos[name] = nil end
	if not (pos and core.get_node(pos).name == BATCH and rockmech.owner_ok(core.get_meta(pos):get_string("owner"), name)) then return true end
	local meta = core.get_meta(pos)
	if fields.toggle then meta:set_int("stopped", meta:get_int("stopped") == 1 and 0 or 1) end
	local wc = wc_of(meta)
	if fields.wc_dec then wc = math.max(WC_MIN, wc - WC_STEP) end
	if fields.wc_inc then wc = math.min(WC_MAX, wc + WC_STEP) end
	meta:set_string("wc", ("%.2f"):format(wc))
	info(pos)
	if not fields.quit and not fields.ok then core.show_formspec(name, BATCH, formspec(pos)) end
	return true
end)
core.register_on_leaveplayer(function(player) form_pos[player:get_player_name()] = nil end)

local function rightclick(pos, node, clicker, itemstack)
	if not (clicker and clicker:is_player()) then return itemstack end
	local b = plant_of(pos)
	if not b then return itemstack end
	local name = clicker:get_player_name()
	if itemstack:get_name() == CEMENT then return store_cement(pos, clicker, itemstack) end
	form_pos[name] = b
	core.show_formspec(name, BATCH, formspec(b))
	return itemstack
end

-- 塔和出料口的位置可以蓋嗎：塔腳下實心、塔身與出料口淨空
local function towers_ok(pos, dx, dz)
	local function solid(p) return not V.passable(core.get_node(p).name) end
	for _, sd in ipairs(SIDES) do
		local tc, sp = layout(pos, dx, dz, sd.s)
		for x = tc.x - 1, tc.x + 1 do for z = tc.z - 1, tc.z + 1 do
			if not solid({x = x, y = pos.y - 1, z = z}) then return false end
			for y = pos.y, pos.y + TOWER_H - 1 do
				if solid({x = x, y = y, z = z}) then return false end
			end
		end end
		if sd.key == "mix" and solid(sp) then return false end
	end
	return true
end
rockmech.facility_site_ok = rockmech.facility_site_ok or {}
rockmech.facility_towers = rockmech.facility_towers or {}
rockmech.facility_site_ok[BATCH] = function(pos, dx, dz) return H.site_ok(pos, dx, dz) and towers_ok(pos, dx, dz) end
rockmech.facility_towers[BATCH] = function(pos, dx, dz)
	local out = {}
	for _, sd in ipairs(SIDES) do out[#out + 1] = (layout(pos, dx, dz, sd.s)) end
	return out, TOWER_H
end

local function build(pos, dx, dz, name)
	local rec = rockmech.clear_site and rockmech.facility_cells and rockmech.clear_site(rockmech.facility_cells(BATCH, pos, dx, dz), pos)
	if rec == false or not (H.site_ok(pos, dx, dz) and towers_ok(pos, dx, dz)) then rockmech.site_undo(rec); return false end
	rockmech.site_charge(rec, name)
	core.set_node(pos, {name = BATCH})
	H.dig_hopper(pos, dx, dz)
	for _, sd in ipairs(SIDES) do
		local tc, sp = layout(pos, dx, dz, sd.s)
		for x = tc.x - 1, tc.x + 1 do for z = tc.z - 1, tc.z + 1 do
			for y = pos.y, pos.y + TOWER_H - 1 do core.set_node({x = x, y = y, z = z}, {name = sd.key == "silo" and SILO or MIXT}) end
		end end
		if sd.key == "mix" then
			local _, _, out = layout(pos, dx, dz, sd.s)
			core.set_node(sp, {name = SPOUT, param2 = core.dir_to_facedir({x = out.x, y = 0, z = out.z})})
			core.get_meta(sp):set_string("infotext", S("Batching plant spout: back a concrete mixer truck up here and press Space"))
		end
	end
	local meta = core.get_meta(pos)
	meta:set_string("owner", rockmech.account_of(name))
	meta:set_int("dx", dx)
	meta:set_int("dz", dz)
	meta:set_string("wc", ("%.2f"):format(CC.WC_REF))
	core.get_node_timer(pos):start(H.STEP)
	H.keep_loaded(pos)
	step(pos, 0)
	return true
end

local function remove_towers(pos, meta)
	local dx, dz = meta:get_int("dx"), meta:get_int("dz")
	for _, sd in ipairs(SIDES) do
		local tc, sp = layout(pos, dx, dz, sd.s)
		for x = tc.x - 1, tc.x + 1 do for z = tc.z - 1, tc.z + 1 do
			for y = pos.y, pos.y + TOWER_H - 1 do
				local p = {x = x, y = y, z = z}
				local n = core.get_node(p).name
				if IS_SILO[n] or n == MIXT then core.remove_node(p) end
			end
		end end
		if core.get_node(sp).name == SPOUT then core.remove_node(sp) end
	end
end

-- 外觀
local BODY = "[fill:16x16:#c8782a^[fill:16x2:0,0:#303030^[fill:16x2:0,14:#303030"
local function frame(c) return ("[fill:16x16:%s^[fill:16x1:0,0:#303030^[fill:1x16:0,0:#303030"):format(c) end
local SILO_PAINT, CEMENT_COLOR = "#a8acb0", "#d4d0c4"
for e = 0, FILL_STEPS do
	local side = e == 0 and frame(SILO_PAINT)
		or ("[fill:16x16:%s^[fill:16x%d:0,%d:%s^[fill:16x1:0,0:#303030^[fill:1x16:0,0:#303030"):format(SILO_PAINT,
			16 * e / FILL_STEPS, 16 - 16 * e / FILL_STEPS, CEMENT_COLOR)
	core.register_node(SILO_STAGE[e], {
		description = S("Cement silo"),
		tiles = {frame(SILO_PAINT), side}, groups = {not_in_creative_inventory = 1},
		diggable = false, is_ground_content = false, drop = "",
		on_rightclick = rightclick,
	})
end
core.register_node(MIXT, {
	description = S("Batching tower"),
	tiles = {frame("#c8782a"), frame("#c8782a") .. "^[fill:6x4:5,6:#404040"}, groups = {not_in_creative_inventory = 1},
	diggable = false, is_ground_content = false, drop = "",
	on_rightclick = rightclick,
})
core.register_node(SPOUT, {
	description = S("Batching plant spout"),
	drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
	node_box = {type = "fixed", fixed = {{-0.4, -0.1, -0.5, 0.4, 0.5, 0.5}, {-0.2, -0.5, -0.2, 0.2, -0.1, 0.2}}},
	tiles = {"[fill:16x16:#606060^[fill:16x2:0,7:#c8782a"},
	groups = {not_in_creative_inventory = 1}, diggable = false, is_ground_content = false, drop = "",
	on_rightclick = rightclick,
})
for n in pairs(IS_SILO) do rockmech.water_sinks[n] = sink end
rockmech.water_sinks[MIXT] = sink
rockmech.water_sinks[BATCH] = sink

core.register_craftitem(CEMENT, {
	description = S("Cement\n1 t. Right-click a batching plant to fill its silo"),
	short_description = S("Cement"),
	inventory_image = "[fill:16x16:#00000000^[fill:10x12:3,3:#c8c4b8^[fill:10x2:3,5:#9a968a^[fill:4x2:6,2:#c8c4b8",
	stack_max = 99,
	on_place = function(itemstack, placer, pointed)
		if pointed.type ~= "node" then return itemstack end
		local un = core.get_node(pointed.under)
		local udef = core.registered_nodes[un.name]
		if udef and udef.on_rightclick then return udef.on_rightclick(pointed.under, un, placer, itemstack, pointed) or itemstack end
		return itemstack
	end,
})

core.register_node(BATCH, {
	description = S("Batching plant\nRight-click on flat ground to build. Dump crushed rock into the hopper, fill the silo with cement, bring water by pipe or pump; mixer trucks load at the spout"),
	short_description = S("Batching plant"),
	drawtype = "nodebox",
	paramtype = "light",
	node_box = {type = "fixed", fixed = {-1.45, -0.5, -1.45, 1.45, 2.4, 1.45}},
	tiles = {BODY},
	inventory_image = "[fill:16x16:#00000000^[fill:5x12:1,3:" .. SILO_PAINT .. "^[fill:6x8:6,7:#c8782a^[fill:4x10:12,5:#c8782a^[fill:2x2:13,15:#404040",
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
			rockmech.notify(name, S("[Batching plant] Place it on flat ground: the 3×3 m machine, the @1×@2 m receiving hopper in front and the two towers on the sides (each 3×3 m, @3 m tall) need level ground, solid rock below and clear space above",
				tostring(H.SIZE), tostring(H.SIZE), tostring(TOWER_H)))
			return itemstack
		end
		if not core.is_creative_enabled(name) then itemstack:take_item() end
		return itemstack
	end,
	can_dig = function(pos, player)
		return player and rockmech.owner_ok(core.get_meta(pos):get_string("owner"), player:get_player_name())
	end,
	on_rightclick = rightclick,
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
core.register_lbm({
	label = "rockmech: 拌合廠計時器", name = "rockmech:batch_plant_timer", nodenames = {BATCH}, run_at_every_load = true,
	action = function(pos)
		if not core.get_node_timer(pos):is_started() then core.get_node_timer(pos):start(H.STEP) end
	end,
})
rockmech.batch_build = build   -- 測試用
