-- rockmech/train.lua
-- 火車出貨（原型，只在教學地圖：分組礦帶）：營地南邊的走廊鋪一條東西向的鐵路（每組礦帶一段，連起來貫穿全圖）。
-- 火車是賣礦的管道（不是訂單）：上班時間（HOURS，08:00–20:00）一直有車，晚上沒車 → 學生要自己堆料（倉儲）。
--   一列 N 節車廂（每節 CAP_M3 m³）從礦帶西邊開進來，停在裝車點（黃黑標示柱，每節一根）不動；
--   N 節都裝滿就開走，下一班馬上從西邊開進來。按「現在出發」帶著已經裝的先走；20:00 還沒滿就帶著已經裝的開走。
--   裝車：裝車料斗（放料臂 10 m）、怪手直接裝、卡車在車廂旁邊倒（orders.lua 的倒料對準）。
--   時鐘：教學地圖的天色跟交易日走：開盤 06:00，一個交易日 24 小時，晚上會暗（不管 time_speed 設多少；不改設定檔）。
--   出發時每節結帳（跟收煤站同一套，但照原價）：煤噸 × 回收率 × 當天煤價 − 廢石噸 × 廢石處理費。
--   收煤站只付 cfg.coal_yard_ratio（坑口價），火車照原價，但要配合班次、湊滿一列。
-- 鐵路和兩側路肩是路權（camp.lua 的保護）：不能挖、不能蓋、炸不壞，往下 10 m 也不能挖；卡車可以直接開過去。
--   碎石滾到軌道上會擋住火車（停下來等清），要自己清。
-- 列車是畫面：狀態（位置、每節的料）存在 mod storage，附近有人才放出來，沒人就收掉（不存進地圖）。

local S = rockmech.S
local cfg = rockmech.cfg
local V = rockmech.vehicles
local NLEV = V.NLEV
local storage = rockmech.collapse.storage
local O = rockmech.orders
local F = core.formspec_escape

local lanes = cfg.coal_seam and cfg.coal_seam.lane_w
if not (cfg.career and cfg.teacher and lanes and O) then
	function rockmech.train_enabled() return false end
	return
end

local RAIL_Z = -80                               -- 鐵路中心線的 z
local LOAD_REL = -26                             -- 裝車點＝第 1 節（相對營地中心 x0）：收料區（x0−17..−11）的西邊，4 節的北邊都是空地
local LINE = {x1 = -(cfg.career_camp_dx or 0) - lanes / 2, x2 = -(cfg.career_camp_dx or 0) + lanes / 2 - 1}   -- 這一組礦帶的那一段
local N = 4                                      -- 車廂數
local CAP_M3 = 8                                 -- 每節 m³
local L_LOCO, PITCH = 9, 7.6                     -- 機車長、車廂間距（中心到中心）
local HOURS = {8, 20}                            -- 上班時間：這段時間一直有車
local V_MAX, ACC = 12, 1.2                       -- 最高速度 (m/s ≈ 43 km/h)、加減速 (m/s²)：進站減速停好、出站慢慢加速
local NEAR = 96                                  -- 離裝車點多近有人才放出列車
local YAW = -math.pi / 2                         -- 車頭朝 +x
local RAIL, BALLAST, MARK = "rockmech:rail", "rockmech:rail_ballast", "rockmech:rail_marker"
local KIND = "wagon"
local ENAME = "rockmech:" .. KIND
local LOCO = "rockmech:train_loco"
local tons_of, pct, t1, money_text, tell = O.tons_of, O.pct, O.t1, O.money_text, O.tell

function rockmech.train_enabled() return true end

local function site_of(acc) return O.site_of(acc) end
local function rail_y() return O.sy() + 1 end                -- 軌道方塊的 y
local function load_x(x0) return x0 + LOAD_REL + 0.5 end
local function stop_head(x0) return load_x(x0) + L_LOCO + PITCH / 2 end   -- 停好時的車頭 x：第 1 節在裝車點，後面幾節往西排
local function wagon_x(x0, i) return math.floor(load_x(x0) - (i - 1) * PITCH) end   -- 停好時第 i 節的中心（標示柱的 x）

