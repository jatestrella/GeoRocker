-- rockmech/traincore.lua
-- 火車的共用部分（教學地圖 class/train.lua、單機地圖的鐵路 trainline.lua 都用這個）：
--   車廂（有斗、不能開的車）、機車、班次（進站 in → 裝車 load → 出站 leaving）、出發結帳、畫面放出／收回、
--   移動（前方軌道上有東西就停）、列車視窗（狀態、每節的料、「現在出發」）。
-- 每條線只要提供「軌道」：位置怎麼算、什麼算擋住、時鐘、錢給誰（rockmech.traincore.line 的 def，見下面）。
-- 列車是畫面：狀態（車頭弧長 head、每節的料）存在 mod storage，附近有人才放出來，不存進地圖。

local S = rockmech.S
local cfg = rockmech.cfg
local V = rockmech.vehicles
local NLEV = V.NLEV
local storage = rockmech.collapse.storage
local O = rockmech.orders
local F = core.formspec_escape
local tons_of, pct, t1, money_text, tell = O.tons_of, O.pct, O.t1, O.money_text, O.tell

local T = {}
rockmech.traincore = T
T.N = 4                        -- 車廂數
T.CAP_M3 = 8                   -- 每節 m³
T.L_LOCO, T.PITCH = 9, 7.6     -- 機車長、車廂間距（中心到中心）
T.WAGON_DY = 1.5               -- 車廂中心比軌面高
local N, CAP_M3, L_LOCO, PITCH, WAGON_DY = T.N, T.CAP_M3, T.L_LOCO, T.PITCH, T.WAGON_DY
local V_MAX, ACC = 12, 1.2     -- 最高速度 (m/s ≈ 43 km/h)、加減速 (m/s²)：進站減速停好、出站慢慢加速
local BLOCK_WARN = 10          -- 軌道被擋住的提醒間隔 (s)
local KIND = "wagon"
local ENAME = "rockmech:" .. KIND
local LOCO = "rockmech:train_loco"
local FORM = "rockmech:train"

-- 車頭弧長 head 時第 i 節車廂中心的弧長
function T.wagon_s(head, i) return head - L_LOCO - (i - 1) * PITCH - PITCH / 2 end

local lines = {}               -- 每條線（def + 這條線上的列車）
local shown = {}               -- "線號|鍵" → 畫面 {loco = obj, wagons = {entity...}}
local open_for = {}            -- 玩家 → {line, key}（打開的列車視窗）

---------------------------------------------------------------------------
-- 車廂、機車（第一條線建立時註冊）
---------------------------------------------------------------------------

local registered = false
local function register()
	if registered then return end
	registered = true
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
		if clicker and clicker:is_player() then rockmech.train_form(rockmech.account_of(clicker:get_player_name()), clicker) end
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
			if clicker and clicker:is_player() then rockmech.train_form(rockmech.account_of(clicker:get_player_name()), clicker) end
		end,
		on_step = function(self)
			local tr = self.tk and shown[self.tk]
			if not (tr and tr.loco == self.object) then self.object:remove() end
		end,
	})
end

---------------------------------------------------------------------------
-- 一條線。def：
--   id          線的名稱（畫面的鍵）
--   keys()      這條線上有哪些列車（鍵；教學地圖每組一列 "team:i"，單機一列 ""）
--   skey(k)     mod storage 的鍵；uid(k, i) 第 i 節車廂的 uid
--   ready(k)    這列車現在要不要跑（軌道鋪好了、帳戶開了…）
--   pose(k, s)  弧長 s 的 x, z, 軌面 y, yaw
--   s_start(k)、s_stop(k)、s_end(k)：進場的車頭位置、停好的車頭位置、出場的車頭位置
--   active(k, st) 畫面要不要放出來（附近有人、而且那裡已載入）
--   blocked(k, st, dir) 車頭前方有擋路的東西就回傳方塊名稱
--   payer(k)    錢給哪個帳戶（可以是 nil：沒人在）
--   owns(k, acc) 這個帳戶能不能看這列車的視窗、按出發；wagon_owner(k) 車廂掛誰的名下（可省：沒有主人）
--   hours       {開始, 結束}；hour() 現在幾點（0～24）
--   tick()      每秒呼叫一次（可省）；migrate(st) 讀進舊版狀態時修正（可省）
---------------------------------------------------------------------------

