-- rockmech/vehicle_dozer.lua
-- 推土機（車身 3×3×3、鏟刀 3 寬伸出車頭 1 m、車尾多 1 m）。由 vehicles.lua 載入。
--   E：放鏟／收鏟（鏟刀與推臂實際抬放）。
--   放鏟：往前開時把鏟刀那一排（車身蓋到的 3～4 欄、高 3 層）與車身前排壓著的薄碎石推到前面，
--         那堆最高 2 格、滿了往前一排（最多 3 排），推不動就停；往前時只壓得過很薄的碎石。
--   收鏟：不推。收鏟或倒車可爬 1 格。HUD 顯示鏟刀前那堆碎石的量

local V = rockmech.vehicles
local NLEV = V.NLEV
local box_tex, face_cells, ground_y, passable = V.box_tex, V.face_cells, V.ground_y, V.passable
local deposit_column, update_hud = V.deposit_column, V.update_hud
local collapse = rockmech.collapse

local def = {desc = "推土機 Bulldozer", color = "#e8c828", cap = 0, speed = 2.5,
	half = 1.5, lat = {-1, 0, 1}, eye_up = 1.65, eye_fwd = 0, mirror = {x = 1.0, y = 1.4, z = -0.2},
	tilt = {front = 1.3, rear = -2.1, side_z = -0.4, side_x = 1.1}, max_grade = math.rad(30),   -- 履帶推土機
	stepheight = 0.3,   -- 放鏟時只壓得過很薄的碎石（要推走，不是爬過去）
	item_desc = "右鍵上車；E 放鏟／收鏟，放鏟時往前開把碎石推走"}
