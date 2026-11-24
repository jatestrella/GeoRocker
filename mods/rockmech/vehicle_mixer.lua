-- rockmech/vehicle_mixer.lua
-- 預拌車（混凝土車）。由 concrete.lua 載入。
--   空白鍵：叫料（付錢把拌筒裝滿，一車 CAP m³；錢不夠就叫買得起的量）。混凝土只在車上，不能卸到背包，收車時倒掉。
--   Shift＋E：瞄準模式（切到追蹤視角，再按一次回駕駛座）：溜槽轉過去、伸到準星指的地方（車尾左右各 SWING 度、
--     水平 REACH m 內；搆不到就停在邊界，提示為什麼）。瞄準、灌的時候不能開車。
--   E：灌準星指的那一格（離溜槽根部水平 REACH m 內），再按一次停：
--     特密管支架（rockmech.pour_targets）：從支架灌，每 POUR_TIME 秒 1 m³，到車上沒料或那一段灌滿。
--     其他地方：從溜槽口直接倒（每 POUR_TIME/8 秒 1 級），新拌混凝土照安息角流（concrete.lua）；WASD 照視線方向移動溜槽口，
--       一邊倒一邊攤。穿過水、穩定液倒下去會夾泥（凝固後強度打折），水中要用特密管。
--     灌的時候不能開車。

local S = rockmech.S
local V = rockmech.vehicles
local box_tex, update_hud = V.box_tex, V.update_hud
local WHEEL, TREAD = V.WHEEL, V.TREAD

local CAP = 6               -- 一車 (m³)
local PRICE = 300           -- 每 m³
local REACH = 4             -- 溜槽（含延長槽）根部到灌的地方的水平距離 (m)
local POUR_TIME = 3.0       -- 灌 1 m³ (s)
local CHUTE = {x = 0, y = 0.9, z = -4.75}    -- 溜槽根部（車身座標）
local SLOPE = 0.3           -- 溜槽往下的坡度
local REST = 1.0            -- 收著的溜槽長 (m)
local SWING = math.rad(90)  -- 左右各轉得到幾度（從車尾正後方量）
local ITEM = rockmech.CONCRETE_M3

local def = {desc = S("Concrete mixer truck"), color = "#e07020", cap = 0, speed = 5.0,
	top_speed = 12, accel = 1.5, max_grade = math.rad(17), look_limit = math.rad(75), tire = 1.0,
	half = 1.5, lat = {-1, 0, 1}, eye_up = 1.55, eye_fwd = 1.35, rear = 5.5, mirror = {x = 1.35, y = 1.3, z = 1.2},
	tilt = {front = 0.5, rear = -3.8, side_z = -1.6, side_x = 1.1},
	tail_lat = {-1.25, 0, 1.25}, tail_dy = {1.2, 2.2},
	store = {{ITEM, CAP, S("Ready-mix concrete (m³)"), buy = PRICE}},
	item_desc = S("Right-click to get in; Space orders concrete. Shift + E aims the chute; press E to pour where you point behind the truck (a tremie frame pours from the trench bottom), WASD moves the chute while pouring")}
