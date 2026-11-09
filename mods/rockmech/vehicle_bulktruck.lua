-- rockmech/vehicle_bulktruck.lua
-- ANFO 裝藥車（露天礦的散裝炸藥車／現場混裝車 MMU）。由 vehicles.lua 載入。
-- 卡車底盤、後面是炸藥儲槽、儲槽後端頂上有迴轉的輸送吊臂（auger boom），軟管從吊臂前端垂直垂進孔裡。
--   空白鍵：儲槽（從背包裝滿 ANFO 與乳膠炸藥、卸回背包；車上存放，跟著車存檔、收車時還給玩家）。
--   E：把吊臂範圍內（BOOM_LEN m）往下的鑽孔依序灌滿：每孔一袋 ANFO ＋ 一條乳膠炸藥當起爆藥包
--      （已經有起爆藥包的只灌 ANFO、只有 ANFO 的只補起爆藥包），從儲槽扣。灌的時候不能開車。
--   車尾有倒車攝影機，畫面裡的孔是色點（白 = 空孔、粉紅 = ANFO）。裝藥車不能起爆。

local S = rockmech.S
local V = rockmech.vehicles
local box_tex, seg_attach, to_local, update_hud = V.box_tex, V.seg_attach, V.to_local, V.update_hud
local WHEEL, TREAD = V.WHEEL, V.TREAD

local BOOM_LEN = 8          -- 輸送吊臂伸得到的水平距離（從吊臂根部到孔口）(m)
local PUMP_TIME = 2.0       -- 灌一個孔 (s)
local BOOM_BASE = {x = 0, y = 1.75, z = -4.6}   -- 吊臂根部（儲槽後端頂上的迴轉台，車身座標）
local BOOM_REST = {x = 0, y = 1.45, z = -1.3}   -- 收起時吊臂前端（沿儲槽頂往前放）
local BOOM_UP = 1.2         -- 灌孔時吊臂前端比根部高多少 (m)
local ANFO, EMULSION = "rockmech:anfo", "rockmech:emulsion"
local HOLE, CHARGED, ANFO_HOLE = "rockmech:drill_hole", "rockmech:charged_hole", "rockmech:anfo_hole"

local def = {desc = S("ANFO bulk truck"), color = "#3a8a50", cap = 0, speed = 5.0,
	top_speed = 12, accel = 1.5, max_grade = math.rad(17), look_limit = math.rad(75), tire = 1.0,
	half = 1.5, lat = {-1, 0, 1}, eye_up = 1.55, eye_fwd = 1.35, rear = 5.5, mirror = {x = 1.35, y = 1.3, z = 1.2},
	tilt = {front = 0.5, rear = -3.8, side_z = -1.6, side_x = 1.1},
	tail_lat = {-1.25, 0, 1.25}, tail_dy = {1.2, 2.2},
	-- 倒車攝影機（車尾上方往後下看）：吊臂範圍內的孔畫成色點
	cam = {o = {x = 0, y = 1.6, z = -5.8}, target = {x = 0, y = -1.5, z = -10}, holes = BOOM_LEN + 2, flip = false,
		hfov = math.rad(80), vfov = math.rad(48), w = 56, h = 31},
	store = {{ANFO, 40, S("ANFO (bags)")}, {EMULSION, 40, S("Emulsion explosive (sticks)")}},
	item_desc = S("Right-click to get in; Space loads, E charges the holes")}
