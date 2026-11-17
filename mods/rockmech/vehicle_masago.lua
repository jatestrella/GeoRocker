-- rockmech/vehicle_masago.lua
-- 連續壁抓斗（MASAGO：履帶吊車吊一個鋼製的蚌殼抓斗，靠自重落下、閉合咬土）。由 vehicles.lua 載入。
-- 3 寬履帶底盤，左前方駕駛室，車尾配重；格狀吊桿從車身斜伸到車頭前方，吊索垂下抓斗。
--   抓斗長 3 m、厚 1 m，橫在車頭正前方（車頭前第 2 格），長邊跟溝槽同方向（溝槽在車頭前、橫向延伸）。
--   E：抓一斗。抓斗沿吊索放下去（穿過空氣、穩定液），咬下最上面那一層（3 格 × 1 m），收回地面。
--      咬得動：碎石、土、岩體強度 σcm ≤ 可裂性門檻的軟岩（跟推土機松土同一個門檻，研發「推土機推力」一起提高）。
--      吊索 40 m：溝深到 40 m 就不能再往下。抓斗滿了（3 m³）要先倒掉。
--   空白鍵：倒掉抓斗（吊車右側有卡車就倒進車斗，沒有就倒在吊車右側地上）。
-- 咬掉的格子上面的穩定液馬上補下去（液面跟著降），要再補液。

local S = rockmech.S
local V = rockmech.vehicles
local collapse = rockmech.collapse
local box_tex, update_hud, seg_attach = V.box_tex, V.update_hud, V.seg_attach
local NLEV = rockmech.RUBBLE_LEVELS

local GZ = 3                 -- 抓斗中心在車頭前（車身座標 z）
local CABLE = 40             -- 吊索長 (m)：最深挖到地面下這麼深
local WINCH = 3              -- 抓斗升降速度 (m/s)
local BITE_T = 4             -- 咬一口的時間 (s)
local PIVOT = {x = 0, y = 0.6, z = 0.9}          -- 吊桿腳
local TIP = {x = 0, y = 11.5, z = GZ}            -- 吊桿頭（吊索從這裡垂下）
local GRAB_H = 1.6           -- 抓斗高
local GRAB_IDLE = 1.2        -- 收起來時抓斗底在車身座標的高度（地面約 −1.5）
local DUMP_X = 4             -- 倒土的位置：吊車右後方（車身座標 x；z 在 −2..0，離溝槽遠一點，土堆攤開才不會滾進溝裡）

local def = {desc = S("Diaphragm wall grab"), short = S("Diaphragm wall grab"), color = "#c8a020", cap = 3 * NLEV, speed = 1.0,
	half = 1.5, rear = 2.4, lat = {-1, 0, 1}, eye_up = 1.75, eye_fwd = 0.9, eye_side = -0.6,
	tail_lat = {-1.1, 0, 1.1}, tail_dy = {1.2, 2.2},
	mirror = {x = 1.35, y = 1.4, z = 0.6},
	tilt = {front = 1.3, rear = -2.0, side_z = -0.6, side_x = 1.1}, max_grade = math.rad(15),
	item_desc = S("Right-click to get in; E grabs a bite 3 m long, 1 m thick and 1 m deep in front of the crane, Space dumps it")}