do   -- 圖示：斜放的拌筒（白底橘色螺旋）、駕駛室、三軸
	local c, r = def.color, {}
	r[#r + 1] = {3, 11, 18, 11, "#e8e8e0"}; r[#r + 1] = {5, 12, 2, 9, c}; r[#r + 1] = {10, 11, 2, 11, c}; r[#r + 1] = {15, 12, 2, 10, c}
	r[#r + 1] = {1, 19, 3, 3, "#6c7278"}
	r[#r + 1] = {2, 22, 27, 2, "#2a2a2a"}
	r[#r + 1] = {23, 11, 7, 12, c}; r[#r + 1] = {25, 13, 4, 5, "#9fd0ff"}
	V.icon_wheel(r, 26, 26, 3); V.icon_wheel(r, 7, 26, 3); V.icon_wheel(r, 14, 26, 3)
	def.inv_image = V.icon(r)
end

do
	local c = def.color
	local cab_front = V.cab_glass(c, 2, 2, 12, 6) .. "^[fill:4x2:2,12:#f0e070^[fill:4x2:10,12:#f0e070"
	local cab_side = V.cab_side(c, {win = {x = 8, y = 2, w = 6, h = 6}, clear = true, doors = {{x = 6.5, y = 1, w = 8.5, h = 12.5}}})
	local cab_side_l = V.flip_side(cab_side)
	local drum = "[fill:16x16:#e8e8e0^[fill:3x16:1,0:" .. c .. "^[fill:3x16:9,0:" .. c
	local drum_end = "[fill:16x16:#d8d8d0^[fill:8x8:4,4:#b8b8b0"
	local wheel = {TREAD, TREAD, WHEEL, WHEEL, TREAD, TREAD}
	def.parts = {
		{pos = {x = 0, y = -0.55, z = -2.0}, size = {x = 1.6, y = 0.3, z = 6.6}, tex = box_tex("#2a2a2a")},   -- 底盤
		{pos = {x = 0, y = 0.6, z = 0.5}, size = {x = 2.4, y = 2.0, z = 2.0}, alpha = true,
			tex = {("[fill:16x16:%s"):format(c), "[fill:16x16:#2a2a2a", cab_side, cab_side_l, cab_front, ("[fill:16x16:%s"):format(c)}},   -- 駕駛室
		{pos = {x = 0, y = 0.6, z = -0.46}, size = {x = 2.36, y = 1.96, z = 0.04}, tex = box_tex(c)},   -- 駕駛室後牆
		{pos = {x = 0, y = -0.25, z = -2.9}, size = {x = 2.0, y = 0.3, z = 4.4}, tex = box_tex("#4a4a4a")},   -- 拌筒座
		{pos = {x = 0, y = 0.75, z = -2.6}, size = {x = 2.0, y = 1.9, z = 3.2}, tex = {drum, drum, drum, drum, drum_end, drum_end}},   -- 拌筒
		{pos = {x = 0, y = 0.95, z = -4.45}, size = {x = 1.3, y = 1.3, z = 0.5}, tex = box_tex("#d8d8d0")},   -- 拌筒尾
		{pos = {x = 0, y = 1.25, z = -4.85}, size = {x = 0.8, y = 0.5, z = 0.5}, tex = box_tex("#6c7278")},   -- 進料斗
		{id = "chute", pos = {x = 0, y = 0.75, z = -5.25}, size = {x = 0.5, y = 1.04, z = 0.12}, rot = {x = 106.7, y = 180, z = 0},
			tex = box_tex("#6c7278")},   -- 溜槽（長軸是自身 +Y，跟著視線轉：place_chute）
	}
	for _, w in ipairs({{x = -1.15, z = 0.5, wd = 0.35}, {x = 1.15, z = 0.5, wd = 0.35},
			{x = -1.1, z = -3.2, wd = 0.6}, {x = 1.1, z = -3.2, wd = 0.6}, {x = -1.1, z = -4.4, wd = 0.6}, {x = 1.1, z = -4.4, wd = 0.6}}) do
		def.parts[#def.parts + 1] = {pos = {x = w.x, y = -1.0, z = w.z}, size = {x = w.wd, y = 1.0, z = 1.0}, tex = wheel}
	end
end
def.overhangs = {{x0 = -1.3, x1 = 1.3, z0 = -5.5, z1 = -1.5, y0 = -1.5, y1 = 1.7, body = "z1"}}

-- 溜槽：車身座標裡的水平角 ang（從車尾正後方量、往右為正）、水平長 len
local function chute_tip(ang, len)
	return {x = CHUTE.x + math.sin(ang) * len, y = CHUTE.y - SLOPE * len, z = CHUTE.z - math.cos(ang) * len}
end
local function place_chute(self, ang, len)
	local o = self.parts and self.parts.chute
	if not o then return end
	if self.chute_ang and math.abs(self.chute_ang - ang) < 0.01 and math.abs(self.chute_len - len) < 0.05 then return end
	if not self.chute_len or math.abs(self.chute_len - len) >= 0.05 then
		o:set_properties({visual_size = {x = 0.5, y = len * math.sqrt(1 + SLOPE * SLOPE), z = 0.12}})
	end
	self.chute_ang, self.chute_len = ang, len
	V.seg_attach(self, o, CHUTE, chute_tip(ang, len))
end
local function clamp_ang(a) return math.max(-SWING, math.min(SWING, a)) end
-- 世界座標的一點 → 溜槽要轉的角度、水平距離、高差（車身座標）
local function chute_to(self, wp)
	local lp = V.to_local(self, wp)
	local dx, dz = lp.x - CHUTE.x, lp.z - CHUTE.z
	return V.atan2(dx, -dz), math.sqrt(dx * dx + dz * dz), lp.y - CHUTE.y
end
-- 準星指的那一格灌不灌得到：特密管支架 → 從支架灌（回傳 支架, true）；其他地方 → 從溜槽口直接倒在那一欄（回傳 那一格, false）；
-- 灌不到回傳 nil, 原因
local function pick_at(self, P)
	if not P then return nil, S("Point where to pour, behind the truck") end
	local frame = rockmech.pour_targets[core.get_node(P).name] ~= nil
	local ang, dist, dy = chute_to(self, {x = P.x, y = P.y + 0.5, z = P.z})
	if math.abs(ang) > SWING then return nil, S("The chute only reaches behind the truck") end
	if dist > REACH then return nil, S("Out of chute reach (@1 m, chute @2 m)", ("%.1f"):format(dist), REACH) end
	if frame then
		if dy > 0.5 or dy < -5 then return nil, S("The chute cannot reach that height") end
		return P, true
	end
	if dy > 0 then return nil, S("The chute cannot reach that height") end
	return P, false
end
rockmech.vehicle_mixer_pick = pick_at     -- 測試用

function def.hud(self)
	local s = "\n" .. S("Concrete @1 / @2 m³", ("%d"):format(V.store_count(self, ITEM)), CAP)
	if self.pouring then s = s .. "  " .. S("Pouring (@1 m³)", ("%d"):format(self.pouring.done)) end
	return s
end
function def.keys(self)
	local k = {{"Shift+E", S("Aim the chute"), on = self.aiming == true}, {"E", S("Pour where you point"), on = self.pouring ~= nil}}
	if self.pouring and self.pouring.open then k[#k + 1] = {"WASD", S("Move the chute")} end
	k[#k + 1] = {S("Space"), S("Order concrete")}
	return k
end
-- 瞄準、灌的時候 WASD 給溜槽用（不開車、Shift 不下車）
function def.hold_controls(self) return self.pouring ~= nil or self.aiming == true end
function def.can_turn(self, pos, yaw, yaw2)
	return not self.pouring and not self.aiming and V.tail_can_turn(self, pos, yaw, yaw2, def)
end
function def.move(self, ctx)
	if self.pouring or self.aiming then ctx.speed = 0; return end
	V.tail_guard(self, def, ctx)
end

local function finish(self, msg)
	self.pouring = nil
	self.msg = msg
	update_hud(self)
end

local CHUTE_SPEED = 1.5     -- WASD 移動溜槽口 (m/s)
local function pour_fx(self, from, to, dtime)
	local v = vector.multiply(vector.subtract(to, from), 1.6)
	core.add_particlespawner({
		amount = 6, time = dtime,
		minpos = vector.subtract(from, 0.1), maxpos = vector.add(from, 0.1),
		minvel = vector.add(v, {x = -0.1, y = 1.2, z = -0.1}), maxvel = vector.add(v, {x = 0.1, y = 1.6, z = 0.1}),
		minacc = {x = 0, y = -4, z = 0}, maxacc = {x = 0, y = -4, z = 0},
		minexptime = 0.5, maxexptime = 0.6, minsize = 1.5, maxsize = 2.5,
		texture = "[fill:4x4:#8c8c86",
	})
end

-- 直接倒（不是特密管）：每 POUR_TIME / 8 秒倒 1 級在溜槽口底下那一欄；WASD 照視線方向移動溜槽口
local function open_step(self, ctx, pm)
	local d = ctx.d
	local c = ctx.ctrl or {}
	if d then
		local f = (c.up and 1 or 0) - (c.down and 1 or 0)
		local s = (c.right and 1 or 0) - (c.left and 1 or 0)
		if f ~= 0 or s ~= 0 then
			local lh = d:get_look_horizontal()
			local hx, hz = -math.sin(lh) * f + math.cos(lh) * s, math.cos(lh) * f + math.sin(lh) * s
			local hl = math.sqrt(hx * hx + hz * hz)
			local step = CHUTE_SPEED * ctx.dtime / hl
			local nT = {x = pm.T.x + hx * step, y = pm.T.y, z = pm.T.z + hz * step}
			local ang, dist = chute_to(self, nT)
			if math.abs(ang) <= SWING and dist <= REACH and dist >= REST then pm.T = nT end
		end
	end
	local ang, dist = chute_to(self, pm.T)
	local ca, cl = clamp_ang(ang), math.max(REST, math.min(REACH, dist))
	place_chute(self, ca, cl)
	local tip = V.to_world(self, chute_tip(ca, cl))
	local x, z = math.floor(tip.x + 0.5), math.floor(tip.z + 0.5)
	pour_fx(self, tip, {x = x, y = pm.land or tip.y - 1, z = z}, ctx.dtime)
	pm.t = pm.t + ctx.dtime
	if pm.t < POUR_TIME / 8 then return end
	pm.t = 0
	if V.store_count(self, ITEM) < 1 then
		return finish(self, S("The truck is empty (poured @1 m³)", ("%d"):format(pm.done)))
	end
	local n, land, dirty = rockmech.concrete_pour_at(x, math.floor(tip.y + 0.5), z, 1, d and d:get_player_name())
	if n <= 0 then return finish(self, S("Something is in the way of the chute") .. " " .. S("(poured @1 m³)", ("%d"):format(pm.done))) end
	pm.land = land and land.y
	if dirty and not pm.warned then
		pm.warned = true
		self.msg = S("Poured through water: the concrete segregates and will be weak (use a tremie pipe)")
	end
	self.drum_lv = (self.drum_lv or 0) + 1
	if self.drum_lv >= 8 then
		self.drum_lv = 0
		V.store_take(self, ITEM, 1)
		pm.done = pm.done + 1
		update_hud(self)
	end
end

function def.step(self, ctx)
	local pm = self.pouring
	if not pm then
		local d = ctx.d
		if not d and self.aiming then self.aiming = nil end        -- 駕駛下車
		if not self.aiming then
			if self.chute_ang ~= 0 or self.chute_len ~= REST then place_chute(self, 0, REST) end
			return
		end
		-- 瞄準模式：溜槽伸到準星指的地方（每 0.1 s 找一次）
		self.aim_t = (self.aim_t or 0) - ctx.dtime
		if self.aim_t > 0 then return end
		self.aim_t = 0.1
		local hit = V.aim_node(self, d, def, REACH + 8)
		if not hit then return end
		local ang, dist = chute_to(self, {x = hit.under.x, y = hit.under.y + 0.5, z = hit.under.z})
		place_chute(self, clamp_ang(ang), math.max(REST, math.min(REACH, dist)))
		-- 指的東西灌不灌得到變了才換訊息（不然剛灌完的「車上沒料了」馬上被蓋掉）
		local _, why = pick_at(self, hit.under)
		if type(why) ~= "string" then why = nil end
		if why ~= self.aim_why then self.aim_why = why; self.msg = why; update_hud(self) end
		return
	end
	if pm.open then return open_step(self, ctx, pm) end
	local F = pm.frame
	local ang, dist = chute_to(self, {x = F.x, y = F.y + 0.5, z = F.z})
	local ca, cl = clamp_ang(ang), math.max(REST, math.min(REACH, dist))
	place_chute(self, ca, cl)
	pour_fx(self, V.to_world(self, chute_tip(ca, cl)), {x = F.x, y = F.y + 0.4, z = F.z}, ctx.dtime)
	pm.t = pm.t + ctx.dtime
	if pm.t < POUR_TIME then return end
	pm.t = 0
	if V.store_count(self, ITEM) < 1 then
		return finish(self, S("The truck is empty (poured @1 m³)", ("%d"):format(pm.done)))
	end
	local fn = rockmech.pour_targets[core.get_node(F).name]
	local ok, why
	if fn then ok, why = fn(F) else why = S("The tremie frame is gone") end
	if not ok then return finish(self, why .. " " .. S("(poured @1 m³)", ("%d"):format(pm.done))) end
	V.store_take(self, ITEM, 1)
	pm.done = pm.done + 1
	if V.store_count(self, ITEM) < 1 then
		return finish(self, S("The truck is empty (poured @1 m³)", ("%d"):format(pm.done)))
	end
	update_hud(self)
end

function def.action(self, ctx)
	local ctrl, d = ctx.ctrl, ctx.d
	if ctrl.aux1 and ctrl.sneak then
		-- 瞄準模式：切到追蹤視角（原本就在追蹤視角就不動），再按一次回到原來的視角、溜槽收回
		self.t_act = 0.5
		if self.pouring or not d then return end
		if self.aiming then
			self.aiming = nil
			if not self.aim_had_chase then V.set_chase(self, d, false) end
			self.msg = nil
		else
			self.aiming, self.aim_had_chase, self.aim_t, self.aim_why = true, self.chase ~= nil, 0, false
			V.set_chase(self, d, true)
		end
		update_hud(self)
	elseif ctrl.aux1 and not self.pouring then
		self.t_act = 0.5
		local hit = d and V.aim_node(self, d, def, REACH + 8)
		local P, frame = pick_at(self, hit and hit.under)
		if not P then
			self.msg = frame
		elseif V.store_count(self, ITEM) < 1 then
			self.msg = S("The drum is empty: press Space to order concrete")
		elseif frame then
			self.pouring = {frame = P, done = 0, t = 0}
			self.msg = nil
		else
			self.pouring = {open = true, T = {x = P.x, y = P.y + 0.5, z = P.z}, done = 0, t = 0}
			self.msg = nil
		end
		update_hud(self)
	elseif ctrl.aux1 and self.pouring then
		self.t_act = 0.5
		finish(self, S("Stopped (poured @1 m³)", ("%d"):format(self.pouring.done)))
	elseif ctrl.jump and d and not self.pouring then
		self.t_act = 0.5
		V.open_store(self, d)
	end
end

V.register("mixer", def)
