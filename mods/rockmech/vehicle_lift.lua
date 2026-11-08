-- rockmech/vehicle_lift.lua
-- 高空作業車（雲梯車）、吊車（吊籠）：把人送到高處的邊坡面施作護坡（岩栓、噴凝土、監測稜鏡…）。由 vehicles.lua 載入。
-- 流程：開到邊坡前 → E 放固定腳（OUT_T 秒；車身傾斜不超過 5°、四支腳底下都有地面）→ 空白鍵進作業籠
--   作業籠裡：WASD 照視線方向水平移動、空白鍵上升、Shift 下降（碰到方塊、到作業範圍邊界就停）；
--             E 回駕駛座（作業籠自動收回原位）；Shift＋E 跨出去：人站在作業籠裡但可以自由走動、自己跳出去，
--             對作業籠右鍵再回到操作。
--   固定腳伸出時車子不能開；作業籠收回原位才能收固定腳。
-- 作業範圍（作業籠中心，車身座標）：離轉台軸的水平距離 rmin..rmax、高度 ymin..ymax、吊臂長 Lmin..Lmax。
--   高空作業車：伸縮臂前端就是作業籠（作業籠保持水平）；吊車：臂尖垂下鋼索吊著吊籠，可以往下吊到車底下。
-- 手臂由作業籠的位置反推：轉台轉向作業籠、伸縮臂從轉台軸指到臂尖，幾節等長的臂身沿臂均勻排開（伸出多少看重疊多少）。

local S = rockmech.S
local V = rockmech.vehicles
local box_tex, update_hud, seg_attach = V.box_tex, V.update_hud, V.seg_attach
local h2v, atan2 = V.h2v, V.atan2

local OUT_T = 3                       -- 固定腳伸出、收回 (s)
local MAX_TILT = math.rad(5)
local BK = {x = 1.8, y = 1.1, z = 1.2}   -- 作業籠（寬、欄杆高、深）
local FLOOR = "rockmech:lift_floor"
local RETURN_SPEED = 2.5              -- 收回原位 (m/s)

-- 作業籠的地板（跨出去時給人站）：不掛在車上的實體，有碰撞，右鍵回到操作
core.register_entity(FLOOR, {
	initial_properties = {
		physical = true, collide_with_objects = false, pointable = true, static_save = false,
		collisionbox = {-0.6, -0.05, -0.6, 0.6, 0.05, 0.6}, selectionbox = {-0.9, -0.05, -0.9, 0.9, 1.0, 0.9},
		visual = "sprite", textures = {"[fill:1x1:#00000000"}, use_texture_alpha = true,
	},
	on_step = function(self)
		local v = self.vehicle and self.vehicle:get_luaentity()
		if not (v and v.lift and v.lift.floor == self.object) then self.object:remove() end
	end,
	on_rightclick = function(self, clicker)
		local v = self.vehicle and self.vehicle:get_luaentity()
		if v and v.lift_board then v:lift_board(clicker) end
	end,
	on_punch = function() return true end,
})

