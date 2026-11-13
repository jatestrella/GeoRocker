-- rockmech/vehicle_miner.lua
-- 連續採礦機（露天 Surface miner，像 Wirtgen 2500 SM）：滾筒直接切削岩層，不用爆破。由 vehicles.lua 載入。
-- 車身 5 寬 × 4 高、車頭 z +2.5、車尾 z −4.5；四組履帶、車身中前段 4.6 m 寬的切削滾筒、車上自帶料倉、車尾可旋轉的卸料臂。
-- 駕駛看不到車頭下方：駕駛艙上方有作業攝影機畫面（紅十字＝切削位置），車頭兩角有標出切削寬度的標桿；切削時車頭前噴碎石。
--   E：滾筒開／關。開著往前開，車頭前方 5 m 寬、從（切深）到地面以上 3 層的岩石和碎石都切下來，
--      品位留著，進車上的料倉（60 m³）；切削時慢速前進。料倉滿了或前面有切不動的東西（設施）就停。
--   空白鍵：切深 下切 1 m（預設：往前開把腳下這層切掉，一層一層往下挖；沿煤層選擇性開採，貧化少）／平切（只削高出地面的部分）。
--   卸料（自動，每 0.25 s）：卸料臂轉向目標，依序找
--     1. LOAD_R 內自己組的卡車、礦卡、手推車（車斗還裝得下）；
--     2. 卸料臂搆得到的輸送帶；
--     3. 卸料臂搆得到的破碎站、選礦場受料倉。
--     都沒有就存在料倉裡。無人卡車（AHS）可以綁定採礦機：自己開過來停在旁邊，裝滿就走。

local V = rockmech.vehicles
local S = rockmech.S
local NLEV = V.NLEV
local box_tex, face_cells, ground_y, passable = V.box_tex, V.face_cells, V.ground_y, V.passable
local update_hud = V.update_hud
local collapse = rockmech.collapse

local CAP = 60 * NLEV       -- 料倉 (級)
local CUT_SPEED = 0.6       -- 切削時的速度 (m/s)
local LOAD_R = 14           -- 卡車在這個距離內（車身中心之間）就裝 (m)
local BOOM_LEN = 12         -- 卸料臂最長 (m)
local RATE = 6 * NLEV       -- 卸料速度 (級/s)：6 m³/s
local PIVOT = {x = 0, y = 0.9, z = -4.2}            -- 卸料臂轉軸（車身座標）
local REST = {x = 0, y = 2.6, z = -9.5}             -- 沒在卸料時卸料臂的端點
local LAT = {-2, -1, 0, 1, 2}

local def = {desc = S("Surface miner"), short = S("Miner"), color = "#e8e4d8", cap = CAP, speed = 1.4,
	half = 2.5, top = 1.5, rear = 4.5, lat = LAT, eye_up = 1.9, eye_fwd = 1.6, eye_side = -1.0,
	mirror = {x = 1.6, y = 1.6, z = 1.0},
	tilt = {front = 2.0, rear = -4.0, side_z = -1.0, side_x = 1.8}, max_grade = math.rad(20),
	stepheight = 1.1,
	exhaust = {x = 1.2, y = 2.05, z = -3.6},   -- 排氣管口（排煙）
	loader = true, arm_reach = LOAD_R,     -- 無人卡車可以綁定（vehicle_ahs.lua）：停車的距離照 arm_reach 算
	-- 作業攝影機（駕駛艙上方中央的小畫面，像露天鑽機）：從車頂往前下方看切削區，紅十字 = 滾筒切到的位置
	cam = {o = {x = 0, y = 3.2, z = 0.6}, target = {x = 0, y = -2.5, z = 3.5}, mark = {x = 0, y = -2.5, z = 3.5},
		hfov = math.rad(80), vfov = math.rad(48), w = 56, h = 31},
	item_desc = S("Right-click to get in; E turns the drum on/off, Space sets the cut")}

