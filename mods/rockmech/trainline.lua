-- rockmech/trainline.lua
-- 單機地圖的鐵路（cfg.railway）：線形在 railline.lua，地圖產生時就挖好路塹、路堤、隧道、鋪好鋼軌（mapgen.lua）。
-- 列車從北邊的隧道開出來，沿著曲線開到裝車點（黃黑標示柱，每節一根，在小鎮那一側）停好；
--   N 節都裝滿就往南開進隧道，下一班再從北邊來。按「現在出發」帶著已經裝的先走；晚上（20:00）還沒滿也帶著走。
--   上班時間 HOURS 一直有車，晚上沒車。
-- 出發時每節結帳：煤噸 × 回收率 × 當天煤價 − 廢石噸 × 廢石處理費（跟收煤站同一套，但照原價；收煤站只付 coal_yard_ratio）。
-- 鐵路、道床、隧道是路權：不能挖、不能蓋（碎石可以清）；路塹的邊坡可以挖，挖垮了碎石掉到軌道上會擋住火車。
-- 列車是畫面：狀態存在 mod storage，附近有人才放出來。
-- 教學地圖的火車是 train.lua（直線、分組礦帶），兩個不會同時開。

local S = rockmech.S
local cfg = rockmech.cfg
if not (cfg.railway and cfg.career and not cfg.teacher) then return end
local R = dofile(rockmech.modpath .. "/railline.lua")
local V = rockmech.vehicles
local NLEV = V.NLEV
local storage = rockmech.collapse.storage
local O = rockmech.orders
local F = core.formspec_escape
local tons_of, pct, t1, money_text, tell = O.tons_of, O.pct, O.t1, O.money_text, O.tell

local N, L_LOCO, PITCH = R.N, R.L_LOCO, R.PITCH
local CAP_M3 = 8                                 -- 每節 m³
local HOURS = {7, 20}                            -- 上班時間
local V_MAX, ACC = 12, 1.2                       -- 最高速度 (m/s)、加減速 (m/s²)
local NEAR = 110                                 -- 列車離玩家多近才放出畫面
local KIND = "wagon"
local ENAME = "rockmech:" .. KIND
local LOCO = "rockmech:train_loco"
local BED, LINING, POST = "rockmech:railbed", "rockmech:tunnel_lining", "rockmech:rail_post"
local SEG = "rockmech:rail_seg_"
local KEY = "trainline"

---------------------------------------------------------------------------
-- 方塊：道床、隧道襯砌、鋼軌（模型，8 種橫向偏移 × degrotate 轉角）、裝車點標示柱
---------------------------------------------------------------------------

local function noop() end
local BAL = "[fill:16x16:#7a746c^[fill:2x2:3,3:#5e5850^[fill:2x2:10,6:#8e887e^[fill:2x2:6,11:#5e5850^[fill:1x1:13,13:#9a948a"
core.register_node(BED, {
	description = S("Track ballast"), tiles = {BAL},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})
core.register_node(LINING, {
	description = S("Tunnel lining"),
	tiles = {"[fill:16x16:#9c988f^[fill:16x1:0,7:#86827a^[fill:1x8:7,0:#86827a^[fill:1x8:15,8:#86827a"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})
local RAIL_SET = {}
for k = 0, 7 do
	core.register_node(SEG .. k, {
		description = S("Railway track"),
		drawtype = "mesh", mesh = "rockmech_rail_o" .. k .. ".obj",
		tiles = {{name = "[fill:16x16:#8e949a^[fill:16x4:0,0:#b4bac0", backface_culling = false},
			{name = "[fill:16x16:#5a4030^[fill:16x2:0,7:#4a3326", backface_culling = false}},
		paramtype = "light", paramtype2 = "degrotate", sunlight_propagates = true,
		walkable = false, pointable = false, diggable = false, buildable_to = false,
		selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.3, 0.5}},
		is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop, drop = "",
	})
	RAIL_SET[SEG .. k] = true
