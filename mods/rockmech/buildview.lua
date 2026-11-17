-- rockmech/buildview.lua
-- 施工視角：拿著施工單（delivery.lua）按 E，鏡頭升到身後上方、斜著往下看，從空中放設施；再按一次 E 回到原地。
--   借用無人機的做法（drone.lua）：玩家附在一個看不見的鏡頭物件上，WASD 照視線方向水平移動、空白鍵上升、Shift 下降，
--   會撞到地形。沒有無人機的模型、旋翼聲、資訊列；別人看到你站在原地（一個跟你同外觀的替身）。
--   範圍：離進入點水平 cfg.build_view_range m（rockmech_build_view_range，預設 40）、高度最多比進入點高 CEILING m；
--   不強制載入區塊（不能拿來探索）。施工單在施工視角裡可及 REACH m（物品 meta "range"），出來就恢復。
--   施工視角裡只能施工（施工單的右鍵）、收回輸送帶（輸送帶施工單的左鍵）：其他的挖、點車、點 NPC、打人都不算
--   （這段期間對這位玩家來說到處都是保護區，施工那一下例外）。
--   E：拿著施工單時一律是進入／離開施工視角（輸送帶反向 conveyor.lua 不管拿著施工單的人）。
--   手上換成別的東西、斷線、伺服器重開：回到原地。

local cfg = rockmech.cfg
local S = rockmech.S
local CAM, STANDIN = "rockmech:build_cam", "rockmech:build_standin"
local SPEED, CLIMB = 10, 6          -- 水平、升降速度 (m/s)
local CEILING = 30                  -- 最高：進入點上方 (m)
local START_UP, START_BACK = 15, 10 -- 進入時鏡頭在身後上方
local REACH = 45                    -- 施工單在施工視角裡的可及距離 (m)
local HOME_KEY = "rockmech:build_view_home"

local views = {}        -- 玩家名稱 → {id, cam, standin, home, props, nametag, hud}
local e_down = {}
local placing = {}      -- 玩家名稱 → true：正在施工（這一下不算保護區）
local next_id = 0

local function is_order(item) return rockmech.order_target and rockmech.order_target(item) ~= nil end

---------------------------------------------------------------------------
-- 鏡頭物件、替身
---------------------------------------------------------------------------

core.register_entity(CAM, {
	initial_properties = {
		visual = "sprite", textures = {"blank.png"}, visual_size = {x = 0, y = 0},
		physical = true, collide_with_objects = false, collisionbox = {-0.3, -0.3, -0.3, 0.3, 0.3, 0.3},
		pointable = false, static_save = false, makes_footstep_sound = false,
	},
	on_step = function(self)
		local v = self.owner and views[self.owner]
		if not (v and v.id == self.view_id) then self.object:remove() end
	end,
})

core.register_entity(STANDIN, {
	initial_properties = {
		visual = "mesh", mesh = "character.b3d", textures = {"character.png"},
		physical = false, collide_with_objects = false, collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
		pointable = false, static_save = false,
	},
	on_step = function(self)
		local v = self.owner and views[self.owner]
		if not (v and v.id == self.view_id) then self.object:remove() end
	end,
})

---------------------------------------------------------------------------
-- 施工單的可及距離（物品 meta "range"）
---------------------------------------------------------------------------

local function set_reach(player, on)
	local inv = player:get_inventory()
	local list = inv:get_list("main") or {}
	local changed = false
	for i, st in ipairs(list) do
		if is_order(st:get_name()) then
			local m = st:get_meta()
			if on then m:set_float("range", REACH) else m:set_string("range", "") end
			list[i] = st
			changed = true
		end
	end
	if changed then inv:set_list("main", list) end
end

---------------------------------------------------------------------------
-- 進入、離開
---------------------------------------------------------------------------