do   -- 圖示：履帶、車身、駕駛室、前面的推土鏟、後面的松土器
	local c, r = def.color, {}
	V.icon_track(r, 3, 23, 21, 7)
	r[#r + 1] = {6, 15, 17, 8, c}; r[#r + 1] = {6, 7, 9, 8, c}; r[#r + 1] = {8, 9, 5, 4, "#9fd0ff"}
	r[#r + 1] = {22, 20, 4, 2, "#3a3a3a"}; r[#r + 1] = {26, 13, 3, 17, "#3a3a3a"}
	r[#r + 1] = {1, 21, 2, 8, "#3a3a3a"}; r[#r + 1] = {1, 21, 5, 2, "#3a3a3a"}
	def.inv_image = V.icon(r)
end

-- 外觀（原點在 3×3×3 碰撞箱中心；車頭 z +1.5、鏟刀到 +2.5、車尾 −2.5；車底 y −1.5）：
-- 兩側履帶、車架、前方引擎蓋、中後段駕駛艙、車尾配重、排氣管；鏟刀由兩側推臂（繞車架上的樞軸轉）
-- 與兩支油壓缸（引擎蓋前端 → 鏟刀背）撐著
do
	local c = def.color
	local TRACK = V.TRACK
	local y = ("[fill:16x16:%s"):format(c)
	local grille = ("[fill:16x16:%s^[fill:12x9:2,4:#2a2a2a^[fill:12x1:2,6:#4a4a4a^[fill:12x1:2,9:#4a4a4a"):format(c)
	local win = ("[fill:16x16:%s^[fill:12x8:2,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
	local side = ("[fill:16x16:%s^[fill:10x8:3,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
	local blade = "[fill:16x16:#4a4a4a^[fill:16x2:0,14:#b0b0b0^[fill:16x1:0,0:#3a3a3a"
	local steel = box_tex("#3a3a3a")
	def.parts = {
		{pos = {x = -1.1, y = -1.0, z = -0.4}, size = {x = 0.7, y = 1.0, z = 3.8}, tex = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}},
		{pos = {x = 1.1, y = -1.0, z = -0.4}, size = {x = 0.7, y = 1.0, z = 3.8}, tex = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}},
		{pos = {x = 0, y = -0.75, z = -0.4}, size = {x = 1.5, y = 0.7, z = 3.6}, tex = box_tex("#3a3a3a")},       -- 車架
		{pos = {x = 0, y = -0.05, z = 0.7}, size = {x = 1.6, y = 1.0, z = 1.6}, tex = {y, y, y, y, grille, y}},    -- 引擎蓋
		{pos = {x = 0, y = 0.55, z = -0.9}, size = {x = 1.8, y = 1.9, z = 1.6},                                   -- 駕駛艙
			tex = {y, "[fill:16x16:#2a2a2a", side, side, win, y}},
		{pos = {x = 0, y = -0.6, z = -2.15}, size = {x = 1.6, y = 0.8, z = 0.7}, tex = box_tex("#b89a18")},      -- 車尾配重
		{pos = {x = 0.5, y = 0.75, z = 1.0}, size = {x = 0.12, y = 0.6, z = 0.12}, tex = box_tex("#202020")},     -- 排氣管
		{id = "blade", pos = {x = 0, y = -0.95, z = 2.15}, size = {x = 3.0, y = 1.1, z = 0.3}, tex = {blade, blade, blade, blade, blade, blade}},
		{id = "arm_l", pos = {x = 0, y = 0, z = 0}, size = {x = 0.15, y = 2.3, z = 0.22}, tex = steel},
		{id = "arm_r", pos = {x = 0, y = 0, z = 0}, size = {x = 0.15, y = 2.3, z = 0.22}, tex = steel},
		{id = "cyl_l", pos = {x = 0, y = 0, z = 0}, size = {x = 0.14, y = 0.8, z = 0.14}, tex = box_tex("#c0c0c0")},
		{id = "cyl_r", pos = {x = 0, y = 0, z = 0}, size = {x = 0.14, y = 0.8, z = 0.14}, tex = box_tex("#c0c0c0")},
	}
end
-- 推臂：樞軸 ARM_PIVOT（車架兩側）到鏟刀背 ARM_TIP（鏟刀放下時），長度固定；抬鏟 h（m）時推臂繞樞軸往上轉
local ARM_PIVOT = {x = 1.3, y = -0.8, z = -0.3}
local ARM_TIP = {x = 1.3, y = -1.05, z = 2.0}
local ARM_LEN = math.sqrt((ARM_TIP.y - ARM_PIVOT.y) ^ 2 + (ARM_TIP.z - ARM_PIVOT.z) ^ 2)
local CYL_BASE = {x = 0.6, y = 0.3, z = 1.4}      -- 油壓缸在引擎蓋前端的支點
local BLADE_UP = 0.8                              -- 收鏟時鏟刀抬高 (m)
local BLADE_RATE = 1.2                            -- 抬放速度 (m/s)
local function place_blade(self, h)
	local parts = self.parts
	if not parts then return end
	local th = math.asin(math.max(-1, math.min(1, (ARM_TIP.y + h - ARM_PIVOT.y) / ARM_LEN)))
	local tip_y, tip_z = ARM_PIVOT.y + ARM_LEN * math.sin(th), ARM_PIVOT.z + ARM_LEN * math.cos(th)
	if parts.blade then
		parts.blade:set_attach(self.object, "", {x = 0, y = (tip_y + 0.1) * 10, z = (tip_z + 0.15) * 10}, {x = 0, y = 0, z = 0})
	end
	for _, sd in ipairs({{-1, parts.arm_l, parts.cyl_l}, {1, parts.arm_r, parts.cyl_r}}) do
		local x = sd[1]
		V.seg_attach(self, sd[2], {x = x * ARM_PIVOT.x, y = ARM_PIVOT.y, z = ARM_PIVOT.z}, {x = x * ARM_TIP.x, y = tip_y, z = tip_z})
		local top = {x = x * CYL_BASE.x, y = tip_y + 0.55, z = tip_z}
		local base = {x = x * CYL_BASE.x, y = CYL_BASE.y, z = CYL_BASE.z}
		if sd[3] then
			sd[3]:set_properties({visual_size = {x = 0.14, y = vector.distance(base, top), z = 0.14}})
			V.seg_attach(self, sd[3], base, top)
		end
	end
end

-- 車身（碰撞箱）橫向蓋到的欄（相對車身中心的橫向位置，給 face_cells 的 lat）：
-- 車子沒對齊格線時 3 格寬的碰撞箱會蓋到 4 欄，鏟刀要清掉全部，不然沒清到的那欄會把車身擋住
local function body_lat(pos, s)
	local half = def.half
	local cl = pos.x * -s.z + pos.z * s.x
	local lat = {}
	for k = math.floor(cl - half + 0.52), math.floor(cl + half - 0.02 + 0.5) do lat[#lat + 1] = k - cl end
	return lat
end
local PILE_H, PILE_ROWS = 2, 3   -- 鏟刀前那堆：最高 2 格；前一排滿了往前一排倒，最多往前 3 排

-- 放鏟往前：把鏟刀那一排（車頭外第一排、高度 0～2 三層）與車身前排壓著的高度 0 碎石收起來，
-- 倒到再前面（每欄最高 PILE_H 格，滿了往前一排，最多 PILE_ROWS 排），不放進車身的位置。
-- 前面是岩石或倒不下 → 放回原處，回傳被擋住的原因（沒被擋住回傳 nil）
local function push(self, pos, s)
	local lat = body_lat(pos, s)
	local y0 = ground_y(pos, def.half)
	local src = face_cells(pos, s, 1, 2, y0, 3, lat)
	local under = face_cells(pos, s, 1, 1, y0, 1, lat)
	local blocked = false
	for _, c in ipairs(src) do
		local n = core.get_node(c).name
		if not rockmech.rubble_level[n] and not passable(n) then blocked = true end   -- 岩石：推不動
	end
	if blocked then return "鏟刀前是岩石" end
	local got = {}
	for _, c in ipairs(under) do src[#src + 1] = c end
	for _, c in ipairs(src) do
		local n = core.get_node(c).name
		local k = rockmech.rubble_level[n]
		if k then
			local base = rockmech.rubble_base[n]
			got[base] = (got[base] or 0) + k
			-- 不用 remove_node：它會讓周圍 5 格的碎石重新流動，剛推出去的那堆會流回鏟刀前。
			-- 只保留開挖記錄與穩定判定（推走撐住岩石的碎石，上面的岩石照樣會掉）
			core.swap_node(c, {name = "air"})
			collapse.mark_excavated(c)
			collapse.queue_stability_check(c, n)
			rockmech.shotcrete_uncover(c)
		end
	end
	local ycap = y0 + PILE_H - 1
	for base, lv in pairs(got) do
		local rest = lv
		for row = 1, PILE_ROWS do
			if rest <= 0 then break end
			local dst = face_cells(pos, s, 1, 2 + row, y0, 1, lat)
			local left = 0
			for i, c in ipairs(dst) do
				local share = math.ceil(rest / (#dst - i + 1))
				rest = rest - share
				-- 從 ycap 往下找落點，往上倒到 ycap 為止
				local y = ycap
				for _ = 1, 8 do
					if not passable(core.get_node({x = c.x, y = y - 1, z = c.z}).name) then break end
					y = y - 1
				end
				self.pile = self.pile or {}
				left = left + deposit_column(c.x, c.z, ycap, base, share, ycap - y + 1, self.pile)
			end
			rest = left
		end
		if rest > 0 then
			-- 前面堆不下：剩下的放回鏟刀前，推土機停住
			blocked = true
			for _, c in ipairs(src) do
				if rest <= 0 then break end
				rest = deposit_column(c.x, c.z, c.y, base, rest, 2)
			end
		end
	end
	return blocked and ("前面的碎石已堆滿（最高 %d 格、往前 %d 排）"):format(PILE_H, PILE_ROWS) or nil
end

-- 鏟刀前那堆碎石的量（級）：鏟刀前 PILE_ROWS 排、高 3 層
local function pile_amount(pos, s)
	local y0 = ground_y(pos, def.half)
	local lv = 0
	for row = 1, PILE_ROWS do
		for _, c in ipairs(face_cells(pos, s, 1, 2 + row, y0, 3, body_lat(pos, s))) do
			lv = lv + (rockmech.rubble_level[core.get_node(c).name] or 0)
		end
	end
	return lv
end
-- 鏟刀（f = 1，車頭外第一排）或車尾（f = −1）伸出碰撞箱的那段會撞進岩石（碎石不算）：layers 是要檢查的高度
local function overhang_blocked(pos, s, f, layers)
	local y0 = ground_y(pos, def.half)
	for _, dy in ipairs(layers) do
		for _, c in ipairs(face_cells(pos, s, f, 2, y0 + dy, 1, body_lat(pos, s))) do
			local n = core.get_node(c).name
			if not rockmech.rubble_level[n] and not passable(n) then return true end
		end
	end
	return false
end

-- 停止推（停下、後退、收鏟）時，前面那堆照安息角攤開
local function settle_pile(self)
	if not self.pile then return end
	local cells = self.pile
	self.pile = nil
	table.sort(cells, function(a, b) return a.y > b.y end)
	for _, p in ipairs(cells) do collapse.check_cell(p) end
end

function def.hud(self)
	return (self.blade and "　【放鏟】往前開把碎石推走" or "　【收鏟】不推碎石")
		.. ("\n鏟刀前碎石 %d 級（%.1f m³）"):format(self.pile_lv or 0, (self.pile_lv or 0) / NLEV)
		.. (self.push_msg and ("\n推不動：" .. self.push_msg .. "，倒車換個方向或先推開前面") or "") .. "\nE 放鏟／收鏟"
end
function def.on_load(self, data)
	if data.blade ~= nil then self.blade = data.blade else self.blade = true end
	self.blade_h = self.blade and 0 or BLADE_UP
end
function def.on_save(self, data) data.blade = self.blade end
function def.on_spawn(self) place_blade(self, self.blade_h) end

-- 推土、鏟刀與車尾伸出段撞岩石就停、越障高度、鏟刀抬放、鏟刀前碎石量
function def.move(self, ctx)
	local pos, s, fwd, obj = ctx.pos, ctx.s, ctx.fwd, ctx.obj
	-- 鏟刀（車頭外 1 m）、車尾（車尾外 1 m）伸出碰撞箱：往那邊開之前看有沒有人或車
	local la = ctx.speed * 0.1
	local p2 = {x = pos.x + ctx.dir.x * la, y = pos.y, z = pos.z + ctx.dir.z * la}
	local h = def.half
	if (fwd > 0 and V.objects_in(self, p2, ctx.yaw, -h, h, h, h + 1))
		or (fwd < 0 and V.objects_in(self, p2, ctx.yaw, -h, h, -h - 1, -h)) then
		ctx.speed, fwd = 0, 0
	end
	if self.blade and fwd > 0 then
		local why = push(self, pos, s)
		if why then ctx.speed = 0; settle_pile(self) end
		if why ~= self.push_msg then self.push_msg = why; update_hud(self) end
	else
		settle_pile(self)
		if fwd > 0 and overhang_blocked(pos, s, 1, {1, 2}) then ctx.speed = 0 end   -- 收鏟：看鏟刀抬起的高度
		if self.push_msg then self.push_msg = nil; update_hud(self) end
	end
	if fwd < 0 and overhang_blocked(pos, s, -1, {1}) then ctx.speed = 0 end        -- 車尾：配重的高度
	-- 越障高度：放鏟往前（含停著）只壓得過很薄的碎石（要推走，不是爬過去）；倒車、收鏟可爬 1 格
	local sh = (self.blade and fwd >= 0) and 0.3 or 1.1
	if sh ~= self.step_h then self.step_h = sh; obj:set_properties({stepheight = sh}) end
	-- 鏟刀抬放
	local goal = self.blade and 0 or BLADE_UP
	if self.blade_h ~= goal then
		local st = BLADE_RATE * ctx.dtime
		self.blade_h = math.abs(goal - self.blade_h) <= st and goal or self.blade_h + (goal > self.blade_h and st or -st)
		place_blade(self, self.blade_h)
	end
	-- 鏟刀前碎石量（有變才更新 HUD）
	self.pile_t = (self.pile_t or 0) + ctx.dtime
	if self.pile_t >= 0.3 then
		self.pile_t = 0
		local lv = pile_amount(pos, s)
		if lv ~= self.pile_lv then self.pile_lv = lv; update_hud(self) end
	end
end

function def.action(self, ctx)
	if ctx.ctrl.aux1 then
		self.t_act = 0.5
		self.blade = not self.blade
		update_hud(self)
	end
end

-- 擋人：鏟刀（車頭外 z 1.5..2.5，從地面到抬起時的上緣）與車尾配重（z −2.5..−1.5）
def.overhangs = {
	{x0 = -1.5, x1 = 1.5, z0 = 1.5, z1 = 2.5, y0 = -1.5, y1 = 0.5, body = "z0"},
	{x0 = -0.8, x1 = 0.8, z0 = -2.5, z1 = -1.5, y0 = -1.5, y1 = -0.2, body = "z1"},
}
V.register("dozer", def)
