-- rockmech/vehicle_lift.lua
-- 高空作業車（雲梯車）、吊車（吊籠）：把人送到高處的邊坡面施作護坡（岩栓、噴凝土、監測稜鏡…）。由 vehicles.lua 載入。
-- 流程：開到邊坡前 → E 放固定腳（OUT_T 秒；車身傾斜不超過 5°、四支腳底下都有地面）→ 空白鍵進作業籠
--   作業籠裡平常自由走動（欄杆擋人，跳過欄杆就出去了）；按住 E 才操作：人固定在籠裡，
--             WASD 照視線方向水平移動、空白鍵上升、Shift 下降（碰到方塊、到作業範圍邊界就停）；放開 E 停住、又能走動。
--             （人站在移動的東西上不會被帶著走，所以作業籠只在按住 E、人固定時才動）
--   駕駛座：空白鍵進作業籠（籠裡有人就改成從駕駛座操作）；Shift＋E 把作業籠收回原位（籠裡的人跟著回來）。
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
	local cab_side = V.cab_side(c, {win = {x = 8, y = 2, w = 6, h = 6}, doors = {{x = 6.5, y = 1, w = 8.5, h = 12.5}}})
	local cab_side_l = V.flip_side(cab_side)
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
			tex = {("[fill:16x16:%s"):format(c), "[fill:16x16:#2a2a2a", cab_side, cab_side_l, cab_front, ("[fill:16x16:%s"):format(c)}},
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

	local sync_floor          -- 下面定義（作業籠地板跟著作業籠）
	local function place_arm(self)
		local ps, st = self.parts, L(self)
		if not ps then return end
		local psi, tip, rope
		if P.crane then
			local B
			local _
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
		sync_floor(self)
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
	local function floor_w(self)
		local st = L(self)
		return V.to_world(self, {x = st.B.x, y = st.B.y - BK.y / 2 + 0.1, z = st.B.z})
	end
	-- 作業籠裡的人：st.occ（名字 → true）。作業籠會動的時候（籠裡的人按住 E 操作、駕駛座操作、收回）籠裡的人
	-- 掛在同一個座位上，座位移到作業籠地板；其他時候自由走動（欄杆擋人：下面每一步檢查）
	local function carried(self)
		local st = L(self)
		local list = {}
		if st.mode == "basket" and st.drv_in and self.driver then
			local dp = core.get_player_by_name(self.driver)
			if dp then list[#list + 1] = dp end
		elseif st.mode == "op" or st.mode == "return" then
			for n in pairs(st.occ) do
				local p = core.get_player_by_name(n)
				if p then list[#list + 1] = p else st.occ[n] = nil end
			end
		end
		return list
	end
	local function place_people(self)
		local st = L(self)
		local list = carried(self)
		-- 不用再掛著的人：放下來站在作業籠地板上
		if st.seat and st.seat:get_pos() then
			local keep = {}
			for _, p in ipairs(list) do keep[p:get_player_name()] = true end
			for n in pairs(st.occ) do
				local p = core.get_player_by_name(n)
				if p and not keep[n] and p:get_attach() == st.seat then
					local w = p:get_pos()
					p:set_detach()
					V.set_seated(p, false)
					core.after(0.05, function() if p:get_pos() then p:set_pos(w) end end)
				end
			end
		end
		if #list == 0 then
			if st.seat and st.seat:get_pos() then st.seat:remove() end
			st.seat = nil
			return
		end
		local w = floor_w(self)
		if not (st.seat and st.seat:get_pos()) then
			st.seat = core.add_entity(w, V.CHASE)
			if not st.seat then return end
			st.seat:get_luaentity().vehicle = self
		else
			st.seat:move_to(w, true)
		end
		for i, p in ipairs(list) do
			local off = #list >= 2 and {x = (i - 1.5) * 8, y = 0, z = 0} or {x = 0, y = 0, z = 0}
			local par, _, pos = p:get_attach()
			if par ~= st.seat or not pos or math.abs(pos.x - off.x) > 0.1 then
				p:set_detach()
				p:set_attach(st.seat, "", off, {x = 0, y = 0, z = 0})
				V.set_seated(p, true, "stand")
			end
		end
	end
	-- 作業籠地板（給人站、右鍵進作業籠）：固定腳放下時一直在，跟著作業籠走
	sync_floor = function(self)
		local st = L(self)
		if st.e >= 1 then
			local f = floor_w(self)
			local fp = {x = f.x, y = f.y - 0.05, z = f.z}
			if st.floor and st.floor:get_pos() then
				st.floor:move_to(fp, true)
			else
				local o = core.add_entity(fp, FLOOR)
				if o then o:get_luaentity().vehicle = self.object; st.floor = o end
			end
		elseif st.floor then
			if st.floor:get_pos() then st.floor:remove() end
			st.floor = nil
		end
	end
	-- 從駕駛座進作業籠：離開駕駛座，人放到作業籠地板上（自由走動）
	local function board(self, d)
		local st = L(self)
		local f = floor_w(self)
		V.drop_chase(self)
		d:set_detach()
		d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		d:set_camera({mode = "any"})
		V.set_seated(d, false)
		V.hud_clear(self, d)
		d:hud_set_flags({hotbar = true, wielditem = true})
		self.driver = nil
		st.drv_in = false
		if st.mode == "cab" then st.mode = "free" end
		st.occ[d:get_player_name()] = true
		sync_floor(self)
		core.after(0.05, function() if d:get_pos() then d:set_pos({x = f.x, y = f.y + 0.02, z = f.z}) end end)
		rockmech.notify(d:get_player_name(), P.crane and S("[Basket] Hold E to operate (Space + Shift switches boom / rope); jump over the rail to get out")
			or S("[Basket] Hold E to operate; jump over the rail to get out"))
	end
	-- 籠裡的人按住 E：變成操作的人，固定在籠裡
	local function operate(self, pl)
		local st = L(self)
		self.driver = pl:get_player_name()
		st.mode, st.drv_in = "basket", true
		place_people(self)
		pl:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		pl:set_camera({mode = st.cam3 and "third" or "first"})
		pl:hud_set_flags({hotbar = true, wielditem = true})      -- 作業籠裡要用工具
		update_hud(self)
	end
	-- 放開 E：停住，人又能在籠裡走動
	local function release(self, d)
		local st = L(self)
		V.hud_clear(self, d)
		d:set_camera({mode = "any"})
		self.driver = nil
		st.mode, st.drv_in = "free", false
		place_people(self)
		update_hud(self)
	end
	-- 地板實體右鍵：回到作業籠操作
	function def.on_spawn(self)
		self.lift = self.lift or {e = 0, B = vector.copy(REST), mode = "cab",
			T = T_REST and vector.copy(T_REST), rope = ROPE_REST}
		self.lift.occ = self.lift.occ or {}
		self.lift_board = function() end          -- 以前右鍵作業籠回到操作；現在走進去、按住 E 就好
		for _, id in ipairs({"brf", "brb", "brl", "brr"}) do
			local o = self.parts and self.parts[id]
			if o then o:set_properties({use_texture_alpha = true, backface_culling = false}) end
		end
		place_legs(self)
		place_arm(self)
	end

	function def.hold_controls(self)
		local m = self.lift and self.lift.mode
		return m == "basket" or m == "return" or m == "op"
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
		if st.mode == "basket" or st.mode == "return" then return end      -- 作業籠裡：按住 E 操作（下面 step）
		local away = vector.distance(P.crane and st.T or st.B, P.crane and T_REST or REST) > 0.05 or (P.crane and math.abs(st.rope - ROPE_REST) > 0.05)
		-- 從駕駛座操作作業籠：E 停止操作（作業籠留在原地）、Shift＋E 收回
		if st.mode == "op" then
			if ctrl.aux1 and ctrl.sneak then
				self.t_act = 0.5; st.mode = "return"; place_people(self); update_hud(self)
			elseif ctrl.aux1 then
				self.t_act = 0.5; st.mode = away and "free" or "cab"; place_people(self); update_hud(self)
			end
			return
		end
		-- 駕駛座：Shift＋E 把作業籠收回原位（籠裡的人跟著回來）
		if ctrl.aux1 and ctrl.sneak and away then
			self.t_act = 0.5; st.mode = "return"; place_people(self); update_hud(self)
			return
		end
		if ctrl.aux1 then
			self.t_act = 0.5
			if away then
				self.msg = S("Bring the basket back first (Shift + E)")
			elseif st.e > 0 and next(st.occ) then
				self.msg = S("Someone is in the basket")
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
			if next(st.occ) then st.mode = "op"; place_people(self); update_hud(self)       -- 作業籠裡有人：從駕駛座操作
			else board(self, ctx.d) end
		end
	end

	function def.step(self, ctx)
		local st = L(self)
		if not st then return end
		local dt = ctx.dtime
		-- 固定腳
		if st.edir then
			st.e = math.max(0, math.min(1, st.e + st.edir * dt / OUT_T))
			if st.e == 0 or st.e == 1 then st.edir = nil; update_hud(self); sync_floor(self) end
			place_legs(self)
		end
		local d = ctx.d
		st.moving = false
		-- 作業籠裡操作的人放開 E：停住
		if st.mode == "basket" and d and not ctx.ctrl.aux1 then release(self, d); return end
		if st.mode == "basket" and d then
			local z = ctx.ctrl.zoom
			if z and not st.zoom_held then
				st.cam3 = not st.cam3
				d:set_camera({mode = st.cam3 and "third" or "first"})
			end
			st.zoom_held = z
		end
		local ctrl_mode = (st.mode == "basket" or st.mode == "op") and d
		if ctrl_mode and P.crane then
			-- 吊車：WASD 臂尖水平移動；空白鍵／Shift：吊臂模式動臂尖上下、吊索模式收放吊索；Z 切換
			local c = ctx.ctrl
			-- 切換動吊臂／收放吊索：Q（rockmech.lift_q，手上有東西時）或空白鍵＋Shift 一起按（兩個一起按時不上下）
			local chord = c.jump and c.sneak
			if chord and not st.chord_held then
				st.hoist = not st.hoist
				update_hud(self)
			end
			st.chord_held = chord
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
					place_people(self)
					st.hud_t = (st.hud_t or 0) + dt
					if st.hud_t > 0.3 then st.hud_t = 0; update_hud(self) end
				end
			end
		elseif ctrl_mode then
			local c = ctx.ctrl
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
					place_people(self)
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
				st.drv_in = false
				place_people(self)
				update_hud(self)
			else
				local nT = dist > step and vector.add(st.T, vector.multiply(dv, step / dist)) or vector.copy(T_REST)
				local nr = st.rope + math.max(-step, math.min(step, dr))
				if solve_c(nT, nr) then st.T, st.rope = nT, nr else st.T, st.rope = vector.copy(T_REST), ROPE_REST end
				place_arm(self)
				place_people(self)
			end
		elseif st.mode == "return" then
			local dv = vector.subtract(REST, st.B)
			local dist = vector.length(dv)
			local step = RETURN_SPEED * dt
			if dist <= step then
				st.B = vector.copy(REST)
				st.mode = "cab"
				place_arm(self)
				st.drv_in = false
				place_people(self)
				update_hud(self)
			else
				local nb = vector.add(st.B, vector.multiply(dv, step / dist))
				if solve(nb) then st.B = nb else st.B = vector.copy(REST) end
				place_arm(self)
				place_people(self)
			end
		end
	end

	-- 每一步（下面的 globalstep 呼叫）：籠裡的人、欄杆擋人、按住 E 開始操作
	local RAIL_TOP = 0.9                  -- 腳底高過地板這麼多（跳起來）才跨得過欄杆
	function def.occ_step(self)
		local st = L(self)
		if not (st and st.e >= 1 and st.psi) then return end
		local hx, hz = BK.x / 2 - 0.3, BK.z / 2 - 0.3
		local fy = st.B.y - BK.y / 2 + 0.1
		for _, pl in ipairs(core.get_connected_players()) do
			local name = pl:get_player_name()
			local par = pl:get_attach()
			if not par then
				local lp = V.to_local(self, pl:get_pos())
				local r = h2v({x = lp.x - st.B.x, y = 0, z = lp.z - st.B.z}, -st.psi)
				local dy = lp.y - fy
				local inside = math.abs(r.x) <= hx + 0.05 and math.abs(r.z) <= hz + 0.05 and dy > -0.4 and dy < 1.6
				if st.occ[name] then
					if math.abs(r.x) > hx + 1.5 or math.abs(r.z) > hz + 1.5 or dy < -1.5 or dy > 3 then
						st.occ[name] = nil                           -- 出去了
					elseif not inside and dy < RAIL_TOP then
						-- 欄杆擋住：推回籠裡
						local c = h2v({x = math.max(-hx, math.min(hx, r.x)), y = 0, z = math.max(-hz, math.min(hz, r.z))}, st.psi)
						local w = V.to_world(self, {x = st.B.x + c.x, y = math.max(lp.y, fy), z = st.B.z + c.z})
						pl:set_pos(w)
					elseif inside and pl:get_player_control().aux1 and (st.mode == "free" or st.mode == "cab") then
						if self.driver then
							rockmech.notify(name, S("[Basket] Someone is in the driver's seat: the driver operates the basket"))
						else operate(self, pl) end
					end
				elseif inside then
					st.occ[name] = true                              -- 走（跳）進籠裡
				end
			end
		end
	end

	function def.hud(self)
		local st = L(self)
		if not st then return "" end
		local s = "\n" .. (st.edir and S("Outriggers moving") or st.e >= 1 and S("Outriggers down") or S("Outriggers up"))
		if st.mode ~= "cab" or vector.distance(st.B, REST) > 0.05 then
			local r
			if P.crane then r = select(4, solve_c(st.T, st.rope)) else r = select(4, solve(st.B)) end
			s = s .. "   " .. S("Basket: @1 m high, @2 m out", ("%.1f"):format(st.B.y - BK.y / 2 + 1.5), ("%.1f"):format(r or 0))
			if P.crane then s = s .. "   " .. S("Rope @1 m", ("%.1f"):format(st.rope)) end
		end
		return s
	end
	function def.keys(self)
		local st = L(self)
		local chord = P.crane and {S("Space + Shift"), st and st.hoist and S("Switch to the boom") or S("Switch to the rope"), on = st and st.hoist} or nil
		if st and st.mode == "op" then
			local k = {{"WASD", P.crane and S("Move the boom") or S("Move the basket")},
				{S("Space") .. " / Shift", P.crane and (st.hoist and S("Basket up / down (rope)") or S("Boom up / down")) or S("Up / down")}}
			if chord then k[#k + 1] = chord end
			k[#k + 1] = {"E", S("Stop operating")}
			k[#k + 1] = {"Shift+E", S("Bring the basket back")}
			return k
		end
		if st and st.mode == "basket" then
			local k = {{"WASD", P.crane and S("Move the boom") or S("Move the basket")},
				{S("Space") .. " / Shift", P.crane and (st.hoist and S("Basket up / down (rope)") or S("Boom up / down")) or S("Up / down")}}
			if chord then k[#k + 1] = chord end
			k[#k + 1] = {S("Release E"), S("Stop and walk around")}
			return k
		end
		local away = st and (vector.distance(P.crane and st.T or st.B, P.crane and T_REST or REST) > 0.05)
		local k = {{"E", st and st.e > 0 and S("Raise the outriggers") or S("Put the outriggers down"), on = st and st.e >= 1},
			{S("Space"), st and next(st.occ) and S("Operate the basket") or S("Go to the basket")}}
		if away then k[#k + 1] = {"Shift+E", S("Bring the basket back")} end
		return k
	end
	V.register(kind, def)
end

-- 作業籠裡的人：欄杆擋人、按住 E 開始操作（每台作業車的 def.occ_step）
local occ_t = 0
core.register_globalstep(function(dtime)
	occ_t = occ_t + dtime
	if occ_t < 0.1 then return end
	occ_t = 0
	for _, e in pairs(V.by_uid) do
		local d = e.lift and e.object and e.object:get_pos() and V.TYPES[e.vkind]
		if d and d.occ_step then d.occ_step(e) end
	end
end)
-- 以前的吊籠操作盒：不再使用，背包裡有的收走
core.register_craftitem("rockmech:crane_remote", {description = "", groups = {not_in_creative_inventory = 1},
	inventory_image = "[fill:16x16:#e8c020", stack_max = 1})
core.register_on_joinplayer(function(pl)
	local inv = pl:get_inventory()
	for i, it in ipairs(inv:get_list("main") or {}) do
		if it:get_name() == "rockmech:crane_remote" then inv:set_stack("main", i, ItemStack("")) end
	end
end)

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