-- 現在幾點（0～24）：教學地圖的時鐘跟交易日走（開盤 06:00，一個交易日 24 小時），天色也照這個（下面每秒對一次）
local function hour()
	local p = cfg.price_period
	local into = core.get_gametime() - rockmech.market_day() * p
	return (6 + 24 * into / p) % 24
end
local function in_hours()
	local h = hour()
	return h >= HOURS[1] and h < HOURS[2]
end
local function clock_text()
	local h = hour()
	return ("%02d:%02d"):format(math.floor(h), math.floor((h % 1) * 60))
end
local function start_head(x0) return x0 + LINE.x1 + 2 + L_LOCO + N * PITCH end
local function end_head(x0) return x0 + LINE.x2 - 1 end

---------------------------------------------------------------------------
-- 方塊：軌道、路肩、裝車點標示柱
---------------------------------------------------------------------------

local function noop() end
local BAL = "[fill:16x16:#7a746c^[fill:2x2:3,3:#5e5850^[fill:2x2:10,6:#8e887e^[fill:2x2:6,11:#5e5850^[fill:1x1:13,13:#9a948a"
core.register_node(RAIL, {
	description = S("Railway track"),
	-- 頂面：碎石道碴、枕木（橫的）、兩條鋼軌（沿 x）
	tiles = {BAL .. "^[fill:3x16:1,0:#5a4030^[fill:3x16:9,0:#5a4030^[fill:16x2:0,3:#9aa0a6^[fill:16x1:0,4:#5a5e64"
		.. "^[fill:16x2:0,11:#9aa0a6^[fill:16x1:0,12:#5a5e64", BAL},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})
core.register_node(BALLAST, {
	description = S("Track ballast"), tiles = {BAL},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
})
core.register_node(MARK, {
	description = S("Loading point"),
	drawtype = "nodebox", paramtype = "light", sunlight_propagates = true,
	node_box = {type = "fixed", fixed = {{-0.12, -0.5, -0.12, 0.12, 1.3, 0.12}, {-0.35, 1.0, -0.06, 0.35, 1.45, 0.06}}},
	tiles = {"[fill:16x16:#e0b428^[fill:16x4:0,0:#202020^[fill:16x4:0,8:#202020"},
	is_ground_content = false, groups = {not_in_creative_inventory = 1}, on_blast = noop,
	on_rightclick = function(pos, node, clicker)
		if clicker and clicker:is_player() then rockmech.notify(clicker:get_player_name(), S("[Train] Loading point: wagons stop here")) end
	end,
})

-- 鋪鐵路：這一組礦帶那一段。地面那一層換成軌道（中線）和路肩（兩側），上面清空
local function lay(x0)
	local y = rail_y()
	for x = x0 + LINE.x1, x0 + LINE.x2 do
		for dz = -1, 1 do
			local z = RAIL_Z + dz
			core.set_node({x = x, y = y, z = z}, {name = dz == 0 and RAIL or BALLAST})
			for yy = y + 1, y + 6 do
				local p = {x = x, y = yy, z = z}
				if core.get_node(p).name ~= "air" then core.remove_node(p) end
			end
			for yy = y - 1, y - 3, -1 do
				local p = {x = x, y = yy, z = z}
				local d = core.registered_nodes[core.get_node(p).name]
				if d and d.walkable ~= false then break end
				core.set_node(p, {name = BALLAST})
			end
		end
	end
	storage:set_string("rail:" .. x0, "1")
	core.log("action", ("[rockmech] 營地 x = %d 鋪好鐵路"):format(x0))
