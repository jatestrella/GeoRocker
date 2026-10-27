-- rockmech/vehicle_excavator.lua
-- 挖土機（3×3×3：兩側半格寬履帶、2×2×2 駕駛艙、前方動臂與鏟斗）。由 vehicles.lua 載入。
--   E：挖斗伸到滑鼠指的位置（10 m 內），挖起那一格周圍 3×3×3 的碎石（鏟斗 4 m³ = 32 級）再收回；
--   空白鍵：挖斗伸到滑鼠指的位置倒出（指著有車斗的車就倒進車斗），同樣的抬起 → 下降 → 倒 → 收回動作。
--   第一人稱駕駛時上部結構（駕駛艙＋手臂）跟著視線的水平方向迴轉；追蹤相機（第三人稱）時不跟

local V = rockmech.vehicles
local TYPES, NLEV = V.TYPES, V.NLEV
local h2v, v2h, lerp, lerp_angle, atan2 = V.h2v, V.v2h, V.lerp, V.lerp_angle, V.atan2
local box_tex, seg_attach, to_local = V.box_tex, V.seg_attach, V.to_local
local load_total, update_hud = V.load_total, V.update_hud

local def = {desc = "挖土機 Excavator", color = "#e0a020", cap = 4 * NLEV, speed = 2.0,
	half = 1.5, lat = {-1, 0, 1}, eye_up = 1.65, eye_fwd = 0.45, mirror = {x = 1.15, y = 1.3, z = 0.4},
	tilt = {front = 1.3, rear = -1.3, side_z = 0, side_x = 1.25},
	item_desc = "右鍵上車；E 挖滑鼠指的位置（鏟斗 4 m³）、空白鍵倒在滑鼠指的位置（指著卡車就倒進卡車）"}
def.inv_image = V.inv_icon(def.color, "^[fill:12x5:2,8:#505050^[fill:2x6:7,2:#404040")   -- 鏟斗與手臂

