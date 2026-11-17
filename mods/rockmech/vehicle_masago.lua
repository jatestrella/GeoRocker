-- rockmech/vehicle_masago.lua
-- 連續壁抓斗（MASAGO：履帶吊車吊一個鋼製的蚌殼抓斗，靠自重落下、閉合咬土）。由 vehicles.lua 載入。
-- 3 寬履帶底盤；上部結構（駕駛室、機房、配重、格狀吊桿、吊索、抓斗）像挖土機一樣迴轉，跟著駕駛的視線轉。
--   抓斗長 3 m、厚 1 m、高 6 m（實機的抓斗又高又重，靠高度導向、挖得直），抓斗頭可旋轉：長邊永遠對齊格線（東西或南北）。
--   吊桿俯仰：抓斗離迴轉軸 R_MIN–R_MAX m。
--   E：抓一斗（跟挖土機一樣，滑鼠指哪裡抓哪裡）：上部結構轉過去、吊桿俯仰到那一欄上方，抓斗沿吊索放下去
--      （穿過空氣、穩定液），咬下最上面兩層（3 格 × 2 m = 6 m³；下面那層咬不動就只咬上面那層），收回地面。
--      咬得動：碎石、土、岩體強度 σcm ≤ 可裂性門檻的軟岩（跟推土機松土同一個門檻，研發「推土機推力」一起提高）。
--      吊索 40 m：溝深到 40 m 就不能再往下。抓斗滿了（3 m³）要先倒掉。
--   空白鍵：倒掉抓斗：滑鼠指著卡車就倒進車斗，指著地面就轉過去倒在那裡。
-- 咬掉的格子上面的穩定液馬上補下去（液面跟著降），要再補液。

local S = rockmech.S
local V = rockmech.vehicles
local collapse = rockmech.collapse
local box_tex, update_hud, seg_attach = V.box_tex, V.update_hud, V.seg_attach
local NLEV = rockmech.RUBBLE_LEVELS

local h2v = V.h2v
local CABLE = 40             -- 吊索長 (m)：最深挖到地面下這麼深
local WINCH = 5              -- 抓斗升降速度 (m/s)
local BITE_T = 3             -- 咬一口的時間 (s)
local BITE_LAYERS = 2        -- 一口咬幾層（每層 3 格 × 1 m）
local PIVOT = {x = 0, y = 0.6, z = 0.9}          -- 吊桿腳（上部結構座標）
local BOOM_L = 15            -- 吊桿長 (m)
local R_MIN, R_MAX = 2.5, 8   -- 抓斗中心離迴轉軸 (m)：吊桿俯仰的範圍
local R0 = 4                 -- 預設
local LUFF_RATE = 3.0        -- 吊桿俯仰（抓斗水平移動）速度 (m/s)
local SWING_RATE = 1.5       -- 迴轉速度 (rad/s，跟挖土機一樣)
local GRAB_H = 6             -- 抓斗高
local GRAB_W = 2.9           -- 抓斗長（外觀，挖 3 格）
local GRAB_IDLE = -1.0       -- 收起來時抓斗底在車身座標的高度（地面約 −1.5）
local AIM_REACH = 24         -- 滑鼠瞄準的距離 (m)

local function tip_of(r) return {x = 0, y = PIVOT.y + math.sqrt(BOOM_L ^ 2 - (r - PIVOT.z) ^ 2), z = r} end

local def = {desc = S("Diaphragm wall grab"), short = S("Diaphragm wall grab"), color = "#c8a020", cap = 3 * BITE_LAYERS * NLEV, speed = 1.0,
	half = 1.5, rear = 2.4, lat = {-1, 0, 1}, eye_up = 1.75, eye_fwd = 0.6, eye_side = -0.3,
	tail_lat = {-1.1, 0, 1.1}, tail_dy = {1.2, 2.2},
	mirror = {x = 1.35, y = 1.4, z = 0.6},
	tilt = {front = 1.3, rear = -2.0, side_z = -0.6, side_x = 1.1}, max_grade = math.rad(15),
	item_desc = S("Right-click to get in; look around to slew; E grabs a bite 3 m long, 1 m thick and 2 m deep where you point, Space dumps it where you point")}
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