end
-- 每節一根標示柱（舊的世界：舊位置的柱子先拔掉，再照現在的節數、裝車點重插）
local POSTS_VER = N .. "@" .. LOAD_REL
local function posts(x0)
	local y = rail_y()
	for x = x0 + LINE.x1, x0 + LINE.x2 do
		local p = {x = x, y = y + 1, z = RAIL_Z - 2}
		if core.get_node(p).name == MARK then core.remove_node(p) end
	end
	for i = 1, N do core.set_node({x = wagon_x(x0, i), y = y + 1, z = RAIL_Z - 2}, {name = MARK}) end
	storage:set_string("rail_posts:" .. x0, POSTS_VER)
end
core.after(6, function()
	for _, x0 in ipairs(O.sites()) do
		if storage:get_string("rail:" .. x0) == "1" and storage:get_string("rail_posts:" .. x0) ~= POSTS_VER then
			local y = rail_y()
			core.emerge_area({x = x0 + LINE.x1, y = y, z = RAIL_Z - 3}, {x = x0 + LINE.x2, y = y + 2, z = RAIL_Z - 1}, function(_, _, rem)
				if rem == 0 then posts(x0) end
			end)
		elseif storage:get_string("rail:" .. x0) ~= "1" then
			local y = rail_y()
			core.emerge_area({x = x0 + LINE.x1, y = y - 4, z = RAIL_Z - 3}, {x = x0 + LINE.x2, y = y + 7, z = RAIL_Z + 2}, function(_, _, rem)
				if rem > 0 or storage:get_string("rail:" .. x0) == "1" then return end
				local col = rockmech.collapse
				col.quiet = col.quiet + 1
				local ok, err = pcall(function() lay(x0); posts(x0) end)
				col.quiet = col.quiet - 1
				if not ok then core.log("error", "[rockmech] rail: " .. tostring(err)) end
			end)
		end
	end
end)
-- 路權：軌道、兩側路肩、標示柱那一排
rockmech.camp.protect({x1 = LINE.x1, x2 = LINE.x2, z1 = RAIL_Z - 2, z2 = RAIL_Z + 1})

---------------------------------------------------------------------------
-- 車廂（有斗的車，不能開）、機車
---------------------------------------------------------------------------

local trains = {}             -- 帳戶 → {loco = obj, wagons = {entity...}}
local open_for = {}           -- 玩家 → 帳戶（打開的列車視窗）

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
		if rockmech.train_form then rockmech.train_form(self.owner, clicker) end
		return true
	end
	-- 不存進地圖：狀態在 mod storage，列車是附近有人時才放出來的畫面
	local on_load = wagon.on_load
	wagon.on_load = function(self, data)
		if on_load then on_load(self, data) end
		self.object:set_properties({static_save = false})
	end
	V.register(KIND, wagon)
	core.override_item(ENAME .. "_item", {groups = {not_in_creative_inventory = 1}})
end

-- 機車：一個方盒（藍色車身、黃色腰帶、前面車窗和頭燈）
local LB = "#28466e"
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
		if self.acc and rockmech.train_form then rockmech.train_form(self.acc, clicker) end
	end,
	on_step = function(self)
		if not (self.acc and trains[self.acc] and trains[self.acc].loco == self.object) then self.object:remove() end
	end,
})

---------------------------------------------------------------------------
-- 狀態：存在 mod storage
---------------------------------------------------------------------------

local KEY = "train:"
local function get_state(acc)
	local s = storage:get_string(KEY .. acc)
	return s ~= "" and core.deserialize(s) or nil
end
local function set_state(acc, st) storage:set_string(KEY .. acc, st and core.serialize(st) or "") end
local states = {}             -- 帳戶 → 狀態（記憶體裡的，定期寫回）
local function state(acc)
	if not states[acc] then states[acc] = get_state(acc) end
	return states[acc]
end
local function save(acc) set_state(acc, states[acc]) end

local function uid_of(acc, i) return ("train-%s-%d"):format(acc, i) end

