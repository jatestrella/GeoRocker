-- rockmech/drone.lua
-- 無人機（遙控器 rockmech:drone_remote）：從空中看礦場、看別組挖得怎樣。
--   拿著遙控器按右鍵起飛：無人機從身邊升起，玩家附在無人機上看第一人稱畫面（身體先藏起來，別人看到的是無人機）。
--   WASD 照視線方向水平移動 SPEED m/s，按住 E 加速到 BOOST 倍；空白鍵上升、Shift 下降 CLIMB m/s；會撞到地形。
--   高度上限：起飛點上方 CEILING m；最大飛行距離：離起飛點水平 rockmech_drone_range m。再按一次右鍵就回到起飛點。
--   HUD：對地高度、比起飛點高多少、速度、方位、座標。旋翼聲 rockmech_drone（devtools/synth_sounds.lua 合成），移動時大聲一點。
--   飛行時暫時強制載入下方 ±LOAD_R m 的區塊：玩家飛高了，地上的區塊離玩家太遠會停用，上面的車就看不到了。
--   飛行中斷線、伺服器重開：起飛點記在玩家 meta，下次登入就回到起飛點。

local cfg = rockmech.cfg
local S = rockmech.S
local DRONE, PART, REMOTE = "rockmech:drone", "rockmech:drone_part", "rockmech:drone_remote"
local CMD = "rockmech:drone_cmd"     -- 指揮無人機（無人機＋對講機，檔案最後）
local CMD_RANGE = 128
local SPEED, BOOST, CLIMB = 12, 2, 6      -- 水平速度 (m/s)、E 加速倍數、升降速度 (m/s)
local CEILING = 80          -- 高度上限：起飛點上方 (m)
local LOAD_R = 40           -- 飛行時強制載入下方 ±LOAD_R m（約 80 × 80 m）
local LOAD_DOWN, LOAD_UP = 32, 16   -- 強制載入的高度範圍：起飛點下方、上方 (m)
local HOME_KEY = "rockmech:drone_home"
-- 旋翼聲：懸停、飛行各一段（同一個音檔，飛行的音高高 PITCH_MOVE 倍），兩段一起循環播放、交叉淡入淡出
-- （正在播的聲音改不了音高）。音量跟 rockmech_vehicle_sound_gain 相乘
local SOUND_HOVER, SOUND_MOVE, PITCH_MOVE = 0.1, 0.4, 1.12   -- 2026-11-07 降一半
-- 駕駛的鏡頭就在無人機上（距離 0，一直是最大聲）；人其實站在起飛點，所以駕駛另外播一組不跟著無人機的聲音，
-- 音量 × SOUND_PILOT；附在無人機上的那組只給其他人聽
local SOUND_PILOT = 0.25
local SOUND_OFF = 0.001     -- 淡到 0 引擎會把聲音停掉，用很小的值代替
local FADE = 2              -- 淡入淡出速度（音量／秒）

local flights = {}          -- 玩家名稱 → {id, drone, home, hud, loaded = {hash → pos}, props, nametag}
local next_id = 0           -- 飛行編號：無人機實體用它認自己的那趟（ObjectRef 不能用 == 比）

---------------------------------------------------------------------------
-- 外觀：機身、四支臂、四個旋翼（零件實體附在機身上）
---------------------------------------------------------------------------

local function tex(c) local t = "[fill:16x16:" .. c; return {t, t, t, t, t, t} end
core.register_entity(PART, {
	initial_properties = {visual = "cube", physical = false, pointable = false, static_save = false,
		textures = tex("#202020"), visual_size = {x = 0.1, y = 0.1, z = 0.1}},
	on_detach = function(self) self.object:remove() end,
})