local SEAT = {x = -0.45, y = 0.1, z = 0.3}          -- 駕駛室裡（上部結構座標，靠近迴轉軸）
def.seat = SEAT
-- 上部結構（跟著迴轉）：pos 是上部結構座標；boom、cable、grab 另外擺
local UPPER = {}
do
	local c = def.color
	local o = ("[fill:16x16:%s"):format(c)
	local win = V.cab_glass(c, 2, 2, 12, 9) .. "^[fill:16x2:0,14:#2a2a2a"
	local side = V.cab_side(c, {win = {x = 3, y = 2, w = 10, h = 8}, clear = true, sill = "#2a2a2a", doors = {{x = 2, y = 1, w = 12, h = 12.8}}})
	local side_l = V.flip_side(side)
	local grille = ("[fill:16x16:%s^[fill:12x8:2,4:#2a2a2a^[fill:12x1:2,6:#4a4a4a^[fill:12x1:2,9:#4a4a4a"):format(c)
	local lattice = "[fill:16x16:#00000000^[fill:3x16:0,0:" .. c .. "^[fill:3x16:13,0:" .. c
		.. "^[fill:16x2:0,0:" .. c .. "^[fill:16x2:0,8:" .. c .. "^[fill:2x2:4,3:" .. c .. "^[fill:2x2:7,5:" .. c .. "^[fill:2x2:10,11:" .. c
	-- 抓斗（高 6 m）：上面是黃色的框架與吊環，下面兩片蚌殼斗（中間一條合縫），最底下是斗齒
	local grab = "[fill:16x48:#3c3c3c^[fill:16x6:0,0:" .. c .. "^[fill:2x30:2,6:" .. c .. "^[fill:2x30:12,6:" .. c
		.. "^[fill:16x2:0,20:" .. c .. "^[fill:1x12:7,36:#202020^[fill:16x1:0,36:#2a2a2a^[fill:16x2:0,46:#6a6a6a"
	local grab_edge = "[fill:16x48:#3c3c3c^[fill:16x6:0,0:" .. c .. "^[fill:16x2:0,20:" .. c .. "^[fill:16x2:0,46:#6a6a6a"
	local TRACK = V.TRACK
	local trk = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}
	UPPER = {
		{id = "turntable", pos = {x = 0, y = -0.05, z = 0}, size = {x = 2.4, y = 0.1, z = 2.4}, tex = box_tex("#4a4a4a")},   -- 迴轉盤
		{id = "cab", pos = {x = -0.45, y = 0.65, z = 0.3}, size = {x = 1.0, y = 1.4, z = 1.3}, alpha = true, tex = {o, "[fill:16x16:#2a2a2a", side, side_l, win, o}},   -- 駕駛室
		{id = "cabwall", pos = {x = -0.45, y = 0.65, z = -0.33}, size = {x = 0.96, y = 1.36, z = 0.04}, tex = box_tex(c)},   -- 駕駛室後牆
		{id = "mach", pos = {x = 0.55, y = 0.5, z = -0.5}, size = {x = 1.3, y = 1.2, z = 2.0}, tex = {o, o, grille, grille, o, o}},   -- 機房（捲揚機）
		{id = "cw", pos = {x = 0, y = 0.4, z = -1.9}, size = {x = 2.4, y = 1.0, z = 0.8}, tex = box_tex("#4a4a4a")},   -- 配重
	}
	def.parts = {
		{pos = {x = -1.1, y = -1.0, z = -0.4}, size = {x = 0.7, y = 1.0, z = 3.8}, tex = trk},
		{pos = {x = 1.1, y = -1.0, z = -0.4}, size = {x = 0.7, y = 1.0, z = 3.8}, tex = trk},
		{pos = {x = 0, y = -0.4, z = -0.4}, size = {x = 1.6, y = 0.5, z = 3.6}, tex = box_tex("#3a3a3a")},   -- 下車架
		{id = "boom", pos = {x = 0, y = 5, z = 2}, size = {x = 0.7, y = 1, z = 0.7}, alpha = true,
			tex = {lattice, lattice, lattice, lattice, lattice, lattice}},   -- 格狀吊桿（吊桿腳 → 吊桿頭）
		{id = "cable", pos = {x = 0, y = 8, z = R0}, size = {x = 0.06, y = 1, z = 0.06}, tex = box_tex("#151515")},   -- 吊索
		{id = "grab", pos = {x = 0, y = GRAB_IDLE + GRAB_H / 2, z = R0}, size = {x = GRAB_W, y = GRAB_H, z = 0.9},
			tex = {o, "[fill:16x16:#2a2a2a", grab_edge, grab_edge, grab, grab}},   -- 抓斗
	}
	for _, p in ipairs(UPPER) do def.parts[#def.parts + 1] = p end
end
function def.figure_pos(self) return h2v(SEAT, self.swing or 0) end
function def.figure_yaw(self) return self.swing or 0 end

-- 上部結構的前方、長邊方向（世界座標的水平向量）
local function upper_dirs(self, psi)
	psi = psi or self.swing or 0
	local o = V.to_world(self, {x = 0, y = 0, z = 0})
	local f = vector.subtract(V.to_world(self, h2v({x = 0, y = 0, z = 1}, psi)), o)
	local r = vector.subtract(V.to_world(self, h2v({x = 1, y = 0, z = 0}, psi)), o)
	return f, r
end
-- 抓斗頭（可旋轉）：長邊對齊最接近上部結構橫向的世界軸。回傳抓斗在車身座標的迴轉角、世界軸
local function grab_head(self, psi)
	psi = psi or self.swing or 0
	local f, r = upper_dirs(self, psi)
	local theta = math.atan2(-f.x, f.z)
	local snap = math.floor(theta / (math.pi / 2) + 0.5) * (math.pi / 2)
	local ax = math.abs(r.x) >= math.abs(r.z) and {x = 1, z = 0} or {x = 0, z = 1}
	return psi + (theta - snap), ax
end

-- 上部結構座標的長方體（迴轉 ψ 後）在車身座標的外框
local function rot_box(x0, x1, z0, z1, psi)
	local ax, az, bx, bz = math.huge, math.huge, -math.huge, -math.huge
	for _, q in ipairs({{x0, z0}, {x0, z1}, {x1, z0}, {x1, z1}}) do
		local v = h2v({x = q[1], y = 0, z = q[2]}, psi)
		ax, az, bx, bz = math.min(ax, v.x), math.min(az, v.z), math.max(bx, v.x), math.max(bz, v.z)
	end
	return ax, bx, az, bz
end
-- 擋人：抓斗（收起來的高度）、配重，跟著迴轉
function def.overhangs_now(self)
	local psi = self.swing or 0
	local r = self.r or R0
	local out = {}
	if not self.grabbing or self.grabbing.phase == "align" then
		local gp = grab_head(self)
		local c = h2v({x = 0, y = 0, z = r}, psi)
		local x0, x1, z0, z1 = rot_box(-GRAB_W / 2, GRAB_W / 2, -0.5, 0.5, gp)
		out[#out + 1] = {x0 = c.x + x0, x1 = c.x + x1, z0 = c.z + z0, z1 = c.z + z1, y0 = GRAB_IDLE, y1 = GRAB_IDLE + GRAB_H}
	end
	local x0, x1, z0, z1 = rot_box(-1.2, 1.2, -2.3, -1.5, psi)
	out[#out + 1] = {x0 = x0, x1 = x1, z0 = z0, z1 = z1, y0 = -0.1, y1 = 0.9}
	return out
end

-- 擺上部結構：迴轉 self.swing、吊桿俯仰到半徑 self.r、抓斗底在車身座標 self.grab_y（拉長吊索）
local function place_upper(self)
	local ps = self.parts
	if not ps then return end
	local psi, r = self.swing or 0, self.r or R0
	local rot = {x = 0, y = math.deg(psi), z = 0}
	for _, hp in ipairs(UPPER) do
		local o = ps[hp.id]
		if o then
			local c = h2v(hp.pos, psi)
			o:set_attach(self.object, "", {x = c.x * 10, y = c.y * 10, z = c.z * 10}, rot)
		end
	end
	local tip = tip_of(r)
	if ps.boom then seg_attach(self, ps.boom, h2v(PIVOT, psi), h2v(tip, psi)) end
	local ybot = self.grab_y or GRAB_IDLE
	if ps.grab then
		local c = h2v({x = 0, y = ybot + GRAB_H / 2, z = r}, psi)
		-- 抓斗頭：作業中照這一口的方向（順著溝槽），沒在作業就照上部結構的橫向對齊格線
		local gp, ax0 = grab_head(self)
		local ax = self.grabbing and self.grabbing.ax
		if ax and ax.x ~= ax0.x then gp = gp + math.pi / 2 end
		ps.grab:set_attach(self.object, "", {x = c.x * 10, y = c.y * 10, z = c.z * 10}, {x = 0, y = math.deg(gp), z = 0})
	end
	if ps.cable then
		local top = ybot + GRAB_H
		local len = math.max(0.05, tip.y - top)
		if self.cable_len ~= len then
			ps.cable:set_properties({visual_size = {x = 0.06, y = len, z = 0.06}})
			self.cable_len = len
		end
		local c = h2v({x = 0, y = (tip.y + top) / 2, z = r}, psi)
		ps.cable:set_attach(self.object, "", {x = c.x * 10, y = c.y * 10, z = c.z * 10}, rot)
	end
end
local function place_grab(self, ybot) self.grab_y = ybot; place_upper(self) end
function def.on_spawn(self)
	if self.parts and self.parts.boom then
		self.parts.boom:set_properties({visual_size = {x = 0.7, y = BOOM_L, z = 0.7}})
	end
	self.cable_len = nil
	place_grab(self, GRAB_IDLE)
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

-- 滑鼠指的東西（從駕駛的相機沿視線找，跟挖土機一樣）：回傳 {truck = 有車斗的車} 或 {under, above}（方塊）；沒有回傳 nil
local TYPES = V.TYPES
local function hauler(e) return e and e.vkind and TYPES[e.vkind] and TYPES[e.vkind].bed and e or nil end
local function aim(self, d, with_trucks)
	local pos = self.object:get_pos()
	local look = d:get_look_dir()
	local hl = math.sqrt(look.x * look.x + look.z * look.z)
	local fx, fz = hl > 0 and look.x / hl or 0, hl > 0 and look.z / hl or 0
	local side = def.eye_side or 0
	local pr = d.get_properties and d:get_properties()
	local eh = pr and pr.eye_height or V.EYE_HEIGHT
	local eye = {x = pos.x + fx * def.eye_fwd + fz * side, y = pos.y + eh + def.eye_up - V.EYE_HEIGHT, z = pos.z + fz * def.eye_fwd - fx * side}
	local reach = AIM_REACH
	if self.chase and self.chase:get_pos() then
		eye = vector.add(self.chase:get_pos(), {x = 0, y = eh, z = 0})
		reach = AIM_REACH + 12
	end
	for pt in core.raycast(eye, vector.add(eye, vector.multiply(look, reach)), with_trucks, false) do
		if pt.type == "object" then
			local o = pt.ref
			local e = o:get_luaentity()
			if e and not e.vkind and o:get_attach() then e = o:get_attach():get_luaentity() end   -- 指到車的零件
			if e ~= self and hauler(e) then return {truck = e} end
		elseif pt.type == "node" then
			-- 指到溝壁（側面）：那一欄是溝槽（面前空的那格），不是壁裡面
			local n = pt.intersection_normal
			if n and n.y == 0 then return {under = pt.above, above = pt.above} end
			return {under = pt.under, above = pt.above}
		end
	end
end

-- 目標欄（世界座標 x, z）→ 上部結構要轉的角度、吊桿半徑；搆不到回傳 nil, 原因
local function reach_to(self, x, z)
	local tl = V.to_local(self, {x = x, y = self.object:get_pos().y, z = z})
	local r = math.sqrt(tl.x * tl.x + tl.z * tl.z)
	if r < R_MIN - 0.01 or r > R_MAX + 0.01 then
		return nil, S("Out of reach (@1–@2 m from the crane)", R_MIN, R_MAX)
	end
	return math.atan2(tl.x, tl.z), r
end
-- 目標欄與抓斗頭（迴轉到 psi 時）的長邊方向 → 抓斗下的三欄
-- 抓斗頭轉向：指的那一欄旁邊已經有溝槽（地面下一、兩層是空的或有穩定液），長邊就順著溝槽；
-- 兩個方向都沒有（或一樣多）就照上部結構的橫向。回傳世界軸
local function grab_axis(self, x, z, psi)
	local _, ax = grab_head(self, psi)
	local y0 = V.ground_y(self.object:get_pos(), def.half)
	local function n_open(dx, dz)
		local n = 0
		for _, k in ipairs({-2, -1, 1, 2}) do
			for _, y in ipairs({y0 - 1, y0 - 2}) do
				if open(core.get_node({x = x + dx * k, y = y, z = z + dz * k}).name) then n = n + 1 end
			end
		end
		return n
	end
	local nx, nz = n_open(1, 0), n_open(0, 1)
	if nx > nz then return {x = 1, z = 0} elseif nz > nx then return {x = 0, z = 1} end
	return ax
end
local function cols_at(self, x, z, psi)
	local ax = grab_axis(self, x, z, psi)
	return {{x = x - ax.x, z = z - ax.z}, {x = x, z = z}, {x = x + ax.x, z = z + ax.z}}, ax
end

-- 找下一口：三欄各自從地面往下穿過空氣、穩定液，找到的最高那層實心就是這一口。回傳 {cells, y, y0} 或 nil, 原因
local function next_bite(self, cols)
	local y0 = V.ground_y(self.object:get_pos(), def.half)       -- 履帶底下那層空氣（地面上一格）
	local top
	for _, c in ipairs(cols) do
		local y = y0 + 1
		while y > y0 - CABLE - 1 and open(core.get_node({x = c.x, y = y, z = c.z}).name) do y = y - 1 end
		top = math.max(top or y, y)
	end
	if y0 - top > CABLE then return nil, S("The trench is as deep as the cable reaches (@1 m)", CABLE) end
	-- 第一層咬不動就不咬；下面的層咬不動（或超過吊索）就只咬到上一層
	local cells, bottom = {}, top
	for layer = 0, BITE_LAYERS - 1 do
		local y = top - layer
		if y0 - y > CABLE then break end
		local these = {}
		for _, c in ipairs(cols) do
			local p = {x = c.x, y = y, z = c.z}
			if not open(core.get_node(p).name) then
				local ok, why = not core.is_protected(p, self.owner or "") and biteable(p, self.owner)
				if not ok then
					if layer == 0 then return nil, why or S("Something in the way of the grab") end
					these = nil
					break
				end
				these[#these + 1] = p
			end
		end
		if not these then break end
		for _, p in ipairs(these) do cells[#cells + 1] = p end
		bottom = y
	end
	return {cells = cells, y = bottom, y0 = y0}
end

-- 咬下來：岩石、土先鬆成原地的碎石（跟手挖一樣），再整格抓進抓斗；上面的穩定液馬上補下去
local function bite(self, b)
	local want = def.cap - V.load_total(self)
	local emptied = {}
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
			emptied[#emptied + 1] = p
		end
	end
	-- 全部咬完再讓上面的穩定液補下來：先補上層、再補下層（整欄往下掉兩格）
	table.sort(emptied, function(u, v) return u.y > v.y end)
	if rockmech.slurry_settle then
		for _, p in ipairs(emptied) do rockmech.slurry_settle(p) end
	end
end

local function trench_depth(self, cols)
	local y0 = V.ground_y(self.object:get_pos(), def.half)
	local deepest = 0
	for _, c in ipairs(cols) do
		local y = y0
		while y > y0 - CABLE - 1 and open(core.get_node({x = c.x, y = y, z = c.z}).name) do y = y - 1 end
		deepest = math.max(deepest, y0 - y - 1)
	end
	return deepest
end
-- 抓斗現在吊著的位置下面那三欄
local function cols_here(self)
	local c = V.to_world(self, h2v({x = 0, y = 0, z = self.r or R0}, self.swing or 0))
	return cols_at(self, math.floor(c.x + 0.5), math.floor(c.z + 0.5))
end

function def.hud(self)
	local s = "\n" .. S("Grab @1", V.volume_text(V.load_total(self), def.cap))
	local g = self.grabbing
	if g then
		s = s .. "  " .. (g.phase == "align" and S("Slewing to the target") or g.phase == "bite" and S("Biting at @1 m", ("%d"):format(g.depth))
			or g.phase == "down" and S("Lowering the grab") or S("Raising the grab"))
	else
		s = s .. "  " .. S("Trench depth @1 m (cable @2 m)", ("%d"):format(trench_depth(self, cols_here(self))), CABLE)
	end
	return s
end
function def.keys(self)
	return {{"E", S("Grab (where the cursor points)"), on = self.grabbing ~= nil}, {S("Space"), S("Dump (point at a truck to load it)")}}
end

function def.can_turn(self, pos, yaw, yaw2)
	return not self.grabbing and V.tail_can_turn(self, pos, yaw, yaw2, def)
end
function def.move(self, ctx)
	if self.grabbing then ctx.speed = 0; return end
	if ctx.speed < 0 then V.tail_guard(self, def, ctx) end
end

-- 倒掉抓斗：倒進卡車（裝得下多少倒多少），或倒在三欄上（之後照殘餘摩擦角攤開）
local function dump(self, g)
	local e = g.truck
	if e then
		if not e.object:get_pos() then return end
		local td = TYPES[e.vkind]
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
	V.dump_to_ground(self, g.cols, g.ytop)
end

local function angle(a) return (a + math.pi) % (2 * math.pi) - math.pi end
-- 一口的流程：轉過去、吊桿俯仰到目標上方 → 放下（離地面的深度 / WINCH）→ 咬（BITE_T）→ 收回。倒土：轉過去 → 倒
function def.step(self, ctx)
	local g = self.grabbing
	if not g then
		-- 駕駛：上部結構轉向視線的水平方向（車身座標的迴轉角 ψ 往右為正，實體 yaw 往左為正）
		local d = ctx.d
		if d and self.parts then
			local diff = angle(ctx.yaw - d:get_look_horizontal() - (self.swing or 0))
			if math.abs(diff) > 1e-3 then
				local st = SWING_RATE * ctx.dtime
				self.swing = angle((self.swing or 0) + math.max(-st, math.min(st, diff)))
				place_upper(self)
			end
		end
		return
	end
	if g.phase == "align" then
		local diff = angle(g.psi - (self.swing or 0))
		local st = SWING_RATE * ctx.dtime
		local dr = g.r - (self.r or R0)
		local sr = LUFF_RATE * ctx.dtime
		self.swing = (self.swing or 0) + math.max(-st, math.min(st, diff))
		self.r = (self.r or R0) + math.max(-sr, math.min(sr, dr))
		place_upper(self)
		if math.abs(diff) <= st and math.abs(dr) <= sr then
			self.swing, self.r = g.psi, g.r
			place_upper(self)
			if g.act == "dump" then
				dump(self, g)
				self.grabbing = nil
			else
				local b, why = next_bite(self, g.cols)
				if not b then self.grabbing, self.msg = nil, why
				else self.grabbing = {phase = "down", t = 0, depth = b.y0 - b.y, bite = b, cols = g.cols, ax = g.ax} end
			end
			update_hud(self)
		end
		return
	end
	g.t = g.t + ctx.dtime * rockmech.eff_dig_mult(self.owner)
	local ground = -def.half                         -- 地面在車身座標的高度
	local bottom = ground - g.depth                  -- 這一口的底（抓斗底）
	local travel = GRAB_IDLE - bottom
	local T = math.max(0.1, travel / WINCH)
	if g.phase == "down" then
		place_grab(self, GRAB_IDLE - travel * math.min(1, g.t / T))
		if g.t >= T then g.phase, g.t = "bite", 0; update_hud(self) end
	elseif g.phase == "bite" then
		if g.t >= BITE_T then
			-- 咬之前再確認一次（這段時間可能有東西掉進來、被別人挖掉）
			local b, why = next_bite(self, g.cols)
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

-- 開始一個動作：目標欄 (x, z) → 轉過去（act = "bite"／"dump"）
local function start(self, act, x, z, extra)
	local psi, r = reach_to(self, x, z)
	if not psi then self.msg = r; return end
	local cols, ax = cols_at(self, x, z, psi)
	local g = {phase = "align", act = act, psi = psi, r = r, cols = cols, ax = ax}
	for k, v in pairs(extra or {}) do g[k] = v end
	self.grabbing = g
	self.msg = nil
end

-- ctx.target（測試用）：{x, y, z} 方塊或 {truck = 車}，取代滑鼠瞄準
function def.action(self, ctx)
	local ctrl, d = ctx.ctrl, ctx.d
	if ctrl.aux1 and not self.grabbing then
		self.t_act = 0.5
		if V.load_total(self) >= def.cap then
			self.msg = S("The grab is full: Space to dump it")
		else
			local t = ctx.target or (d and aim(self, d, false))
			local p = t and (t.under or t)
			if not p or not p.x then self.msg = S("Point at the ground where to grab")
			else start(self, "bite", p.x, p.z) end
		end
		update_hud(self)
	elseif ctrl.jump and not self.grabbing then
		self.t_act = 0.5
		if V.load_total(self) <= 0 then self.msg = S("The grab is empty")
		else
			local t = ctx.target or (d and aim(self, d, true))
			if t and t.truck then
				local tp = t.truck.object:get_pos()
				start(self, "dump", math.floor(tp.x + 0.5), math.floor(tp.z + 0.5), {truck = t.truck})
			elseif t and (t.above or t.x) then
				local p = t.above or t
				start(self, "dump", p.x, p.z, {ytop = p.y + 1})
				if self.grabbing then self.grabbing.cols = cols_at(self, p.x, p.z, self.grabbing.psi) end
			else
				self.msg = S("Point at the ground or a truck to dump")
			end
		end
		update_hud(self)
	end
end

function def.on_load(self, data) self.swing, self.r = data.swing, data.r end
function def.on_save(self, data) data.swing, data.r = self.swing, self.r end

V.MASS.masago = 50
V.register("masago", def)