-- 收掉畫面（先把車廂的料寫回狀態）
local function sync(acc)
	local tr, st = trains[acc], states[acc]
	if not (tr and st) then return end
	for i, e in ipairs(tr.wagons) do
		if e.object:get_pos() then st.loads[i] = {load = table.copy(e.load), loadq = table.copy(e.loadq)} end
	end
end
local function despawn(acc)
	local tr = trains[acc]
	if not tr then return end
	sync(acc)
	if tr.loco and tr.loco:get_pos() then tr.loco:remove() end
	for i, e in ipairs(tr.wagons) do
		V.registry_drop(uid_of(acc, i)); V.snapshot_clear(uid_of(acc, i))
		if e.object:get_pos() then e.object:remove() end
	end
	trains[acc] = nil
	if states[acc] then save(acc) end
end

local function place(acc)
	local tr, st = trains[acc], states[acc]
	local y = rail_y() + 0.5 + 1.5
	local head = st.head
	if tr.loco and tr.loco:get_pos() then tr.loco:move_to({x = head - L_LOCO / 2, y = y + 0.1, z = RAIL_Z + 0.5}, true) end
	for i, e in ipairs(tr.wagons) do
		if e.object:get_pos() then
			e.object:move_to({x = head - L_LOCO - (i - 1) * PITCH - PITCH / 2, y = y, z = RAIL_Z + 0.5}, true)
		end
	end
end

