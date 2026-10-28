-- rockmech/vehicle_jumbo.lua
-- 鑽堡（雙臂鑿岩台車，Sandvik DT／Epiroc Boomer 類）。由 vehicles.lua 載入。
-- 3 寬 × 3 高；四輪底盤、中間駕駛室、後方動力箱；車頭兩支鑽臂，臂端是往前的推進樑。
--   E：照爆破孔設計圖，在車頭前方的工作面鑽一整片孔（寬 × 高的孔網、孔距 1 m；橫向以車身中心線為中、
--      從地面那層往上）。每個孔位沿車頭方向往前找第一個露出的岩面（最遠 REACH 格）；兩支鑽臂輪流鑽，鑽的時候不能開車。
--   空白鍵：爆破孔設計圖（● 裝藥孔／○ 空孔／· 不鑽，寬高 3～7）。● ○ 都會鑽，鑽好的孔記住設計（指著看得到）；
--      鑽堡只鑽孔，裝藥另外用乳膠炸藥（真的工地是另一台裝藥台車）

local V = rockmech.vehicles
local NLEV = V.NLEV
local box_tex, seg_attach, to_local, update_hud = V.box_tex, V.seg_attach, V.to_local, V.update_hud

local REACH = 3            -- 孔位從車頭外第一排往前找岩面最多幾格
local HOLE_TIME = 0.5      -- 一支鑽臂鑽一個孔 (s)
local FEED_LEN = 1.6       -- 推進樑長 (m)
local BOOM_BASE = {{x = -0.6, y = 0.0, z = 1.9}, {x = 0.6, y = 0.0, z = 1.9}}   -- 鑽臂根部（車身座標）
local BOOM_REST = {{x = -0.6, y = -0.1, z = 1.7}, {x = 0.6, y = -0.1, z = 1.7}} -- 收起時臂端（推進樑中心）

local def = {desc = "鑽堡 Drill jumbo", color = "#d86a18", cap = 0, speed = 2.0,
	half = 1.5, lat = {-1, 0, 1}, eye_up = 1.75, eye_fwd = 0.6, mirror = {x = 1.35, y = 1.4, z = 0.3},
	tilt = {front = 1.0, rear = -2.3, side_z = -0.6, side_x = 1.15}, max_grade = math.rad(15),
	item_desc = "右鍵上車；E 依爆破孔設計圖在前方工作面鑽孔、空白鍵 編輯設計圖"}
def.inv_image = V.inv_icon(def.color, "^[fill:6x2:10,5:#b0b0b0^[fill:6x2:10,9:#b0b0b0^[fill:4x5:2,4:#9fd0ff")

