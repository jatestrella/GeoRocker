-- rockmech/haulroad.lua
-- 往電廠的道路（rockmech_haul_gate、rockmech_power_plants）：小鎮接一條路到地圖邊緣的地磅站（出廠管制站），
-- 卡車在這裡換手給外包司機開去電廠，過一段時間空車回來。
--   換手：卡車停上地磅、駕駛下車，按地磅站的控制箱「派車」；無人卡車（AHS）的傾倒點設在地磅上，開到就自己派車。
--   只有能上公路的車能去（傾卸卡車）；礦卡太寬太重，不能上公路。
--   一趟：去程（倒數，下雨時路程變慢：rockmech_haul_rain）→ 電廠排隊 → 卸煤（每座電廠的消化係數 t/s）→
--   過磅結帳（照原價，跟火車一樣；扣每趟的運費 rockmech_haul_fee）→ 回程 → 空車停在地磅前面
--   （無人卡車接著沿路線開回裝載點）。
--   電廠可以有好幾座（名稱:單程秒:消化係數），越遠的路程越久，消化快慢也不同。
-- 車子在路上時：整份資料（get_staticdata）存在 mod storage 的 haul_trips，回來時照它重建。
-- 道路、地磅、控制箱、柵欄只蓋一次（mod storage haul_gate），小鎮的地形做好之後。