do   -- 圖示：白色儲槽（綠、粉紅條紋）、槽頂的黃色吊臂、駕駛室、三軸
	local c, r = def.color, {}
	r[#r + 1] = {2, 12, 20, 10, "#e8e8e0"}; r[#r + 1] = {2, 12, 1, 10, "#c8c8c0"}
	r[#r + 1] = {2, 17, 20, 2, c}; r[#r + 1] = {2, 19, 20, 1, "#e890b0"}
	r[#r + 1] = {4, 10, 3, 2, "#4a4a4a"}; r[#r + 1] = {5, 8, 17, 2, "#d8b020"}
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
	local tank = "[fill:16x16:#e8e8e0^[fill:16x2:0,9:" .. c .. "^[fill:16x1:0,12:#e890b0"
	local tank_end = "[fill:16x16:#d8d8d0^[fill:10x10:3,3:#c8c8c0"
	local wheel = {TREAD, TREAD, WHEEL, WHEEL, TREAD, TREAD}
	def.parts = {
		{pos = {x = 0, y = -0.55, z = -2.0}, size = {x = 1.6, y = 0.3, z = 6.6}, tex = box_tex("#2a2a2a")},   -- 底盤
		{pos = {x = 0, y = 0.6, z = 0.5}, size = {x = 2.4, y = 2.0, z = 2.0}, alpha = true,
			tex = {("[fill:16x16:%s"):format(c), "[fill:16x16:#2a2a2a", cab_side, cab_side_l, cab_front, ("[fill:16x16:%s"):format(c)}},   -- 駕駛室（車窗半透明）
		{pos = {x = 0, y = 0.6, z = -0.46}, size = {x = 2.36, y = 1.96, z = 0.04}, tex = box_tex(c)},   -- 駕駛室後牆
		{pos = {x = 0, y = 0.45, z = -2.9}, size = {x = 2.2, y = 1.6, z = 4.4}, tex = {tank, tank, tank, tank, tank_end, tank_end}},   -- 儲槽
		{pos = {x = 0, y = 1.45, z = BOOM_BASE.z}, size = {x = 0.8, y = 0.4, z = 0.8}, tex = box_tex("#4a4a4a")},   -- 吊臂迴轉台
		{id = "boom", pos = {x = 0, y = 0, z = 0}, size = {x = 0.25, y = 1, z = 0.25}, tex = box_tex("#d8b020")},   -- 輸送吊臂
		{id = "hose", pos = {x = 0, y = 0, z = 0}, size = {x = 0.12, y = 1, z = 0.12}, tex = box_tex("#1a1a1a")},   -- 軟管（灌孔時從吊臂前端垂進孔裡）
	}
	for _, w in ipairs({{x = -1.15, z = 0.5, wd = 0.35}, {x = 1.15, z = 0.5, wd = 0.35},
			{x = -1.1, z = -3.2, wd = 0.6}, {x = 1.1, z = -3.2, wd = 0.6}, {x = -1.1, z = -4.4, wd = 0.6}, {x = 1.1, z = -4.4, wd = 0.6}}) do
		def.parts[#def.parts + 1] = {pos = {x = w.x, y = -1.0, z = w.z}, size = {x = w.wd, y = 1.0, z = 1.0}, tex = wheel}
	end
end
-- 擋人：儲槽那段（碰撞箱後方）
def.overhangs = {{x0 = -1.3, x1 = 1.3, z0 = -5.5, z1 = -1.5, y0 = -1.5, y1 = 1.3, body = "z1"}}

-- 吊臂與軟管：p（孔口那格，世界座標）→ 吊臂轉過去、前端停在孔口正上方，軟管垂直垂進孔裡；nil → 收起來
local function seg(self, o, a, b, w)
	o:set_properties({is_visible = true, visual_size = {x = w, y = math.max(0.1, vector.distance(a, b)), z = w}})
	seg_attach(self, o, a, b)
end
local function place_boom(self, p)
	local ps = self.parts
	if not (ps and ps.boom and ps.hose) then return end
	if not p then
		seg(self, ps.boom, BOOM_BASE, BOOM_REST, 0.25)
		ps.hose:set_properties({is_visible = false})
		return
	end
	local lp = to_local(self, p)
	local tip = {x = lp.x, y = BOOM_BASE.y + BOOM_UP, z = lp.z}
	seg(self, ps.boom, BOOM_BASE, tip, 0.25)
	seg(self, ps.hose, tip, {x = lp.x, y = lp.y - 0.3, z = lp.z}, 0.12)
end

-- 吊臂範圍內要灌的孔：往下的空孔、只放了乳膠炸藥的孔、只有 ANFO 的孔；近的先灌
local function hole_list(self)
	local r = V.to_world(self, BOOM_BASE)
	local list = {}
	for _, p in ipairs(core.find_nodes_in_area({x = r.x - BOOM_LEN, y = r.y - 7, z = r.z - BOOM_LEN},
			{x = r.x + BOOM_LEN, y = r.y, z = r.z + BOOM_LEN},
 rockmech.with_sprayed({HOLE, CHARGED, ANFO_HOLE}))) do
		local dx, dz = p.x - r.x, p.z - r.z
		if dx * dx + dz * dz <= BOOM_LEN * BOOM_LEN and core.wallmounted_to_dir(core.get_node(p).param2).y < 0 then
			list[#list + 1] = p
		end
	end
	table.sort(list, function(a, b) return vector.distance(a, r) < vector.distance(b, r) end)
	return list
end
rockmech.vehicle_bulktruck_holes = hole_list   -- 測試用

function def.hud(self)
	local s = "\n" .. S("Tank: ANFO @1 / @2 bags  Emulsion @3 / @4 sticks",
		("%d"):format(V.store_count(self, ANFO)), ("%d"):format(def.store[1][2]), ("%d"):format(V.store_count(self, EMULSION)), ("%d"):format(def.store[2][2]))
	if self.pumping then s = s .. "  " .. S("Filling holes @1 / @2", ("%d"):format(self.pumping.done), ("%d"):format(#self.pumping.list)) end
	return s
end
function def.keys(self)
	return {{"E", S("Fill holes (within @1 m of the boom)", ("%d"):format(BOOM_LEN)), on = self.pumping ~= nil}, {S("Space"), S("Tank")}}
end
function def.on_spawn(self) place_boom(self, nil) end

function def.can_turn(self, pos, yaw, yaw2)
	return not self.pumping and V.tail_can_turn(self, pos, yaw, yaw2, def)
end
function def.move(self, ctx)
	if self.pumping then ctx.speed = 0; return end
	V.tail_guard(self, def, ctx)
end

local function finish(self, msg)
	self.pumping = nil
	self.msg = msg
	place_boom(self, nil)
	update_hud(self)
end

function def.step(self, ctx)
	local pm = self.pumping
	if not pm then return end
	local p = pm.list[pm.done + 1]
	if not p then
		return finish(self, pm.bare > 0 and S("Filled @1 holes; @2 holes have no primer (not enough emulsion)", ("%d"):format(pm.done), ("%d"):format(pm.bare))
			or S("Filled @1 holes", ("%d"):format(pm.done)))
	end
	if pm.t == 0 then place_boom(self, p) end
	pm.t = pm.t + ctx.dtime
	core.add_particlespawner({
		amount = 3, time = ctx.dtime,
		minpos = vector.subtract(p, 0.15), maxpos = vector.add(p, 0.15),
		minvel = {x = -0.3, y = 0.3, z = -0.3}, maxvel = {x = 0.3, y = 0.8, z = 0.3},
		minexptime = 0.4, maxexptime = 0.8, minsize = 0.5, maxsize = 1.0,
		texture = "[fill:4x4:#e890b0",
	})
	if pm.t < PUMP_TIME then return end
	pm.t = 0
	local name = rockmech.hole_kind(core.get_node(p).name)
	local need_anfo, need_primer = name == HOLE or name == CHARGED, name == HOLE or name == ANFO_HOLE
	if need_anfo and V.store_count(self, ANFO) < 1 then
		return finish(self, S("Out of ANFO (filled @1 holes)", ("%d"):format(pm.done)))
	end
	if need_primer then
		if V.store_count(self, EMULSION) >= 1 and rockmech.load_charge(p, p, self.driver and core.get_player_by_name(self.driver)) then
			V.store_take(self, EMULSION, 1)
		else
			pm.bare = pm.bare + 1
		end
	end
	if need_anfo and rockmech.pour_anfo(p, self.driver and core.get_player_by_name(self.driver)) then V.store_take(self, ANFO, 1) end
	pm.done = pm.done + 1
	update_hud(self)
end

function def.action(self, ctx)
	local ctrl, d = ctx.ctrl, ctx.d
	if ctrl.aux1 and not self.pumping then
		self.t_act = 0.5
		local list = hole_list(self)
		if #list == 0 then
			self.msg = S("No downward holes to fill within @1 m of the boom", ("%d"):format(BOOM_LEN))
		else
			self.pumping = {list = list, done = 0, t = 0, bare = 0}
			self.msg = nil
		end
		update_hud(self)
	elseif ctrl.jump and d and not self.pumping then
		self.t_act = 0.5
		V.open_store(self, d)
	end
end

-- 重機操作員（vehicle_op.lua）：按住 E 點孔 → 開到附近、車尾對著它倒車，吊臂搆得到就把範圍內的孔都灌好
V.op_setup("bulktruck", def, {
	label = S("ANFO bulk truck"), verb = S("charge the holes"), working = S("Filling holes"), half = def.half,
	seat = {x = -0.55, y = 0.1, z = 0.6},
	busy = function(self) return self.pumping ~= nil end,
	approach = function(self, ctx, p, steer)
		local r = V.to_world(self, BOOM_BASE)
		if math.sqrt((p.x - r.x) ^ 2 + (p.z - r.z) ^ 2) <= BOOM_LEN - 2 then return nil, true end
		local d = math.sqrt((p.x - ctx.pos.x) ^ 2 + (p.z - ctx.pos.z) ^ 2)
		if d > BOOM_LEN + 1 then return steer(self, ctx, p.x, p.z) end
		return steer(self, ctx, p.x, p.z, true, 0.3)
	end,
	can_work = function(self)
		if V.store_count(self, ANFO) < 1 and V.store_count(self, EMULSION) < 1 then
			return S("The tank is empty: load ANFO and emulsion first")
		end
	end,
})

V.register("bulktruck", def)