function T.line(def)
	register()
	local L = {def = def, states = {}}
	lines[#lines + 1] = L
	local function tkey(k) return def.id .. "|" .. k end

	local function in_hours()
		local h = def.hour()
		return h >= def.hours[1] and h < def.hours[2]
	end
	L.in_hours = in_hours
	local function state(k)
		if L.states[k] == nil then
			local s = storage:get_string(def.skey(k))
			L.states[k] = s ~= "" and core.deserialize(s) or false
			if L.states[k] and def.migrate then def.migrate(L.states[k]) end
		end
		return L.states[k] or nil
	end
	L.state = state
	local function save(k)
		local st = L.states[k]
		storage:set_string(def.skey(k), st and core.serialize(st) or "")
	end
	local function set_state(k, st) L.states[k] = st or false; save(k) end

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

	-- 畫面：車廂的料寫回狀態、收掉、放出、擺到位置
	local function sync(k)
		local tr, st = shown[tkey(k)], state(k)
		if not (tr and st) then return end
		for i, e in ipairs(tr.wagons) do
			if e.object:get_pos() then st.loads[i] = {load = table.copy(e.load), loadq = table.copy(e.loadq), loada = table.copy(e.loada or {})} end
		end
	end
	local function despawn(k)
		local tr = shown[tkey(k)]
		if not tr then return end
		sync(k)
		if tr.loco and tr.loco:get_pos() then tr.loco:remove() end
		for i, e in ipairs(tr.wagons) do
			V.registry_drop(def.uid(k, i)); V.snapshot_clear(def.uid(k, i))
			if e.object:get_pos() then e.object:remove() end
		end
		shown[tkey(k)] = nil
		if state(k) then save(k) end
	end
	local function place(k)
		local tr, st = shown[tkey(k)], state(k)
		if not (tr and st) then return end
		if tr.loco and tr.loco:get_pos() then
			local x, z, y, yaw = def.pose(k, st.head - L_LOCO / 2)
			tr.loco:move_to({x = x, y = y + WAGON_DY + 0.1, z = z}, true)
			tr.loco:set_yaw(yaw)
		end
		for i, e in ipairs(tr.wagons) do
			if e.object:get_pos() then
				local x, z, y, yaw = def.pose(k, T.wagon_s(st.head, i))
				e.object:move_to({x = x, y = y + WAGON_DY, z = z}, true)
				e.object:set_yaw(yaw)
			end
		end
	end
	local function spawn(k)
		local st = state(k)
		local tr = {wagons = {}}
		shown[tkey(k)] = tr
		local x, z, y, yaw = def.pose(k, st.head - L_LOCO / 2)
		local loco = core.add_entity({x = x, y = y + WAGON_DY + 0.1, z = z}, LOCO)
		if loco then
			loco:set_yaw(yaw)
			local le = loco:get_luaentity()
			if le then le.tk = tkey(k) end
			tr.loco = loco
		end
		for i = 1, N do
			local ld = st.loads[i] or {}
			local wx, wz, wy, wyaw = def.pose(k, T.wagon_s(st.head, i))
			local data = core.serialize({uid = def.uid(k, i), owner = def.wagon_owner and def.wagon_owner(k) or "", load = ld.load or {}, loadq = ld.loadq or {}, loada = ld.loada or {},
				wall = os.time() + 1, yaw = wyaw})
			local obj = core.add_entity({x = wx, y = wy + WAGON_DY, z = wz}, ENAME, data)
			local e = obj and obj:get_luaentity()
			if e then
				obj:set_yaw(wyaw)
				e.train_i = i
				obj:set_acceleration({x = 0, y = 0, z = 0})
				V.refresh(e)
				tr.wagons[#tr.wagons + 1] = e
			end
		end
	end
	L.spawn, L.despawn = spawn, despawn

	-- 出發：每節照市價結帳（economy.lua 的 coal_value，跟收煤站同一條，但照原價）
	local function depart(k)
		local st = state(k)
		if not st then return end
		sync(k)
		local acc = def.payer(k)
		local rows, net, total_t, coal_t = {}, 0, 0, 0
		for i = 1, N do
			local ld = st.loads[i] or {}
			local wagon = {load = ld.load or {}, loadq = ld.loadq or {}, loada = ld.loada or {}}
			-- 每節照車上最多的那種礦計價，別種礦算廢石（多種礦的地圖要分開裝）
			local ore, lv, g = cfg.main_ore, 0, -1
			for _, o in ipairs(cfg.active_ores) do
				local l, og = O.load_grade(wagon, o)
				if og > g then ore, lv, g = o, l, og end
			end
			local price = rockmech.ore_price(ore)
			local rec = rockmech.eff_ore_recovery(acc, ore)
			if lv > 0 then
				local t = tons_of(lv)
				local gross, fee = rockmech.coal_value(t, g, ore, acc)
				local m = math.floor(gross - fee + 0.5)
				net, total_t, coal_t = net + m, total_t + t, coal_t + t * g
				rows[#rows + 1] = {S("Wagon @1  grade @2", i, pct(g)) .. (rockmech.multi_ore() and ("  " .. S(ore.label)) or ""), t1(t),
					("$%.0f × %.0f%%"):format(price, rec * 100), money_text(m), m >= 0 and 0x80ff80 or 0xff8080}
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
		-- 車廂的料跟著火車走了：畫面上清空
		st.loads = {}
		local tr = shown[tkey(k)]
		if tr then for _, e in ipairs(tr.wagons) do e.load, e.loadq, e.loada = {}, {}, {}; V.refresh(e) end end
		st.phase = "leaving"
		save(k)
	end
	L.depart = depart
	local function start(k) set_state(k, {phase = "in", head = def.s_start(k), loads = {}}) end
	function L.remove(k) despawn(k); set_state(k, nil) end

	-- 每秒：班次、畫面放出／收掉
	function L.step(k)
		if not def.ready(k) then return end
		local st = state(k)
		if not st then
			if in_hours() then start(k) end      -- 上班時間一直有車；晚上沒車
			st = state(k)
			if not st then return end
		end
		local active = def.active(k, st)
		if active and not shown[tkey(k)] then spawn(k)
		elseif not active and shown[tkey(k)] then despawn(k) end
		sync(k)
		-- 都裝滿就走；下班還沒滿也帶著已經裝的走
		if st.phase == "load" and (all_full(st) or not in_hours()) then depart(k) end
		-- 畫面不在：直接跳到目標
		if not shown[tkey(k)] then
			if st.phase == "in" then st.head = def.s_stop(k); st.phase = "load"
			elseif st.phase == "leaving" then st.head = def.s_end(k) end
		end
		if st.phase == "leaving" and st.head >= def.s_end(k) - 0.01 then
			despawn(k)
			set_state(k, nil)
			if in_hours() then start(k) end     -- 下一班馬上來（上班時間內）
			return
		end
		save(k)
	end

	-- 每 0.1 秒：畫面在的列車往目標開；前面軌道上有東西就停
	function L.move(k, dt)
		local st = state(k)
		if not (shown[tkey(k)] and st) then return end
		local target, speed
		local stop = def.s_stop(k)
		if st.phase == "in" then
			target = stop
			speed = math.max(1, math.min(V_MAX, math.sqrt(2 * ACC * math.max(0, target - st.head))))
		elseif st.phase == "leaving" then
			target = def.s_end(k)
			speed = math.max(1.5, math.min(V_MAX, math.sqrt(2 * ACC * math.max(0, st.head - stop))))
		end
		if target and st.head < target - 0.01 then
			if def.blocked(k, st) then
				local now = core.get_gametime()
				if not st.warned or now - st.warned > BLOCK_WARN then
					st.warned = now
					local acc = def.payer(k)
					if acc then tell(acc, S("The track is blocked in front of the train. Clear it")) end
				end
			else
				st.head = math.min(target, st.head + speed * dt)
				place(k)
			end
		elseif target and st.phase == "in" then
			st.phase = "load"
			save(k)
		end
	end

	function L.status(k)
		local st = state(k)
		if not st then
			if in_hours() then return S("Train: arriving") end
			return S("Train: no trains at night; the first one comes at @1:00", ("%02d"):format(def.hours[1]))
		end
		if st.phase == "load" then
			return S("Train: loading @1 / @2, leaves when all wagons are full", t1(tons_of(train_total(st))), t1(tons_of(N * CAP_M3 * NLEV)))
		end
		if st.phase == "leaving" then return S("Train: leaving") end
		return S("Train: arriving")
	end
	function L.form(k)
		local st = state(k)
		local h = def.hour()
		local out = {"formspec_version[6]size[9,6.4]",
			("label[0.5,0.6;%s]"):format(F(S("Freight train") .. "   " .. ("%02d:%02d"):format(math.floor(h), math.floor((h % 1) * 60)))),
			("label[0.5,1.2;%s]"):format(F(L.status(k)))}
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
	return L
end

---------------------------------------------------------------------------
-- 全部的線：每秒、每 0.1 秒；對外的函式
---------------------------------------------------------------------------

local tick = 0
core.register_globalstep(function(dtime)
	tick = tick + dtime
	if tick < 1 then return end
	tick = 0
	for _, L in ipairs(lines) do
		if L.def.tick then L.def.tick() end
		for _, k in ipairs(L.def.keys()) do L.step(k) end
	end
end)
local mt = 0
core.register_globalstep(function(dtime)
	mt = mt + dtime
	if mt < 0.1 then return end
	local dt = mt
	mt = 0
	for _, L in ipairs(lines) do
		for _, k in ipairs(L.def.keys()) do L.move(k, dt) end
	end
end)

-- 這個帳戶看得到的列車（線、鍵）
local function find(acc)
	for _, L in ipairs(lines) do
		for _, k in ipairs(L.def.keys()) do
			if L.def.owns(k, acc) then return L, k end
		end
	end
end

function rockmech.train_enabled() return #lines > 0 end
-- 給 orders.lua：卡車倒料對準車廂
function rockmech.train_wagons()
	local out = {}
	for _, tr in pairs(shown) do
		for _, e in ipairs(tr.wagons) do if e.object:get_pos() then out[#out + 1] = e end end
	end
	return out
end
function rockmech.train_status(acc)
	local L, k = find(acc)
	return L and L.status(k) or ""
end
function rockmech.train_form(acc, clicker)
	if not (acc and clicker and clicker:is_player()) then return end
	local L, k = find(acc)
	if not L then return end
	local name = clicker:get_player_name()
	open_for[name] = {L = L, k = k}
	core.show_formspec(name, FORM, L.form(k))
end
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORM then return end
	local name = player:get_player_name()
	local o = open_for[name]
	if fields.quit then open_for[name] = nil; return true end
	if not o then return true end
	local st = o.L.state(o.k)
	if not (st and st.phase == "load" and o.L.def.owns(o.k, rockmech.account_of(name))) then return true end
	if fields.go then o.L.depart(o.k) end
	core.close_formspec(name, FORM)
	return true
end)

return T