local function leave(name)
	local v = views[name]
	if not v then return end
	views[name] = nil
	placing[name] = nil
	local player = core.get_player_by_name(name)
	if player then
		player:set_detach()
		player:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		player:set_camera({mode = "any"})
		if v.props then player:set_properties(v.props) end
		if v.nametag then player:set_nametag_attributes(v.nametag) end
		if rockmech.nametag_hide then rockmech.nametag_hide(name, false) end
		if v.hud then player:hud_remove(v.hud) end
		set_reach(player, false)
		-- 跟無人機一樣：解除附著和傳送同時送出時，玩家端有時會被蓋回空中的位置，下一刻、再下一刻各補一次
		local home = v.home
		player:set_pos(home)
		player:set_look_horizontal(v.yaw or player:get_look_horizontal())
		player:set_look_vertical(0)
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
	for _, o in ipairs({v.cam, v.standin}) do if o and o:get_pos() then o:remove() end end
end

-- 進入點身後上方的鏡頭位置：中間被擋住（房子、山壁）就改成正上方；兩條都被擋，取升得比較高的那個（停在擋住的前面）
local function start_pos(home, yaw)
	local eye = vector.add(home, {x = 0, y = 1.6, z = 0})
	local function reach(want)
		for pt in core.raycast(eye, want, false, false) do
			if pt.type == "node" then
				return vector.add(pt.intersection_point, vector.multiply(vector.direction(want, eye), 1)), false
			end
		end
		return want, true
	end
	local a, ok = reach(vector.add(home, {x = math.sin(yaw) * START_BACK, y = START_UP, z = -math.cos(yaw) * START_BACK}))
	if ok then return a end
	local b = reach(vector.add(home, {x = 0, y = START_UP, z = 0}))
	return b.y > a.y and b or a
end