local ROTOR = {"[fill:16x16:#00000000^[fill:16x2:0,7:#303030c0^[fill:2x16:7,0:#303030c0"}
local parts = {
	{pos = {x = 0, y = 0, z = 0}, size = {x = 0.35, y = 0.12, z = 0.45}, tex = tex("#e8e8e8")},            -- 機身
	{pos = {x = 0, y = -0.07, z = 0.2}, size = {x = 0.12, y = 0.08, z = 0.08}, tex = tex("#202020")},      -- 鏡頭
	{pos = {x = 0, y = 0, z = 0}, size = {x = 0.9, y = 0.04, z = 0.05}, tex = tex("#3a3a3a"), rot = {x = 0, y = 45, z = 0}},
	{pos = {x = 0, y = 0, z = 0}, size = {x = 0.9, y = 0.04, z = 0.05}, tex = tex("#3a3a3a"), rot = {x = 0, y = -45, z = 0}},
}
for _, c in ipairs({{0.32, 0.32}, {-0.32, 0.32}, {0.32, -0.32}, {-0.32, -0.32}}) do
	parts[#parts + 1] = {pos = {x = c[1], y = 0.06, z = c[2]}, size = {x = 0.4, y = 0.01, z = 0.4},
		tex = {ROTOR[1], ROTOR[1], ROTOR[1], ROTOR[1], ROTOR[1], ROTOR[1]}, rotor = true}
end