end
core.register_node(POST, {
	description = S("Loading point"),
	drawtype = "nodebox", paramtype = "light", sunlight_propagates = true,
	node_box = {type = "fixed", fixed = {{-0.12, -0.5, -0.12, 0.12, 1.3, 0.12}, {-0.35, 1.0, -0.06, 0.35, 1.45, 0.06}}},
	tiles = {"[fill:16x16:#e0b428^[fill:16x4:0,0:#202020^[fill:16x4:0,8:#202020"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
	on_rightclick = function(pos, node, clicker)
		if clicker and clicker:is_player() and rockmech.train_form then
			rockmech.train_form(rockmech.account_of(clicker:get_player_name()), clicker)
		end
	end,
})

-- 線形（第一次用到才算：地形函數要等 stress 都載入）
local line
local function L()
	line = line or R.for_cfg(cfg, rockmech.stress)
	return line
end
local function s_start() return 6 end                             -- 北端隧道裡
local function s_end() return L().n - 2 end                         -- 南端隧道裡
-- 弧長 s 的位置、yaw（y：軌面 = 道床頂）
local function at(s)
	local l = L()
	local x, z, y, yaw = l:at(s)
	return x, z, l.sy + y + 0.5, yaw
end

---------------------------------------------------------------------------
-- 路權：道床、鋼軌、隧道（中線兩側 FW + 襯砌，軌面下 8 m 到上 7 m）不能挖、不能放；碎石可以清
---------------------------------------------------------------------------

local function rail_protected(pos, name)
	local l = L()
	if not l then return false end
	local z = math.floor(pos.z + 0.5)
	local d, row = l:lateral(pos.x, z)
	if not d or math.abs(d) > R.FW + R.LINING + 0.5 then return false end
	local yr = l.sy + row.yr
	if pos.y < yr - 8 or pos.y > yr + R.H + 1 then return false end
	if name and name ~= "" and core.check_player_privs(name, {rockmech = true}) then return false end
	if rockmech.rubble_level[core.get_node(pos).name] then return false end
	return true
end
rockmech.rail_protected = rail_protected
local old_protected = core.is_protected
function core.is_protected(pos, name)
	if rail_protected(pos, name) then return true end
	return old_protected(pos, name)
end
local last_warn = {}
core.register_on_protection_violation(function(pos, name)
	if not rail_protected(pos, name) then return end
	local now = core.get_us_time()
	if last_warn[name] and now - last_warn[name] < 3e6 then return end
	last_warn[name] = now
	rockmech.notify(name, S("Railway: nothing can be built or dug here"))
end)

---------------------------------------------------------------------------
-- 車廂、機車
---------------------------------------------------------------------------

do
	local box_tex = V.box_tex
	local c = "#6a3a24"
	local wagon = {desc = S("Rail wagon"), short = S("Rail wagon"), color = c, cap = CAP_M3 * NLEV, speed = 0,
		top_speed = 0, accel = 0, tire = 1.0, no_ahs = true, no_dump_snap = true,
		half = 1.5, lat = {-1, 0, 1}, eye_up = 1.9, eye_fwd = 1.6, eye_side = -0.55, rear = 3.5, mirror = {x = 1.35, y = 1.3, z = 1.2},
		seat = {x = 0, y = 0.1, z = 0}, tilt = {front = 3, rear = -3, side_z = -1.6, side_x = 1.1},
		max_grade = math.rad(17), item_desc = ""}
	local r = {}
	r[#r + 1] = {2, 10, 28, 12, c}; V.icon_wheel(r, 8, 26, 3); V.icon_wheel(r, 24, 26, 3)
	wagon.inv_image = V.icon(r)
	local wheel = {V.TREAD, V.TREAD, V.WHEEL, V.WHEEL, V.TREAD, V.TREAD}
	local body = {{pos = {x = 0, y = -0.75, z = 0}, size = {x = 2.0, y = 0.3, z = 7.0}, tex = box_tex("#2a2a2a")}}
	for _, z in ipairs({-2.6, -1.8, 1.8, 2.6}) do
		for _, x in ipairs({-0.75, 0.75}) do
			body[#body + 1] = {pos = {x = x, y = -1.15, z = z}, size = {x = 0.2, y = 0.7, z = 0.7}, tex = wheel}
		end
	end
	V.hauler(wagon, {
		hinge = {x = 0, y = -0.6, z = -3.4}, size = {x = 2.8, y = 1.6, z = 6.8}, body = body,
		floor_tex = "[fill:16x16:#3a2216",
		side_tex = ("[fill:16x16:%s^[fill:16x2:0,0:#4a2a18^[fill:1x16:3,0:#4a2a18^[fill:1x16:8,0:#4a2a18^[fill:1x16:12,0:#4a2a18"):format(c),
		overlap_lat = {-1.25, 0, 1.25}, overlap_dy = {1.2, 2.2}, aim_top = 1.0,
	})
	local refresh = wagon.refresh
	wagon.refresh = function(self)
		refresh(self)
		V.nametag(self, S("Wagon @1  @2 / @3", self.train_i or "?", t1(tons_of(V.load_total(self))), t1(tons_of(CAP_M3 * NLEV))),
			V.load_total(self) >= wagon.cap and "#ff8060" or "#ffe0a0")
	end
	wagon.rightclick = function(self, clicker)
		if rockmech.train_form and clicker and clicker:is_player() then
			rockmech.train_form(rockmech.account_of(clicker:get_player_name()), clicker)
		end
		return true
	end
	local on_load = wagon.on_load
	wagon.on_load = function(self, data)
		if on_load then on_load(self, data) end
		self.object:set_properties({static_save = false})
	end
	V.register(KIND, wagon)
	core.override_item(ENAME .. "_item", {groups = {not_in_creative_inventory = 1}})
end

local LB = "#28466e"
local train = nil             -- 畫面：{loco = obj, wagons = {entity...}}
core.register_entity(LOCO, {
	initial_properties = {
		visual = "cube", visual_size = {x = 2.8, y = 3.2, z = L_LOCO}, physical = false, static_save = false,
		collisionbox = {-1.4, -1.6, -1.4, 1.4, 1.6, 1.4}, selectionbox = {-1.4, -1.6, -4.5, 1.4, 1.6, 4.5, rotate = true},
		textures = {
			("[fill:16x16:%s^[fill:4x4:6,6:#1a2a40"):format(LB),
			"[fill:16x16:#202020",
			("[fill:16x16:%s^[fill:16x2:0,10:#e0b428^[fill:3x3:12,2:#9fd0ff^[fill:16x2:0,14:#202020"):format(LB),
			("[fill:16x16:%s^[fill:16x2:0,10:#e0b428^[fill:3x3:1,2:#9fd0ff^[fill:16x2:0,14:#202020"):format(LB),
			("[fill:16x16:%s^[fill:12x4:2,2:#9fd0ff^[fill:2x2:2,11:#fff4b0^[fill:2x2:12,11:#fff4b0^[fill:16x2:0,8:#e0b428"):format(LB),
			("[fill:16x16:%s^[fill:16x2:0,10:#e0b428"):format(LB),
		},
		nametag = S("Freight train"), nametag_color = "#e0e0ff",
	},
	on_activate = function(self) self.object:set_armor_groups({immortal = 1}) end,
	on_punch = function() return true end,
	on_rightclick = function(self, clicker)
		if rockmech.train_form and clicker and clicker:is_player() then
			rockmech.train_form(rockmech.account_of(clicker:get_player_name()), clicker)
		end
	end,
	on_step = function(self)
		if not (train and train.loco == self.object) then self.object:remove() end
	end,
})

---------------------------------------------------------------------------
-- 狀態（mod storage）：{phase = "in" | "load" | "leaving", head = 車頭弧長, loads = {每節的料}}
---------------------------------------------------------------------------

local st
local function load_state()
	local s = storage:get_string(KEY)
	st = s ~= "" and core.deserialize(s) or nil
end
local function save() storage:set_string(KEY, st and core.serialize(st) or "") end
load_state()

local function uid_of(i) return ("trainline-%d"):format(i) end
local function sync()
	if not (train and st) then return end
	for i, e in ipairs(train.wagons) do
		if e.object:get_pos() then st.loads[i] = {load = table.copy(e.load), loadq = table.copy(e.loadq), loada = table.copy(e.loada or {})} end
	end
end
local function despawn()
	if not train then return end
	sync()
	if train.loco and train.loco:get_pos() then train.loco:remove() end
	for i, e in ipairs(train.wagons) do
		V.registry_drop(uid_of(i)); V.snapshot_clear(uid_of(i))
		if e.object:get_pos() then e.object:remove() end
	end
	train = nil
	if st then save() end
end

local WAGON_DY = 1.5          -- 車廂中心比軌面高（跟 train.lua 一樣）
local function place()
	if not (train and st) then return end
	local h = st.head
	if train.loco and train.loco:get_pos() then
		local x, z, y, yaw = at(h - L_LOCO / 2)
		train.loco:move_to({x = x, y = y + WAGON_DY + 0.1, z = z}, true)
		train.loco:set_yaw(yaw)
	end
	for i, e in ipairs(train.wagons) do
		if e.object:get_pos() then
			local x, z, y, yaw = at(R.wagon_s(L(), h, i))
			e.object:move_to({x = x, y = y + WAGON_DY, z = z}, true)
			e.object:set_yaw(yaw)
		end
	end
end

local function spawn()
	train = {wagons = {}}
	local x, z, y, yaw = at(st.head - L_LOCO / 2)
	local loco = core.add_entity({x = x, y = y + WAGON_DY + 0.1, z = z}, LOCO)
	if loco then loco:set_yaw(yaw); train.loco = loco end
	for i = 1, N do
		local ld = st.loads[i] or {}
		local wx, wz, wy, wyaw = at(R.wagon_s(L(), st.head, i))
		local data = core.serialize({uid = uid_of(i), owner = st.acc or "", load = ld.load or {}, loadq = ld.loadq or {}, loada = ld.loada or {},
			wall = os.time() + 1, yaw = wyaw})
		local obj = core.add_entity({x = wx, y = wy + WAGON_DY, z = wz}, ENAME, data)
		local e = obj and obj:get_luaentity()
		if e then
			obj:set_yaw(wyaw)
			e.train_i = i
			obj:set_acceleration({x = 0, y = 0, z = 0})
			V.refresh(e)
			train.wagons[#train.wagons + 1] = e
		end
	end
end

-- 給 orders.lua：卡車倒料對準車廂
function rockmech.train_wagons()
	local out = {}
	if train then for _, e in ipairs(train.wagons) do if e.object:get_pos() then out[#out + 1] = e end end end
	return out
end
function rockmech.train_enabled() return true end

local function hour() return (core.get_timeofday() or 0.5) * 24 end
local function in_hours() local h = hour(); return h >= HOURS[1] and h < HOURS[2] end
local function clock_text() local h = hour(); return ("%02d:%02d"):format(math.floor(h), math.floor((h % 1) * 60)) end

local function wagon_total(i)
	local t = 0
	for _, lv in pairs((st.loads[i] or {}).load or {}) do t = t + lv end
	return t
end
local function all_full()
	for i = 1, N do if wagon_total(i) < CAP_M3 * NLEV then return false end end
	return true
end
local function train_total()
	local t = 0
	for i = 1, N do t = t + wagon_total(i) end
	return t
end

-- 單機：錢記在單機帳戶；多人競爭：記在離裝車點最近的玩家
local function payer()
	local l = L()
	local px, pz, py = at(l.s_load)
	local best, bd
	for _, p in ipairs(core.get_connected_players()) do
		local d = vector.distance(p:get_pos(), {x = px, y = py, z = pz})
		if not bd or d < bd then best, bd = p:get_player_name(), d end
	end
	return best and rockmech.account_of(best)
end

local function depart()
	if not st then return end
	sync()
	local acc = payer()
	local rows, net, total_t, coal_t = {}, 0, 0, 0
	for i = 1, N do
		local ld = st.loads[i] or {}
		local wagon = {load = ld.load or {}, loadq = ld.loadq or {}, loada = ld.loada or {}}
		local ore, lv, g = cfg.main_ore, 0, -1
		for _, o in ipairs(cfg.active_ores) do
			local l, og = O.load_grade(wagon, o)
			if og > g then ore, lv, g = o, l, og end
		end
		local price = rockmech.ore_price(ore)
		local rec = rockmech.eff_ore_recovery(acc, ore)
		if lv > 0 then
			local t = tons_of(lv)
			local gross, fee = rockmech.coal_value(t, g, ore, acc)      -- economy.lua，跟收煤站同一條（照原價）
			local m = math.floor(gross - fee + 0.5)
			net, total_t, coal_t = net + m, total_t + t, coal_t + t * g
			rows[#rows + 1] = {S("Wagon @1  grade @2", i, pct(g)), t1(t), ("$%.0f × %.0f%%"):format(price, rec * 100),
				money_text(m), m >= 0 and 0x80ff80 or 0xff8080}
		end
	end
	if #rows > 0 and acc then
		rockmech.add_money(acc, net)
		if rockmech.power_add then rockmech.power_add(coal_t, "train") end     -- 火車的煤進電廠存煤（powerplant.lua）
		rows[#rows + 1] = {S("Total"), t1(total_t), "", money_text(net), net >= 0 and 0x80ff80 or 0xff8080}
		for _, m in ipairs(rockmech.account_members(acc)) do
			core.sound_play("rockmech_coin", {to_player = m, gain = 0.8}, true)
			if rockmech.show_bill then rockmech.show_bill(m, S("Train shipment"), rows) end
		end
		tell(acc, S("The train left with @1, income @2", t1(total_t), money_text(net)))
	elseif acc then
		tell(acc, S("The train left empty"))
	end
	st.loads = {}
	if train then for _, e in ipairs(train.wagons) do e.load, e.loadq, e.loada = {}, {}, {}; V.refresh(e) end end
	st.phase = "leaving"
	save()
end

---------------------------------------------------------------------------
-- 每秒：班次、畫面放出／收掉；每 0.1 秒：移動
---------------------------------------------------------------------------

local function player_near()
	local x, z, y = at(st.head - 20)
	local lx, lz, ly = at(L().s_load)
	for _, p in ipairs(core.get_connected_players()) do
		local pp = p:get_pos()
		if vector.distance(pp, {x = x, y = y, z = z}) < NEAR or vector.distance(pp, {x = lx, y = ly, z = lz}) < NEAR then return true end
	end
	return false
end

local function step()
	if not L() or (#core.get_connected_players() == 0 and not rockmech.trainline_force) then return end
	if not st then
		if not in_hours() then return end
		st = {phase = "in", head = s_start(), loads = {}}
		save()
	end
	local x, z, y = at(st.head - 20)
	local active = (rockmech.trainline_force or player_near()) and core.get_node({x = x, y = y, z = z}).name ~= "ignore"
	if active and not train then spawn()
	elseif not active and train then despawn() end
	sync()
	if st.phase == "load" and (all_full() or not in_hours()) then depart() end
	-- 畫面不在：直接跳到目標
	if not train then
		if st.phase == "in" then st.head = L().s_stop; st.phase = "load"
		elseif st.phase == "leaving" then st.head = s_end() end
	end
	if st.phase == "leaving" and st.head >= s_end() - 0.01 then
		despawn()
		st = nil
		save()
		if in_hours() then st = {phase = "in", head = s_start(), loads = {}}; save() end
		return
	end
	save()
end
local tick = 0
core.register_globalstep(function(dtime)
	tick = tick + dtime
	if tick < 1 then return end
	tick = 0
	step()
end)

local BLOCK_WARN = 10
local mt = 0
core.register_globalstep(function(dtime)
	mt = mt + dtime
	if mt < 0.1 then return end
	local dt = mt
	mt = 0
	if not (train and st) then return end
	local target, speed
	local stop = L().s_stop
	if st.phase == "in" then
		target = stop
		speed = math.max(1, math.min(V_MAX, math.sqrt(2 * ACC * math.max(0, target - st.head))))
	elseif st.phase == "leaving" then
		target = s_end()
		speed = math.max(1.5, math.min(V_MAX, math.sqrt(2 * ACC * math.max(0, st.head - stop))))
	end
	if target and st.head < target - 0.01 then
		-- 車頭前面 3 m 的軌道上有東西（碎石…）：停下來
		local blocked
		for ds = 0.5, 3, 0.5 do
			-- 用那一排實際的軌面高（道床一格一格升降，平滑的縱斷面會差半格，會把高一階的道碴當成障礙）
			local x, z = at(st.head + ds)
			local zr = math.floor(z + 0.5)
			local yr = R.rail_y(L(), zr)
			for dy = 1, 2 do
				local n = yr and core.get_node({x = math.floor(x + 0.5), y = yr + dy, z = zr}).name or "ignore"
				if not RAIL_SET[n] and not rockmech.air_like(n) and n ~= "ignore" and n ~= POST then blocked = n; break end
			end
			if blocked then break end
		end
		if blocked then
			local now = core.get_gametime()
			if not st.warned or now - st.warned > BLOCK_WARN then
				st.warned = now
				local acc = payer()
				if acc then tell(acc, S("The track is blocked in front of the train. Clear it")) end
			end
		else
			st.head = math.min(target, st.head + speed * dt)
			place()
		end
	elseif target and st.phase == "in" then
		st.phase = "load"
		save()
	end
end)

---------------------------------------------------------------------------
-- 視窗
---------------------------------------------------------------------------

local FORM = "rockmech:trainline"
function rockmech.train_status()
	if not st then
		if in_hours() then return S("Train: arriving") end
		return S("Train: no trains at night; the first one comes at @1:00", ("%02d"):format(HOURS[1]))
	end
	if st.phase == "load" then
		return S("Train: loading @1 / @2, leaves when all wagons are full", t1(tons_of(train_total())), t1(tons_of(N * CAP_M3 * NLEV)))
	end
	if st.phase == "leaving" then return S("Train: leaving") end
	return S("Train: arriving")
end
local function form()
	local out = {"formspec_version[6]size[9,6.4]", ("label[0.5,0.6;%s]"):format(F(S("Freight train") .. "   " .. clock_text())),
		("label[0.5,1.2;%s]"):format(F(rockmech.train_status()))}
	if st then
		for i = 1, N do
			out[#out + 1] = ("label[0.5,%g;%s]"):format(1.6 + i * 0.5, F(S("Wagon @1  @2 / @3", i, t1(tons_of(wagon_total(i))),
				t1(tons_of(CAP_M3 * NLEV)))))
		end
		if st.phase == "load" then
			out[#out + 1] = ("button[4.7,5.2;3.8,0.8;go;%s]"):format(F(S("Depart now")))
		end
	end
	return table.concat(out)
end
function rockmech.train_form(acc, clicker)
	if not (clicker and clicker:is_player()) then return end
	core.show_formspec(clicker:get_player_name(), FORM, form())
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	if fields.go and st and st.phase == "load" then depart() end
	if not fields.quit then core.close_formspec(player:get_player_name(), FORM) end
	return true
end)

rockmech.trainline_debug = {L = L, state = function() return st end, train = function() return train end, at = at, depart = depart}