do   -- 圖示：白色長車身、四組履帶、中間的滾筒、上面的駕駛室、車尾斜上的卸料臂
	local c, r = def.color, {}
	V.icon_track(r, 2, 24, 9, 6); V.icon_track(r, 20, 24, 9, 6)
	r[#r + 1] = {2, 15, 27, 8, c}; r[#r + 1] = {11, 21, 10, 5, "#3a3a3a"}; r[#r + 1] = {12, 22, 8, 3, "#8a8a8a"}
	r[#r + 1] = {19, 8, 7, 7, c}; r[#r + 1] = {21, 9, 4, 4, "#9fd0ff"}
	r[#r + 1] = {3, 11, 10, 4, "#5a5a5a"}
	V.icon_line(r, 2, 15, 0, 5, 2, "#3a3a3a")
	r[#r + 1] = {2, 18, 27, 1, "#e07818"}
	def.inv_image = V.icon(r)
end

-- 外觀（原點在碰撞箱中心上方：車底 y −2.5、碰撞箱上緣 +1.5；車頭 z +2.5、車尾 −4.5）
do
	local c = def.color
	local TRACK = V.TRACK
	local tr = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}
	local body = ("[fill:16x16:%s^[fill:16x2:0,10:#e07818"):format(c)                         -- 白色車身、橘色腰線
	local body_t = {body, "[fill:16x16:#3a3a3a", body, body, body, body}
	local plain = box_tex(c)
	local dark = box_tex("#3a3a3a")
	local win = V.cab_glass(c, 2, 2, 12, 9) .. "^[fill:16x2:0,14:#3a3a3a"
	local side = V.cab_side(c, {win = {x = 2, y = 2, w = 12, h = 9}, clear = true, sill = "#3a3a3a", doors = {{x = 1, y = 1, w = 14, h = 12.8}}})
	local side_l = V.flip_side(side)
	local drum = "[fill:16x16:#4a4a4a^[fill:2x2:2,2:#c0c0c0^[fill:2x2:8,5:#c0c0c0^[fill:2x2:13,9:#c0c0c0^[fill:2x2:5,12:#c0c0c0"
	local bin = "[fill:16x16:#6a6e72^[fill:16x2:0,0:#4a4e52^[fill:2x16:0,0:#4a4e52^[fill:2x16:14,0:#4a4e52"
	local rail = box_tex("#f0c020")
	def.parts = {
		-- 四組履帶
		{pos = {x = -1.9, y = -2.0, z = 1.3}, size = {x = 0.9, y = 1.0, z = 2.2}, tex = tr},
		{pos = {x = 1.9, y = -2.0, z = 1.3}, size = {x = 0.9, y = 1.0, z = 2.2}, tex = tr},
		{pos = {x = -1.9, y = -2.0, z = -3.2}, size = {x = 0.9, y = 1.0, z = 2.2}, tex = tr},
		{pos = {x = 1.9, y = -2.0, z = -3.2}, size = {x = 0.9, y = 1.0, z = 2.2}, tex = tr},
		-- 履帶支柱（油壓升降腳）
		{pos = {x = -1.9, y = -1.2, z = 1.3}, size = {x = 0.35, y = 0.8, z = 0.35}, tex = box_tex("#c0c0c0")},
		{pos = {x = 1.9, y = -1.2, z = 1.3}, size = {x = 0.35, y = 0.8, z = 0.35}, tex = box_tex("#c0c0c0")},
		{pos = {x = -1.9, y = -1.2, z = -3.2}, size = {x = 0.35, y = 0.8, z = 0.35}, tex = box_tex("#c0c0c0")},
		{pos = {x = 1.9, y = -1.2, z = -3.2}, size = {x = 0.35, y = 0.8, z = 0.35}, tex = box_tex("#c0c0c0")},
		-- 主車架
		{pos = {x = 0, y = -0.6, z = -1.0}, size = {x = 4.4, y = 0.8, z = 7.0}, tex = body_t},
		-- 滾筒罩與切削滾筒（車身中前段、貼地）
		{pos = {x = 0, y = -1.55, z = -0.6}, size = {x = 4.8, y = 1.1, z = 1.8}, tex = box_tex("#d8d4c8")},
		{id = "drum", pos = {x = 0, y = -2.0, z = -0.6}, size = {x = 4.6, y = 0.9, z = 0.9}, tex = {drum, drum, drum, drum, drum, drum}},
		-- 引擎艙（後段）、散熱格柵
		{pos = {x = 0, y = 0.5, z = -2.8}, size = {x = 3.6, y = 1.4, z = 3.0}, tex = body_t},
		{pos = {x = 0, y = 0.5, z = -4.32}, size = {x = 2.8, y = 1.0, z = 0.05},
			tex = {dark, dark, dark, dark, "[fill:16x16:#2a2a2a^[fill:14x1:1,4:#555555^[fill:14x1:1,8:#555555^[fill:14x1:1,12:#555555", dark}},
		-- 車上料倉（中段上方，開口朝上）與料位
		{pos = {x = 0.5, y = 0.6, z = 0.6}, size = {x = 3.0, y = 1.6, z = 2.6}, tex = {bin, bin, bin, bin, bin, bin}},
		{id = "fill", pos = {x = 0.5, y = -0.15, z = 0.6}, size = {x = 2.7, y = 0.05, z = 2.3}, tex = box_tex("#3a3a3a")},
		-- 駕駛室（左前）、頂蓋
		{pos = {x = -1.6, y = 0.9, z = 1.8}, size = {x = 1.4, y = 2.0, z = 1.4}, alpha = true, tex = {plain, dark, side, side_l, win, win}},
		{pos = {x = -1.6, y = 1.95, z = 1.8}, size = {x = 1.7, y = 0.1, z = 1.7}, tex = dark},
		-- 欄杆（黃色）
		{pos = {x = 2.15, y = 0.4, z = -1.0}, size = {x = 0.06, y = 0.06, z = 6.4}, tex = rail},
		{pos = {x = -2.15, y = 0.4, z = -2.0}, size = {x = 0.06, y = 0.06, z = 4.4}, tex = rail},
		-- 排氣管、警示燈
		{pos = {x = 1.2, y = 1.6, z = -3.6}, size = {x = 0.15, y = 0.8, z = 0.15}, tex = box_tex("#202020")},
		{pos = {x = -1.6, y = 2.1, z = 1.8}, size = {x = 0.25, y = 0.2, z = 0.25}, tex = box_tex("#ff9020")},
		-- 車頭兩角的切削寬度標桿（橘白相間），坐在車上看得到切削區的左右邊界
		{pos = {x = -2.45, y = -1.2, z = 2.45}, size = {x = 0.12, y = 2.6, z = 0.12},
			tex = box_tex("#f07010^[fill:16x4:0,4:#f0f0f0^[fill:16x4:0,12:#f0f0f0")},
		{pos = {x = 2.45, y = -1.2, z = 2.45}, size = {x = 0.12, y = 2.6, z = 0.12},
			tex = box_tex("#f07010^[fill:16x4:0,4:#f0f0f0^[fill:16x4:0,12:#f0f0f0")},
		{pos = {x = 0, y = -2.2, z = 2.48}, size = {x = 4.9, y = 0.12, z = 0.06}, tex = box_tex("#f07010")},     -- 前緣切削線
		-- 作業攝影機（車頂中央）
		{pos = {x = 0, y = 3.2, z = 0.6}, size = {x = 0.3, y = 0.25, z = 0.35}, tex = box_tex("#202020")},
		{pos = {x = 0, y = 2.5, z = 0.6}, size = {x = 0.08, y = 1.3, z = 0.08}, tex = box_tex("#3a3a3a")},
		-- 卸料臂（從轉軸伸出去，V.seg_attach 擺）與轉台
		{pos = {x = PIVOT.x, y = PIVOT.y - 0.2, z = PIVOT.z}, size = {x = 1.0, y = 0.3, z = 1.0}, tex = dark},
		{id = "boom", pos = {x = 0, y = 0, z = 0}, size = {x = 0.9, y = 1, z = 0.5},
			tex = {"[fill:16x16:#3a3a3a", "[fill:16x16:#3a3a3a", "[fill:16x16:#e07818^[fill:16x2:0,7:#3a3a3a", "[fill:16x16:#e07818^[fill:16x2:0,7:#3a3a3a",
				"[fill:16x16:#2a2a2a", "[fill:16x16:#2a2a2a"}},
	}
end

-- 料倉的料位：上面那塊跟著存量升高
local function show_fill(self)
	local o = self.parts and self.parts.fill
	if not o then return end
	local f = math.min(1, V.load_total(self) / CAP)
	local h = 0.05 + 1.35 * f
	o:set_properties({visual_size = {x = 2.7, y = h, z = 2.3}})
	o:set_attach(self.object, "", {x = 5, y = (-0.15 + h / 2) * 10, z = 6}, {x = 0, y = 0, z = 0})
end

-- 卸料臂指向車身座標的 tip（夾在 BOOM_LEN 內）
local function aim_boom(self, tip)
	local o = self.parts and self.parts.boom
	if not o then return end
	local v = {x = tip.x - PIVOT.x, y = tip.y - PIVOT.y, z = tip.z - PIVOT.z}
	local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if len > BOOM_LEN then
		local k = BOOM_LEN / len
		tip = {x = PIVOT.x + v.x * k, y = PIVOT.y + v.y * k, z = PIVOT.z + v.z * k}
		len = BOOM_LEN
	end
	if math.abs(len - (self.boom_len or 0)) > 0.05 then
		self.boom_len = len
		o:set_properties({visual_size = {x = 0.9, y = len, z = 0.5}})
	end
	V.seg_attach(self, o, PIVOT, tip)
end

---------------------------------------------------------------------------
-- 切削
---------------------------------------------------------------------------

-- 切一格：岩石 → 滿格碎石（品位留著）、碎石 → 拿起來、壓實的路面 → 碎石。回傳 "full"／"block"／nil
local function cut_cell(self, c)
	local node = core.get_node(c)
	local n = node.name
	if passable(n) then return nil end
	local room = CAP - V.load_total(self)
	if rockmech.lith_of_node[n] then
		if room < NLEV then return "full" end
		self.cut_now = (self.cut_now or 0) + 1
		if rockmech.lith_of_node[n].ore then self.cut_coal = (self.cut_coal or 0) + 1; self.cut_ore = rockmech.cfg.ores[rockmech.lith_of_node[n].ore] end      -- 切到礦層（煤、大理岩）
		local rn, ca = rockmech.assay.break_rock(c, node)
		V.load_put(self, rockmech.rubble_base[rn], NLEV, ca)
		core.remove_node(c)
		collapse.mark_excavated(c)
		if rockmech.shotcrete_uncover then rockmech.shotcrete_uncover(c) end
		return nil
	end
	if rockmech.rubble_level[n] then
		if room <= 0 then return "full" end
		local t, base, _, ca = V.take_rubble(c, room)
		if t > 0 then
			V.load_put(self, base, t, ca)
			self.cut_now = (self.cut_now or 0) + 1
			if rockmech.ore_of_rubble[base] then self.cut_coal = (self.cut_coal or 0) + 1; self.cut_ore = rockmech.ore_of_rubble[base] end
		end
		return rockmech.rubble_level[core.get_node(c).name] and "full" or nil
	end
	local road = rockmech.road_level and rockmech.road_level[n]
	if road then
		if room < road then return "full" end
		V.load_put(self, rockmech.RUBBLE, road, 0)
		core.remove_node(c)
		collapse.mark_excavated(c)
		return nil
	end
	if core.get_item_group(n, "stone") > 0 or core.get_item_group(n, "crumbly") > 0 then
		-- 其他天然的石頭、土：當一般碎石收
		if room < NLEV then return "full" end
		V.load_put(self, rockmech.RUBBLE, NLEV, 0)
		core.remove_node(c)
		collapse.mark_excavated(c)
		return nil
	end
	return "block"       -- 設施、輸送帶、帳篷……切不動
end

-- 車頭前方兩排（車頭外 0.6 m、1.4 m）、5 寬、從切深到地面以上 3 層
local function cut_front(self, pos, s)
	local y0 = ground_y(pos, def.half)
	local depth = self.depth or 1
	local why
	for _, dist in ipairs({def.half + 0.6, def.half + 1.4}) do
		for _, c in ipairs(face_cells(pos, s, 1, dist, y0 - depth, 4 + depth, LAT)) do
			local r = cut_cell(self, c)
			if r then why = why or r end
		end
	end
	return why
end

---------------------------------------------------------------------------
-- 卸料
---------------------------------------------------------------------------

-- 把料倉的料移出最多 n 級，每種料按比例：put(base, k, g) 回傳實際收下幾級。回傳總共移出幾級
local function unload(self, n, put)
	local total = V.load_total(self)
	if total <= 0 or n <= 0 then return 0 end
	local moved = 0
	for base, lv in pairs(table.copy(self.load)) do
		local want = math.min(lv, math.max(1, math.floor(n * lv / total + 0.5)))
		local g = V.load_assay(self, base)
		local k = put(base, want, g)
		if k > 0 then
			V.load_keep(self, base, lv - k)
			moved = moved + k
		end
	end
	return moved
end

-- 1. 旁邊自己組的車斗
local function find_truck(self, pos)
	local best, bd
	for _, o in ipairs(core.get_objects_inside_radius(pos, LOAD_R + 8)) do
		local e = o:get_luaentity()
		local td = e and e ~= self and e.vkind and V.TYPES[e.vkind]
		if td and td.bed and (td.cap or 0) > V.load_total(e) and (not self.owner or not e.owner or e.owner == self.owner) then
			local p = o:get_pos()
			local d = math.sqrt((p.x - pos.x) ^ 2 + (p.z - pos.z) ^ 2)
			if d <= LOAD_R and (not bd or d < bd) then best, bd = e, d end
		end
	end
	return best
end

-- 3. 卸料臂搆得到的破碎站、選礦場受料倉：回傳 倉中心（世界座標，倉口上方）
local function find_hopper(pos)
	local H = rockmech.hopper_lib
	if not H then return nil end
	local r = BOOM_LEN + 6
	for _, p in ipairs(core.find_nodes_in_area(vector.subtract(pos, {x = r, y = 6, z = r}), vector.add(pos, {x = r, y = 6, z = r}),
			{"rockmech:crusher", "rockmech:crusher_big", "rockmech:plant"})) do
		local c = H.hopper_center(core.get_meta(p))
		if c and math.sqrt((c.x - pos.x) ^ 2 + (c.z - pos.z) ^ 2) <= BOOM_LEN + 2 then
			return {x = c.x, y = p.y + 1, z = c.z}
		end
	end
end

local function discharge(self, pos, dt)
	if V.load_total(self) <= 0 then
		if self.target_msg then self.target_msg = nil; update_hud(self) end
		aim_boom(self, REST)
		return
	end
	local n = math.floor(RATE * dt + 0.5)
	local msg, tip, moved
	local truck = find_truck(self, pos)
	if truck then
		local wp = V.bed_target(truck, V.to_world(self, PIVOT))
		tip = V.to_local(self, wp)
		local room = V.TYPES[truck.vkind].cap - V.load_total(truck)
		moved = unload(self, math.min(n, room), function(base, k, g)
			local put = math.min(k, V.TYPES[truck.vkind].cap - V.load_total(truck))
			if put > 0 then V.load_put(truck, base, put, g) end
			return math.max(0, put)
		end)
		if moved > 0 then V.refresh(truck); update_hud(truck) end
		msg = S("Unloading into @1", V.TYPES[truck.vkind].short or S("Truck"))
	else
		local pw = V.to_world(self, PIVOT)
		local bp, by = rockmech.belt_near and rockmech.belt_near({x = pw.x, y = pw.y + 3, z = pw.z}, BOOM_LEN)
		if bp then
			tip = V.to_local(self, {x = bp.x, y = by + 1.5, z = bp.z})
			moved = unload(self, n, function(base, k, g) return rockmech.belt_put(bp, base, k, g) end)
			msg = S("Unloading onto the conveyor")
		else
			local hc = find_hopper(pw)
			if hc then
				tip = V.to_local(self, {x = hc.x, y = hc.y + 2, z = hc.z})
				moved = unload(self, n, function(base, k, g)
					return k - V.deposit_column(hc.x, hc.z, hc.y + 1, base, k, 8, nil, g)
				end)
				msg = S("Unloading into the hopper")
			end
		end
	end
	aim_boom(self, tip or REST)
	if moved and moved > 0 then
		show_fill(self)
		-- 卸料臂末端往下掉的料
		local tw = V.to_world(self, tip)
		core.add_particlespawner({amount = 6, time = 0.25, minpos = vector.subtract(tw, 0.3), maxpos = vector.add(tw, 0.3),
			minvel = {x = 0, y = -4, z = 0}, maxvel = {x = 0, y = -6, z = 0}, minsize = 2, maxsize = 4,
			minexptime = 0.4, maxexptime = 0.7, texture = "[fill:4x4:#3a3530"})
	end
	msg = msg or S("Nothing to unload into: call a truck, connect a conveyor or move close to the crusher")
	if msg ~= self.target_msg then self.target_msg = msg; update_hud(self) end
end

---------------------------------------------------------------------------

function def.hud(self)
	return "\n" .. S("Unloading: @1", self.target_msg or S("bin is empty"))
		.. (self.cut_msg and ("\n" .. self.cut_msg) or "")
end
function def.keys(self)
	return {{"E", S("Drum cutting"), on = self.cut}, {S("Space"), S("Cut 1 m down (off = level)"), on = (self.depth or 1) > 0}}
end
function def.busy(self) return self.cut end
function def.on_load(self, data) self.cut, self.depth = data.cut, data.depth end
function def.on_save(self, data) data.cut, data.depth = self.cut, self.depth end
function def.on_spawn(self)
	show_fill(self)
	aim_boom(self, REST)
end

-- 切削粒子：車頭前緣噴起碎石、落地往前後滾開（顏色跟著切到的料：煤黑、岩石灰褐）
local function debris(self, pos, s, coal_part)
	local front = {x = pos.x + s.x * (def.half + 0.4), y = pos.y - def.half + 0.4, z = pos.z + s.z * (def.half + 0.4)}
	local px, pz = -s.z, s.x
	local function spawn(color, amount)
		if amount <= 0 then return end
		core.add_particlespawner({
			amount = amount, time = 0.2,
			minpos = {x = front.x - px * 2.4, y = front.y, z = front.z - pz * 2.4},
			maxpos = {x = front.x + px * 2.4, y = front.y + 1.2, z = front.z + pz * 2.4},
			minvel = {x = -s.x * 1.5 - 0.8, y = 1.0, z = -s.z * 1.5 - 0.8}, maxvel = {x = s.x * 1.0 + 0.8, y = 3.0, z = s.z * 1.0 + 0.8},
			minacc = {x = 0, y = -9, z = 0}, maxacc = {x = 0, y = -9, z = 0},
			minexptime = 0.6, maxexptime = 1.4, minsize = 1.0, maxsize = 2.6,
			collisiondetection = true, bounce = {min = 0.2, max = 0.4},
			texture = ("[fill:4x4:%s^[fill:2x2:0,0:#00000040"):format(color),
		})
	end
	local ore = self.cut_ore or rockmech.cfg.main_ore      -- 最後切到的礦的顏色
	spawn(ore.key == "coal" and "#1e1e22" or ore.pure, math.floor(18 * coal_part + 0.5))
	spawn("#7a7068", math.floor(18 * (1 - coal_part) + 0.5))
end

function def.move(self, ctx)
	local why
	if self.cut and ctx.fwd > 0 then
		ctx.speed = math.min(ctx.speed, CUT_SPEED)
		why = cut_front(self, ctx.pos, ctx.s)
		if why then ctx.speed = 0 end
		show_fill(self)
	end
	-- 切到東西就噴碎石（每 0.2 s 一次，比例照這段時間切到的煤／岩石）
	self.deb_t = (self.deb_t or 0) + ctx.dtime
	if self.deb_t >= 0.2 then
		self.deb_t = 0
		local n = self.cut_now or 0
		if n > 0 then debris(self, ctx.pos, ctx.s, (self.cut_coal or 0) / n) end
		self.cut_now, self.cut_coal = 0, 0
	end
	local msg = why == "full" and S("Bin full: waiting to unload") or why == "block" and S("Something ahead can't be cut (facility, conveyor)") or nil
	if msg ~= self.cut_msg then self.cut_msg = msg; update_hud(self) end
	-- 滾筒轉動
	if self.cut and self.parts and self.parts.drum then
		self.drum_a = ((self.drum_a or 0) + ctx.dtime * 400) % 360
		self.parts.drum:set_attach(self.object, "", {x = 0, y = -20, z = -6}, {x = self.drum_a, y = 0, z = 0})
	end
end

function def.step(self, ctx)
	self.dis_t = (self.dis_t or 0) + ctx.dtime
	if self.dis_t < 0.25 then return end
	discharge(self, ctx.pos, self.dis_t)
	self.dis_t = 0
end

function def.action(self, ctx)
	if ctx.ctrl.aux1 then
		self.t_act = 0.5
		self.cut = not self.cut
		update_hud(self)
	elseif ctx.ctrl.jump then
		self.t_act = 0.4
		self.depth = (self.depth or 1) > 0 and 0 or 1
		update_hud(self)
	end
end

-- 擋人：車尾伸出碰撞箱的那段（z −4.5..−2.5）
def.overhangs = {
	{x0 = -2.2, x1 = 2.2, z0 = -4.5, z1 = -2.5, y0 = -2.5, y1 = 1.2, body = "z1"},
}
def.tail_lat, def.tail_dy = {-2, 0, 2}, {0, 1}
V.register("miner", def)