local function spawn(acc)
	local st = states[acc]
	local y = rail_y() + 0.5 + 1.5
	local tr = {wagons = {}}
	trains[acc] = tr
	local loco = core.add_entity({x = st.head - L_LOCO / 2, y = y + 0.1, z = RAIL_Z + 0.5}, LOCO)
	if loco then
		loco:set_yaw(YAW)
		local le = loco:get_luaentity()
		if le then le.acc = acc end
		tr.loco = loco
	end
	for i = 1, N do
		local ld = st.loads[i] or {}
		local data = core.serialize({uid = uid_of(acc, i), owner = acc, load = ld.load or {}, loadq = ld.loadq or {}, wall = os.time() + 1,
			yaw = YAW})
		local obj = core.add_entity({x = st.head - L_LOCO - (i - 1) * PITCH - PITCH / 2, y = y, z = RAIL_Z + 0.5}, ENAME, data)
		local e = obj and obj:get_luaentity()
		if e then
			obj:set_yaw(YAW)
			e.train_i = i
			obj:set_acceleration({x = 0, y = 0, z = 0})
			V.refresh(e)
			tr.wagons[#tr.wagons + 1] = e
		end
	end
end

-- 給 orders.lua：卡車倒料對準車廂
function rockmech.train_wagons()
	local out = {}
	for _, tr in pairs(trains) do
		for _, e in ipairs(tr.wagons) do if e.object:get_pos() then out[#out + 1] = e end end
	end
	return out
end

-- 下一班從西邊開進來
local function start(acc)
	local x0 = site_of(acc)
	if not x0 then return end
	states[acc] = {phase = "in", head = start_head(x0), loads = {}}
	save(acc)
end
function rockmech.train_remove(acc)
	despawn(acc)
	states[acc] = nil
	set_state(acc, nil)
end

local function wagon_total(st, i)
	local t = 0
	for _, lv in pairs((st.loads[i] or {}).load or {}) do t = t + lv end
	return t
end
local function all_full(st)
	for i = 1, N do if wagon_total(st, i) < CAP_M3 * NLEV then return false end end
	return true
end
local function train_total(st)
	local t = 0
	for i = 1, N do t = t + wagon_total(st, i) end
	return t
end

-- 出發：每節照市價結帳
local function depart(acc)
	local st = states[acc]
	if not st then return end
	sync(acc)
	local ore = cfg.main_ore
	local price = ore and rockmech.ore_price(ore) or 0
	local rec = ore and (rockmech.eff_ore_recovery and rockmech.eff_ore_recovery(acc, ore) or ore.recovery) or 0
	local rows, net, total_t = {}, 0, 0
	for i = 1, N do
		local ld = st.loads[i] or {}
		local lv, g = O.load_grade({load = ld.load or {}, loadq = ld.loadq or {}})
		if lv > 0 then
			local t = tons_of(lv)
			local m = math.floor(t * g * rec * price - t * (1 - g) * rockmech.gangue_fee(ore) + 0.5)
			net, total_t = net + m, total_t + t
			rows[#rows + 1] = {S("Wagon @1  grade @2", i, pct(g)), t1(t), ("$%.0f × %.0f%%"):format(price, rec * 100),
				money_text(m), m >= 0 and 0x80ff80 or 0xff8080}
		end
	end
	if #rows > 0 then
		rockmech.add_money(acc, net)
		rows[#rows + 1] = {S("Total"), t1(total_t), "", money_text(net), net >= 0 and 0x80ff80 or 0xff8080}
		for _, m in ipairs(rockmech.account_members(acc)) do
			core.sound_play("rockmech_coin", {to_player = m, gain = 0.8}, true)
			if rockmech.show_bill then rockmech.show_bill(m, S("Train shipment"), rows) end
		end
		tell(acc, S("The train left with @1, income @2", t1(total_t), money_text(net)))
	else
		tell(acc, S("The train left empty"))
	end
	-- 車廂的料跟著火車走了：畫面上清空
	st.loads = {}
	local tr = trains[acc]
	if tr then for _, e in ipairs(tr.wagons) do e.load, e.loadq = {}, {}; V.refresh(e) end end
	st.phase = "leaving"
	save(acc)
end

---------------------------------------------------------------------------
-- 每秒（orders.lua 呼叫）：進站、裝車、挪節、出發、結案；畫面放出／收掉
---------------------------------------------------------------------------

local function players_near(p)
	for _, pl in ipairs(core.get_connected_players()) do
		if vector.distance(pl:get_pos(), p) < NEAR then return true end
	end
	return false
end

local function step(acc)
	local x0 = site_of(acc)
	if not x0 or storage:get_string("rail:" .. x0) ~= "1" or not rockmech.has_account(acc) then return end
	local st = state(acc)
	if not st then
		-- 上班時間一直有車；晚上沒車
		if in_hours() then start(acc) end
		st = states[acc]
		if not st then return end
	end
	local lp = {x = load_x(x0), y = rail_y(), z = RAIL_Z}
	local active = (rockmech.train_debug.force or players_near(lp)) and core.get_node(lp).name ~= "ignore"   -- force：測試用
	if st.phase == "coming" then st.phase = "in" end   -- 舊版的狀態
	-- 畫面：附近有人才放
	if active and not trains[acc] then spawn(acc)
	elseif not active and trains[acc] then despawn(acc) end
	sync(acc)
	if st.phase == "load" then
		-- 都裝滿就走；下班（20:00）還沒滿也帶著已經裝的走
		if all_full(st) or not in_hours() then depart(acc) end
	end
	-- 沒人在附近時也照樣「開」：直接跳到目標（畫面不在）
	if not trains[acc] then
		if st.phase == "in" then st.head = stop_head(x0); st.phase = "load"
		elseif st.phase == "leaving" then st.head = end_head(x0) end
	end
	if st.phase == "leaving" and st.head >= end_head(x0) - 0.01 then
		despawn(acc)
		states[acc] = nil
		set_state(acc, nil)
		-- 下一班馬上來（上班時間內）
		if in_hours() then start(acc) end
		return
	end
	save(acc)
end
-- 每秒：各組的火車（組員不在線也照樣跑班次）
local tick = 0
core.register_globalstep(function(dtime)
	tick = tick + dtime
	if tick < 1 then return end
	tick = 0
	core.set_timeofday(hour() / 24)
	for i = 0, cfg.career_teams or 0 do step("team:" .. i) end   -- 0 = 老師組（出生點的營地）
end)

-- 移動（0.1 秒）：畫面在的列車往目標開；前面軌道上有東西就停
local BLOCK_WARN = 10
local mt = 0
core.register_globalstep(function(dtime)
	mt = mt + dtime
	if mt < 0.1 then return end
	local dt = mt
	mt = 0
	for acc, tr in pairs(trains) do
		local st = states[acc]
		local x0 = site_of(acc)
		if st and x0 then
			local target, speed
			if st.phase == "in" then
				target = stop_head(x0)
				speed = math.max(1, math.min(V_MAX, math.sqrt(2 * ACC * math.max(0, target - st.head))))
			elseif st.phase == "leaving" then
				target = end_head(x0)
				speed = math.max(1.5, math.min(V_MAX, math.sqrt(2 * ACC * math.max(0, st.head - stop_head(x0)))))
			end
			if target and st.head < target - 0.01 then
				-- 車頭前面 2 m 的軌道上方有東西（碎石…）：停下來
				local y = rail_y() + 1
				local blocked
				for dx = 0, 2 do
					local n = core.get_node({x = math.floor(st.head + dx + 0.5), y = y, z = RAIL_Z}).name
					if n ~= "air" and n ~= "ignore" then blocked = n; break end
				end
				if blocked then
					local now = core.get_gametime()
					if not st.warned or now - st.warned > BLOCK_WARN then
						st.warned = now
						tell(acc, S("The track is blocked in front of the train. Clear it"))
					end
				else
					st.head = math.min(target, st.head + speed * dt)
					place(acc)
				end
			elseif target then
				if st.phase == "in" then
					st.phase = "load"
					save(acc)
				end
			end
		end
	end
end)

---------------------------------------------------------------------------
-- 視窗：列車狀態、挪下一節、出發
---------------------------------------------------------------------------

local FORM = "rockmech:train"
function rockmech.train_status(acc)
	local st = state(acc)
	if not st then
		if in_hours() then return S("Train: arriving") end
		return S("Train: no trains at night; the first one comes at @1:00", ("%02d"):format(HOURS[1]))
	end
	if st.phase ~= "load" and st.phase ~= "leaving" then return S("Train: arriving") end
	if st.phase == "load" then
		return S("Train: loading @1 / @2, leaves when all wagons are full", t1(tons_of(train_total(st))), t1(tons_of(N * CAP_M3 * NLEV)))
	end
	return S("Train: leaving")
end
local function form(acc)
	local st = state(acc)
	local out = {"formspec_version[6]size[9,6.4]", ("label[0.5,0.6;%s]"):format(F(S("Freight train") .. "   " .. clock_text())),
		("label[0.5,1.2;%s]"):format(F(rockmech.train_status(acc)))}
	if st then
		for i = 1, N do
			out[#out + 1] = ("label[0.5,%g;%s]"):format(1.6 + i * 0.5, F(S("Wagon @1  @2 / @3", i, t1(tons_of(wagon_total(st, i))),
				t1(tons_of(CAP_M3 * NLEV)))))
		end
		if st.phase == "load" then
			out[#out + 1] = ("button[4.7,5.2;3.8,0.8;go;%s]"):format(F(S("Depart now")))
		end
	end
	return table.concat(out)
end
function rockmech.train_form(acc, clicker)
	if not (acc and clicker and clicker:is_player()) then return end
	local name = clicker:get_player_name()
	if rockmech.account_of(name) ~= acc then return end
	open_for[name] = acc
	core.show_formspec(name, FORM, form(acc))
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	local name = player:get_player_name()
	local acc = open_for[name]
	if fields.quit then open_for[name] = nil; return true end
	local st = acc and state(acc)
	if not (st and st.phase == "load" and rockmech.account_of(name) == acc) then return true end
	if fields.go then
		depart(acc)
	end
	core.close_formspec(name, FORM)
	return true
end)

rockmech.train_debug = {spawn = spawn, despawn = despawn, states = states, trains = trains, stop_head = stop_head,
	load_x = load_x, RAIL_Z = RAIL_Z, LINE = LINE, hour = hour, in_hours = in_hours, N = N}