core.register_entity(DRONE, {
	initial_properties = {
		visual = "cube", textures = tex("#00000000"), use_texture_alpha = true, visual_size = {x = 1, y = 1, z = 1},
		physical = true, collide_with_objects = false, collisionbox = {-0.3, -0.1, -0.3, 0.3, 0.15, 0.3},
		pointable = false, static_save = false,
	},
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
		self.rotors, self.part_objs = {}, {}
		for _, pt in ipairs(parts) do
			local o = core.add_entity(self.object:get_pos(), PART)
			if o then
				o:set_properties({visual_size = pt.size, textures = pt.tex, use_texture_alpha = pt.rotor or nil})
				o:set_attach(self.object, "", vector.multiply(pt.pos, 10), pt.rot or {x = 0, y = 0, z = 0})
				self.part_objs[#self.part_objs + 1] = o
				if pt.rotor then self.rotors[#self.rotors + 1] = {o = o, pos = pt.pos} end
			end
		end
	end,
	on_step = function(self, dtime)
		-- 沒人在飛（玩家斷線等）就收掉
		if not (self.pilot and flights[self.pilot] and flights[self.pilot].id == self.flight_id) then
			for _, c in ipairs(self.object:get_children()) do if not c:is_player() then c:remove() end end
			self.object:remove()
			return
		end
		-- 駕駛自己看不到無人機（鏡頭就在機身上，零件貼著鏡頭會擋滿畫面）：零件只給其他玩家看，每 2 秒照線上玩家更新
		self.obs_t = (self.obs_t or 2) + dtime
		if self.obs_t >= 2 then
			self.obs_t = 0
			local obs = {}
			for _, p in ipairs(core.get_connected_players()) do
				local n = p:get_player_name()
				if n ~= self.pilot then obs[n] = true end
			end
			for _, o in ipairs(self.part_objs or {}) do
				if o.set_observers and o:get_pos() then o:set_observers(obs) end
			end
		end
		self.spin = ((self.spin or 0) + dtime * 1500) % 360
		for _, r in ipairs(self.rotors or {}) do
			r.o:set_attach(self.object, "", vector.multiply(r.pos, 10), {x = 0, y = self.spin, z = 0})
		end
	end,
})

---------------------------------------------------------------------------
-- 強制載入下方的區塊（飛行中跟著移動，回來時全部放掉）
---------------------------------------------------------------------------

local function update_load(f, pos)
	local want = {}
	local function bk(v) return math.floor(v / 16) end
	for bx = bk(pos.x - LOAD_R), bk(pos.x + LOAD_R) do
		for bz = bk(pos.z - LOAD_R), bk(pos.z + LOAD_R) do
			for by = bk(f.home.y - LOAD_DOWN), bk(f.home.y + LOAD_UP) do
				local p = {x = bx * 16, y = by * 16, z = bz * 16}
				want[core.hash_node_position(p)] = p
			end
		end
	end
	for h, p in pairs(want) do
		if not f.loaded[h] then core.forceload_block(p, true, -1) end
	end
	for h, p in pairs(f.loaded) do
		if not want[h] then core.forceload_free_block(p, true) end
	end
	f.loaded = want
end
local function free_load(f)
	for _, p in pairs(f.loaded or {}) do core.forceload_free_block(p, true) end
	f.loaded = {}
end

---------------------------------------------------------------------------
-- 起飛、降落
---------------------------------------------------------------------------

local DIRS = {S("N"), S("NE"), S("E"), S("SE"), S("S"), S("SW"), S("W"), S("NW")}
local function heading_text(yaw)
	-- yaw 0 = 北（+z），往左轉（逆時針）為正：yaw π/2 = 西
	local deg = (-math.deg(yaw)) % 360
	return DIRS[math.floor(deg / 45 + 0.5) % 8 + 1]
end

local function ground_below(pos)
	for pt in core.raycast(pos, vector.subtract(pos, {x = 0, y = 200, z = 0}), false, false) do
		if pt.type == "node" then return pt.intersection_point.y end
	end
end

local function land(name)
	local f = flights[name]
	if not f then return end
	flights[name] = nil
	free_load(f)
	local player = core.get_player_by_name(name)
	if player then
		player:set_detach()
		player:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		player:set_camera({mode = "any"})
		if f.props then player:set_properties(f.props) end
		if f.nametag then player:set_nametag_attributes(f.nametag) end
		if rockmech.nametag_hide then rockmech.nametag_hide(name, false) end
		if f.hud then player:hud_remove(f.hud) end
		player:hud_set_flags({wielditem = true})
		-- 解除附著和傳送同時送出時，玩家端有時會先傳送、再被解除附著前的位置（空中）蓋回去，人就從天上掉下來：
		-- 現在傳一次，下一刻、再下一刻各補一次，速度清零
		local home = f.home
		player:set_pos(home)
		for _, t in ipairs({0.1, 0.3}) do
			core.after(t, function()
				local p = core.get_player_by_name(name)
				if p and not p:get_attach() then
					p:set_pos(home)
					p:add_velocity(vector.multiply(p:get_velocity(), -1))
				end
			end)
		end
		player:get_meta():set_string(HOME_KEY, "")
	end
	for _, k in ipairs({"snd_hover", "snd_move", "psnd_hover", "psnd_move"}) do
		if f[k] then core.sound_stop(f[k]) end
	end
	if f.drone and f.drone:get_pos() then
		for _, c in ipairs(f.drone:get_children()) do if not c:is_player() then c:remove() end end
		f.drone:remove()
	end
end

local function take_off(player)
	local name = player:get_player_name()
	if player:get_attach() then
		rockmech.notify(name, S("[Drone] Get out of the vehicle before taking off"))
		return
	end
	local home = player:get_pos()
	local start = vector.add(home, {x = 0, y = 1.8, z = 0})
	local d = core.add_entity(start, DRONE)
	if not d then return end
	next_id = next_id + 1
	local ent = d:get_luaentity()
	ent.pilot, ent.flight_id = name, next_id
	d:set_yaw(player:get_look_horizontal())
	local f = {id = next_id, drone = d, home = home, loaded = {},
		props = {visual_size = player:get_properties().visual_size, makes_footstep_sound = player:get_properties().makes_footstep_sound},
		nametag = player:get_nametag_attributes()}
	flights[name] = f
	player:get_meta():set_string(HOME_KEY, core.serialize(home))
	player:set_properties({visual_size = {x = 0, y = 0, z = 0}, makes_footstep_sound = false})
	player:set_nametag_attributes({color = {a = 0, r = 255, g = 255, b = 255}, text = ""})
	if rockmech.nametag_hide then rockmech.nametag_hide(name, true) end     -- 掛在身上的名牌（nametag.lua）
	player:set_attach(d, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
	player:set_eye_offset({x = 0, y = -14, z = 0}, {x = 0, y = -10, z = -20})    -- 鏡頭在機身上
	player:set_camera({mode = "first"})
	player:hud_set_flags({wielditem = false})     -- 手上的遙控器不擋畫面
	-- 放在快捷欄上方（畫面上方是聊天訊息和方位）
	f.hud = player:hud_add({type = "text", position = {x = 0.5, y = 0.86}, alignment = {x = 0, y = -1},
		number = 0x9fe0ff, text = "", z_index = 100})
	update_load(f, start)
	-- 旋翼聲：跟著無人機走，附近的人也聽得到
	local g = rockmech.cfg.vehicle_sound_gain or 1
	if g > 0 then
		f.snd_hover = core.sound_play("rockmech_drone", {object = d, loop = true, gain = SOUND_HOVER * g, max_hear_distance = 40, exclude_player = name})
		f.snd_move = core.sound_play("rockmech_drone", {object = d, loop = true, gain = SOUND_OFF, pitch = PITCH_MOVE, max_hear_distance = 40, exclude_player = name})
		f.psnd_hover = core.sound_play("rockmech_drone", {to_player = name, loop = true, gain = SOUND_HOVER * SOUND_PILOT * g})
		f.psnd_move = core.sound_play("rockmech_drone", {to_player = name, loop = true, gain = SOUND_OFF, pitch = PITCH_MOVE})
		f.moving = false
	end
	rockmech.notify(name, S("[Drone] Take-off! WASD to move, E to speed up, Space to climb, Shift to descend; right-click again to return to the take-off point (limits: @1 m above the take-off point, within @2 m horizontally)",
		("%d"):format(CEILING), ("%d"):format(cfg.drone_range)))
end

---------------------------------------------------------------------------
-- 飛行控制
---------------------------------------------------------------------------

core.register_globalstep(function(dtime)
	for name, f in pairs(flights) do
		local player = core.get_player_by_name(name)
		local d = f.drone
		local pos = d and d:get_pos()
		if not (player and pos) then
			land(name)
		else
			local ctrl = player:get_player_control()
			local yaw = player:get_look_horizontal()
			d:set_yaw(yaw)
			local fwd = (ctrl.up and 1 or 0) - (ctrl.down and 1 or 0)
			local side = (ctrl.right and 1 or 0) - (ctrl.left and 1 or 0)
			local v = SPEED * (ctrl.aux1 and BOOST or 1)
			-- 視線方向（yaw 0 = +z）與右手邊
			local fx, fz = -math.sin(yaw), math.cos(yaw)
			local rx, rz = math.cos(yaw), math.sin(yaw)
			local len = math.sqrt(fwd * fwd + side * side)
			local k = len > 0 and v / len or 0
			local vy = (ctrl.jump and CLIMB or 0) - (ctrl.sneak and CLIMB or 0)
			if vy > 0 and pos.y >= f.home.y + CEILING then vy = 0 end
			local vx, vz = (fwd * fx + side * rx) * k, (fwd * fz + side * rz) * k
			-- 最大飛行距離：離起飛點水平 drone_range 以外，往外的分量拿掉（往回、沿著邊界飛照常）
			local ox, oz = pos.x - f.home.x, pos.z - f.home.z
			local dist = math.sqrt(ox * ox + oz * oz)
			f.out = dist >= cfg.drone_range
			if f.out then
				local out = (vx * ox + vz * oz) / dist
				if out > 0 then vx, vz = vx - out * ox / dist, vz - out * oz / dist end
			end
			d:set_velocity({x = vx, y = vy, z = vz})
			-- 飛行時旋翼聲大一點、音高高一點：兩段交叉淡入淡出
			local moving = len > 0 or vy ~= 0
			if f.snd_hover and moving ~= f.moving then
				f.moving = moving
				local g = rockmech.cfg.vehicle_sound_gain or 1
				core.sound_fade(f.snd_hover, FADE, moving and SOUND_OFF or SOUND_HOVER * g)
				core.sound_fade(f.snd_move, FADE, moving and SOUND_MOVE * g or SOUND_OFF)
				core.sound_fade(f.psnd_hover, FADE * SOUND_PILOT, moving and SOUND_OFF or SOUND_HOVER * SOUND_PILOT * g)
				core.sound_fade(f.psnd_move, FADE * SOUND_PILOT, moving and SOUND_MOVE * SOUND_PILOT * g or SOUND_OFF)
			end
			-- 強制載入跟著走（換了區塊才重算）
			local bh = core.hash_node_position({x = math.floor(pos.x / 16), y = 0, z = math.floor(pos.z / 16)})
			if bh ~= f.block then f.block = bh; update_load(f, pos) end
			-- HUD（每 0.2 s）
			f.hud_t = (f.hud_t or 0) + dtime
			if f.hud_t >= 0.2 then
				f.hud_t = 0
				local vel = d:get_velocity()
				local g = ground_below(pos)
				local hd = math.sqrt((pos.x - f.home.x) ^ 2 + (pos.z - f.home.z) ^ 2)
				player:hud_change(f.hud, "text", S("Drone   Above ground @1   vs take-off point @2 m (limit +@3)   Distance @4 / @5 m   @6 km/h   Heading @7   Position @8\n@9",
					g and ("%.0f m"):format(pos.y - g) or "—", ("%+.0f"):format(pos.y - f.home.y), ("%d"):format(CEILING),
					("%.0f"):format(hd), ("%d"):format(cfg.drone_range),
					("%d"):format(math.floor(math.sqrt(vel.x ^ 2 + vel.y ^ 2 + vel.z ^ 2) * 3.6 + 0.5)), heading_text(yaw),
					("(%d, %d, %d)"):format(math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5)),
					(f.out and S("Maximum flight distance reached, can't fly further out   Right-click again to return to the take-off point")
						or S("Right-click again to return to the take-off point"))
					.. (player:get_wielded_item():get_name() == CMD and "   " .. S("Left-click to command: click an excavator or truck") or "")))
			end
		end
	end
end)

core.register_on_leaveplayer(function(player) land(player:get_player_name()) end)
-- 斷線、伺服器重開時沒能降落：登入就回到起飛點
core.register_on_joinplayer(function(player)
	local s = player:get_meta():get_string(HOME_KEY)
	if s ~= "" then
		local home = core.deserialize(s)
		player:get_meta():set_string(HOME_KEY, "")
		if home then core.after(0.5, function() if player:is_player() then player:set_pos(home) end end) end
	end
end)

---------------------------------------------------------------------------
-- 遙控器
---------------------------------------------------------------------------

local function click(itemstack, user)
	if not (user and user:is_player()) then return itemstack end
	local name = user:get_player_name()
	if flights[name] then land(name) else take_off(user) end
	return itemstack
end
rockmech.drone_toggle = function(user) click(nil, user) end
function rockmech.drone_flying(name) return flights[name] ~= nil end
function rockmech.drone_remote_item(item) return item == REMOTE or item == CMD end
core.register_craftitem(REMOTE, {
	description = S("Drone controller\nRight-click to take off / come back"),
	short_description = S("Drone remote"),
	inventory_image = "[fill:16x16:#00000000^[fill:12x8:2,6:#3a3a3a^[fill:4x4:3,8:#808080^[fill:4x4:9,8:#808080"
		.. "^[fill:1x6:3,0:#c0c0c0^[fill:1x6:12,0:#c0c0c0^[fill:2x2:7,9:#40c0ff",
	stack_max = 1,
	on_place = click,
	on_secondary_use = click,
})

-- 指揮無人機：無人機＋對講機。右鍵起飛／回到起飛點，左鍵就是對講機（vehicle_excavator.lua 的 rockmech.radio_click）：
-- 點怪手選定、點地面叫它開過去、點移動中的那台叫它停；點卡車、礦卡打開它的無人駕駛設定。
-- 從空中指得比地上的對講機遠（CMD_RANGE m）
core.register_craftitem(CMD, {
	description = S("Command drone\nRight-click to take off / come back; left-click to command"),
	short_description = S("Command drone"),
	inventory_image = "[fill:16x16:#00000000^[fill:12x8:2,6:#3a3a3a^[fill:4x4:3,8:#808080^[fill:4x4:9,8:#70c070"
		.. "^[fill:1x6:3,0:#c0c0c0^[fill:1x6:12,0:#c0c0c0^[fill:2x2:7,9:#ffb030",
	stack_max = 1,
	range = CMD_RANGE,
	on_use = function(itemstack, user, pointed)
		if user and user:is_player() and rockmech.radio_click then rockmech.radio_click(user, pointed) end
	end,
	on_place = click,
	on_secondary_use = click,
})