-- 外觀（原點在 3×3×3 碰撞箱中心；車頭 z +1.5、鑽臂收起時伸到約 +2.5、車尾 −3；車底 y −1.5）
do
	local c = def.color
	local o = ("[fill:16x16:%s"):format(c)
	local win = ("[fill:16x16:%s^[fill:12x9:2,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
	local side = ("[fill:16x16:%s^[fill:9x8:3,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
	local grille = ("[fill:16x16:%s^[fill:12x8:2,4:#2a2a2a^[fill:12x1:2,6:#4a4a4a^[fill:12x1:2,9:#4a4a4a"):format(c)
	local WHEEL, TREAD = V.WHEEL, V.TREAD
	local wheel = {TREAD, TREAD, WHEEL, WHEEL, TREAD, TREAD}
	local steel = box_tex("#3a3a3a")
	def.parts = {
		{pos = {x = 0, y = -0.85, z = -0.5}, size = {x = 2.3, y = 0.6, z = 5.0}, tex = box_tex("#2a2a2a")},   -- 底盤
		{pos = {x = 0, y = -0.3, z = 1.55}, size = {x = 1.8, y = 0.8, z = 0.7}, tex = box_tex("#4a4a4a")},   -- 鑽臂座
		{pos = {x = 0, y = 0.45, z = -0.6}, size = {x = 1.8, y = 1.9, z = 1.6}, tex = {o, "[fill:16x16:#2a2a2a", side, side, win, o}},   -- 駕駛室
		{pos = {x = 0, y = 0.0, z = -2.4}, size = {x = 2.2, y = 1.2, z = 1.2}, tex = {o, o, grille, grille, o, o}},   -- 動力箱
		{id = "boom1", pos = {x = 0, y = 0, z = 0}, size = {x = 0.25, y = 1, z = 0.25}, tex = box_tex(c)},
		{id = "boom2", pos = {x = 0, y = 0, z = 0}, size = {x = 0.25, y = 1, z = 0.25}, tex = box_tex(c)},
		{id = "feed1", pos = {x = 0, y = 0, z = 0}, size = {x = 0.2, y = 0.2, z = FEED_LEN}, tex = steel},
		{id = "feed2", pos = {x = 0, y = 0, z = 0}, size = {x = 0.2, y = 0.2, z = FEED_LEN}, tex = steel},
	}
	for _, w in ipairs({{x = -1.15, z = 0.8}, {x = 1.15, z = 0.8}, {x = -1.15, z = -2.2}, {x = 1.15, z = -2.2}}) do
		def.parts[#def.parts + 1] = {pos = {x = w.x, y = -0.9, z = w.z}, size = {x = 0.5, y = 1.2, z = 1.2}, tex = wheel}
	end
end

-- 鑽臂 i 的臂端（推進樑中心，車身座標）擺到 tip：臂從根部到推進樑後端，推進樑朝車頭方向
local function place_boom(self, i, tip)
	local ps = self.parts
	if not ps then return end
	local base = BOOM_BASE[i]
	local back = {x = tip.x, y = tip.y, z = tip.z - FEED_LEN / 2}
	local boom, feed = ps["boom" .. i], ps["feed" .. i]
	if boom then
		boom:set_properties({visual_size = {x = 0.25, y = math.max(0.1, vector.distance(base, back)), z = 0.25}})
		seg_attach(self, boom, base, back)
	end
	if feed then feed:set_attach(self.object, "", {x = tip.x * 10, y = tip.y * 10, z = tip.z * 10}, {x = 0, y = 0, z = 0}) end
end
local function rest_booms(self)
	for i = 1, 2 do place_boom(self, i, BOOM_REST[i]) end
end

-- 爆破孔設計圖：寬 w、高 h（3～7），cells 是 w·h 個字元（由左到右、由下到上）：c 裝藥孔、r 空孔、n 不鑽
local MARK = {c = "●", r = "○", n = "·"}
local NEXT = {c = "r", r = "n", n = "c"}
local function preset(w, h, kind)
	local t = {}
	local cx, cy = math.floor((w - 1) / 2), math.floor((h - 1) / 2)
	for j = 0, h - 1 do for i = 0, w - 1 do
		local k = "c"
		if kind == "cut" and math.abs(i - cx) + math.abs(j - cy) == 0 then k = "r" end
		if kind == "cut4" and math.abs(i - cx) + math.abs(j - cy) == 1 then k = "r" end
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
	local y0 = V.ground_y(pos, def.half)
	local px, pz = -s.z, s.x   -- 往右
	local list = {}
	for j = 0, plan.h - 1 do
		for i = 0, plan.w - 1 do
			local k = cell(plan, i, j)
			if k ~= "n" then
				local l = i - math.floor((plan.w - 1) / 2)
				local prev
				for dist = 2, 2 + REACH do
					local p = {x = math.floor(pos.x + s.x * dist + px * l + 0.5), y = y0 + j, z = math.floor(pos.z + s.z * dist + pz * l + 0.5)}
					local n = core.get_node(p).name
					if rockmech.lith_of_node[n] then
						if prev and core.get_node(prev).name == "air" then list[#list + 1] = {under = p, above = prev, plan = k} end
						break
					end
					if not V.passable(n) then break end   -- 碎石、其他方塊擋住：這個孔位不鑽
					prev = p
				end
			end
		end
	end
	return list
end

-- 鑽臂伸到孔位（推進樑前端頂著岩面）
local function boom_to_hole(self, i, h)
	local face = vector.add(h.above, vector.multiply(vector.subtract(h.under, h.above), 0.5))
	local lp = to_local(self, face)
	place_boom(self, i, {x = lp.x, y = lp.y, z = lp.z - FEED_LEN / 2})
end

function def.hud(self)
	local plan = pattern(self)
	local s = ("\n爆破孔設計圖 %d × %d"):format(plan.w, plan.h)
	if self.drill then s = s .. ("　鑽孔中 %d / %d"):format(self.drill.done, #self.drill.list) end
	if self.msg then s = s .. "\n" .. self.msg end
	return s .. "\nE 依設計圖鑽孔　空白鍵 編輯設計圖"
end
function def.on_load(self, data)
	if data.plan and data.plan.cells and #data.plan.cells == data.plan.w * data.plan.h then self.plan = data.plan end
end
function def.on_save(self, data) data.plan = self.plan end
function def.on_spawn(self) rest_booms(self) end

-- 擋人：收起的鑽臂（車頭外 1 m）與車尾（動力箱，車尾外 1.5 m）
def.overhangs = {
	{x0 = -1.0, x1 = 1.0, z0 = 1.5, z1 = 2.6, y0 = -1.0, y1 = 0.5, body = "z0"},
	{x0 = -1.2, x1 = 1.2, z0 = -3.0, z1 = -1.5, y0 = -1.5, y1 = 0.6, body = "z1"},
}

-- 鑽臂（車頭外第一排）與車尾（外兩排）伸出碰撞箱：往那邊開前看有沒有岩石、人或車
local function overhang_blocked(self, pos, s, f, dists, layers, ctx)
	local y0 = V.ground_y(pos, def.half)
	for _, dist in ipairs(dists) do
		for _, dy in ipairs(layers) do
			for _, c in ipairs(V.face_cells(pos, s, f, dist, y0 + dy, 1, def.lat)) do
				local n = core.get_node(c).name
				if not rockmech.rubble_level[n] and not V.passable(n) then return true end
			end
		end
	end
	local la = ctx.speed * 0.1
	local p2 = {x = pos.x + ctx.dir.x * la, y = pos.y, z = pos.z + ctx.dir.z * la}
	local h = def.half
	if f > 0 then return V.objects_in(self, p2, ctx.yaw, -1.0, 1.0, h, h + 1.1) end
	return V.objects_in(self, p2, ctx.yaw, -1.2, 1.2, -3.0, -h)
end

function def.move(self, ctx)
	if self.drill then ctx.speed = 0; return end   -- 鑽孔時不能開車
	if ctx.fwd > 0 and overhang_blocked(self, ctx.pos, ctx.s, 1, {2}, {1}, ctx) then ctx.speed = 0 end
	if ctx.fwd < 0 and overhang_blocked(self, ctx.pos, ctx.s, -1, {2}, {1, 2}, ctx) then ctx.speed = 0 end
end

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
			b.t = b.t + ctx.dtime
			local h = b.hole
			local face = vector.add(h.above, vector.multiply(vector.subtract(h.under, h.above), 0.45))
			core.add_particlespawner({
				amount = 3, time = ctx.dtime,
				minpos = vector.subtract(face, 0.1), maxpos = vector.add(face, 0.1),
				minvel = {x = -1, y = 0, z = -1}, maxvel = {x = 1, y = 1.5, z = 1},
				minacc = {x = 0, y = -6, z = 0}, maxacc = {x = 0, y = -6, z = 0},
				minexptime = 0.3, maxexptime = 0.8, minsize = 0.5, maxsize = 1.2,
				texture = "[fill:4x4:#9a9088",
			})
			if b.t >= HOLE_TIME then
				if rockmech.make_hole(h.under, h.above) then
					core.get_meta(h.above):set_string("infotext",
						h.plan == "r" and "鑽孔（設計：空孔，不要裝藥）" or "鑽孔（設計：裝藥孔）")
				end
				dr.done = dr.done + 1
				b.hole = nil
				update_hud(self)
			end
		end
	end
	if dr.done >= #dr.list then
		self.drill = nil
		self.msg = ("鑽好 %d 個孔"):format(dr.done)
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
		"label[0.5,0.5;爆破孔設計圖（面向工作面看；最下面一排是地面那層）]",
		"label[0.5,1.0;點格子切換：● 裝藥孔　○ 空孔　· 不鑽]",
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
	fs[#fs + 1] = ("label[0.5,%.2f;寬 %d]button[1.6,%.2f;0.7,0.7;w_dec;−]button[2.35,%.2f;0.7,0.7;w_inc;+]"):format(y + 0.35, plan.w, y, y)
	fs[#fs + 1] = ("label[3.5,%.2f;高 %d]button[4.6,%.2f;0.7,0.7;h_dec;−]button[5.35,%.2f;0.7,0.7;h_inc;+]"):format(y + 0.35, plan.h, y, y)
	y = y + 1.0
	fs[#fs + 1] = ("button[0.5,%.2f;2.6,0.8;p_all;全部裝藥]button[3.2,%.2f;2.6,0.8;p_cut;中心空孔掏槽]button[5.9,%.2f;2.6,0.8;p_cut4;十字空孔掏槽]"):format(y, y, y)
	y = y + 0.95
	fs[#fs + 1] = ("button[0.5,%.2f;2.6,0.8;p_none;清空]button_exit[%.2f,%.2f;2.6,0.8;ok;完成]"):format(y, W - 3.1, y)
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
			i, j = tonumber(i), tonumber(j)
			local idx = j * plan.w + i + 1
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
			self.msg = ("前方 %d 格內沒有可鑽的岩面（車頭要對著岩壁）"):format(REACH + 1)
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
rockmech.vehicle_jumbo_holes = hole_list   -- 測試用

V.register("jumbo", def)
