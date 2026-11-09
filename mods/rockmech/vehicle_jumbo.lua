-- rockmech/vehicle_jumbo.lua
-- 隧道開挖的兩台台車（由 vehicles.lua 載入），共用同一款鉸接式底盤（3 寬 × 3 高 × 約 11 m：前段鑽臂座與駕駛室、
-- 中間鉸接、後段動力箱與電纜捲盤；車尾那段倒車、轉彎前自己檢查，見 V.tail_guard）：
--   鑽堡（雙臂鑿岩台車，Sandvik DT／Epiroc Boomer 類，全長含鑽臂約 13 m）：
--     E：照爆破孔設計圖在車頭前方的工作面鑽一整片孔（寬 × 高的孔網、孔距 1 m；橫向以車身中心線為中、從地面那層往上）。
--        每個孔位沿車頭方向往前找第一個露出的岩面（最遠 REACH 格）；兩支鑽臂輪流鑽，鑽的時候不能開車。
--     空白鍵：爆破孔設計圖（● 裝藥孔／○ 空孔／· 不鑽，寬高 3～7）。● ○ 都會鑽，鑽好的孔記住設計（meta plan）。
--   裝藥台車（Normet Charmec 類：吊臂＋工作籃、乳化炸藥罐）：
--     E：吊臂把工作籃伸到前方工作面，一孔一孔裝藥（設計是空孔的跳過），每孔 n 條，從駕駛的物品欄扣乳膠炸藥（創造模式不扣）。
--     空白鍵：設定每孔幾條（1～4）。
-- 真的工地也是分開的：鑽堡只鑽孔，裝藥台車裝藥（鑽孔時旁邊已有裝藥孔不安全）。

local S = rockmech.S
local V = rockmech.vehicles
local box_tex, seg_attach, to_local, update_hud = V.box_tex, V.seg_attach, V.to_local, V.update_hud

local REACH = 3            -- 孔位從車頭外第一排往前找岩面最多幾格
local HOLE = "rockmech:drill_hole"
local EMULSION = "rockmech:emulsion"