local function enter(player)
	local name = player:get_player_name()
	if views[name] then return end
	local home = player:get_pos()
	local yaw = player:get_look_horizontal()
	local cam = core.add_entity(start_pos(home, yaw), CAM)
	if not cam then return end
	next_id = next_id + 1
	local v = {id = next_id, cam = cam, home = home, yaw = yaw,
		props = {visual_size = player:get_properties().visual_size, makes_footstep_sound = player:get_properties().makes_footstep_sound},
		nametag = player:get_nametag_attributes()}
	views[name] = v
	local ce = cam:get_luaentity()
	ce.owner, ce.view_id = name, next_id
	-- 替身：跟玩家同一個模型、外觀，站在原地
	local pp = player:get_properties()
	local sd = core.add_entity(home, STANDIN)
	if sd then
		local se = sd:get_luaentity()
		se.owner, se.view_id = name, next_id
		sd:set_properties({mesh = pp.mesh, textures = pp.textures, visual = pp.visual, visual_size = pp.visual_size})
		sd:set_yaw(yaw)
		local model = player_api and player_api.registered_models and player_api.registered_models[pp.mesh]
		local st = model and model.animations and model.animations.stand
		if st then sd:set_animation(st, model.animation_speed or 30, 0) end
		v.standin = sd
	end
	player:get_meta():set_string(HOME_KEY, core.serialize(home))
	player:set_properties({visual_size = {x = 0, y = 0, z = 0}, makes_footstep_sound = false})
	player:set_nametag_attributes({color = {a = 0, r = 255, g = 255, b = 255}, text = ""})
	if rockmech.nametag_hide then rockmech.nametag_hide(name, true) end
	player:set_attach(cam, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
	player:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
	player:set_camera({mode = "first"})
	player:set_look_vertical(math.rad(45))
	v.hud = player:hud_add({type = "text", position = {x = 0.5, y = 0.86}, alignment = {x = 0, y = -1},
		number = 0xffffff, text = S("Build view   E to exit"), z_index = 100})
	set_reach(player, true)
end

---------------------------------------------------------------------------
-- 每一步：E、換手上的東西、移動
---------------------------------------------------------------------------

core.register_globalstep(function()
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local ctrl = player:get_player_control()
		local press = ctrl.aux1 and not e_down[name]
		e_down[name] = ctrl.aux1
		local v = views[name]
		if v then
			local pos = v.cam and v.cam:get_pos()
			if press or not pos or not is_order(player:get_wielded_item():get_name()) then
				leave(name)
			else
				local yaw = player:get_look_horizontal()
				local fwd = (ctrl.up and 1 or 0) - (ctrl.down and 1 or 0)
				local side = (ctrl.right and 1 or 0) - (ctrl.left and 1 or 0)
				local fx, fz = -math.sin(yaw), math.cos(yaw)
				local rx, rz = math.cos(yaw), math.sin(yaw)
				local len = math.sqrt(fwd * fwd + side * side)
				local k = len > 0 and SPEED / len or 0
				local vx, vz = (fwd * fx + side * rx) * k, (fwd * fz + side * rz) * k
				local vy = (ctrl.jump and CLIMB or 0) - (ctrl.sneak and CLIMB or 0)
				if vy > 0 and pos.y >= v.home.y + CEILING then vy = 0 end
				-- 離進入點水平 build_view_range 以外：往外的分量拿掉
				local ox, oz = pos.x - v.home.x, pos.z - v.home.z
				local dist = math.sqrt(ox * ox + oz * oz)
				if dist >= cfg.build_view_range then
					-- 沿著邊界橫移時切線方向會讓距離一直變大（慢慢滑出去）：超過就拉回邊界上
					if dist > cfg.build_view_range then
						local k2 = cfg.build_view_range / dist
						v.cam:set_pos({x = v.home.x + ox * k2, y = pos.y, z = v.home.z + oz * k2})
					end
					local out = (vx * ox + vz * oz) / dist
					if out > 0 then vx, vz = vx - out * ox / dist, vz - out * oz / dist end
				end
				v.cam:set_velocity({x = vx, y = vy, z = vz})
			end
		elseif press and is_order(player:get_wielded_item():get_name()) and not player:get_attach()
				and not (rockmech.drone_flying and rockmech.drone_flying(name)) then
			enter(player)
		end
	end
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	leave(name)
	e_down[name] = nil
end)
core.register_on_joinplayer(function(player)
	local s = player:get_meta():get_string(HOME_KEY)
	if s ~= "" then
		local home = core.deserialize(s)
		player:get_meta():set_string(HOME_KEY, "")
		if home then core.after(0.5, function() if player:is_player() then player:set_pos(home) end end) end
	end
	core.after(0.6, function() if player:is_player() then set_reach(player, false) end end)
end)

---------------------------------------------------------------------------
-- 給其他檔案用
---------------------------------------------------------------------------

function rockmech.build_view_active(name) return views[name] ~= nil end
rockmech.build_view_enter, rockmech.build_view_leave = enter, leave      -- 測試用
function rockmech.build_view_reach(name) return views[name] and REACH or nil end
-- 施工視角裡的人本人站在進入點（替身）：施工範圍不能蓋到（delivery.lua 的 cells_blocked）
function rockmech.build_view_homes()
	local t = {}
	for name, v in pairs(views) do t[#t + 1] = {name = name, pos = v.home} end
	return t
end
-- 施工那一下（delivery.lua 的施工單 on_place／on_use 包住原本的動作）
function rockmech.build_view_placing(name, on) placing[name] = on or nil end

-- 施工視角裡，對這位玩家來說到處都是保護區（挖不了、放不了），施工那一下例外
local old_protected = core.is_protected
function core.is_protected(pos, name)
	if name and views[name] and not placing[name] then return true end
	return old_protected(pos, name)
end
-- 點車、點 NPC、打東西：都不算
core.register_on_mods_loaded(function()
	for _, def in pairs(core.registered_entities) do
		local rc, pu = def.on_rightclick, def.on_punch
		if rc then
			def.on_rightclick = function(self, clicker, ...)
				if clicker and clicker.is_player and clicker:is_player() and views[clicker:get_player_name()] then return end
				return rc(self, clicker, ...)
			end
		end
		if pu then
			def.on_punch = function(self, puncher, ...)
				if puncher and puncher.is_player and puncher:is_player() and views[puncher:get_player_name()] then return true end
				return pu(self, puncher, ...)
			end
		end
	end
	for name, def in pairs(core.registered_nodes) do
		if def.on_rightclick then
			local rc = def.on_rightclick
			core.override_item(name, {on_rightclick = function(pos, node, clicker, ...)
				if clicker and clicker.is_player and clicker:is_player() and views[clicker:get_player_name()] then return end
				return rc(pos, node, clicker, ...)
			end})
		end
	end
end)
core.register_on_punchplayer(function(player, hitter)
	if hitter and hitter.is_player and hitter:is_player() and views[hitter:get_player_name()] then return true end
end)