local cfg = rockmech.cfg
if not (cfg.career and cfg.haul_gate and cfg.plants and #cfg.plants > 0) then return end
local S = rockmech.S
local V = rockmech.vehicles
local storage = rockmech.collapse.storage
local O = rockmech.orders
local F = core.formspec_escape
local tons_of, pct, t1 = rockmech.tons_of, O.pct, O.t1
local function money_text(v) return rockmech.money_text and rockmech.money_text(v) or ("$%.0f"):format(v) end

local G = cfg.haul_gate                          -- 地磅中心 (x, z)
local ROAD_LEGAL = {truck = true}                -- 能上公路的車種
local SCALE_L, SCALE_W = 10, 4                   -- 地磅長（沿路）、寬 (m)
local ROAD_W = 8
local ON_SCALE = {along = SCALE_L / 2 + 2, lat = ROAD_W / 2}   -- 車身中心在這個範圍內算停在地磅上
local SCALE_BLOCK = "rockmech:weighbridge"
local KIOSK, BAR, SIGN = "rockmech:haul_kiosk", "rockmech:haul_bar", "rockmech:haul_sign"
local BUILT, TRIPS = "haul_gate", "haul_trips"
local FORM = "rockmech:haul_gate"

-- 出口的方向：往最近的地圖邊緣（沿 x 或 z）；lat：路的左手邊
local d = math.abs(G.x) >= math.abs(G.z) and {x = G.x >= 0 and 1 or -1, z = 0} or {x = 0, z = G.z >= 0 and 1 or -1}
local lat = {x = -d.z, z = d.x}
local function at(a, l) return {x = math.floor(G.x + d.x * a + lat.x * l + 0.5), z = math.floor(G.z + d.z * a + lat.z * l + 0.5)} end
local function local_of(p) local dx, dz = p.x - G.x, p.z - G.z; return dx * d.x + dz * d.z, dx * lat.x + dz * lat.z end
local function gate_y() return storage:get_int("haul_gate_y") end
local function clock(s) s = math.max(0, math.ceil(s)); return ("%d:%02d"):format(math.floor(s / 60), s % 60) end

---------------------------------------------------------------------------
-- 方塊：地磅、控制箱、柵欄、路牌
---------------------------------------------------------------------------

local function noop() end
core.register_node(SCALE_BLOCK, {
	description = S("Weighbridge"),
	tiles = {"[fill:16x16:#5a6066^[fill:16x1:0,0:#3a3e44^[fill:1x16:0,0:#3a3e44^[fill:3x1:3,5:#7a8088^[fill:3x1:10,11:#7a8088", "[fill:16x16:#6a6a66"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop, drop = "",
})
local function kiosk_click(pos, node, clicker)
	if clicker and clicker:is_player() then rockmech.haul_form(clicker) end
end
core.register_node(KIOSK, {
	description = S("Weighbridge office"),
	drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir",
	node_box = {type = "fixed", fixed = {{-0.4, -0.5, -0.4, 0.4, 1.2, 0.4}, {-0.5, 1.2, -0.5, 0.5, 1.35, 0.5}}},
	tiles = {"[fill:16x16:#d0d4d8", "[fill:16x16:#606468", "[fill:16x16:#e8ecef^[fill:10x6:3,3:#2a6a9a"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop, drop = "",
	on_rightclick = kiosk_click,
})
core.register_node(BAR, {
	description = S("Barrier"),
	drawtype = "nodebox", paramtype = "light", sunlight_propagates = true,
	node_box = {type = "fixed", fixed = {-0.5, 0.35, -0.08, 0.5, 0.55, 0.08}},
	tiles = {"[fill:16x16:#f0f0f0^[fill:4x16:0,0:#d02020^[fill:4x16:8,0:#d02020"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop, drop = "",
})
core.register_node(SIGN, {
	description = S("To the power plant"),
	drawtype = "nodebox", paramtype = "light", paramtype2 = "facedir", sunlight_propagates = true,
	node_box = {type = "fixed", fixed = {{-0.05, -0.5, -0.05, 0.05, 1.0, 0.05}, {-0.5, 0.9, -0.04, 0.5, 1.5, 0.04}}},
	tiles = {"[fill:16x16:#2a6a3a^[fill:10x2:3,7:#ffffff^[fill:2x6:11,5:#ffffff"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop, drop = "",
	on_rightclick = kiosk_click,
})

-- 地磅站一帶不能挖、不能蓋（碎石可以清）
local function gate_protected(pos, name)
	if storage:get_string(BUILT) ~= "1" then return false end
	local a, l = local_of(pos)
	if a < -SCALE_L / 2 - 8 or a > SCALE_L / 2 + 5 or math.abs(l) > ROAD_W / 2 + 3 then return false end
	local y = gate_y()
	if pos.y < y - 3 or pos.y > y + 6 then return false end
	if name and name ~= "" and core.check_player_privs(name, {rockmech = true}) then return false end
	if rockmech.rubble_level[core.get_node(pos).name] then return false end
	return true
end
local old_protected = core.is_protected
function core.is_protected(pos, name)
	if gate_protected(pos, name) then return true end
	return old_protected(pos, name)
end

---------------------------------------------------------------------------
-- 蓋：小鎮的路尾 → 地磅站的路，地磅、控制箱、柵欄、路牌
---------------------------------------------------------------------------

local building = false
local function build_gate()
	local RL = rockmech.roadlib
	if building or not RL or storage:get_string(BUILT) == "1" then return end
	building = true
	local gy = math.floor(cfg.surface_y + rockmech.stress.terrain_rise(cfg, G.x, G.z) + 0.5)
	-- 起點：小鎮最靠近地磅站的路點（沒有小鎮就是營地中心）
	local from = {x = 0, z = 0}
	local P = rockmech.village and rockmech.village.get()
	if P then
		local best = math.huge
		for _, r in ipairs(P.roads) do
			for _, q in ipairs(r.points) do
				local dd = (q[1] - G.x) ^ 2 + (q[2] - G.z) ^ 2
				if dd < best then best, from = dd, {x = q[1], z = q[2]} end
			end
		end
	end
	local entry = at(-SCALE_L / 2 - 14, 0)
	local box = {x1 = math.min(from.x, entry.x) - 120, z1 = math.min(from.z, entry.z) - 120,
		x2 = math.max(from.x, entry.x) + 120, z2 = math.max(from.z, entry.z) + 120}
	local path
	for _, mg in ipairs({0.08, 0.12, 0.18, 10}) do
		path = RL.route(from, entry, 6, function() return false end, {}, box, mg)
		if path then break end
	end
	if not path then
		core.log("warning", "[rockmech] 往電廠的道路：找不到路線")
		path = {from}
	end
	path[#path + 1] = entry
	path[#path + 1] = at(-SCALE_L / 2 - 4, 0)
	path[#path + 1] = at(SCALE_L / 2 + 4, 0)
	local line = RL.smooth_line(path)
	local ys = RL.profile(line, gy + 1)
	-- 經過池塘、河：路面不低於水面上一格（路堤填過去）
	local wl = (tonumber(core.settings:get("water_level")) or 1) + 1
	for i = 1, #ys do ys[i] = math.max(ys[i], wl) end
	-- 地磅前後一段整平在 gy + 1（路面 = 地磅面），再往前 25 m 漸變
	local flat_from
	for i, p in ipairs(line) do
		local a = local_of(p)
		if a >= -SCALE_L / 2 - 10 then flat_from = flat_from or i; ys[i] = gy + 1 end
	end
	if flat_from then
		for i = math.max(1, flat_from - 25), flat_from - 1 do
			local t = (i - (flat_from - 25)) / 25
			ys[i] = ys[i] + (gy + 1 - ys[i]) * t
		end
	end
	local cells = {}
	local V2 = rockmech.village
	RL.stamp(cells, line, ys, function(x, z) return V2 and V2.in_village and V2.in_village(x, z, 1) or false end, ROAD_W)
	rockmech.haul_debug.cells = cells
	RL.pave_cells(cells, "往電廠的道路", function()
		local lo, hi = at(-SCALE_L / 2 - 8, -ROAD_W), at(SCALE_L / 2 + 6, ROAD_W)
		core.emerge_area({x = math.min(lo.x, hi.x), y = gy - 4, z = math.min(lo.z, hi.z)}, {x = math.max(lo.x, hi.x), y = gy + 8, z = math.max(lo.z, hi.z)},
			function(_, _, rem)
				if rem > 0 then return end
				-- 地磅
				for a = -SCALE_L / 2, SCALE_L / 2 - 1 do for l = -SCALE_W / 2, SCALE_W / 2 - 1 do
					local c = at(a + 0.5, l + 0.5)
					core.set_node({x = c.x, y = gy, z = c.z}, {name = SCALE_BLOCK})
				end end
				-- 控制箱（地磅旁邊，面向路）、路牌（地磅前面的另一邊）、柵欄（地磅後面橫過整條路）
				local face = core.dir_to_facedir({x = -lat.x, y = 0, z = -lat.z})
				local k = at(0, SCALE_W / 2 + 2)
				core.set_node({x = k.x, y = gy + 1, z = k.z}, {name = KIOSK, param2 = face})
				local sg = at(-SCALE_L / 2 - 5, -(ROAD_W / 2 + 1))
				core.set_node({x = sg.x, y = gy + 1, z = sg.z}, {name = SIGN, param2 = core.dir_to_facedir({x = -d.x, y = 0, z = -d.z})})
				for l = -ROAD_W / 2, ROAD_W / 2 do
					local b = at(SCALE_L / 2 + 3, l)
					core.set_node({x = b.x, y = gy + 1, z = b.z}, {name = BAR})
				end
				storage:set_int("haul_gate_y", gy)
				storage:set_string(BUILT, "1")
				building = false
				core.log("action", ("[rockmech] 地磅站蓋好了（%d, %d, %d）"):format(G.x, gy, G.z))
			end)
	end)
end
-- 小鎮（或營地）蓋好之後才蓋
local bt = 0
core.register_globalstep(function(dtime)
	bt = bt + dtime
	if bt < 5 then return end
	bt = 0
	if storage:get_string(BUILT) == "1" or building then return end
	local ready = cfg.village and storage:get_string("village_ground") == "1" or (not cfg.village and storage:get_string("career_site") ~= "")
	if ready then build_gate() end
end)

---------------------------------------------------------------------------
-- 路上的車（mod storage）：{uid, kind, owner, data, plant, tons, coal, g, ore, phase = out | queue | unload | back | spawn, left, seq}
---------------------------------------------------------------------------

local trips
local function load_trips()
	if not trips then
		local s = storage:get_string(TRIPS)
		trips = s ~= "" and core.deserialize(s) or {}
	end
	return trips
end
local function save_trips() storage:set_string(TRIPS, core.serialize(trips or {})) end

local function label_of(t)
	local def = V.TYPES[t.kind]
	return (def and def.short or t.kind) .. " " .. (t.uid or ""):sub(-4)
end
local function veh_label(e) local def = V.TYPES[e.vkind]; return (def and def.short or e.vkind or "?") .. " " .. (e.uid or ""):sub(-4) end
local function tell(acc, msg) rockmech.notify_account(acc, S("[To the power plant] @1", msg)) end

-- 這台車能不能派：回傳 nil（可以）或原因
local function cannot(e)
	if not ROAD_LEGAL[e.vkind] then return S("Haul trucks cannot use public roads") end
	if e.driver or (e.pass and next(e.pass)) then return S("Get out first") end
	if e.object:get_attach() then return S("Unload it from the trailer first") end
	if e.op and (e.op.on or e.op.standby) then return S("Send the operator off first") end
	if V.load_total(e) <= 0 then return S("Empty") end
end

-- 派車：車的資料存起來、車從地圖上拿掉
local function dispatch(e, plant_i)
	local load = {load = e.load, loadq = e.loadq, loada = e.loada}
	local ore, lv, g = cfg.main_ore, 0, -1
	for _, o in ipairs(cfg.active_ores) do
		local l, og = O.load_grade(load, o)
		if og > g then ore, lv, g = o, l, og end
	end
	local plant = cfg.plants[plant_i] or cfg.plants[1]
	local t = {uid = e.uid, kind = e.vkind, owner = e.owner or "", data = e:get_staticdata(), plant = plant_i,
		tons = tons_of(lv), g = math.max(0, g), ore = ore.key, phase = "out", left = plant.trip}
	load_trips()
	trips[#trips + 1] = t
	save_trips()
	V.snapshot_clear(e.uid)
	e.object:remove()
	core.log("action", ("[rockmech] %s 開去%s：%.1f t、品位 %.0f%%"):format(label_of(t), plant.name, t.tons, t.g * 100))
	tell(t.owner, S("@1 left for @2 with @3", label_of(t), plant.name, t1(t.tons)))
end

-- 卸完：過磅結帳（照原價），扣運費
local function settle(t)
	local plant = cfg.plants[t.plant] or cfg.plants[1]
	local ore = cfg.ores[t.ore] or cfg.main_ore
	local acc = t.owner
	local gross, fee = rockmech.coal_value(t.tons, t.g, ore, acc)
	local trip_fee = cfg.haul_fee
	local net = math.floor(gross - fee - trip_fee + 0.5)
	if acc ~= "" then rockmech.add_money(acc, net) end
	if rockmech.power_add then rockmech.power_add(t.tons * t.g, "road") end      -- 電廠存煤（powerplant.lua）
	local rows = {
		{S("@1  grade @2", label_of(t), pct(t.g)), t1(t.tons), ("$%.0f × %.0f%%"):format(rockmech.ore_price(ore), rockmech.eff_ore_recovery(acc, ore) * 100),
			money_text(math.floor(gross - fee + 0.5)), 0x80ff80},
		{S("Haulage"), "", "", money_text(-trip_fee), 0xff8080},
		{S("Total"), t1(t.tons), "", money_text(net), net >= 0 and 0x80ff80 or 0xff8080},
	}
	for _, m in ipairs(rockmech.account_members(acc)) do
		core.sound_play("rockmech_coin", {to_player = m, gain = 0.8}, true)
		if rockmech.show_bill then rockmech.show_bill(m, plant.name, rows) end
	end
	tell(acc, S("@1 unloaded at @2, income @3", label_of(t), plant.name, money_text(net)))
end

-- 回程到了：空車停在地磅前面（往小鎮那邊），車頭朝小鎮；無人卡車接著開回裝載點
local function spawn_back(t)
	local gy = gate_y()
	t.phase = "spawn"
	local spots = {}
	for k = 0, 5 do spots[#spots + 1] = at(-SCALE_L / 2 - 6 - k * 9, -2) end
	local lo, hi = spots[#spots], at(-SCALE_L / 2, 0)
	core.emerge_area({x = math.min(lo.x, hi.x) - 4, y = gy - 2, z = math.min(lo.z, hi.z) - 4}, {x = math.max(lo.x, hi.x) + 4, y = gy + 6, z = math.max(lo.z, hi.z) + 4},
		function(_, _, rem)
			if rem > 0 then return end
			-- 停車格輪流用（附近沒人時車子會收進地圖，查不到，所以不能只看哪一格空著）；輪到的那格有車就往下一格
			local k0 = storage:get_int("haul_spot")
			storage:set_int("haul_spot", (k0 + 1) % #spots)
			local spot = spots[k0 % #spots + 1]
			for j = 0, #spots - 1 do
				local sp = spots[(k0 + j) % #spots + 1]
				local free = true
				for _, e in pairs(V.by_uid) do
					local p = e.object and e.object:get_pos()
					if p and (p.x - sp.x) ^ 2 + (p.z - sp.z) ^ 2 < 36 then free = false; break end
				end
				if free then spot = sp; break end
			end
			local data = core.deserialize(t.data) or {}
			data.load, data.loadq, data.loada = {}, {}, {}
			data.wall = os.time()
			data.uid = t.uid
			data.yaw = math.atan2(d.x, -d.z)          -- 車頭朝 −d（往小鎮）
			local a = data.ahs
			if type(a) == "table" and a.on and a.route and #a.route >= 2 then
				a.phase, a.wait_msg, a.target, a.yield = "to_load", nil, nil, nil
				a.idx = math.max(1, #a.route - 1)
			end
			V.snapshot_clear(t.uid)
			local obj = core.add_entity({x = spot.x, y = gy + 1.6, z = spot.z}, "rockmech:" .. t.kind, core.serialize(data))
			load_trips()
			for i, x in ipairs(trips) do
				if x == t then table.remove(trips, i); break end
			end
			save_trips()
			-- 附近沒人時 add_entity 可能回傳 nil：車子照樣存進地圖，有人走近就出現
			tell(t.owner, S("@1 is back at the weighbridge", label_of(t)))
			core.log("action", ("[rockmech] %s 回到地磅站（%d, %d）%s"):format(label_of(t), spot.x, spot.z, obj and "" or "（區塊沒在跑，先存進地圖）"))
		end)
end

-- 每秒：去程、回程倒數（下雨變慢）、電廠排隊、卸煤
local function rain_factor() return 1 + cfg.haul_rain * (rockmech.rain_level and rockmech.rain_level() or 0) end
local function step_trips(dt)
	load_trips()
	if #trips == 0 then return end
	local busy = {}
	for _, t in ipairs(trips) do if t.phase == "unload" then busy[t.plant] = true end end
	local seq = storage:get_int("haul_seq")
	local changed = false
	for _, t in ipairs(trips) do
		local plant = cfg.plants[t.plant] or cfg.plants[1]
		if t.phase == "out" or t.phase == "back" then
			t.left = t.left - dt / rain_factor()
			if t.left <= 0 then
				if t.phase == "out" then
					seq = seq + 1
					t.phase, t.seq = "queue", seq
				else
					spawn_back(t)
				end
				changed = true
			end
		elseif t.phase == "unload" then
			t.left = t.left - dt
			if t.left <= 0 then
				settle(t)
				t.phase, t.left = "back", plant.trip
				busy[t.plant] = nil
				changed = true
			end
		end
	end
	-- 排隊：每座電廠一次卸一台，先到先卸
	for pi, plant in ipairs(cfg.plants) do
		if not busy[pi] then
			local first
			for _, t in ipairs(trips) do
				if t.phase == "queue" and t.plant == pi and (not first or t.seq < first.seq) then first = t end
			end
			if first then
				first.phase, first.left = "unload", math.max(5, first.tons / plant.rate)
				changed = true
			end
		end
	end
	storage:set_int("haul_seq", seq)
	save_trips()
	return changed
end

-- 無人卡車開到地磅（AHS 的 gate 階段）：自己派車；不能上公路的就停著顯示原因
local function auto_dispatch()
	for _, e in pairs(V.by_uid) do
		local a = e.ahs
		local p = a and a.on and a.phase == "gate" and e.object:get_pos()
		if p then
			local al, ll = local_of(p)
			if math.abs(al) <= ON_SCALE.along + 4 and math.abs(ll) <= ON_SCALE.lat + 2 then
				local why = cannot(e)
				if why then
					if a.wait_msg ~= why then a.wait_msg = why; V.refresh(e) end
				else
					dispatch(e, a.plant or 1)
				end
			end
		end
	end
end

local tick = 0
core.register_globalstep(function(dtime)
	tick = tick + dtime
	if tick < 1 then return end
	local dt = tick
	tick = 0
	if storage:get_string(BUILT) ~= "1" then return end
	step_trips(dt)
	auto_dispatch()
end)

-- 無人卡車：傾倒點在地磅站（vehicle_ahs.lua 開到路線終點時問這個）
function rockmech.haul_gate_at(p)
	if not p or storage:get_string(BUILT) ~= "1" then return false end
	local al, ll = local_of(p)
	return math.abs(al) <= ON_SCALE.along + 4 and math.abs(ll) <= ON_SCALE.lat + 2
end

---------------------------------------------------------------------------
-- 控制箱的視窗：電廠、地磅上的車（派車）、路上的車
---------------------------------------------------------------------------

local open_for = {}           -- 玩家 → {uids = {按鈕序號 → 車號}, plant = 選的電廠}
local function on_scale(acc)
	local out = {}
	for _, e in pairs(V.by_uid) do
		local p = e.object and e.object:get_pos()
		local def = e.vkind and V.TYPES[e.vkind]
		if p and def and def.cap then
			local al, ll = local_of(p)
			if math.abs(al) <= ON_SCALE.along and math.abs(ll) <= ON_SCALE.lat and (e.owner == acc or e.owner == "" or not e.owner) then
				out[#out + 1] = e
			end
		end
	end
	return out
end
local function phase_text(t)
	local plant = cfg.plants[t.plant] or cfg.plants[1]
	if t.phase == "out" then return S("To @1  @2", plant.name, clock(t.left * rain_factor())) end
	if t.phase == "queue" then
		local ahead = 0
		for _, x in ipairs(trips) do
			if x.plant == t.plant and (x.phase == "unload" or (x.phase == "queue" and x.seq < t.seq)) then ahead = ahead + 1 end
		end
		return S("Queuing at @1 (@2 ahead)", plant.name, ahead)
	end
	if t.phase == "unload" then return S("Unloading  @1", clock(t.left)) end
	if t.phase == "back" then return S("Coming back  @1", clock(t.left * rain_factor())) end
	return S("Arriving")
end
local function form(name)
	local acc = rockmech.account_of(name)
	local o = open_for[name] or {}
	open_for[name] = o
	o.plant = o.plant or 1
	o.uids = {}
	local out = {"formspec_version[6]size[12,10]", ("label[0.5,0.6;%s]"):format(F(S("Weighbridge  (to the power plant)")))}
	local y = 1.3
	for i, p in ipairs(cfg.plants) do
		out[#out + 1] = ("label[0.5,%g;%s]"):format(y, F(S("@1: @2 one way, unloads @3 t/s", p.name, clock(p.trip), ("%g"):format(p.rate))))
		y = y + 0.45
	end
	local rf = rain_factor()
	if rf > 1.01 then
		out[#out + 1] = ("label[0.5,%g;%s]"):format(y, F(S("Raining: the trip takes @1% longer", ("%.0f"):format((rf - 1) * 100))))
		y = y + 0.45
	end
	out[#out + 1] = ("label[0.5,%g;%s]"):format(y, F(S("Haulage per trip @1", money_text(cfg.haul_fee))))
	y = y + 0.7
	if #cfg.plants > 1 then
		local names = {}
		for i, p in ipairs(cfg.plants) do names[i] = F(p.name) end
		out[#out + 1] = ("label[0.5,%g;%s]"):format(y + 0.3, F(S("Send to")))
		out[#out + 1] = ("dropdown[2.5,%g;4,0.7;plant;%s;%d;true]"):format(y, table.concat(names, ","), o.plant)
		y = y + 1
	end
	out[#out + 1] = ("label[0.5,%g;%s]"):format(y, F(S("On the weighbridge")))
	y = y + 0.5
	local list = on_scale(acc)
	if #list == 0 then
		out[#out + 1] = ("label[0.8,%g;%s]"):format(y, F(S("No truck. Park on the weighbridge and get out")))
		y = y + 0.5
	end
	for i, e in ipairs(list) do
		local tons = tons_of(V.load_total(e))
		out[#out + 1] = ("label[0.8,%g;%s]"):format(y + 0.3, F(veh_label(e) .. "  " .. t1(tons)))
		local why = cannot(e)
		if why then
			out[#out + 1] = ("label[6.5,%g;%s]"):format(y + 0.3, F(why))
		else
			o.uids[i] = e.uid
			out[#out + 1] = ("button[8,%g;3.5,0.7;go_%d;%s]"):format(y, i, F(S("Send")))
		end
		y = y + 0.8
	end
	y = y + 0.3
	out[#out + 1] = ("label[0.5,%g;%s]"):format(y, F(S("On the road")))
	y = y + 0.5
	local n = 0
	for _, t in ipairs(load_trips()) do
		if t.owner == acc then
			out[#out + 1] = ("label[0.8,%g;%s]"):format(y, F(label_of(t) .. "  " .. t1(t.tons) .. "  " .. phase_text(t)))
			y = y + 0.45
			n = n + 1
		end
	end
	if n == 0 then out[#out + 1] = ("label[0.8,%g;%s]"):format(y, F(S("None"))) end
	return table.concat(out)
end
function rockmech.haul_form(player)
	local name = player:get_player_name()
	core.show_formspec(name, FORM, form(name))
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	local name = player:get_player_name()
	local o = open_for[name]
	if fields.quit then open_for[name] = nil; return true end
	if not o then return true end
	if fields.plant then o.plant = tonumber(fields.plant) or o.plant end
	for k in pairs(fields) do
		local i = tonumber(k:match("^go_(%d+)$") or "")
		local uid = i and o.uids[i]
		local e = uid and V.by_uid[uid]
		if e and e.object:get_pos() then
			local p = e.object:get_pos()
			local al, ll = local_of(p)
			local why = cannot(e)
			if not (math.abs(al) <= ON_SCALE.along and math.abs(ll) <= ON_SCALE.lat) then why = S("Not on the weighbridge") end
			if not why and not rockmech.owner_ok(e.owner or "", name) then why = "" end
			if why then
				if why ~= "" then rockmech.notify(name, S("[To the power plant] @1", why)) end
			else
				dispatch(e, o.plant)
			end
		end
	end
	core.show_formspec(name, FORM, form(name))
	return true
end)

rockmech.haul_debug = {build = build_gate, trips = load_trips, dispatch = dispatch, step = step_trips, G = G, d = d, at = at, gate_y = gate_y}