-- 外觀：兩側半格寬履帶、下車架、2×2×2 駕駛艙（偏後）、前方動臂與鏟斗（鏟斗可伸出碰撞箱，只是外觀）
local TRACK = V.TRACK
local CAB_POS = {x = 0, y = 0.5, z = -0.5}
local PARTS = {
	{pos = {x = -1.25, y = -1.0, z = 0}, size = {x = 0.5, y = 1.0, z = 3.0}, tex = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}},
	{pos = {x = 1.25, y = -1.0, z = 0}, size = {x = 0.5, y = 1.0, z = 3.0}, tex = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}},
	{pos = {x = 0, y = -1.0, z = 0}, size = {x = 2.0, y = 1.0, z = 2.6}, tex = box_tex("#3a3a3a")},
	{id = "cab", pos = CAB_POS, size = {x = 2.0, y = 2.0, z = 2.0},
		tex = (function()
			local c = def.color
			local win = ("[fill:16x16:%s^[fill:12x7:2,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
			local side = ("[fill:16x16:%s^[fill:6x6:8,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
			return {("[fill:16x16:%s"):format(c), "[fill:16x16:#2a2a2a", side, side, win, ("[fill:16x16:%s"):format(c)}
		end)()},
	{id = "bucket", pos = {x = 0.55, y = -0.9, z = 2.6}, size = {x = 1.3, y = 0.8, z = 0.7}, tex = box_tex("#505050")},
}
-- 手臂（兩節、長度固定的長方體，像真的怪手）：動臂從駕駛艙前方（BOOM_ROOT）到手肘、斗桿從手肘到挖斗。
-- 給定挖斗位置，手肘由兩節長度以餘弦定理求出（手肘朝上）；長方體沿各節方向旋轉（seg_attach）
local BOOM_ROOT = {x = 0.55, y = 0.3, z = 0.7}       -- 駕駛艙前方（駕駛的右手邊）
local BUCKET_REST = {x = 0.55, y = -0.9, z = 2.6}    -- 收起時挖斗在車頭前方約 1.1 m
local BOOM_LEN, STICK_LEN = 3.6, 3.0
local ARM_REACH = BOOM_LEN + STICK_LEN
PARTS[#PARTS + 1] = {id = "boom", pos = BUCKET_REST, size = {x = 0.5, y = BOOM_LEN, z = 0.5}, tex = box_tex(def.color)}
PARTS[#PARTS + 1] = {id = "stick", pos = BUCKET_REST, size = {x = 0.4, y = STICK_LEN, z = 0.4}, tex = box_tex(def.color)}
-- 鏟斗裡的碎石：高度依載量（空 → 不顯示），貼圖用載最多的那種碎石
PARTS[#PARTS + 1] = {id = "fill", pos = BUCKET_REST, size = {x = 1.1, y = 0.2, z = 0.55}, tex = box_tex("#6a6058")}
def.parts = PARTS

local DIG_REACH = 10        -- 挖斗最遠 (m，從相機量)
-- 挖的動作：抬到目標上方 DIG_LIFT → 往下插進目標（挖）→ 抬回目標上方 → 收回。各段時間 (s)
local DIG_LIFT = 2.0
local DIG_PHASES = {0.3, 0.2, 0.2, 0.3}
local DIG_TOTAL = DIG_PHASES[1] + DIG_PHASES[2] + DIG_PHASES[3] + DIG_PHASES[4]
local SWING_RATE = 1.5      -- 上部結構跟著視線迴轉的最大速度（rad/s；真的怪手約 1 rad/s）
local DUMP_REACH = 6        -- HUD 顯示前方車斗載量的距離 (m)

-- 挖斗位置 b（上部結構座標）→ 實際搆得到的挖斗位置、手肘位置
local function arm_solve(b)
	local dx, dy, dz = b.x - BOOM_ROOT.x, b.y - BOOM_ROOT.y, b.z - BOOM_ROOT.z
	local hl = math.sqrt(dx * dx + dz * dz)
	local hx, hz = 0, 1
	if hl > 1e-6 then hx, hz = dx / hl, dz / hl end
	local D = math.sqrt(hl * hl + dy * dy)
	local Dmin, Dmax = math.abs(BOOM_LEN - STICK_LEN) + 0.05, ARM_REACH - 0.05
	local phi = atan2(dy, hl)
	if D > Dmax or D < Dmin then
		D = math.max(Dmin, math.min(Dmax, D))
		b = {x = BOOM_ROOT.x + D * math.cos(phi) * hx, y = BOOM_ROOT.y + D * math.sin(phi), z = BOOM_ROOT.z + D * math.cos(phi) * hz}
	end
	local cosA = (BOOM_LEN * BOOM_LEN + D * D - STICK_LEN * STICK_LEN) / (2 * BOOM_LEN * D)
	local ang = phi + math.acos(math.max(-1, math.min(1, cosA)))
	local elbow = {x = BOOM_ROOT.x + BOOM_LEN * math.cos(ang) * hx, y = BOOM_ROOT.y + BOOM_LEN * math.sin(ang),
		z = BOOM_ROOT.z + BOOM_LEN * math.cos(ang) * hz}
	return b, elbow
end

-- 鏟斗裡的碎石（parts.fill）：跟著載量改高度與貼圖，擺在挖斗上面
local function place_fill(self, b, psi)
	local o = self.parts and self.parts.fill
	if not o then return end
	local total, best = V.load_mix(self)
	local frac = math.min(1, total / def.cap)
	local h = frac > 0 and (0.12 + 0.6 * frac) or 0
	local key = ("%.2f/%s"):format(h, tostring(best))
	if self.fill_key ~= key then
		self.fill_key = key
		if h > 0 then
			local t = V.rubble_tex(best)
			o:set_properties({is_visible = true, visual_size = {x = 1.1, y = h, z = 0.55}, textures = {t, t, t, t, t, t}})
		else
			o:set_properties({is_visible = false})
		end
	end
	o:set_attach(self.object, "", {x = b.x * 10, y = (b.y + 0.4 + h / 2) * 10, z = b.z * 10}, {x = 0, y = math.deg(psi or 0), z = 0})
end

-- 挖斗放在 b（上部結構座標）；上部結構迴轉 self.swing
local function place_arm(self, b)
	local parts = self.parts
	if not parts then return end
	local psi = self.swing or 0
	local elbow
	b, elbow = arm_solve(b)
	local vb, ve, vr = h2v(b, psi), h2v(elbow, psi), h2v(BOOM_ROOT, psi)
	local rot = {x = 0, y = math.deg(psi), z = 0}
	if parts.cab then
		local c = h2v(CAB_POS, psi)
		parts.cab:set_attach(self.object, "", {x = c.x * 10, y = c.y * 10, z = c.z * 10}, rot)
	end
	if parts.bucket then parts.bucket:set_attach(self.object, "", {x = vb.x * 10, y = vb.y * 10, z = vb.z * 10}, rot) end
	place_fill(self, vb, psi)
	self.bucket_at = vb
	seg_attach(self, parts.boom, vr, ve)
	seg_attach(self, parts.stick, ve, vb)
end

-- 目標（車身座標）→ 上部結構要轉的角度、目標在上部結構座標、離動臂根部的距離
local function swing_to(tl)
	local psi = atan2(tl.x, tl.z)
	local h = v2h(tl, psi)
	local reach = math.sqrt((h.x - BOOM_ROOT.x) ^ 2 + (h.y - BOOM_ROOT.y) ^ 2 + (h.z - BOOM_ROOT.z) ^ 2)
	return psi, h, reach
end

-- 有車斗的車（卡車等，TYPES[kind].bed）
local function hauler_def(e)
	local hd = e and e.vkind and TYPES[e.vkind]
	return hd and hd.bed and hd
end

-- 滑鼠指的東西：從駕駛的相機沿視線找。回傳 {under, above}（方塊）或 {truck = 有車斗的車}；沒有回傳 nil。
-- with_trucks：也找有車斗的車（跳過自己、零件與玩家）
local function aim(self, d, pos, with_trucks)
	local look = d:get_look_dir()
	local hl = math.sqrt(look.x * look.x + look.z * look.z)
	local eye = {x = pos.x + (hl > 0 and look.x / hl or 0) * def.eye_fwd, y = pos.y + def.eye_up,
		z = pos.z + (hl > 0 and look.z / hl or 0) * def.eye_fwd}
	local reach = DIG_REACH
	if self.chase and self.chase:get_pos() then
		eye = vector.add(self.chase:get_pos(), {x = 0, y = V.EYE_HEIGHT, z = 0})
		reach = DIG_REACH + 12   -- 追蹤相機在車子後方，射線要長一點
	end
	-- 先找方塊
	local node_hit, node_t
	for pt in core.raycast(eye, vector.add(eye, vector.multiply(look, reach)), false, false) do
		if pt.type == "node" then
			node_hit = {under = pt.under, above = pt.above}
			node_t = vector.distance(eye, pt.intersection_point)
			break
		end
	end
	-- 再找有車斗的車：沿視線每 0.2 m 檢查是否落在車身內（照車子朝向旋轉；伺服器的射線不會旋轉選取框）
	if with_trucks then
		local trucks = {}
		for _, o in ipairs(core.get_objects_inside_radius(eye, reach + 12)) do
			local e = o:get_luaentity()
			if e and e ~= self and hauler_def(e) then trucks[#trucks + 1] = e end
		end
		if #trucks > 0 then
			local tmax = node_t or reach
			for t = 0, tmax, 0.2 do
				local p = vector.add(eye, vector.multiply(look, t))
				for _, e in ipairs(trucks) do
					local tp, ty = e.object:get_pos(), e.object:get_yaw()
					if tp then
						local dx, dy, dz = p.x - tp.x, p.y - tp.y, p.z - tp.z
						local c, sn = math.cos(ty), math.sin(ty)
						local lx, lz = dx * c + dz * sn, -dx * sn + dz * c
						local td = TYPES[e.vkind]
						if math.abs(lx) <= td.half - 0.1 and dy >= -td.half and dy <= td.bed.aim_top
							and lz >= -td.rear and lz <= td.half then
							return {truck = e}
						end
					end
				end
			end
		end
	end
	return node_hit
end
rockmech.vehicle_aim = aim   -- 測試用

-- 車頭前方的有車斗的車（HUD 顯示它的載量）
local function find_truck(pos, s)
	local dd = def.half + 1.5
	local front = {x = pos.x + s.x * dd, y = pos.y, z = pos.z + s.z * dd}
	for _, obj in ipairs(core.get_objects_inside_radius(front, DUMP_REACH)) do
		local e = obj:get_luaentity()
		if hauler_def(e) then return e end
	end
end

function def.hud(self)
	local s = ""
	local p = self.object:get_pos()
	local truck = p and find_truck(p, select(2, V.dirs(self.object:get_yaw())))
	if truck then
		local tt, cap = load_total(truck), TYPES[truck.vkind].cap
		s = s .. ("\n前方%s：%d / %d 級（%.1f / %.0f m³）"):format(TYPES[truck.vkind].short, tt, cap, tt / NLEV, cap / NLEV)
	end
	if self.msg then s = s .. "\n" .. self.msg end
	return s .. "\nE 挖滑鼠指的位置　空白鍵 倒在滑鼠指的位置（指著卡車就倒進卡車）"
end

-- 擋人：鏟斗（跟著手臂動；用把鏟斗連同裡面的碎石包起來的方塊，不照迴轉角轉）
function def.overhangs_now(self)
	local b = self.bucket_at
	if not b then return nil end
	return {{x0 = b.x - 0.7, x1 = b.x + 0.7, z0 = b.z - 0.7, z1 = b.z + 0.7, y0 = b.y - 0.45, y1 = b.y + 0.9}}
end

function def.on_load(self, data) self.swing = data.swing end
function def.on_save(self, data) data.swing = self.swing end
function def.on_spawn(self) place_arm(self, BUCKET_REST) end

-- 倒出鏟斗：倒進車斗（裝得下多少倒多少），或倒在指到的那格（與周圍 3×3 欄，之後依安息角攤開）
local function dump_bucket(self, dg)
	local truck = dg.truck
	if truck and truck.object:get_pos() then
		local room = TYPES[truck.vkind].cap - load_total(truck)
		for base, lv in pairs(self.load) do
			local m = math.min(lv, room)
			if m > 0 then
				truck.load[base] = (truck.load[base] or 0) + m
				room = room - m
				self.load[base] = lv - m > 0 and (lv - m) or nil
			end
		end
		if load_total(self) > 0 then self.msg = TYPES[truck.vkind].short .. "滿了" end
		V.refresh(truck)
		update_hud(truck)
	elseif dg.target then
		local a = dg.target
		local cells = {}
		for dx = -1, 1 do for dz = -1, 1 do cells[#cells + 1] = {x = a.x + dx, y = a.y, z = a.z + dz} end end
		table.sort(cells, function(u, v) return math.abs(u.x - a.x) + math.abs(u.z - a.z) < math.abs(v.x - a.x) + math.abs(v.z - a.z) end)
		V.dump_to_ground(self, cells, a.y + 1)
	end
	update_hud(self)
end

-- 挖起目標周圍 3×3×3 的碎石（上層、離中心近的先）
local function dig_bucket(self, target)
	local want = def.cap - load_total(self)
	local cells = {}
	for dx = -1, 1 do for dz = -1, 1 do for dy = 1, -1, -1 do
		cells[#cells + 1] = {x = target.x + dx, y = target.y + dy, z = target.z + dz}
	end end end
	table.sort(cells, function(a, b)
		if a.y ~= b.y then return a.y > b.y end
		return math.abs(a.x - target.x) + math.abs(a.z - target.z) < math.abs(b.x - target.x) + math.abs(b.z - target.z)
	end)
	local got = 0
	for _, c in ipairs(cells) do
		if want <= 0 then break end
		local t, base = V.take_rubble(c, want)
		if t > 0 then
			self.load[base] = (self.load[base] or 0) + t
			want = want - t
			got = got + t
		end
	end
	if got == 0 then
		self.msg = want <= 0 and "鏟斗滿了，先倒掉（空白鍵）" or "那裡沒有碎石（岩石要先爆破）"
	end
	update_hud(self)
end

function def.step(self, ctx)
	-- 挖斗：抬到目標上方 → 往下插進目標（挖／倒）→ 抬回目標上方 → 收回
	if self.dig then
		local dg = self.dig
		dg.t = dg.t + ctx.dtime
		if not dg.done and dg.t >= DIG_PHASES[1] + DIG_PHASES[2] then
			dg.done = true
			if dg.mode == "dump" then dump_bucket(self, dg) else dig_bucket(self, dg.target) end
		end
		-- 抬起時上部結構轉向目標；挖完收回時轉回車頭（跟著視線時不轉回），倒完就停在倒的方向
		local to = dg.to
		local above = {x = to.x, y = to.y + DIG_LIFT, z = to.z}
		local t, ph = dg.t, DIG_PHASES
		local b
		if t < ph[1] then
			b = lerp(BUCKET_REST, above, t / ph[1])
			self.swing = lerp_angle(dg.psi0, dg.psi, t / ph[1])
		elseif t < ph[1] + ph[2] then b = lerp(above, to, (t - ph[1]) / ph[2]); self.swing = dg.psi
		elseif t < ph[1] + ph[2] + ph[3] then b = lerp(to, above, (t - ph[1] - ph[2]) / ph[3]); self.swing = dg.psi
		else
			local u = math.min(1, (t - ph[1] - ph[2] - ph[3]) / ph[4])
			b = lerp(above, BUCKET_REST, u)
			local back = (dg.mode == "dump" or self.follow) and dg.psi or 0
			self.swing = lerp_angle(dg.psi, back, u)
		end
		place_arm(self, b)
		if t >= DIG_TOTAL then
			self.dig = nil
			self.swing = (dg.mode == "dump" or self.follow) and dg.psi or 0
			place_arm(self, BUCKET_REST)
		end
	end
	-- 第一人稱駕駛：上部結構轉向視線的水平方向（車身座標的迴轉角 ψ 往右為正，實體 yaw 往左為正）
	local d = ctx.d
	self.follow = d ~= nil and not self.chase
	if self.follow and not self.dig and self.parts then
		local goal = ctx.yaw - d:get_look_horizontal()
		local cur = self.swing or 0
		local diff = (goal - cur + math.pi) % (2 * math.pi) - math.pi
		if math.abs(diff) > 1e-3 then
			local st = SWING_RATE * ctx.dtime
			self.swing = cur + math.max(-st, math.min(st, diff))
			place_arm(self, BUCKET_REST)
		end
	end
end

function def.action(self, ctx)
	local ctrl, d, pos = ctx.ctrl, ctx.d, ctx.pos
	if ctrl.aux1 and not self.dig then
		self.t_act = DIG_TOTAL + 0.1
		-- 滑鼠指的方塊：從相機沿視線找第一個方塊
		local target = self.autopilot and self.autopilot.target
		if d then
			local hit = aim(self, d, pos, false)
			target = hit and hit.under
		end
		local tl = target and to_local(self, target)
		local psi, th, reach
		if tl then psi, th, reach = swing_to(tl) end
		if tl and reach > ARM_REACH then
			self.msg = ("超出手臂範圍（%.1f m，手臂約 %.1f m）"):format(reach, ARM_REACH)
		elseif target then
			self.dig = {t = 0, mode = "dig", target = target, to = th, psi = psi, psi0 = self.swing or 0}
			self.msg = nil
		else
			self.msg = "挖斗搆不到（10 m 內沒有方塊）"
		end
		update_hud(self)
	elseif ctrl.jump and load_total(self) > 0 and not self.dig then
		self.t_act = DIG_TOTAL + 0.1
		local hit
		if d then hit = aim(self, d, pos, true)
		elseif self.autopilot then
			local t = self.autopilot.dump_target
			hit = self.autopilot.dump_truck and {truck = self.autopilot.dump_truck}
				or t and {above = {x = t.x, y = t.y + 1, z = t.z}}
		end
		local dg
		if hit and hit.truck then
			dg = {t = 0, mode = "dump", truck = hit.truck, to = to_local(self, V.bed_target(hit.truck))}
		elseif hit and hit.above then
			local a = hit.above
			dg = {t = 0, mode = "dump", target = a, to = to_local(self, {x = a.x, y = a.y + 0.8, z = a.z})}
		elseif d then
			-- 10 m 內沒有指到方塊：沿視線取遠處一點，下面抓最遠距離倒
			dg = {t = 0, mode = "dump", to = to_local(self, vector.add(pos, vector.multiply(d:get_look_dir(), 30)))}
		end
		local reach
		if dg then
			dg.psi, dg.to, reach = swing_to(dg.to)
			dg.psi0 = self.swing or 0
			if reach > ARM_REACH and dg.truck then
				self.msg = ("搆不到車斗（%.1f m，手臂約 %.1f m）"):format(reach, ARM_REACH)
			else
				if reach > ARM_REACH then
					-- 超出手臂範圍：挖斗伸到同一方向最遠處，倒在那一點正下方
					local k = (ARM_REACH - 0.2) / reach
					local b = {x = BOOM_ROOT.x + (dg.to.x - BOOM_ROOT.x) * k, y = BOOM_ROOT.y + (dg.to.y - BOOM_ROOT.y) * k,
						z = BOOM_ROOT.z + (dg.to.z - BOOM_ROOT.z) * k}
					dg.to = b
					dg.target = vector.round(V.to_world(self, h2v(b, dg.psi)))
					self.msg = ("超出手臂範圍，倒在最遠處（約 %.1f m）"):format(ARM_REACH)
				else
					self.msg = nil
				end
				self.dig = dg
			end
		else
			self.msg = "要倒在哪裡？（10 m 內沒有方塊或卡車）"
		end
		update_hud(self)
	end
end

V.register("excavator", def)