do   -- 圖示：履帶、車身、駕駛室、斜吊桿、吊索、抓斗
	local c, r = def.color, {}
	V.icon_track(r, 1, 24, 18, 7)
	r[#r + 1] = {2, 16, 16, 8, c}; r[#r + 1] = {2, 9, 6, 7, c}; r[#r + 1] = {3, 10, 4, 4, "#9fd0ff"}
	r[#r + 1] = {12, 13, 6, 3, "#3a3a3a"}
	V.icon_line(r, 10, 16, 26, 2, 2, "#3a3a3a")
	r[#r + 1] = {26, 2, 1, 16, "#202020"}
	r[#r + 1] = {23, 18, 7, 8, "#4a4a4a"}; r[#r + 1] = {23, 18, 7, 2, c}
	def.inv_image = V.icon(r)
end

do
	local c = def.color
	local o = ("[fill:16x16:%s"):format(c)
	local win = V.cab_glass(c, 2, 2, 12, 9) .. "^[fill:16x2:0,14:#2a2a2a"
	local side = V.cab_side(c, {win = {x = 3, y = 2, w = 10, h = 8}, clear = true, sill = "#2a2a2a", doors = {{x = 2, y = 1, w = 12, h = 12.8}}})
	local side_l = V.flip_side(side)
	local grille = ("[fill:16x16:%s^[fill:12x8:2,4:#2a2a2a^[fill:12x1:2,6:#4a4a4a^[fill:12x1:2,9:#4a4a4a"):format(c)
	local lattice = "[fill:16x16:#00000000^[fill:3x16:0,0:" .. c .. "^[fill:3x16:13,0:" .. c
		.. "^[fill:16x2:0,0:" .. c .. "^[fill:16x2:0,8:" .. c .. "^[fill:2x2:4,3:" .. c .. "^[fill:2x2:7,5:" .. c .. "^[fill:2x2:10,11:" .. c
	local grab = "[fill:16x16:#3c3c3c^[fill:16x3:0,0:" .. c .. "^[fill:1x13:7,3:#202020^[fill:16x2:0,14:#5a5a5a"
	local TRACK = V.TRACK
	local trk = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}
	def.parts = {
		{pos = {x = -1.1, y = -1.0, z = -0.4}, size = {x = 0.7, y = 1.0, z = 3.8}, tex = trk},
		{pos = {x = 1.1, y = -1.0, z = -0.4}, size = {x = 0.7, y = 1.0, z = 3.8}, tex = trk},
		{pos = {x = 0, y = -0.35, z = -0.4}, size = {x = 2.2, y = 0.5, z = 3.8}, tex = box_tex("#3a3a3a")},   -- 甲板
		{pos = {x = -0.6, y = 0.6, z = 0.4}, size = {x = 1.1, y = 1.5, z = 1.4}, alpha = true, tex = {o, "[fill:16x16:#2a2a2a", side, side_l, win, o}},   -- 駕駛室
		{pos = {x = -0.6, y = 0.6, z = -0.26}, size = {x = 1.06, y = 1.46, z = 0.04}, tex = box_tex(c)},   -- 駕駛室後牆
		{pos = {x = 0.5, y = 0.45, z = -0.6}, size = {x = 1.6, y = 1.4, z = 2.2}, tex = {o, o, grille, grille, o, o}},   -- 機房（捲揚機）
		{pos = {x = 0, y = 0.3, z = -2.0}, size = {x = 2.6, y = 1.0, z = 0.8}, tex = box_tex("#4a4a4a")},   -- 配重
		{id = "boom", pos = {x = 0, y = 5, z = 2}, size = {x = 0.7, y = 1, z = 0.7}, alpha = true,
			tex = {lattice, lattice, lattice, lattice, lattice, lattice}},   -- 格狀吊桿（on_spawn 擺到吊桿腳 → 吊桿頭）
		{id = "cable", pos = {x = 0, y = 8, z = GZ}, size = {x = 0.06, y = 1, z = 0.06}, tex = box_tex("#151515")},   -- 吊索
		{id = "grab", pos = {x = 0, y = GRAB_IDLE + GRAB_H / 2, z = GZ}, size = {x = 2.9, y = GRAB_H, z = 0.9},
			tex = {o, "[fill:16x16:#2a2a2a", grab, grab, grab, grab}},   -- 抓斗
	}
end
-- 擋人：車頭前的抓斗、車尾配重
def.overhangs = {
	{x0 = -1.5, x1 = 1.5, z0 = GZ - 0.5, z1 = GZ + 0.5, y0 = GRAB_IDLE, y1 = GRAB_IDLE + GRAB_H},
	{x0 = -1.3, x1 = 1.3, z0 = -2.4, z1 = -1.5, y0 = -0.2, y1 = 0.8, body = "z1"},
}

-- 抓斗底在車身座標的高度 → 擺抓斗、拉長吊索
local function place_grab(self, ybot)
	local ps = self.parts
	if not ps then return end
	if ps.grab then ps.grab:set_attach(self.object, "", {x = 0, y = (ybot + GRAB_H / 2) * 10, z = GZ * 10}, {x = 0, y = 0, z = 0}) end
	if ps.cable then
		local top = ybot + GRAB_H
		local len = math.max(0.05, TIP.y - top)
		ps.cable:set_properties({visual_size = {x = 0.06, y = len, z = 0.06}})
		ps.cable:set_attach(self.object, "", {x = 0, y = (TIP.y + top) * 5, z = GZ * 10}, {x = 0, y = 0, z = 0})
	end
end
function def.on_spawn(self)
	if self.parts and self.parts.boom then
		local len = vector.distance(PIVOT, TIP)
		self.parts.boom:set_properties({visual_size = {x = 0.7, y = len, z = 0.7}})
		seg_attach(self, self.parts.boom, PIVOT, TIP)
	end
	place_grab(self, GRAB_IDLE)
end

-- 抓斗下的三格（世界座標，對齊格線）：抓斗長邊是車身的 x 方向，取最接近的世界軸
local function grab_cells(self)
	local c = V.to_world(self, {x = 0, y = 0, z = GZ})
	local yaw = self.object:get_yaw()
	local ax = math.abs(math.cos(yaw)) >= math.abs(math.sin(yaw)) and {x = 1, z = 0} or {x = 0, z = 1}
	local cx, cz = math.floor(c.x + 0.5), math.floor(c.z + 0.5)
	return {{x = cx - ax.x, z = cz - ax.z}, {x = cx, z = cz}, {x = cx + ax.x, z = cz + ax.z}}
end
local function open(n) return n == "air" or rockmech.slurry_level[n] ~= nil or V.passable(n) end

local function rip_limit(owner)
	return rockmech.eff_rip_sigcm and owner and rockmech.eff_rip_sigcm(owner) or rockmech.cfg.dozer_rip_sigcm
end
-- 這格咬得動嗎：回傳 種類（"rubble"／"soil"／"rock"）或 nil, 原因
local function biteable(p, owner)
	local node = core.get_node(p)
	local n = node.name
	if rockmech.rubble_level[n] then return "rubble" end
	if core.get_item_group(n, "rockmech_topsoil") > 0 then return "soil" end
	local lith = rockmech.lith_of_node[n]
	if lith then
		local D = collapse.damage_at_xyz and collapse.damage_at_xyz(p.x, p.y, p.z)
		local sc = collapse.rock.at(lith.name, p.y, node.param2, D).sigcm
		local lim = rip_limit(owner)
		if sc <= lim then return "rock" end
		return nil, S("Rock too hard for the grab (rock mass strength @1 MPa > @2 MPa)", ("%.0f"):format(sc), ("%.0f"):format(lim))
	end
	return nil, S("Something in the way of the grab")
end

-- 找下一口：三欄各自從地面往下穿過空氣、穩定液，找到的最高那層實心就是這一口。回傳 {cells, y, y0} 或 nil, 原因
local function next_bite(self)
	local y0 = V.ground_y(self.object:get_pos(), def.half)       -- 履帶底下那層空氣（地面上一格）
	local cols, top = grab_cells(self), nil
	for _, c in ipairs(cols) do
		local y = y0
		while y > y0 - CABLE - 1 and open(core.get_node({x = c.x, y = y, z = c.z}).name) do y = y - 1 end
		top = math.max(top or y, y)
	end
	if y0 - top > CABLE then return nil, S("The trench is as deep as the cable reaches (@1 m)", CABLE) end
	local cells = {}
	for _, c in ipairs(cols) do
		local p = {x = c.x, y = top, z = c.z}
		if not open(core.get_node(p).name) then
			if core.is_protected(p, self.owner or "") then return nil, S("Something in the way of the grab") end
			local ok, why = biteable(p, self.owner)
			if not ok then return nil, why end
			cells[#cells + 1] = p
		end
	end
	return {cells = cells, y = top, y0 = y0}
end

-- 咬下來：岩石、土先鬆成原地的碎石（跟手挖一樣），再整格抓進抓斗；上面的穩定液馬上補下去
local function bite(self, b)
	local want = def.cap - V.load_total(self)
	for _, p in ipairs(b.cells) do
		local n = core.get_node(p).name
		local kind = biteable(p, self.owner)
		if kind == "rock" then core.dig_node(p)
		elseif kind == "soil" then rockmech.dig_topsoil(p) end
		while want > 0 and rockmech.rubble_level[core.get_node(p).name] do
			local t, base, _, ca = V.take_rubble(p, want)
			if t <= 0 then break end
			V.load_put(self, base, t, ca)
			want = want - t
		end
		if core.get_node(p).name == "air" then
			collapse.mark_excavated(p)
			collapse.queue_stability_check(p, n)
			if rockmech.slurry_settle then rockmech.slurry_settle(p) end
		end
	end
end

local function trench_depth(self)
	local y0 = V.ground_y(self.object:get_pos(), def.half)
	local deepest = 0
	for _, c in ipairs(grab_cells(self)) do
		local y = y0
		while y > y0 - CABLE - 1 and open(core.get_node({x = c.x, y = y, z = c.z}).name) do y = y - 1 end
		deepest = math.max(deepest, y0 - y - 1)
	end
	return deepest
end

function def.hud(self)
	local s = "\n" .. S("Grab @1", V.volume_text(V.load_total(self), def.cap))
	local g = self.grabbing
	if g then
		s = s .. "  " .. (g.phase == "bite" and S("Biting at @1 m", ("%d"):format(g.depth)) or g.phase == "down" and S("Lowering the grab")
			or S("Raising the grab"))
	else
		s = s .. "  " .. S("Trench depth @1 m (cable @2 m)", ("%d"):format(trench_depth(self)), CABLE)
	end
	return s
end
function def.keys(self)
	return {{"E", S("Grab a bite"), on = self.grabbing ~= nil}, {S("Space"), S("Dump the grab (truck or ground on the right)")}}
end

function def.can_turn(self, pos, yaw, yaw2)
	return not self.grabbing and V.tail_can_turn(self, pos, yaw, yaw2, def)
end
function def.move(self, ctx)
	if self.grabbing then ctx.speed = 0; return end
	if ctx.speed > 0 then
		local la = ctx.speed * 0.1
		local p2 = {x = ctx.pos.x + ctx.dir.x * la, y = ctx.pos.y, z = ctx.pos.z + ctx.dir.z * la}
		if V.objects_in(self, p2, ctx.yaw, -1.5, 1.5, def.half, GZ + 0.5) then ctx.speed = 0 end
		return
	end
	V.tail_guard(self, def, ctx)
end

-- 一口的流程：放下（離地面的深度 / WINCH）→ 咬（BITE_T）→ 收回
function def.step(self, ctx)
	local g = self.grabbing
	if not g then return end
	g.t = g.t + ctx.dtime * rockmech.eff_dig_mult(self.owner)
	local ground = -def.half                         -- 地面在車身座標的高度
	local bottom = ground - g.depth                  -- 這一口的底（抓斗底）
	local travel = GRAB_IDLE - bottom
	local T = travel / WINCH
	if g.phase == "down" then
		place_grab(self, GRAB_IDLE - travel * math.min(1, g.t / T))
		if g.t >= T then g.phase, g.t = "bite", 0; update_hud(self) end
	elseif g.phase == "bite" then
		if g.t >= BITE_T then
			-- 咬之前再確認一次（這段時間可能有東西掉進來、被別人挖掉）
			local b, why = next_bite(self)
			if b and b.y == g.bite.y then bite(self, b) else self.msg = why end
			g.phase, g.t = "up", 0
			update_hud(self)
		end
	else
		place_grab(self, bottom + travel * math.min(1, g.t / T))
		if g.t >= T then
			self.grabbing = nil
			place_grab(self, GRAB_IDLE)
			update_hud(self)
		end
	end
end

-- 倒掉抓斗：吊車右側有卡車就倒進車斗，沒有就倒在右側地上（之後照殘餘摩擦角攤開）
local TYPES = V.TYPES
local function dump(self)
	local spot = V.to_world(self, {x = DUMP_X, y = 0, z = -1})
	for _, obj in ipairs(core.get_objects_inside_radius(spot, 2.5)) do
		local e = obj:get_luaentity()
		local td = e and e ~= self and e.vkind and TYPES[e.vkind]
		if td and td.bed and not e.tip then
			local room = td.cap - V.load_total(e)
			for base, lv in pairs(self.load) do
				local m = math.min(lv, room)
				if m > 0 then
					V.load_put(e, base, m, V.load_assay(self, base))
					room = room - m
					V.load_keep(self, base, lv - m)
				end
			end
			if V.load_total(self) > 0 then self.msg = S("@1 is full", td.short) end
			V.refresh(e)
			update_hud(e)
			return
		end
	end
	local y0 = V.ground_y(self.object:get_pos(), def.half)
	local cells = {}
	for _, lz in ipairs({-2, -1, 0}) do
		for _, lx in ipairs({DUMP_X - 0.5, DUMP_X + 0.5}) do
			local w = V.to_world(self, {x = lx, y = 0, z = lz})
			cells[#cells + 1] = {x = math.floor(w.x + 0.5), z = math.floor(w.z + 0.5)}
		end
	end
	V.dump_to_ground(self, cells, y0 + 1)
end

function def.action(self, ctx)
	local ctrl = ctx.ctrl
	if ctrl.aux1 and not self.grabbing then
		self.t_act = 0.5
		if V.load_total(self) >= def.cap then
			self.msg = S("The grab is full: Space to dump it")
		else
			local b, why = next_bite(self)
			if not b then self.msg = why
			else
				self.grabbing = {phase = "down", t = 0, depth = b.y0 - b.y, bite = b}
				self.msg = nil
			end
		end
		update_hud(self)
	elseif ctrl.jump and not self.grabbing then
		self.t_act = 0.5
		if V.load_total(self) > 0 then dump(self) else self.msg = S("The grab is empty") end
		update_hud(self)
	end
end

V.MASS.masago = 50
V.register("masago", def)