local function lift(kind, P)
	local def = P.def
	local P0, REST = P.pivot, P.rest
	local NSEC = math.ceil(P.Lmax / (P.Lmin - 0.4))
	local LS = P.Lmin                     -- 每節臂身的長度（全縮時全部重疊）

	-- 底盤（跟卡車一樣：駕駛室在 z −0.5..1.5，車尾到 z −5.5）
	local c = def.color
	local cab_front = ("[fill:16x16:%s^[fill:12x6:2,2:#9fd0ff^[fill:4x2:2,12:#f0e070^[fill:4x2:10,12:#f0e070"):format(c)
	local cab_side = ("[fill:16x16:%s^[fill:6x6:8,2:#9fd0ff"):format(c)
	local wheel = {V.TREAD, V.TREAD, V.WHEEL, V.WHEEL, V.TREAD, V.TREAD}
	local parts = {
		{pos = {x = 0, y = -0.55, z = -2.0}, size = {x = 2.0, y = 0.3, z = 7.0}, tex = box_tex("#2a2a2a")},     -- 底盤
		-- 後段車體：有厚度的箱型（引擎、液壓油箱、固定腳箱都在裡面），上面是轉台座；輪子上半埋在輪拱裡
		{pos = {x = 0, y = -0.35, z = -3.0}, size = {x = 2.4, y = 1.3, z = 5.0},
			tex = {"[fill:16x16:#5a5e62^[fill:16x1:0,0:#4a4e52^[fill:16x1:0,15:#4a4e52",
				"[fill:16x16:#2a2a2a",
				("[fill:16x16:%s^[fill:16x2:0,12:#2a2a2a^[fill:3x8:2,3:#3a3a3a^[fill:3x8:7,3:#3a3a3a^[fill:3x8:12,3:#3a3a3a"):format(c),
				("[fill:16x16:%s^[fill:16x2:0,12:#2a2a2a^[fill:3x8:2,3:#3a3a3a^[fill:3x8:7,3:#3a3a3a^[fill:3x8:12,3:#3a3a3a"):format(c),
				("[fill:16x16:%s"):format(c),
				"[fill:16x16:#e8c020^[fill:3x16:0,0:#202020^[fill:3x16:6,0:#202020^[fill:3x16:12,0:#202020^[fill:4x3:1,2:#c02020^[fill:4x3:11,2:#c02020"}},
		{pos = {x = 0, y = 0.6, z = 0.5}, size = {x = 2.4, y = 2.0, z = 2.0},
			tex = {("[fill:16x16:%s"):format(c), "[fill:16x16:#2a2a2a", cab_side, cab_side, cab_front, ("[fill:16x16:%s"):format(c)}},
	}
	for _, w in ipairs({{x = -1.15, z = 0.5, wd = 0.35}, {x = 1.15, z = 0.5, wd = 0.35},
			{x = -1.1, z = -3.6, wd = 0.6}, {x = 1.1, z = -3.6, wd = 0.6}, {x = -1.1, z = -4.8, wd = 0.6}, {x = 1.1, z = -4.8, wd = 0.6}}) do
		parts[#parts + 1] = {pos = {x = w.x, y = -1.0, z = w.z}, size = {x = w.wd, y = 1.0, z = 1.0}, tex = wheel}
	end
	-- 固定腳：四個角，橫樑往外伸、千斤頂往下撐，底下一塊墊板
	local LEGS = {{-1, -0.2}, {1, -0.2}, {-1, -5.0}, {1, -5.0}}
	local stripe = "[fill:16x16:#e8c020^[fill:4x16:0,0:#202020^[fill:4x16:8,0:#202020"
	for i = 1, 4 do
		parts[#parts + 1] = {id = "ob" .. i, pos = P0, size = {x = 1.6, y = 0.25, z = 0.3}, tex = {stripe, stripe, stripe, stripe, stripe, stripe}}
		parts[#parts + 1] = {id = "oj" .. i, pos = P0, size = {x = 0.22, y = 0.8, z = 0.22}, tex = box_tex("#c8ccd0")}
		parts[#parts + 1] = {id = "op" .. i, pos = P0, size = {x = 0.6, y = 0.1, z = 0.6}, tex = box_tex("#3a3a3a")}
	end
	-- 轉台、臂身、作業籠
	parts[#parts + 1] = {id = "turret", pos = P0, size = P.turret, tex = box_tex(c)}
	if P.counterweight then
		parts[#parts + 1] = {id = "cw", pos = P0, size = P.counterweight, tex = box_tex("#4a4a4a")}
	end
	for i = 1, NSEC do
		local w = P.boom_w * (1 - 0.45 * (i - 1) / math.max(1, NSEC - 1))
		parts[#parts + 1] = {id = "s" .. i, pos = P0, size = {x = w, y = LS, z = w}, tex = box_tex(i % 2 == 1 and c or P.boom_c2)}
	end
	if P.crane then
		parts[#parts + 1] = {id = "rope", pos = P0, size = {x = 0.06, y = 1, z = 0.06}, tex = box_tex("#202020")}
		parts[#parts + 1] = {id = "hook", pos = P0, size = {x = 0.3, y = 0.4, z = 0.3}, tex = box_tex("#d0a020")}
	end
	local RAIL = "[fill:16x16:#00000000^[fill:16x2:0,0:#e8c020^[fill:16x2:0,7:#e8c020^[fill:16x3:0,13:#c8a010^[fill:2x16:0,0:#e8c020^[fill:2x16:14,0:#e8c020"
	local rail = {RAIL, RAIL, RAIL, RAIL, RAIL, RAIL}
	local BKP = {      -- 作業籠：{id, 中心（作業籠座標）, 大小}
		{"bfloor", {x = 0, y = -BK.y / 2 + 0.05, z = 0}, {x = BK.x, y = 0.1, z = BK.z}, box_tex("#4a4e52")},
		{"brf", {x = 0, y = 0, z = BK.z / 2}, {x = BK.x, y = BK.y, z = 0.05}, rail},
		{"brb", {x = 0, y = 0, z = -BK.z / 2}, {x = BK.x, y = BK.y, z = 0.05}, rail},
		{"brl", {x = -BK.x / 2, y = 0, z = 0}, {x = 0.05, y = BK.y, z = BK.z}, rail},
		{"brr", {x = BK.x / 2, y = 0, z = 0}, {x = 0.05, y = BK.y, z = BK.z}, rail},
	}
	for _, b in ipairs(BKP) do parts[#parts + 1] = {id = b[1], pos = P0, size = b[3], tex = b[4]} end
	def.parts = parts
	def.overhangs = {{x0 = -1.3, x1 = 1.3, z0 = -5.5, z1 = -1.5, y0 = -1.5, y1 = 0.6, body = "z1"}}

	local function L(self) return self.lift end

	-- 固定腳：e = 0 收起 … 1 撐在地上
	local function place_legs(self)
		local ps, e = self.parts, L(self).e
		if not ps then return end
		for i, g in ipairs(LEGS) do
			local sx, z = g[1], g[2]
			local ox = sx * (1.25 + 0.9 * e)
			local bot = -1.0 - 0.45 * e
			if ps["ob" .. i] then ps["ob" .. i]:set_attach(self.object, "", {x = sx * (0.45 + 0.9 * e) * 10, y = -6.5, z = z * 10}, {x = 0, y = 0, z = 0}) end
			if ps["oj" .. i] then ps["oj" .. i]:set_attach(self.object, "", {x = ox * 10, y = (bot + 0.4) * 10, z = z * 10}, {x = 0, y = 0, z = 0}) end
			if ps["op" .. i] then ps["op" .. i]:set_attach(self.object, "", {x = ox * 10, y = (bot - 0.05) * 10, z = z * 10}, {x = 0, y = 0, z = 0}) end
		end
	end

	-- 作業籠在 B（車身座標）時的轉台角度、臂尖、吊索長；不合作業範圍回傳 nil
	local function solve(B)
		local dx, dz = B.x - P0.x, B.z - P0.z
		local r = math.sqrt(dx * dx + dz * dz)
		if r < P.rmin - 1e-6 or r > P.rmax + 1e-6 or B.y < P.ymin - 1e-6 or B.y > P.ymax + 1e-6 then return nil end
		local psi = atan2(dx, dz)
		local hx, hz = dx / r, dz / r
		local tip, rope
		if P.crane then
			-- 臂尖在作業籠正上方：高度盡量在籠頂上 1.5 m，但受臂長限制；吊索至少 1 m
			local top = B.y + BK.y / 2
			local ty = math.max(top + 1.5, P0.y + 1.0)
			local maxy = P0.y + math.sqrt(math.max(0, P.Lmax ^ 2 - r * r))
			if r > P.Lmax then return nil end
			ty = math.min(ty, maxy)
			local Lc = math.sqrt(r * r + (ty - P0.y) ^ 2)
			if Lc < P.Lmin then ty = P0.y + math.sqrt(math.max(0, P.Lmin ^ 2 - r * r)) end
			rope = ty - top
			if rope < 1 then return nil end
			tip = {x = B.x, y = ty, z = B.z}
		else
			-- 臂尖接在作業籠靠轉台那側的下緣
			tip = {x = B.x - hx * BK.z / 2, y = B.y - BK.y / 2 + 0.2, z = B.z - hz * BK.z / 2}
		end
		local Lb = vector.distance(tip, P0)
		if Lb < P.Lmin - 1e-6 or Lb > P.Lmax + 1e-6 then return nil end
		return psi, tip, rope, r
	end

	-- 吊車：臂尖 T、吊索長 rope 決定吊籠位置。回傳 轉台角度, 臂尖, 吊索, 水平距離, 吊籠中心；不合作業範圍回傳 nil
	local ROPE_MAX = 45
	local function solve_c(T, rope)
		local dx, dz = T.x - P0.x, T.z - P0.z
		local r = math.sqrt(dx * dx + dz * dz)
		if r < P.rmin - 1e-6 or r > P.rmax + 1e-6 or T.y < P0.y + 0.3 then return nil end
		local Lb = vector.distance(T, P0)
		if Lb < P.Lmin - 1e-6 or Lb > P.Lmax + 1e-6 then return nil end
		if rope < 1 - 1e-6 or rope > ROPE_MAX then return nil end
		local B = {x = T.x, y = T.y - rope - BK.y / 2, z = T.z}
		if B.y < P.ymin - 1e-6 or B.y > P.ymax + 1e-6 then return nil end
		return atan2(dx, dz), T, rope, r, B
	end
	-- 收起時的臂尖、吊索（從收起的作業籠位置算）
	local T_REST, ROPE_REST
	if P.crane then
		local _, tip, rope = solve(REST)
		T_REST, ROPE_REST = tip, rope
	end

	local function attach_box(self, o, center, psi)
		if o then o:set_attach(self.object, "", {x = center.x * 10, y = center.y * 10, z = center.z * 10}, {x = 0, y = math.deg(psi), z = 0}) end
	end

	local function place_arm(self)
		local ps, st = self.parts, L(self)
		if not ps then return end
		local psi, tip, rope
		if P.crane then
			local B
			psi, tip, rope, _, B = solve_c(st.T, st.rope)
			if not psi then st.T, st.rope = vector.copy(T_REST), ROPE_REST; psi, tip, rope, _, B = solve_c(st.T, st.rope) end
			st.B = B
		else
			psi, tip, rope = solve(st.B)
			if not psi then st.B = vector.copy(REST); psi, tip, rope = solve(st.B) end
		end
		st.psi = psi
		attach_box(self, ps.turret, {x = P0.x, y = P0.y - P.turret.y / 2, z = P0.z}, psi)
		if ps.cw then attach_box(self, ps.cw, vector.add(P0, h2v({x = 0, y = 0.1, z = -1.4}, psi)), psi) end
		-- 臂身：NSEC 節等長，沿臂均勻排開
		local Lb = vector.distance(tip, P0)
		local u = vector.divide(vector.subtract(tip, P0), Lb)
		for i = 1, NSEC do
			local a = (Lb - LS) * (i - 1) / math.max(1, NSEC - 1)
			seg_attach(self, ps["s" .. i], vector.add(P0, vector.multiply(u, a)), vector.add(P0, vector.multiply(u, a + LS)))
		end
		if P.crane then
			local top = {x = st.B.x, y = st.B.y + BK.y / 2, z = st.B.z}
			if ps.rope then
				if math.abs((st.rope_shown or 0) - rope) > 0.05 then
					st.rope_shown = rope
					ps.rope:set_properties({visual_size = {x = 0.06, y = rope, z = 0.06}})
				end
				seg_attach(self, ps.rope, tip, top)
			end
			attach_box(self, ps.hook, {x = tip.x, y = tip.y - 0.3, z = tip.z}, psi)
		end
		for _, b in ipairs(BKP) do attach_box(self, ps[b[1]], vector.add(st.B, h2v(b[2], psi)), psi) end
	end

	-- 作業籠會不會撞到方塊
	local function blocked(self, B, psi)
		for _, dx in ipairs({-BK.x / 2 + 0.1, 0, BK.x / 2 - 0.1}) do
			for _, dz in ipairs({-BK.z / 2 + 0.1, BK.z / 2 - 0.1}) do
				for _, dy in ipairs({-BK.y / 2 + 0.05, BK.y / 2 - 0.1}) do
					local w = V.to_world(self, vector.add(B, h2v({x = dx, y = dy, z = dz}, psi)))
					if not V.passable(core.get_node(vector.round(w)).name) then return true end
				end
			end
		end
		return false
	end

	-- 人在作業籠裡：掛在車上、站在作業籠地板上
	-- 人在作業籠裡：掛在一個獨立的「座位」物件上（跟追蹤相機同一種），座位每步移到作業籠地板上。
	-- （掛在車身上再改掛載位置、或掛在掛在車上的零件上，客戶端都不會把人移過去）
	local function attach_player(self, d)
		local st = L(self)
		local w = V.to_world(self, {x = st.B.x, y = st.B.y - BK.y / 2 + 0.1, z = st.B.z})
		if not (st.seat and st.seat:get_pos()) then
			st.seat = core.add_entity(w, V.CHASE)
			if not st.seat then return end
			st.seat:get_luaentity().vehicle = self
		else
			st.seat:move_to(w, true)
		end
		if d:get_attach() ~= st.seat then
			d:set_detach()
			d:set_attach(st.seat, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		end
	end
	local function drop_seat(self)
		local st = L(self)
		if st.seat and st.seat:get_pos() then st.seat:remove() end
		st.seat = nil
	end
	local function to_basket(self, d)
		local st = L(self)
		V.drop_chase(self)
		if st.floor then
			if st.floor:get_pos() then st.floor:remove() end
			st.floor = nil
		end
		st.mode = "basket"
		attach_player(self, d)
		d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		d:set_camera({mode = st.cam3 and "third" or "first"})
		V.set_seated(d, true, "stand")
		d:hud_set_flags({hotbar = true, wielditem = true})      -- 作業籠裡要用工具
		update_hud(self)
	end
	-- 跨出去：人放在作業籠地板上、自由走動；地板是一個有碰撞的實體
	local function step_out(self, d)
		local st = L(self)
		local f = V.to_world(self, {x = st.B.x, y = st.B.y - BK.y / 2 + 0.1, z = st.B.z})
		d:set_detach()
		drop_seat(self)
		d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		d:set_camera({mode = "any"})
		V.set_seated(d, false)
		V.hud_clear(self, d)
		self.driver = nil
		st.mode = "free"
		local o = core.add_entity({x = f.x, y = f.y - 0.05, z = f.z}, FLOOR)
		if o then
			o:get_luaentity().vehicle = self.object
			st.floor = o
		end
		core.after(0.05, function() if d:get_pos() then d:set_pos({x = f.x, y = f.y + 0.02, z = f.z}) end end)
	end

	-- 地板實體右鍵：回到作業籠操作
	function def.on_spawn(self)
		self.lift = self.lift or {e = 0, B = vector.copy(REST), mode = "cab",
			T = T_REST and vector.copy(T_REST), rope = ROPE_REST}
		self.lift_board = function(me, clicker)
			if not clicker or not clicker:is_player() then return end
			local name = clicker:get_player_name()
			if me.driver or not V.may_use(me, name) then return end
			me.driver = name
			to_basket(me, clicker)
		end
		for _, id in ipairs({"brf", "brb", "brl", "brr"}) do
			local o = self.parts and self.parts[id]
			if o then o:set_properties({use_texture_alpha = true, backface_culling = false}) end
		end
		place_legs(self)
		place_arm(self)
	end

	function def.hold_controls(self)
		local m = self.lift and self.lift.mode
		return m == "basket" or m == "return"
	end
	function def.move(self, ctx)
		local st = L(self)
		if not st or st.e > 0 or st.mode ~= "cab" then ctx.speed = 0; return end
		V.tail_guard(self, def, ctx)
	end
	function def.can_turn(self, pos, yaw, yaw2)
		local st = L(self)
		if st and (st.e > 0 or st.mode ~= "cab") then return false end
		return V.tail_can_turn(self, pos, yaw, yaw2, def)
	end
	function def.busy(self)
		local st = L(self)
		return st and (st.edir ~= nil or st.moving or st.mode == "return")
	end

	-- 放固定腳的條件：停著、車身不斜、四支腳底下 1 m 內有地面
	local function can_deploy(self)
		local v = self.object:get_velocity()
		if v and math.sqrt(v.x * v.x + v.z * v.z) > 0.1 then return S("Stop the vehicle first") end
		if math.abs(self.pitch or 0) > MAX_TILT or math.abs(self.roll or 0) > MAX_TILT then
			return S("Too steep for the outriggers (more than @1°)", ("%d"):format(math.deg(MAX_TILT)))
		end
		for _, g in ipairs(LEGS) do
			local pw = V.to_world(self, {x = g[1] * 2.15, y = -1.6, z = g[2]})
			local ok = false
			for dy = 0, -1, -1 do
				if not V.passable(core.get_node(vector.round({x = pw.x, y = pw.y + dy, z = pw.z})).name) then ok = true; break end
			end
			if not ok then return S("No ground under an outrigger") end
		end
	end

	function def.action(self, ctx)
		local st, ctrl = L(self), ctx.ctrl
		if not st then return end
		if st.mode == "basket" then
			if ctrl.aux1 and ctrl.sneak then
				self.t_act = 0.5
				step_out(self, ctx.d)
			elseif ctrl.aux1 then
				self.t_act = 0.5
				st.mode = "return"
				update_hud(self)
			end
			return
		end
		if st.mode == "return" then return end
		-- 駕駛座
		if ctrl.aux1 then
			self.t_act = 0.5
			if st.mode ~= "cab" or vector.distance(st.B, REST) > 0.05 then
				self.msg = S("Bring the basket back first")
			elseif st.e > 0 then
				st.edir = -1; self.msg = nil
			else
				local why = can_deploy(self)
				if why then self.msg = why else st.edir = 1; self.msg = nil end
			end
			update_hud(self)
		elseif ctrl.jump then
			self.t_act = 0.5
			if st.e < 1 then self.msg = S("Put the outriggers down first (E)"); update_hud(self); return end
			self.msg = nil
			to_basket(self, ctx.d)
		end
	end

	function def.step(self, ctx)
		local st = L(self)
		if not st then return end
		local dt = ctx.dtime
		-- 固定腳
		if st.edir then
			st.e = math.max(0, math.min(1, st.e + st.edir * dt / OUT_T))
			if st.e == 0 or st.e == 1 then st.edir = nil; update_hud(self) end
			place_legs(self)
		end
		local d = ctx.d
		st.moving = false
		if st.mode == "basket" and d then
			local z = ctx.ctrl.zoom
			if z and not st.zoom_held then
				st.cam3 = not st.cam3
				d:set_camera({mode = st.cam3 and "third" or "first"})
			end
			st.zoom_held = z
		end
		if st.mode == "basket" and d and P.crane then
			-- 吊車：WASD 臂尖水平移動；空白鍵／Shift：吊臂模式動臂尖上下、吊索模式收放吊索；Z 切換
			local c = ctx.ctrl
			-- 切換動吊臂／收放吊索：Q（rockmech.lift_q，手上有東西時）或空白鍵＋Shift 一起按（兩個一起按時不上下）
			local chord = c.jump and c.sneak
			if chord and not st.chord_held then
				st.hoist = not st.hoist
				update_hud(self)
			end
			st.chord_held = chord
			if c.aux1 then return end
			local f = (c.up and 1 or 0) - (c.down and 1 or 0)
			local s = (c.right and 1 or 0) - (c.left and 1 or 0)
			local u = (c.jump and 1 or 0) - (c.sneak and 1 or 0)
			if f ~= 0 or s ~= 0 or u ~= 0 then
				local lh = d:get_look_horizontal()
				local fw, rt = {x = -math.sin(lh), z = math.cos(lh)}, {x = math.cos(lh), z = math.sin(lh)}
				local hx, hz = fw.x * f + rt.x * s, fw.z * f + rt.z * s
				local hl = math.sqrt(hx * hx + hz * hz)
				if hl > 0 then hx, hz = hx / hl, hz / hl end
				local step = P.speed * dt
				local function try(dw, drope)
					local nT = V.to_local(self, vector.add(V.to_world(self, st.T), dw))
					local nr = st.rope + drope
					local psi, _, _, _, B = solve_c(nT, nr)
					if psi and not blocked(self, B, psi) then st.T, st.rope = nT, nr; return true end
				end
				local moved = false
				if hl > 0 then moved = try({x = hx * step, y = 0, z = hz * step}, 0) or moved end
				if u ~= 0 then
					if st.hoist then moved = try({x = 0, y = 0, z = 0}, -u * step) or moved
					else moved = try({x = 0, y = u * step, z = 0}, 0) or moved end
				end
				if moved then
					st.moving = true
					place_arm(self)
					attach_player(self, d)
					st.hud_t = (st.hud_t or 0) + dt
					if st.hud_t > 0.3 then st.hud_t = 0; update_hud(self) end
				end
			end
		elseif st.mode == "basket" and d then
			local c = ctx.ctrl
			if c.aux1 then return end
			local f = (c.up and 1 or 0) - (c.down and 1 or 0)
			local s = (c.right and 1 or 0) - (c.left and 1 or 0)
			local u = (c.jump and 1 or 0) - (c.sneak and 1 or 0)
			if f ~= 0 or s ~= 0 or u ~= 0 then
				local lh = d:get_look_horizontal()
				local fw, rt = {x = -math.sin(lh), z = math.cos(lh)}, {x = math.cos(lh), z = math.sin(lh)}
				local hx, hz = fw.x * f + rt.x * s, fw.z * f + rt.z * s
				local hl = math.sqrt(hx * hx + hz * hz)
				if hl > 0 then hx, hz = hx / hl, hz / hl end
				local step = P.speed * dt
				local wnow = V.to_world(self, st.B)
				local function try(dw)
					local nb = V.to_local(self, vector.add(wnow, dw))
					local psi = solve(nb)
					if psi and not blocked(self, nb, psi) then st.B = nb; return true end
				end
				-- 一起動不了就分開試（沿著邊界、貼著岩面滑）
				local moved = try({x = hx * step, y = u * step, z = hz * step})
				if not moved then
					local a = (hl > 0) and try({x = hx * step, y = 0, z = hz * step})
					local b = u ~= 0 and try({x = 0, y = u * step, z = 0})
					moved = a or b
				end
				if moved then
					st.moving = true
					place_arm(self)
					attach_player(self, d)
					st.hud_t = (st.hud_t or 0) + dt
					if st.hud_t > 0.3 then st.hud_t = 0; update_hud(self) end
				end
			end
		elseif st.mode == "return" and P.crane then
			-- 吊車收回：吊索收到原長、臂尖回原位（一起動）
			local step = RETURN_SPEED * dt
			local dv = vector.subtract(T_REST, st.T)
			local dist = vector.length(dv)
			local dr = ROPE_REST - st.rope
			if dist <= step and math.abs(dr) <= step then
				st.T, st.rope, st.mode = vector.copy(T_REST), ROPE_REST, "cab"
				place_arm(self)
				if d then V.seat_driver(self, d) end
				drop_seat(self)
				update_hud(self)
			else
				local nT = dist > step and vector.add(st.T, vector.multiply(dv, step / dist)) or vector.copy(T_REST)
				local nr = st.rope + math.max(-step, math.min(step, dr))
				if solve_c(nT, nr) then st.T, st.rope = nT, nr else st.T, st.rope = vector.copy(T_REST), ROPE_REST end
				place_arm(self)
				if d then attach_player(self, d) end
			end
		elseif st.mode == "return" then
			local dv = vector.subtract(REST, st.B)
			local dist = vector.length(dv)
			local step = RETURN_SPEED * dt
			if dist <= step then
				st.B = vector.copy(REST)
				st.mode = "cab"
				place_arm(self)
				if d then V.seat_driver(self, d) end
				drop_seat(self)
				update_hud(self)
			else
				local nb = vector.add(st.B, vector.multiply(dv, step / dist))
				if solve(nb) then st.B = nb else st.B = vector.copy(REST) end
				place_arm(self)
				if d then attach_player(self, d) end
			end
		end
	end

	function def.hud(self)
		local st = L(self)
		if not st then return "" end
		local s = "\n" .. (st.edir and S("Outriggers moving") or st.e >= 1 and S("Outriggers down") or S("Outriggers up"))
		if st.mode ~= "cab" or vector.distance(st.B, REST) > 0.05 then
			local r
			if P.crane then _, _, _, r = solve_c(st.T, st.rope) else _, _, _, r = solve(st.B) end
			s = s .. "   " .. S("Basket: @1 m high, @2 m out", ("%.1f"):format(st.B.y - BK.y / 2 + 1.5), ("%.1f"):format(r or 0))
			if P.crane then s = s .. "   " .. S("Rope @1 m", ("%.1f"):format(st.rope)) end
		end
		return s
	end
	function def.keys(self)
		local st = L(self)
		if st and (st.mode == "basket" or st.mode == "return") then
			if P.crane then
				return {{"WASD", S("Move the boom")},
					{S("Space") .. " / Shift", st.hoist and S("Basket up / down (rope)") or S("Boom up / down")},
					{"Q", st.hoist and S("Switch to the boom") or S("Switch to the rope"), on = st.hoist},
					{"E", S("Back to the cab")}, {"Shift+E", S("Step out")}}
			end
			return {{"WASD", S("Move the basket")}, {S("Space") .. " / Shift", S("Up / down")},
				{"E", S("Back to the cab")}, {"Shift+E", S("Step out")}}
		end
		return {{"E", st and st.e > 0 and S("Raise the outriggers") or S("Put the outriggers down"), on = st and st.e >= 1},
			{S("Space"), S("Go to the basket")}}
	end
	-- Q：吊車吊籠裡切換動吊臂／收放吊索
	if P.crane then
		function def.on_q(self)
			local st = L(self)
			if not (st and st.mode == "basket") then return false end
			st.hoist = not st.hoist
			update_hud(self)
			return true
		end
	end
	V.register(kind, def)
end

-- Q（丟東西）：人在作業籠裡時不丟東西；吊車吊籠裡拿來切換動吊臂／收放吊索。
-- 空手按 Q 伺服器收不到（引擎不送），空手時用空白鍵＋Shift 一起按
local function lift_of(player)
	local parent = player:get_attach()
	local veh = parent and parent:get_attach()
	local e = veh and veh:get_luaentity()
	if e and e.lift and e.driver == player:get_player_name() then return e end
end
local old_drop = core.item_drop
function core.item_drop(itemstack, dropper, pos)
	local e = dropper and dropper.is_player and dropper:is_player() and lift_of(dropper)
	if e then
		local def = V.TYPES[e.vkind]
		if def.on_q then def.on_q(e) end
		return itemstack
	end
	return old_drop(itemstack, dropper, pos)
end

-- 高空作業車：伸縮臂 15 m 級（作業高度 15 m：籠底最高離地 13 m、水平 10 m），白車身、橘色臂
do
	local def = {desc = S("Aerial work platform"), short = S("Aerial platform"), color = "#e8e8e0", cap = 0, speed = 4.0,
		top_speed = 11, accel = 1.5, tire = 1.0,
		half = 1.5, rear = 5.5, lat = {-1, 0, 1}, eye_up = 1.55, eye_fwd = 1.35,
		tail_lat = {-1.1, 0, 1.1}, tail_dy = {1.2, 2.2},
		tilt = {front = 0.5, rear = -3.8, side_z = -1.6, side_x = 1.1}, max_grade = math.rad(17),
		item_desc = S("Right-click to get in; E outriggers, Space to the basket")}
	do
		local r = {}
		r[#r + 1] = {2, 18, 19, 4, "#2a2a2a"}; r[#r + 1] = {22, 12, 8, 10, def.color}; r[#r + 1] = {24, 14, 5, 4, "#9fd0ff"}
		r[#r + 1] = {6, 6, 18, 3, "#e07020"}; r[#r + 1] = {4, 15, 4, 3, "#e8e8e0"}; r[#r + 1] = {22, 2, 6, 5, "#e8c020"}
		V.icon_wheel(r, 26, 25, 3); V.icon_wheel(r, 7, 25, 3); V.icon_wheel(r, 13, 25, 3)
		def.inv_image = V.icon(r)
	end
	V.MASS.aerial = 12
	lift("aerial", {def = def, pivot = {x = 0, y = 0.9, z = -3.6}, rest = {x = 0, y = 2.3, z = 1.0},
		Lmin = 3.8, Lmax = 15, rmin = 2.2, rmax = 10, ymin = -0.95, ymax = -1.5 + 13 + 0.55,      -- 籠底最高 13 m（作業高度 15 m）
		turret = {x = 1.4, y = 0.6, z = 1.4}, boom_w = 0.45, boom_c2 = "#e07020", speed = 1.0})
end

-- 吊車：伸縮吊臂 32 m（作業高度 30 m：籠底最高離地 28 m、水平 20 m、可以往下吊到車底下 10 m），黃色
do
	local def = {desc = S("Crane"), short = S("Crane"), color = "#e8b020", cap = 0, speed = 3.0,
		top_speed = 9, accel = 1.2, tire = 1.0,
		half = 1.5, rear = 5.5, lat = {-1, 0, 1}, eye_up = 1.55, eye_fwd = 1.35,
		tail_lat = {-1.1, 0, 1.1}, tail_dy = {1.2, 2.2},
		tilt = {front = 0.5, rear = -3.8, side_z = -1.6, side_x = 1.1}, max_grade = math.rad(15),
		item_desc = S("Right-click to get in; E outriggers, Space to the basket")}
	do
		local r = {}
		r[#r + 1] = {2, 18, 19, 4, "#2a2a2a"}; r[#r + 1] = {22, 12, 8, 10, def.color}; r[#r + 1] = {24, 14, 5, 4, "#9fd0ff"}
		r[#r + 1] = {6, 2, 3, 15, "#e8b020"}; r[#r + 1] = {6, 1, 22, 3, "#e8b020"}; r[#r + 1] = {26, 4, 1, 6, "#202020"}
		V.icon_wheel(r, 26, 25, 3); V.icon_wheel(r, 7, 25, 3); V.icon_wheel(r, 13, 25, 3)
		def.inv_image = V.icon(r)
	end
	V.MASS.crane = 30
	lift("crane", {def = def, pivot = {x = 0, y = 1.2, z = -4.2}, rest = {x = 0, y = 2.3, z = 0.6},
		Lmin = 6, Lmax = 32, rmin = 3, rmax = 20, ymin = -1.5 - 10 + 0.55, ymax = -1.5 + 28 + 0.55,
		turret = {x = 2.0, y = 0.9, z = 2.2}, counterweight = {x = 2.0, y = 0.8, z = 0.8},
		boom_w = 0.8, boom_c2 = "#c89010", speed = 0.8, crane = true})
end