-- 底盤：外觀零件（不含車頭作業裝置）與共用的設定
local function carrier(def, extra_parts)
	def.half, def.rear = 1.5, 9.5
	def.lat = {-1, 0, 1}
	def.tail_lat, def.tail_dy = {-1.1, 0, 1.1}, {1.2, 2.2}
	def.eye_up, def.eye_fwd = 1.6, 0.8
	def.mirror = {x = 1.35, y = 1.3, z = 0.4}
	def.rearcam = {x = 0, y = 1.2, z = -9.7}
	def.tilt = {front = 0.4, rear = -7.0, side_z = -3.3, side_x = 1.15}
	def.max_grade = math.rad(15)
	def.speed = 2.5
	local c = def.color
	local o = ("[fill:16x16:%s"):format(c)
	local win = V.cab_glass(c, 1, 2, 14, 9) .. "^[fill:16x2:0,14:#2a2a2a"
	local side = V.cab_side(c, {win = {x = 3, y = 2, w = 11, h = 8}, clear = true, sill = "#2a2a2a", doors = {{x = 2, y = 1, w = 13, h = 12.8}}})
	local side_l = V.flip_side(side)
	local grille = ("[fill:16x16:%s^[fill:14x8:1,4:#2a2a2a^[fill:14x1:1,6:#4a4a4a^[fill:14x1:1,9:#4a4a4a"):format(c)
	local reel = "[fill:16x16:#2c2c2c^[fill:12x12:2,2:#3c3c3c^[fill:4x4:6,6:#1c1c1c"
	local WHEEL, TREAD = V.WHEEL, V.TREAD
	local wheel = {TREAD, TREAD, WHEEL, WHEEL, TREAD, TREAD}
	local parts = {
		{pos = {x = 0, y = -0.85, z = -0.5}, size = {x = 2.4, y = 0.6, z = 4.0}, tex = box_tex("#2a2a2a")},    -- 前段底盤
		{pos = {x = 0, y = -0.8, z = -2.8}, size = {x = 1.0, y = 0.5, z = 0.7}, tex = box_tex("#1e1e1e")},     -- 鉸接
		{pos = {x = 0, y = -0.85, z = -6.2}, size = {x = 2.4, y = 0.6, z = 6.4}, tex = box_tex("#2a2a2a")},    -- 後段底盤
		{pos = {x = 0, y = -0.4, z = 1.4}, size = {x = 2.2, y = 0.9, z = 0.8}, tex = box_tex("#4a4a4a")},      -- 作業裝置座
		{pos = {x = 0, y = 0.45, z = -0.5}, size = {x = 2.4, y = 1.9, z = 2.2}, alpha = true, tex = {o, "[fill:16x16:#2a2a2a", side, side_l, win, o}},   -- 駕駛室（車窗半透明）
		{pos = {x = 0, y = 0.45, z = -1.56}, size = {x = 2.36, y = 1.86, z = 0.04}, tex = box_tex(c)},   -- 駕駛室後牆
		{pos = {x = 0, y = 0.2, z = -5.0}, size = {x = 2.4, y = 1.6, z = 3.2}, tex = {o, o, grille, grille, o, o}},   -- 動力箱
		{pos = {x = 0, y = 0.45, z = -8.4}, size = {x = 2.2, y = 1.9, z = 1.6}, tex = {reel, reel, reel, reel, reel, reel}},   -- 電纜捲盤
	}
	for _, w in ipairs({{x = -1.15, z = 0.4}, {x = 1.15, z = 0.4}, {x = -1.15, z = -7.0}, {x = 1.15, z = -7.0}}) do
		parts[#parts + 1] = {pos = {x = w.x, y = -0.9, z = w.z}, size = {x = 0.6, y = 1.2, z = 1.2}, tex = wheel}
	end
	for _, p in ipairs(extra_parts) do parts[#parts + 1] = p end
	def.parts = parts
	-- 擋人：車尾那段（車頭作業裝置那段由各車加）
	def.overhangs = {{x0 = -1.3, x1 = 1.3, z0 = -9.5, z1 = -1.5, y0 = -1.5, y1 = 1.4, body = "z1"}}
end

-- 車頭作業裝置伸出碰撞箱（車頭外 front_len m）：往前開前看前方幾排有沒有岩石（碎石不算）、人或車
local function front_blocked(self, def, ctx, front_len)
	local y0 = V.ground_y(ctx.pos, def.half)
	for dist = 2, 1 + math.ceil(front_len) do
		for _, c in ipairs(V.face_cells(ctx.pos, ctx.s, 1, dist, y0 + 1, 1, def.lat)) do
			local n = core.get_node(c).name
			if not rockmech.rubble_level[n] and not V.passable(n) then return true end
		end
	end
	local la = ctx.speed * 0.1
	local p2 = {x = ctx.pos.x + ctx.dir.x * la, y = ctx.pos.y, z = ctx.pos.z + ctx.dir.z * la}
	return V.objects_in(self, p2, ctx.yaw, -1.1, 1.1, def.half, def.half + front_len)
end
-- 共用的行駛：作業中不能開；往前看車頭作業裝置、倒車看車尾
local function carrier_move(def, front_len, busy)
	def.busy = busy
	function def.can_turn(self, pos, yaw, yaw2)
		return not busy(self) and V.tail_can_turn(self, pos, yaw, yaw2, def)
	end
	function def.move(self, ctx)
		if busy(self) then ctx.speed = 0; return end
		if ctx.speed > 0 and front_blocked(self, def, ctx, front_len) then ctx.speed = 0; return end
		V.tail_guard(self, def, ctx)
	end
end

-- 車頭前方工作面上，孔網 w × h 各孔位（橫向以車身中心線為中、從地面那層往上）沿車頭方向往前找：
-- fn(i, j, p, prev, name)：p 是這一格、prev 是前一格；回傳 true 就停（這個孔位找完）
local function scan_face(pos, s, half, w, h, fn)
	local y0 = V.ground_y(pos, half)
	local px, pz = -s.z, s.x   -- 往右
	for j = 0, h - 1 do
		for i = 0, w - 1 do
			local l = i - math.floor((w - 1) / 2)
			local prev
			for dist = 2, 2 + REACH do
				local p = {x = math.floor(pos.x + s.x * dist + px * l + 0.5), y = y0 + j, z = math.floor(pos.z + s.z * dist + pz * l + 0.5)}
				if fn(i, j, p, prev, core.get_node(p).name) then break end
				prev = p
			end
		end
	end
end

local function dust(face, dtime)
	core.add_particlespawner({
		amount = 3, time = dtime,
		minpos = vector.subtract(face, 0.1), maxpos = vector.add(face, 0.1),
		minvel = {x = -1, y = 0, z = -1}, maxvel = {x = 1, y = 1.5, z = 1},
		minacc = {x = 0, y = -6, z = 0}, maxacc = {x = 0, y = -6, z = 0},
		minexptime = 0.3, maxexptime = 0.8, minsize = 0.5, maxsize = 1.2,
		texture = "[fill:4x4:#9a9088",
	})
end
-- 孔口岩面上的點（世界座標）
local function face_point(above, under, k)
	return vector.add(above, vector.multiply(vector.subtract(under, above), k or 0.5))
end

---------------------------------------------------------------- 鑽堡
do
	local HOLE_TIME = 0.5      -- 一支鑽臂鑽一個孔 (s)
	local FEED_LEN = 3.0       -- 推進樑長 (m)
	local BOOM_BASE = {{x = -0.6, y = 0.0, z = 1.2}, {x = 0.6, y = 0.0, z = 1.2}}   -- 鑽臂根部（車身座標）
	local BOOM_REST = {{x = -0.6, y = -0.1, z = 2.4}, {x = 0.6, y = -0.1, z = 2.4}} -- 收起時臂端（推進樑中心）
	local FRONT = 2.4          -- 收起的推進樑伸出車頭 (m)

	local def = {desc = S("Drill jumbo"), color = "#d86a18", cap = 0,
		item_desc = S("Right-click to get in; E drills, Space edits the pattern")}
	do   -- 圖示：輪式車身、護頂、往前伸的兩支鑽臂
		local c, r = def.color, {}
		r[#r + 1] = {2, 16, 19, 8, c}; r[#r + 1] = {2, 8, 9, 2, c}
		r[#r + 1] = {3, 10, 1, 6, "#3a3a3a"}; r[#r + 1] = {9, 10, 1, 6, "#3a3a3a"}
		r[#r + 1] = {16, 9, 4, 10, "#3a3a3a"}
		r[#r + 1] = {18, 10, 13, 2, "#b0b0b0"}; r[#r + 1] = {18, 15, 13, 2, "#b0b0b0"}
		r[#r + 1] = {29, 9, 2, 4, "#e0e0e0"}; r[#r + 1] = {29, 14, 2, 4, "#e0e0e0"}
		V.icon_wheel(r, 7, 26, 4); V.icon_wheel(r, 17, 26, 4)
		def.inv_image = V.icon(r)
	end
	local steel = box_tex("#3a3a3a")
	carrier(def, {
		{id = "boom1", pos = {x = 0, y = 0, z = 0}, size = {x = 0.3, y = 1, z = 0.3}, tex = box_tex(def.color)},
		{id = "boom2", pos = {x = 0, y = 0, z = 0}, size = {x = 0.3, y = 1, z = 0.3}, tex = box_tex(def.color)},
		{id = "feed1", pos = {x = 0, y = 0, z = 0}, size = {x = 0.22, y = 0.22, z = FEED_LEN}, tex = steel},
		{id = "feed2", pos = {x = 0, y = 0, z = 0}, size = {x = 0.22, y = 0.22, z = FEED_LEN}, tex = steel},
	})
	def.overhangs[#def.overhangs + 1] = {x0 = -1.0, x1 = 1.0, z0 = 1.5, z1 = 1.5 + FRONT, y0 = -1.0, y1 = 0.5, body = "z0"}

	-- 鑽臂 i 的臂端（推進樑中心，車身座標）擺到 tip；鑽臂從根部到推進樑中段，推進樑朝車頭方向
	local function place_boom(self, i, tip)
		local ps = self.parts
		if not ps then return end
		local base = BOOM_BASE[i]
		local boom, feed = ps["boom" .. i], ps["feed" .. i]
		if boom then
			boom:set_properties({visual_size = {x = 0.3, y = math.max(0.1, vector.distance(base, tip)), z = 0.3}})
			seg_attach(self, boom, base, tip)
		end
		if feed then feed:set_attach(self.object, "", {x = tip.x * 10, y = tip.y * 10, z = tip.z * 10}, {x = 0, y = 0, z = 0}) end
	end
	local function rest_booms(self)
		for i = 1, 2 do place_boom(self, i, BOOM_REST[i]) end
	end
	-- 鑽臂伸到孔位（推進樑前端頂著岩面）
	local function boom_to_hole(self, i, h)
		local lp = to_local(self, face_point(h.above, h.under))
		place_boom(self, i, {x = lp.x, y = lp.y, z = lp.z - FEED_LEN / 2})
	end

	-- 爆破孔設計圖：寬 w、高 h（3～7），cells 是 w·h 個字元（由左到右、由下到上）：c 裝藥孔、r 空孔、n 不鑽
	local MARK = {c = "●", r = "○", n = "·"}
	local NEXT = {c = "r", r = "n", n = "c"}
	local function preset(w, h, kind)
		local t = {}
		local cx, cy = math.floor((w - 1) / 2), math.floor((h - 1) / 2)
		for j = 0, h - 1 do for i = 0, w - 1 do
			local k = "c"
			local d = math.abs(i - cx) + math.abs(j - cy)
			if kind == "cut" and d == 0 then k = "r" end
			if kind == "cut4" and d == 1 then k = "r" end
			if kind == "none" then k = "n" end
			t[#t + 1] = k
		end end
		return table.concat(t)
	end
	local function pattern(self)
		if not self.plan then self.plan = {w = 5, h = 5, cells = preset(5, 5, "cut")} end
		return self.plan
	end
	local function cell(plan, i, j) return plan.cells:sub(j * plan.w + i + 1, j * plan.w + i + 1) end

	-- 依設計圖找出要鑽的孔：{under（岩石）, above（孔口那格）, plan}
	local function hole_list(self, pos, s)
		local plan = pattern(self)
		local list = {}
		scan_face(pos, s, def.half, plan.w, plan.h, function(i, j, p, prev, n)
			local k = cell(plan, i, j)
			if k == "n" then return true end
			if rockmech.lith_of_node[n] then
				if prev and core.get_node(prev).name == "air" then list[#list + 1] = {under = p, above = prev, plan = k} end
				return true
			end
			return not V.passable(n)   -- 碎石、其他方塊擋住：這個孔位不鑽
		end)
		return list
	end
	rockmech.vehicle_jumbo_holes = hole_list   -- 測試用

	function def.hud(self)
		local plan = pattern(self)
		local s = "\n" .. S("Blast hole pattern @1 × @2", ("%d"):format(plan.w), ("%d"):format(plan.h))
		if self.drill then s = s .. "  " .. S("Drilling @1 / @2", ("%d"):format(self.drill.done), ("%d"):format(#self.drill.list)) end
		return s
	end
	function def.keys(self) return {{"E", S("Drill to pattern"), on = self.drill ~= nil}, {S("Space"), S("Edit pattern")}} end
	function def.on_load(self, data)
		if data.plan and data.plan.cells and #data.plan.cells == data.plan.w * data.plan.h then self.plan = data.plan end
	end
	function def.on_save(self, data) data.plan = self.plan end
	function def.on_spawn(self) rest_booms(self) end
	carrier_move(def, FRONT, function(self) return self.drill ~= nil end)

	-- 鑽孔：兩支鑽臂各拿下一個孔，HOLE_TIME 秒鑽好
	function def.step(self, ctx)
		local dr = self.drill
		if not dr then return end
		for i = 1, 2 do
			local b = dr.booms[i]
			if not b.hole and dr.next <= #dr.list then
				b.hole, b.t = dr.list[dr.next], 0
				dr.next = dr.next + 1
				boom_to_hole(self, i, b.hole)
			end
			if b.hole then
				b.t = b.t + ctx.dtime * rockmech.eff_dig_mult(self.owner)
				local h = b.hole
				dust(face_point(h.above, h.under, 0.45), ctx.dtime)
				if b.t >= HOLE_TIME then
					if rockmech.make_hole(h.under, h.above) then
						local meta = core.get_meta(h.above)
						meta:set_string("plan", h.plan)
						meta:set_string("infotext", h.plan == "r" and S("Drill hole (design: relief hole, do not charge)") or S("Drill hole (design: charged hole)"))
					end
					dr.done = dr.done + 1
					b.hole = nil
					update_hud(self)
				end
			end
		end
		if dr.done >= #dr.list then
			self.drill = nil
			self.msg = S("Drilled @1 holes", ("%d"):format(dr.done))
			rest_booms(self)
			update_hud(self)
		end
	end

	-- 設計圖編輯畫面
	local editing = {}   -- 玩家名 → 鑽堡
	local function plan_formspec(self)
		local plan = pattern(self)
		local cs = 0.9
		local W = math.max(9, plan.w * cs + 1.5)
		local fs = {("formspec_version[6]size[%.2f,%.2f]"):format(W, plan.h * cs + 4.6),
			"label[0.5,0.5;" .. core.formspec_escape(S("Blast hole pattern (looking at the face; the bottom row is at floor level)")) .. "]",
			"label[0.5,1.0;" .. core.formspec_escape(S("Click a cell to toggle: ● charged hole  ○ relief hole  · not drilled")) .. "]",
			"style_type[button;font_size=*1.3]"}
		local x0 = (W - plan.w * cs) / 2
		for j = 0, plan.h - 1 do
			for i = 0, plan.w - 1 do
				local y = 1.5 + (plan.h - 1 - j) * cs
				fs[#fs + 1] = ("button[%.2f,%.2f;%.2f,%.2f;c_%d_%d;%s]"):format(x0 + i * cs, y, cs - 0.05, cs - 0.05, i, j, MARK[cell(plan, i, j)])
			end
		end
		local y = 1.7 + plan.h * cs
		fs[#fs + 1] = "style_type[button;font_size=*1]"
		fs[#fs + 1] = ("label[0.5,%.2f;%s]button[1.6,%.2f;0.7,0.7;w_dec;−]button[2.35,%.2f;0.7,0.7;w_inc;+]"):format(y + 0.35,
			core.formspec_escape(S("Width @1", ("%d"):format(plan.w))), y, y)
		fs[#fs + 1] = ("label[3.5,%.2f;%s]button[4.6,%.2f;0.7,0.7;h_dec;−]button[5.35,%.2f;0.7,0.7;h_inc;+]"):format(y + 0.35,
			core.formspec_escape(S("Height @1", ("%d"):format(plan.h))), y, y)
		y = y + 1.0
		fs[#fs + 1] = ("button[0.5,%.2f;2.6,0.8;p_all;%s]button[3.2,%.2f;2.6,0.8;p_cut;%s]button[5.9,%.2f;2.6,0.8;p_cut4;%s]"):format(
			y, core.formspec_escape(S("Charge all")), y, core.formspec_escape(S("Center relief-hole cut")), y, core.formspec_escape(S("Cross relief-hole cut")))
		y = y + 0.95
		fs[#fs + 1] = ("button[0.5,%.2f;2.6,0.8;p_none;%s]button_exit[%.2f,%.2f;2.6,0.8;ok;%s]"):format(y, core.formspec_escape(S("Clear")),
			W - 3.1, y, core.formspec_escape(S("Done")))
		return table.concat(fs)
	end
	local function show_plan(self, name)
		editing[name] = self
		core.show_formspec(name, "rockmech:jumbo_plan", plan_formspec(self))
	end
	core.register_on_player_receive_fields(function(player, formname, fields)
		if formname ~= "rockmech:jumbo_plan" then return end
		local name = player:get_player_name()
		local self = editing[name]
		if not self or not self.object:get_pos() then return true end
		local plan = pattern(self)
		if fields.quit or fields.ok then
			editing[name] = nil
			update_hud(self)
			return true
		end
		local function resize(w, h)
			w, h = math.max(3, math.min(7, w)), math.max(3, math.min(7, h))
			if w ~= plan.w or h ~= plan.h then self.plan = {w = w, h = h, cells = preset(w, h, "cut")} end
		end
		for k in pairs(fields) do
			local i, j = k:match("^c_(%d+)_(%d+)$")
			if i then
				local idx = tonumber(j) * plan.w + tonumber(i) + 1
				plan.cells = plan.cells:sub(1, idx - 1) .. NEXT[plan.cells:sub(idx, idx)] .. plan.cells:sub(idx + 1)
			end
		end
		if fields.w_dec then resize(plan.w - 1, plan.h) end
		if fields.w_inc then resize(plan.w + 1, plan.h) end
		if fields.h_dec then resize(plan.w, plan.h - 1) end
		if fields.h_inc then resize(plan.w, plan.h + 1) end
		if fields.p_all then plan.cells = preset(plan.w, plan.h, "all") end
		if fields.p_cut then plan.cells = preset(plan.w, plan.h, "cut") end
		if fields.p_cut4 then plan.cells = preset(plan.w, plan.h, "cut4") end
		if fields.p_none then plan.cells = preset(plan.w, plan.h, "none") end
		show_plan(self, name)
		return true
	end)

	function def.action(self, ctx)
		local ctrl, d = ctx.ctrl, ctx.d
		if ctrl.aux1 and not self.drill then
			self.t_act = 0.5
			local list = hole_list(self, ctx.pos, ctx.s)
			if #list == 0 then
				self.msg = S("No rock face to drill within @1 m ahead (point the front at the rock wall)", ("%d"):format(REACH + 1))
			else
				self.drill = {list = list, next = 1, done = 0, booms = {{}, {}}}
				self.msg = nil
			end
			update_hud(self)
		elseif ctrl.jump and d and not self.drill then
			self.t_act = 0.5
			show_plan(self, d:get_player_name())
		end
	end

	V.register("jumbo", def)
end

---------------------------------------------------------------- 裝藥台車
do
	local CHARGE_TIME = 0.6    -- 裝一個孔 (s)
	local BOOM_BASE = {x = 0, y = 0.3, z = 1.2}       -- 吊臂根部（車身座標）
	local BASKET_REST = {x = 0, y = 0.2, z = 2.3}     -- 收起時工作籃中心
	local BASKET = {x = 1.2, y = 0.9, z = 1.0}
	local FRONT = 1.4          -- 收起的工作籃伸出車頭 (m)

	local def = {desc = S("Charging unit"), color = "#2a7ac0", cap = 0,
		item_desc = S("Right-click to get in; E charges, Space sets sticks per hole")}
	do   -- 圖示：輪式車身、後面的炸藥罐、吊臂與工作籃
		local c, r = def.color, {}
		r[#r + 1] = {2, 17, 19, 7, c}; r[#r + 1] = {2, 10, 8, 7, "#e8e8e0"}; r[#r + 1] = {2, 13, 8, 1, c}
		V.icon_line(r, 16, 16, 24, 8, 2, c)
		r[#r + 1] = {22, 3, 9, 1, "#e8c020"}; r[#r + 1] = {22, 8, 9, 1, "#e8c020"}
		r[#r + 1] = {22, 3, 1, 6, "#e8c020"}; r[#r + 1] = {30, 3, 1, 6, "#e8c020"}
		V.icon_wheel(r, 7, 26, 4); V.icon_wheel(r, 17, 26, 4)
		def.inv_image = V.icon(r)
	end
	local rail = "[fill:16x16:#00000000^[fill:16x2:0,0:#e8c020^[fill:2x16:0,0:#e8c020^[fill:2x16:14,0:#e8c020^[fill:16x6:0,10:#e8c020"
	local tank = "[fill:16x16:#e8e8e0^[fill:16x3:0,6:" .. def.color
	carrier(def, {
		{id = "boom", pos = {x = 0, y = 0, z = 0}, size = {x = 0.35, y = 1, z = 0.35}, tex = box_tex(def.color)},
		{id = "basket", pos = BASKET_REST, size = BASKET, tex = {rail, "[fill:16x16:#3a3a3a", rail, rail, rail, rail}},
		{pos = {x = 0, y = 0.35, z = -2.4}, size = {x = 1.6, y = 1.4, z = 1.1}, tex = {tank, tank, tank, tank, tank, tank}},   -- 乳化炸藥罐
	})
	def.overhangs[#def.overhangs + 1] = {x0 = -0.8, x1 = 0.8, z0 = 1.5, z1 = 1.5 + FRONT, y0 = -0.5, y1 = 0.8, body = "z0"}

	local function place_basket(self, b)
		local ps = self.parts
		if not ps then return end
		if ps.boom then
			ps.boom:set_properties({visual_size = {x = 0.35, y = math.max(0.1, vector.distance(BOOM_BASE, b)), z = 0.35}})
			seg_attach(self, ps.boom, BOOM_BASE, {x = b.x, y = b.y - BASKET.y / 2, z = b.z - BASKET.z / 2})
		end
		if ps.basket then
			ps.basket:set_properties({use_texture_alpha = true})
			ps.basket:set_attach(self.object, "", {x = b.x * 10, y = b.y * 10, z = b.z * 10}, {x = 0, y = 0, z = 0})
		end
	end

	local function per_hole(self) return self.cart or 2 end

	-- 前方工作面（7 × 7 範圍）上的鑽孔：設計是空孔的跳過
	local function hole_list(self, pos, s)
		local list = {}
		scan_face(pos, s, def.half, 7, 7, function(i, j, p, prev, n)
			if rockmech.hole_kind(n) == HOLE then
				if core.get_meta(p):get_string("plan") ~= "r" then list[#list + 1] = p end
				return true
			end
			return not V.passable(n) or rockmech.lith_of_node[n] ~= nil
		end)
		return list
	end
	rockmech.vehicle_charger_holes = hole_list   -- 測試用

	-- 駕駛的物品欄裡的乳膠炸藥（創造模式不限）
	local function stock(d)
		if not d then return math.huge end
		if core.is_creative_enabled(d:get_player_name()) then return math.huge end
		local n = 0
		for _, st in ipairs(d:get_inventory():get_list("main") or {}) do
			if st:get_name() == EMULSION then n = n + st:get_count() end
		end
		return n
	end

	function def.hud(self)
		local s = "\n" .. S("@1 emulsion sticks per hole", ("%d"):format(per_hole(self)))
		local d = self.driver and core.get_player_by_name(self.driver)
		local n = stock(d)
		s = s .. "  " .. (n == math.huge and S("(not used up in creative mode)") or S("@1 sticks in inventory", ("%d"):format(n)))
		if self.charging then s = s .. "  " .. S("Charging @1 / @2", ("%d"):format(self.charging.done), ("%d"):format(#self.charging.list)) end
		return s
	end
	function def.keys(self) return {{"E", S("Charge (face ahead)"), on = self.charging ~= nil}, {S("Space"), S("Sticks per hole")}} end
	function def.on_load(self, data) self.cart = data.cart end
	function def.on_save(self, data) data.cart = self.cart end
	function def.on_spawn(self) place_basket(self, BASKET_REST) end
	carrier_move(def, FRONT, function(self) return self.charging ~= nil end)

	function def.step(self, ctx)
		local cg = self.charging
		if not cg then return end
		local p = cg.list[cg.done + 1]
		if not p then
			self.charging = nil
			place_basket(self, BASKET_REST)
			update_hud(self)
			return
		end
		if cg.t == 0 then
			-- 工作籃伸到孔口前方、稍低（人站在籃裡裝）
			local lp = to_local(self, p)
			place_basket(self, {x = lp.x, y = lp.y - 0.5, z = lp.z - 0.9})
		end
		cg.t = cg.t + ctx.dtime
		if cg.t >= CHARGE_TIME then
			cg.t = 0
			local d = ctx.d
			local n = math.min(per_hole(self), stock(d))
			if n <= 0 then
				self.msg = S("Out of emulsion (charged @1 holes)", ("%d"):format(cg.done))
				self.charging = nil
				place_basket(self, BASKET_REST)
				update_hud(self)
				return
			end
			local loaded = 0
			for _ = 1, n do
				local hn = rockmech.hole_kind(core.get_node(p).name)
				if hn == HOLE or hn == "rockmech:charged_hole" then
					if rockmech.load_charge(p, p, self.driver and core.get_player_by_name(self.driver)) then loaded = loaded + 1 end
				end
			end
			if d and loaded > 0 and stock(d) ~= math.huge then d:get_inventory():remove_item("main", ItemStack(EMULSION .. " " .. loaded)) end
			cg.done = cg.done + 1
			if cg.done >= #cg.list then self.msg = S("Charged @1 holes", ("%d"):format(cg.done)) end
			update_hud(self)
		end
	end

	local editing = {}
	local function cart_formspec(self)
		local fs = {"formspec_version[6]size[7,3.2]label[0.5,0.6;" .. core.formspec_escape(S("Emulsion sticks per hole")) .. "]"}
		for k = 1, 4 do
			fs[#fs + 1] = ("button[%.2f,1.2;1.3,0.9;n_%d;%s%d]"):format(0.5 + (k - 1) * 1.5, k, k == per_hole(self) and "▶ " or "", k)
		end
		fs[#fs + 1] = "button_exit[4.5,2.3;2,0.7;ok;" .. core.formspec_escape(S("Done")) .. "]"
		return table.concat(fs)
	end
	core.register_on_player_receive_fields(function(player, formname, fields)
		if formname ~= "rockmech:charger_cart" then return end
		local name = player:get_player_name()
		local self = editing[name]
		if not self or not self.object:get_pos() then return true end
		for k = 1, 4 do
			if fields["n_" .. k] then self.cart = k end
		end
		if fields.quit or fields.ok then
			editing[name] = nil
		else
			core.show_formspec(name, "rockmech:charger_cart", cart_formspec(self))
		end
		update_hud(self)
		return true
	end)

	function def.action(self, ctx)
		local ctrl, d = ctx.ctrl, ctx.d
		if ctrl.aux1 and not self.charging then
			self.t_act = 0.5
			local list = hole_list(self, ctx.pos, ctx.s)
			if #list == 0 then
				self.msg = S("No holes to charge within @1 m ahead", ("%d"):format(REACH + 1))
			else
				self.charging = {list = list, done = 0, t = 0}
				self.msg = nil
			end
			update_hud(self)
		elseif ctrl.jump and d and not self.charging then
			self.t_act = 0.5
			editing[d:get_player_name()] = self
			core.show_formspec(d:get_player_name(), "rockmech:charger_cart", cart_formspec(self))
		end
	end

	V.register("charger", def)
end
