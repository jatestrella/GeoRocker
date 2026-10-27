-- rockmech/vehicles.lua
-- 載具：挖土機（3×3×3：兩側半格寬履帶、2×2×2 駕駛艙、前方動臂與鏟斗）、卡車、推土機（3 寬 × 3 高 × 5 長）。
-- 只處理碎石：完整岩石要先爆破或用魔杖弄碎（爆破 → 裝載 → 運輸）。
-- 操作：右鍵上車；駕駛中 Shift 下車，W/S 前進後退，A/D 轉向。
--   挖土機：E 挖斗伸到滑鼠指的位置（10 m 內），挖起那一格周圍 3×3×3 的碎石（鏟斗 4 m³ = 32 級）再收回；
--           空白鍵：挖斗伸到滑鼠指的位置倒出（指著卡車就倒進卡車），同樣的抬起 → 下降 → 倒 → 收回動作
--           第一人稱駕駛時上部結構（駕駛艙＋手臂）跟著視線的水平方向迴轉；追蹤相機（第三人稱）時不跟
--   卡車（3 寬 × 3 高 × 7 長，十輪砂石車）：空白鍵車斗以後端為軸抬起、把碎石（12 m³ = 96 級）倒在車尾再放下；
--         名牌與車斗裡的碎石顯示載量。碰撞箱是駕駛艙那段 3×3×3，車斗那段（往後 5 m）倒車、轉彎前自己檢查
--   推土機（車身 3×3×3、鏟刀 3 寬伸出車頭 1 m、車尾多 1 m）：E 放鏟／收鏟（鏟刀與推臂實際抬放）。
--           放鏟：往前開時把鏟刀那一排（車身蓋到的 3～4 欄、高 3 層）與車身前排壓著的薄碎石推到前面，
--           那堆最高 2 格、滿了往前一排（最多 3 排），推不動就停；往前時只壓得過很薄的碎石。
--           收鏟：不推。收鏟或倒車可爬 1 格。HUD 顯示鏟刀前那堆碎石的量
-- 駕駛的相機在車頂（挖土機：駕駛艙頂）前緣；Z 切換追蹤相機（從車子後上方看作動）。
-- 不在車上時左鍵：收回成物品（車上的碎石換成碎石物品，8 級 = 1 個）
-- 碎石的增減用 set_node／remove_node，照常觸發開挖記錄、支撐判定；動過的碎石再依安息角流動。

local NLEV = rockmech.RUBBLE_LEVELS
local collapse = rockmech.collapse

local TYPES = {
	-- half：碰撞箱半邊長；lat：車頭外一排的橫向位置（相對中心）；eye_up／eye_fwd：相機在車身中心上方、
	-- 沿視線往前的距離（m）；mirror：右後照鏡位置（車身座標，左鏡 x 取負）；rearcam：倒車攝影機位置；
	-- tilt：外觀隨地形傾斜時量地面的位置（前、後端的 z，左右兩側的 z 與 ±x）
	excavator = {desc = "挖土機 Excavator", color = "#e0a020", cap = 4 * NLEV, speed = 2.0,
		half = 1.5, lat = {-1, 0, 1}, eye_up = 1.65, eye_fwd = 0.45, mirror = {x = 1.15, y = 1.3, z = 0.4},
		tilt = {front = 1.3, rear = -1.3, side_z = 0, side_x = 1.25}},
	truck = {desc = "卡車 Dump truck", color = "#c84020", cap = 12 * NLEV, speed = 5.0,
		half = 1.5, lat = {-1, 0, 1}, eye_up = 1.55, eye_fwd = 1.35, rear = 5.5, mirror = {x = 1.35, y = 1.3, z = 1.2},
		rearcam = {x = 0, y = 1.0, z = -5.7}, tilt = {front = 0.5, rear = -3.8, side_z = -1.6, side_x = 1.1}},
	dozer = {desc = "推土機 Bulldozer", color = "#e8c828", cap = 0, speed = 2.5,
		half = 1.5, lat = {-1, 0, 1}, eye_up = 1.65, eye_fwd = 0, mirror = {x = 1.0, y = 1.4, z = -0.2},
		tilt = {front = 1.3, rear = -2.1, side_z = -0.4, side_x = 1.1}},
}
local TURN_RATE = 1.6        -- rad/s
local TIP_ANGLE, TIP_UP, TIP_HOLD, TIP_DOWN = math.rad(50), 1.0, 0.4, 0.8   -- 卡車車斗抬起
local TIP_TOTAL = TIP_UP + TIP_HOLD + TIP_DOWN
-- 駕駛視線：第一人稱相機不受 set_attach 位移影響（遊戲內確認：改位移視角不變），改用 set_eye_offset。
-- 玩家掛在車身中心（腳在中心），相機往下 EYE_DOWN、沿視線方向往前 EYE_FWD（m）：坐在車頂前緣，
-- 往前看得到自己的車頂前緣與車頭正前方的地面（車身方塊從裡面看不透明，相機不能放進車身）
local EYE_HEIGHT = 1.625
local function eye_offset(def)
	return {x = 0, y = (def.eye_up - EYE_HEIGHT) * 10, z = def.eye_fwd * 10}
end
local DUMP_REACH = 4         -- 挖土機倒進卡車的距離 (m)

-- 貼圖（[fill 組合）。cube 的六面：上、下、+X、−X、+Z（車頭：yaw 0 朝 +Z）、−Z
local function tex(kind, frac, blade_down)
	local c = TYPES[kind].color
	local body = ("[fill:16x16:%s^[fill:16x3:0,13:#2a2a2a"):format(c)          -- 底部履帶／輪
	local side = body .. "^[fill:5x4:9,3:#9fd0ff"                             -- 車窗
	local top = ("[fill:16x16:%s"):format(c)
	local front = body
	if kind == "excavator" then
		front = body .. "^[fill:12x5:2,8:#505050^[fill:2x6:7,2:#404040"          -- 鏟斗與手臂
	elseif kind == "dozer" then
		front = body .. (blade_down and "^[fill:16x5:0,11:#3a3a3a" or "^[fill:16x5:0,3:#3a3a3a")   -- 推土鏟（放下／抬起）
	elseif kind == "truck" then
		top = ("[fill:16x16:%s^[fill:14x14:1,1:#5a2010"):format(c)             -- 車斗
		local h = frac and math.min(12, math.ceil(12 * frac)) or 0         -- 碎石依載量比例填滿
		if h > 0 then top = top .. ("^[fill:12x%d:2,%d:#6a6058"):format(h, 14 - h) end
		front = body .. "^[fill:10x4:3,3:#9fd0ff"                              -- 擋風玻璃
	end
	return {top, body, side, side, front, body}
end

-- 挖土機外觀：兩側半格寬履帶、下車架、2×2×2 駕駛艙（偏後）、前方動臂與鏟斗（鏟斗可伸出碰撞箱，只是外觀）
local function box_tex(c, front)
	local t = ("[fill:16x16:%s"):format(c)
	return {t, t, t, t, front or t, t}
end
local TRACK = "[fill:16x16:#2a2a2a^[fill:16x2:0,0:#454545^[fill:16x2:0,14:#454545^[fill:2x12:3,2:#383838^[fill:2x12:9,2:#383838"
local EXC_PARTS = {
	{pos = {x = -1.25, y = -1.0, z = 0}, size = {x = 0.5, y = 1.0, z = 3.0}, tex = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}},
	{pos = {x = 1.25, y = -1.0, z = 0}, size = {x = 0.5, y = 1.0, z = 3.0}, tex = {TRACK, TRACK, TRACK, TRACK, TRACK, TRACK}},
	{pos = {x = 0, y = -1.0, z = 0}, size = {x = 2.0, y = 1.0, z = 2.6}, tex = box_tex("#3a3a3a")},
	{id = "cab", pos = {x = 0, y = 0.5, z = -0.5}, size = {x = 2.0, y = 2.0, z = 2.0},
		tex = (function()
			local c = TYPES.excavator.color
			local win = ("[fill:16x16:%s^[fill:12x7:2,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
			local side = ("[fill:16x16:%s^[fill:6x6:8,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
			return {("[fill:16x16:%s"):format(c), "[fill:16x16:#2a2a2a", side, side, win, ("[fill:16x16:%s"):format(c)}
		end)()},
	{id = "bucket", pos = {x = 0.55, y = -0.9, z = 2.6}, size = {x = 1.3, y = 0.8, z = 0.7}, tex = box_tex("#505050")},
}
-- 手臂（兩節、長度固定的長方體，像真的怪手）：動臂從駕駛艙前方（BOOM_ROOT）到手肘、斗桿從手肘到挖斗。
-- 給定挖斗位置，手肘由兩節長度以餘弦定理求出（手肘朝上）；長方體沿各節方向旋轉。
-- 掛載旋轉：左手座標、外旋 X → Y → Z（度）。+Y 軸先繞 X 轉 θx、再繞 Y 轉 θy 後指向
-- (sin θx·sin θy, cos θx, sin θx·cos θy)：θx = acos(v.y)、θy = atan2(v.x, v.z)
local BOOM_ROOT = {x = 0.55, y = 0.3, z = 0.7}       -- 駕駛艙前方（駕駛的右手邊）
local BUCKET_REST = {x = 0.55, y = -0.9, z = 2.6}    -- 收起時挖斗在車頭前方約 1.1 m
local BOOM_LEN, STICK_LEN = 3.6, 3.0
local ARM_REACH = BOOM_LEN + STICK_LEN
EXC_PARTS[#EXC_PARTS + 1] = {id = "boom", pos = BUCKET_REST, size = {x = 0.5, y = BOOM_LEN, z = 0.5},
	tex = box_tex(TYPES.excavator.color)}
EXC_PARTS[#EXC_PARTS + 1] = {id = "stick", pos = BUCKET_REST, size = {x = 0.4, y = STICK_LEN, z = 0.4},
	tex = box_tex(TYPES.excavator.color)}
-- 鏟斗裡的碎石：高度依載量（空 → 不顯示），貼圖用載最多的那種碎石
EXC_PARTS[#EXC_PARTS + 1] = {id = "fill", pos = BUCKET_REST, size = {x = 1.1, y = 0.2, z = 0.55}, tex = box_tex("#6a6058")}
local DIG_REACH = 10        -- 挖斗最遠 (m，從相機量)
-- 挖的動作：抬到目標上方 DIG_LIFT → 往下插進目標（挖）→ 抬回目標上方 → 收回。各段時間 (s)
local DIG_LIFT = 2.0
local DIG_PHASES = {0.3, 0.2, 0.2, 0.3}
local DIG_TOTAL = DIG_PHASES[1] + DIG_PHASES[2] + DIG_PHASES[3] + DIG_PHASES[4]
local SWING_RATE = 1.5      -- 上部結構跟著視線迴轉的最大速度（rad/s；真的怪手約 1 rad/s）
local CLEAR = "[fill:1x1:#00000000"
local PART = "rockmech:vehicle_part"
core.register_entity(PART, {
	initial_properties = {
		physical = false, collide_with_objects = false, pointable = false, static_save = false,
		visual = "cube", textures = box_tex("#808080"), backface_culling = true,
	},
	on_activate = function(self)
		-- 沒有掛在載具上的零件（例如載具已經卸載）自己消失
		core.after(1, function()
			if self.object:get_pos() and not self.object:get_attach() then self.object:remove() end
		end)
	end,
})
local function remove_parts(self)
	for _, c in ipairs(self.object:get_children()) do
		local e = c:get_luaentity()
		if e and e.name == PART then c:remove() end
	end
end
local function spawn_parts(self, parts)
	remove_parts(self)
	self.parts = {}
	for _, pt in ipairs(parts) do
		local o = core.add_entity(self.object:get_pos(), PART)
		if o then
			o:set_properties({visual_size = pt.size, textures = pt.tex})
			o:set_attach(self.object, "", {x = pt.pos.x * 10, y = pt.pos.y * 10, z = pt.pos.z * 10}, pt.rot or {x = 0, y = 0, z = 0})
			if pt.id then self.parts[pt.id] = o end
		end
	end
end

-- 卡車外觀（原點在駕駛艙那段 3×3×3 的中心；車頭 z +1.5、車尾 z −5.5）。車斗以後端下緣 TRUCK_HINGE 為軸抬起
-- 尺寸接近真實的十輪砂石車：車寬 2.4～2.6 m、駕駛室頂離地約 3.1 m、車斗上緣約 2.3 m、輪胎直徑 1.0 m
-- （碰撞箱仍是 3 格寬）。車底在 y −1.5
local TRUCK_HINGE = {x = 0, y = -0.4, z = -5.5}
local BED_SIZE = {x = 2.6, y = 1.2, z = 4.8}
-- 空心車斗的 5 片（rel：相對軸心 TRUCK_HINGE 的中心，車斗放平時）。碎石塊放在裡面，四周與上緣都留空隙，
-- 不和車斗的任何一面重疊（重疊會 z-fighting 閃爍）
local BED_T = 0.1
local BED_PLATES = {
	{id = "bed_floor", rel = {x = 0, y = BED_T / 2, z = BED_SIZE.z / 2}, size = {x = BED_SIZE.x, y = BED_T, z = BED_SIZE.z}},
	{id = "bed_left", rel = {x = -(BED_SIZE.x - BED_T) / 2, y = BED_SIZE.y / 2, z = BED_SIZE.z / 2}, size = {x = BED_T, y = BED_SIZE.y, z = BED_SIZE.z}},
	{id = "bed_right", rel = {x = (BED_SIZE.x - BED_T) / 2, y = BED_SIZE.y / 2, z = BED_SIZE.z / 2}, size = {x = BED_T, y = BED_SIZE.y, z = BED_SIZE.z}},
	{id = "bed_front", rel = {x = 0, y = BED_SIZE.y / 2, z = BED_SIZE.z - BED_T / 2}, size = {x = BED_SIZE.x, y = BED_SIZE.y, z = BED_T}},
	{id = "bed_back", rel = {x = 0, y = BED_SIZE.y / 2, z = BED_T / 2}, size = {x = BED_SIZE.x, y = BED_SIZE.y, z = BED_T}},
}
local FILL_W, FILL_L = BED_SIZE.x - 2 * BED_T - 0.1, BED_SIZE.z - 2 * BED_T - 0.1
local FILL_HMAX = BED_SIZE.y - BED_T - 0.1
local WHEEL = "[fill:16x16:#1c1c1c^[fill:10x10:3,3:#3a3a3a^[fill:6x6:5,5:#8a8a8a^[fill:2x2:7,7:#c0c0c0"
local TREAD = "[fill:16x16:#1c1c1c^[fill:16x1:0,3:#2e2e2e^[fill:16x1:0,8:#2e2e2e^[fill:16x1:0,13:#2e2e2e"
local TRUCK_PARTS = (function()
	local c = TYPES.truck.color
	local cab_front = ("[fill:16x16:%s^[fill:12x6:2,2:#9fd0ff^[fill:4x2:2,12:#f0e070^[fill:4x2:10,12:#f0e070"):format(c)
	local cab_side = ("[fill:16x16:%s^[fill:6x6:8,2:#9fd0ff"):format(c)
	local bed_side = ("[fill:16x16:%s^[fill:16x2:0,0:#8a2a10^[fill:2x16:4,0:#a83418^[fill:2x16:10,0:#a83418"):format(c)
	local wheel = {TREAD, TREAD, WHEEL, WHEEL, TREAD, TREAD}   -- 上下前後是胎面，左右兩側是輪圈
	local parts = {
		{pos = {x = 0, y = -0.55, z = -2.0}, size = {x = 1.6, y = 0.3, z = 6.6}, tex = box_tex("#2a2a2a")},   -- 底盤
		{pos = {x = 0, y = 0.6, z = 0.5}, size = {x = 2.4, y = 2.0, z = 2.0},
			tex = {("[fill:16x16:%s"):format(c), "[fill:16x16:#2a2a2a", cab_side, cab_side, cab_front, ("[fill:16x16:%s"):format(c)}},
		{id = "bedfill", pos = {x = 0, y = -0.1, z = -3.1}, size = {x = FILL_W, y = 0.2, z = FILL_L}, tex = box_tex("#6a6058")},
	}
	for _, p in ipairs(BED_PLATES) do
		local t = p.id == "bed_floor" and "[fill:16x16:#4a2010" or bed_side
		parts[#parts + 1] = {id = p.id, pos = {x = p.rel.x, y = -0.1, z = -3.1}, size = p.size, tex = {t, t, t, t, t, t}}
	end
	-- 前軸單輪、後兩軸雙輪（較寬），外緣在車斗外側
	for _, w in ipairs({{x = -1.15, z = 0.5, wd = 0.35}, {x = 1.15, z = 0.5, wd = 0.35},
			{x = -1.1, z = -3.2, wd = 0.6}, {x = 1.1, z = -3.2, wd = 0.6}, {x = -1.1, z = -4.4, wd = 0.6}, {x = 1.1, z = -4.4, wd = 0.6}}) do
		parts[#parts + 1] = {pos = {x = w.x, y = -1.0, z = w.z}, size = {x = w.wd, y = 1.0, z = 1.0}, tex = wheel}
	end
	return parts
end)()

-- 車斗與裡面的碎石：抬起角度 alpha（rad，前端往上）。掛載旋轉繞 X 轉 θx 時 +Z → (0, −sin θx, cos θx)，
-- 所以前端往上 alpha 用 θx = −alpha；相對軸心的點 (y, z) → (y cos α + z sin α, −y sin α + z cos α)
local function place_bed(self, alpha)
	local parts = self.parts
	if not parts then return end
	local ca, sa = math.cos(alpha), math.sin(alpha)
	local function put(o, rel)
		if not o then return end
		local y = TRUCK_HINGE.y + rel.y * ca + rel.z * sa
		local z = TRUCK_HINGE.z - rel.y * sa + rel.z * ca
		o:set_attach(self.object, "", {x = rel.x * 10, y = y * 10, z = z * 10}, {x = -math.deg(alpha), y = 0, z = 0})
	end
	for _, p in ipairs(BED_PLATES) do put(parts[p.id], p.rel) end
	-- 碎石：高度依載量（空 → 不顯示），貼圖用載最多的那種碎石
	local o = parts.bedfill
	if o then
		local total, best, bl = 0, nil, 0
		for base, lv in pairs(self.load or {}) do
			total = total + lv
			if lv > bl then best, bl = base, lv end
		end
		local frac = math.min(1, total / TYPES.truck.cap)
		local h = frac > 0 and (0.1 + (FILL_HMAX - 0.1) * frac) or 0
		local key = ("%.2f/%s"):format(h, tostring(best))
		if self.fill_key ~= key then
			self.fill_key = key
			if h > 0 then
				local nd = core.registered_nodes[best]
				local t = nd and nd.tiles and nd.tiles[1]
				t = type(t) == "table" and t.name or t or "[fill:16x16:#6a6058"
				o:set_properties({is_visible = true, visual_size = {x = FILL_W, y = h, z = FILL_L}, textures = {t, t, t, t, t, t}})
			else
				o:set_properties({is_visible = false})
			end
		end
		put(o, {x = 0, y = BED_T + h / 2, z = BED_SIZE.z / 2})
	end
end

-- 卡車車斗那段（車身座標 z −rear..−half）在位置 p、朝向 yaw 時會不會撞到實心方塊（車底往上 1.2 m 以內不算：
-- 小台階、碎石讓碰撞箱自己爬）
-- (x, z) 這一欄、y_from 往下 depth 格內最上面的實心面高度（不滿格碎石照級數），找不到回傳 nil
local function ground_top(x, y_from, z, depth)
	local xi, zi = math.floor(x + 0.5), math.floor(z + 0.5)
	for y = math.floor(y_from + 0.5), math.floor(y_from + 0.5) - depth, -1 do
		local n = core.get_node({x = xi, y = y, z = zi}).name
		local nd = core.registered_nodes[n]
		if n ~= "air" and (not nd or nd.walkable ~= false) then
			local k = rockmech.rubble_level[n]
			return k and (y - 0.5 + k / NLEV) or (y + 0.5)
		end
	end
end

-- 隨地形傾斜：量前後軸（履帶前後端）、左右輪（履帶）下方的地面（def.tilt），算俯仰（前高為正）
-- 與側傾（右側低為正，set_rotation 是右手 Z-X-Y：X 正 = 抬頭、Z 正 = 向右傾）。只有外觀傾斜，碰撞箱維持水平
local function ground_tilt(p, yaw, def)
	local TILT_AXLES = def.tilt
	local c, sn = math.cos(yaw), math.sin(yaw)
	local function at(lx, lz)
		return p.x + lx * c - lz * sn, p.z + lx * sn + lz * c
	end
	local from, depth = p.y + 0.5, 8   -- 1:1 坡上車尾量測點的地面可比車身中心低 5 m 以上
	local fx, fz = at(0, TILT_AXLES.front)
	local rx, rz = at(0, TILT_AXLES.rear)
	local lx, lz = at(-TILT_AXLES.side_x, TILT_AXLES.side_z)
	local qx, qz = at(TILT_AXLES.side_x, TILT_AXLES.side_z)
	local hf, hr = ground_top(fx, from, fz, depth), ground_top(rx, from, rz, depth)
	local hl, hq = ground_top(lx, from, lz, depth), ground_top(qx, from, qz, depth)
	local pitch, roll = 0, 0
	if hf and hr then pitch = math.atan((hf - hr) / (TILT_AXLES.front - TILT_AXLES.rear)) end
	if hl and hq then roll = math.atan((hl - hq) / (2 * TILT_AXLES.side_x)) end
	local lim = math.rad(25)
	return math.max(-lim, math.min(lim, pitch)), math.max(-lim, math.min(lim, roll))
end

-- 回傳車斗那段卡進實心方塊的檢查點數
local function truck_overlap(p, yaw, def)
	local c, sn = math.cos(yaw), math.sin(yaw)
	local bottom = p.y - def.half
	local n_hit = 0
	for lz = -def.rear + 0.25, -def.half - 0.25, 0.5 do
		for _, lx in ipairs({-1.25, 0, 1.25}) do
			local wx, wz = p.x + lx * c - lz * sn, p.z + lx * sn + lz * c
			for _, dy in ipairs({1.2, 2.2}) do
				local n = core.get_node({x = math.floor(wx + 0.5), y = math.floor(bottom + dy + 0.5), z = math.floor(wz + 0.5)}).name
				local nd = core.registered_nodes[n]
				if n ~= "air" and (not nd or nd.walkable ~= false) then n_hit = n_hit + 1 end
			end
		end
	end
	return n_hit
end
-- 從 (p, yaw) 動到 (p2, yaw2) 會不會讓車斗撞得更多（已經卡住時，不會更糟的動作照樣允許，才能脫困）
local function truck_blocked(p, yaw, p2, yaw2, def)
	local after = truck_overlap(p2, yaw2, def)
	if after == 0 then return false end
	return after > truck_overlap(p, yaw, def)
end

-- 挖斗放在 b（車身座標，m）：動臂 BOOM_ROOT → 手肘、斗桿 手肘 → b
local function lerp(a, b, t) return {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t} end
local atan2 = math.atan2 or math.atan
-- 上部結構（駕駛艙＋手臂）迴轉 ψ（rad）：上部座標 → 車身座標。+Z 轉 ψ 後指向 (sin ψ, cos ψ)，
-- 與掛載旋轉的 Y 角同一個方向（見下面 seg_attach 的說明）
local CAB_POS = {x = 0, y = 0.5, z = -0.5}
local function h2v(p, psi)
	local c, sn = math.cos(psi), math.sin(psi)
	return {x = p.x * c + p.z * sn, y = p.y, z = -p.x * sn + p.z * c}
end
local function v2h(p, psi)
	local c, sn = math.cos(psi), math.sin(psi)
	return {x = p.x * c - p.z * sn, y = p.y, z = p.x * sn + p.z * c}
end
-- 角度內插（走最短的方向）
local function lerp_angle(a, b, t)
	local d = (b - a + math.pi) % (2 * math.pi) - math.pi
	return a + d * t
end
-- 挖斗位置 b（車身座標）→ 實際搆得到的挖斗位置、手肘位置
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
-- 長方體（長軸是自身 +Y）擺在 a → c 之間
local function seg_attach(self, o, a, c)
	if not o then return end
	local v = {x = c.x - a.x, y = c.y - a.y, z = c.z - a.z}
	local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if len < 1e-6 then return end
	local tx = math.deg(math.acos(math.max(-1, math.min(1, v.y / len))))
	local ty = math.deg(atan2(v.x, v.z))
	o:set_attach(self.object, "", {x = (a.x + c.x) * 5, y = (a.y + c.y) * 5, z = (a.z + c.z) * 5}, {x = tx, y = ty, z = 0})
end
-- 推土機外觀（原點在 3×3×3 碰撞箱中心；車頭 z +1.5、鏟刀到 +2.5、車尾 −2.5；車底 y −1.5）：
-- 兩側履帶、車架、前方引擎蓋、中後段駕駛艙、車尾配重、排氣管；鏟刀由兩側推臂（繞車架上的樞軸轉）
-- 與兩支油壓缸（引擎蓋前端 → 鏟刀背）撐著
local DOZER_PARTS = (function()
	local c = TYPES.dozer.color
	local y = ("[fill:16x16:%s"):format(c)
	local grille = ("[fill:16x16:%s^[fill:12x9:2,4:#2a2a2a^[fill:12x1:2,6:#4a4a4a^[fill:12x1:2,9:#4a4a4a"):format(c)
	local win = ("[fill:16x16:%s^[fill:12x8:2,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
	local side = ("[fill:16x16:%s^[fill:10x8:3,2:#9fd0ff^[fill:16x2:0,14:#2a2a2a"):format(c)
	local blade = "[fill:16x16:#4a4a4a^[fill:16x2:0,14:#b0b0b0^[fill:16x1:0,0:#3a3a3a"
	local steel = box_tex("#3a3a3a")
	return {
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
end)()
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
		seg_attach(self, sd[2], {x = x * ARM_PIVOT.x, y = ARM_PIVOT.y, z = ARM_PIVOT.z}, {x = x * ARM_TIP.x, y = tip_y, z = tip_z})
		local top = {x = x * CYL_BASE.x, y = tip_y + 0.55, z = tip_z}
		local base = {x = x * CYL_BASE.x, y = CYL_BASE.y, z = CYL_BASE.z}
		if sd[3] then
			sd[3]:set_properties({visual_size = {x = 0.14, y = vector.distance(base, top), z = 0.14}})
			seg_attach(self, sd[3], base, top)
		end
	end
end

-- 鏟斗裡的碎石（parts.fill）：跟著載量改高度與貼圖，擺在挖斗上面
local function place_fill(self, b, psi)
	local o = self.parts and self.parts.fill
	if not o then return end
	local total, best, bl = 0, nil, 0
	for base, lv in pairs(self.load or {}) do
		total = total + lv
		if lv > bl then best, bl = base, lv end
	end
	local frac = math.min(1, total / TYPES.excavator.cap)
	local h = frac > 0 and (0.12 + 0.6 * frac) or 0
	local key = ("%.2f/%s"):format(h, tostring(best))
	if self.fill_key ~= key then
		self.fill_key = key
		if h > 0 then
			local nd = core.registered_nodes[best]
			local t = nd and nd.tiles and nd.tiles[1]
			t = type(t) == "table" and t.name or t or "[fill:16x16:#6a6058"
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

-- 世界座標 → 車身座標（車頭 +Z）
-- 世界座標 → 車身座標（含隨地形傾斜：實體旋轉依序是側傾 Z、俯仰 X、偏航 Y，這裡反過來解）。
-- 挖臂在這個座標裡解，車身傾斜時挖斗照樣落在目標上
local function to_local(self, wp)
	local p, yaw = self.object:get_pos(), self.object:get_yaw()
	local dx, dy, dz = wp.x - p.x, wp.y - p.y, wp.z - p.z
	local c, sn = math.cos(yaw), math.sin(yaw)
	local x, y, z = dx * c + dz * sn, dy, -dx * sn + dz * c
	local cp, sp = math.cos(self.pitch or 0), math.sin(self.pitch or 0)
	y, z = y * cp - z * sp, y * sp + z * cp
	local cr, sr = math.cos(self.roll or 0), math.sin(self.roll or 0)
	return {x = x * cr - y * sr, y = x * sr + y * cr, z = z}
end

-- 追蹤相機：Z 鍵時把駕駛掛到一個看不見、跟著車子的點上（Luanti 內建第三人稱拉不遠）。
-- 位置：車身座標 (0, CHASE_UP, −CHASE_BACK)；相機（眼睛）在它上方 EYE_HEIGHT
local CHASE = "rockmech:chasecam"
core.register_entity(CHASE, {
	initial_properties = {
		physical = false, collide_with_objects = false, pointable = false, static_save = false,
		visual = "sprite", textures = {"[fill:1x1:#00000000"}, use_texture_alpha = true,
	},
	on_activate = function(self)
		core.after(1, function()
			if self.object:get_pos() and #self.object:get_children() == 0 then self.object:remove() end
		end)
	end,
})
local function chase_pos(self, def)
	local p, yaw = self.object:get_pos(), self.object:get_yaw()
	local back = (def.rear or def.half) + 3.5   -- 車尾後 3.5 m
	local up = def.half + 4.0                 -- 車頂上方 4 m（眼睛）
	return {x = p.x + math.sin(yaw) * back, y = p.y + up - EYE_HEIGHT, z = p.z - math.cos(yaw) * back}
end

-- 滑鼠指的東西：從駕駛的相機沿視線找。回傳 {under, above}（方塊）或 {truck = 卡車實體}；沒有回傳 nil。
-- with_trucks：也找卡車（跳過自己、零件與玩家）
local function aim(self, d, pos, def, with_trucks)
	local look = d:get_look_dir()
	local hl = math.sqrt(look.x * look.x + look.z * look.z)
	local eye = {x = pos.x + (hl > 0 and look.x / hl or 0) * def.eye_fwd, y = pos.y + def.eye_up,
		z = pos.z + (hl > 0 and look.z / hl or 0) * def.eye_fwd}
	local reach = DIG_REACH
	if self.chase and self.chase:get_pos() then
		eye = vector.add(self.chase:get_pos(), {x = 0, y = EYE_HEIGHT, z = 0})
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
	-- 再找卡車：沿視線每 0.2 m 檢查是否落在卡車車身內（照卡車朝向旋轉；伺服器的射線不會旋轉選取框）
	if with_trucks then
		local trucks = {}
		for _, o in ipairs(core.get_objects_inside_radius(eye, reach + 8)) do
			local e = o:get_luaentity()
			if e and e ~= self and e.vkind == "truck" then trucks[#trucks + 1] = e end
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
						local td = TYPES.truck
						if math.abs(lx) <= 1.4 and dy >= -td.half and dy <= 1.0 and lz >= -td.rear and lz <= td.half then
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

local function passable(name)
	local def = core.registered_nodes[name]
	return name == "air" or (def and def.walkable == false)
end

-- 車頭方向（連續）與對齊格線的方向
local function dirs(yaw)
	local dx, dz = -math.sin(yaw), math.cos(yaw)
	local sx, sz
	if math.abs(dx) > math.abs(dz) then sx, sz = dx > 0 and 1 or -1, 0 else sx, sz = 0, dz > 0 and 1 or -1 end
	return {x = dx, z = dz}, {x = sx, z = sz}
end

-- 車頭（f = 1）或車尾（f = −1）外側、距車身中心 dist 的一排（地面層 + 上方 h−1 層）。
-- lat：橫向位置（預設 2 格寬 {−0.5, 0.5}）
local function face_cells(pos, s, f, dist, y0, h, lat)
	local px, pz = -s.z, s.x
	local cx, cz = pos.x + f * s.x * dist, pos.z + f * s.z * dist
	local cells = {}
	for _, l in ipairs(lat or {-0.5, 0.5}) do
		local x = math.floor(cx + px * l + 0.5)
		local z = math.floor(cz + pz * l + 0.5)
		for dy = 0, h - 1 do cells[#cells + 1] = {x = x, y = y0 + dy, z = z} end
	end
	return cells
end

-- 地面層（車身最下面那層格子的高程）。half：碰撞箱半邊長（預設 1）
local function ground_y(pos, half) return math.floor(pos.y - (half or 1) + 0.5) end

-- 從 cell 取走最多 want 級碎石。回傳 取走的級數, 碎石種類
local function take_rubble(cell, want)
	local name = core.get_node(cell).name
	local k = rockmech.rubble_level[name]
	if not k or want <= 0 then return 0 end
	local base = rockmech.rubble_base[name]
	local t = math.min(k, want)
	local rest = rockmech.rubble_with_level(base, k - t)
	if rest then core.swap_node(cell, {name = rest}) else core.remove_node(cell) end
	collapse.check_cell({x = cell.x, y = cell.y + 1, z = cell.z})   -- 上方的碎石往下掉
	return t, base
end

-- 在 (x, z) 這一欄、從 ytop 往下找落點，倒 a 級 base 碎石；滿了往上堆（最多 max_h 格，預設 8）。
-- placed（可選）：收集倒下的格子，不立即做安息角流動（推土機推著的那堆）。回傳倒不下的級數
local function deposit_column(x, z, ytop, base, a, max_h, placed)
	local y = ytop
	for _ = 1, 8 do
		if not passable(core.get_node({x = x, y = y - 1, z = z}).name) then break end
		y = y - 1
	end
	for _ = 1, max_h or 8 do
		if a <= 0 then break end
		local p = {x = x, y = y, z = z}
		local n = core.get_node(p).name
		local k = rockmech.rubble_level[n]
		if passable(n) then
			local put = math.min(NLEV, a)
			core.set_node(p, {name = rockmech.rubble_with_level(base, put)})
			a = a - put
			if placed then placed[#placed + 1] = p else collapse.check_cell(p) end
		elseif k and k < NLEV and rockmech.rubble_base[n] == base then
			local put = math.min(NLEV - k, a)
			core.swap_node(p, {name = rockmech.rubble_with_level(base, k + put)})
			a = a - put
			if placed then placed[#placed + 1] = p else collapse.check_cell(p) end
		end
		y = y + 1
	end
	return a
end

local function load_total(self)
	local t = 0
	for _, v in pairs(self.load) do t = t + v end
	return t
end

-- 倒出車上的碎石：平均分到 cells 所在的欄（每欄往上最多堆 8 格），之後依安息角流開
local function dump_to_ground(self, cells, ytop)
	for base, lv in pairs(self.load) do
		local rest = 0
		for i, c in ipairs(cells) do
			local share = math.ceil(lv / (#cells - i + 1))
			lv = lv - share
			rest = rest + deposit_column(c.x, c.z, ytop, base, share)
		end
		self.load[base] = rest > 0 and rest or nil
	end
end

local function find_truck(pos, s, half)
	local d = (half or 1) + 1.5
	local front = {x = pos.x + s.x * d, y = pos.y, z = pos.z + s.z * d}
	for _, obj in ipairs(core.get_objects_inside_radius(front, DUMP_REACH)) do
		local e = obj:get_luaentity()
		if e and e.vkind == "truck" then return e end
	end
end

-- 推土機車身（碰撞箱）橫向蓋到的欄（相對車身中心的橫向位置，給 face_cells 的 lat）：
-- 車子沒對齊格線時 3 格寬的碰撞箱會蓋到 4 欄，鏟刀要清掉全部，不然沒清到的那欄會把車身擋住
local function body_lat(pos, s)
	local half = TYPES.dozer.half
	local cl = pos.x * -s.z + pos.z * s.x
	local lat = {}
	for k = math.floor(cl - half + 0.52), math.floor(cl + half - 0.02 + 0.5) do lat[#lat + 1] = k - cl end
	return lat
end
local PILE_H, PILE_ROWS = 2, 3   -- 鏟刀前那堆：最高 2 格；前一排滿了往前一排倒，最多往前 3 排

-- 推土機（放鏟）：把鏟刀那一排（車頭外第一排、高度 0～2 三層）與車身前排壓著的高度 0 碎石收起來，
-- 倒到再前面（每欄最高 PILE_H 格，滿了往前一排，最多 PILE_ROWS 排），不放進車身的位置。
-- 前面是岩石或倒不下 → 放回原處，回傳被擋住的原因（沒被擋住回傳 nil）
local function push(self, pos, s)
	local lat = body_lat(pos, s)
	local y0 = ground_y(pos, TYPES.dozer.half)
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
			-- 只保留開挖記錄與支撐判定（推走撐住岩石的碎石，上面的岩石照樣會掉）
			core.swap_node(c, {name = "air"})
			collapse.mark_excavated(c)
			collapse.queue_support_check(c, n)
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
	local def = TYPES.dozer
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
	local def = TYPES.dozer
	local y0 = ground_y(pos, def.half)
	for _, dy in ipairs(layers) do
		for _, c in ipairs(face_cells(pos, s, f, 2, y0 + dy, 1, body_lat(pos, s))) do
			local n = core.get_node(c).name
			if not rockmech.rubble_level[n] and not passable(n) then return true end
		end
	end
	return false
end

-- 推土機停止推（停下、後退、收鏟）時，前面那堆照安息角攤開
local function settle_pile(self)
	if not self.pile then return end
	local cells = self.pile
	self.pile = nil
	table.sort(cells, function(a, b) return a.y > b.y end)
	for _, p in ipairs(cells) do collapse.check_cell(p) end
end

-- 駕駛的 HUD
local function hud_text(self)
	local def = TYPES[self.vkind]
	local s = def.desc
	if def.cap > 0 then
		local t = load_total(self)
		s = s .. ("　載量 %d / %d 級（%.1f / %.0f m³）"):format(t, def.cap, t / NLEV, def.cap / NLEV)
	end
	if self.vkind == "excavator" then
		local p = self.object:get_pos()
		local truck = p and find_truck(p, select(2, dirs(self.object:get_yaw())), TYPES.excavator.half)
		if truck then
			local tt = load_total(truck)
			s = s .. ("\n前方卡車：%d / %d 級（%.1f / %.0f m³）"):format(tt, TYPES.truck.cap, tt / NLEV, TYPES.truck.cap / NLEV)
		end
		if self.msg then s = s .. "\n" .. self.msg end
		s = s .. "\nE 挖滑鼠指的位置　空白鍵 倒在滑鼠指的位置（指著卡車就倒進卡車）"
	elseif self.vkind == "truck" then s = s .. "\n空白鍵 把車斗倒在車尾"
	else
		s = s .. (self.blade and "　【放鏟】往前開把碎石推走" or "　【收鏟】不推碎石")
			.. ("\n鏟刀前碎石 %d 級（%.1f m³）"):format(self.pile_lv or 0, (self.pile_lv or 0) / NLEV)
			.. (self.push_msg and ("\n推不動：" .. self.push_msg .. "，倒車換個方向或先推開前面") or "") .. "\nE 放鏟／收鏟"
	end
	return s .. "　Z 切換視角　Shift 下車"
end

-- 外觀與名牌（卡車：載量；推土機：鏟子高低）
local function refresh_look(self)
	if self.vkind == "truck" then
		local t, cap = load_total(self), TYPES.truck.cap
		self.object:set_properties({
			nametag = ("載量 %d / %d 級（%.1f / %.0f m³）"):format(t, cap, t / NLEV, cap / NLEV),
			nametag_color = t >= cap and "#ff8060" or "#ffffff",
		})
		if not self.tip then place_bed(self, 0) end
	end
end
-- 駕駛艙框（全螢幕 HUD 圖片，中間透明）：上方車頂邊條、左右 A 柱（車身顏色）、左右上方後照鏡、下方儀表板
local function cockpit_tex(kind)
	local c = TYPES[kind].color
	local dark, mid = "#1e1e1e", "#2c2c2c"
	return table.concat({
		"[fill:160x90:#00000000",
		"^[fill:160x7:0,0:" .. dark, "^[fill:160x2:0,7:" .. c,                        -- 車頂邊條
		"^[fill:10x90:0,0:" .. c, "^[fill:2x90:10,0:" .. dark,                          -- 左 A 柱
		"^[fill:10x90:150,0:" .. c, "^[fill:2x90:148,0:" .. dark,                       -- 右 A 柱
		"^[fill:6x8:12,9:" .. c, "^[fill:6x8:142,9:" .. c,                              -- 柱子上方的斜角
		"^[fill:3x6:18,9:" .. c, "^[fill:3x6:139,9:" .. c,
		"^[fill:160x2:0,70:" .. c, "^[fill:160x18:0,72:" .. mid,                       -- 儀表板
		"^[fill:14x8:18,78:#101010^[fill:12x6:19,79:#203828",                            -- 儀表
		"^[fill:14x8:128,78:#101010^[fill:12x6:129,79:#382820",
		-- 後照鏡（左上、右上）：支架 + 鏡框；鏡面 24×14（x 18／118、y 11 起）上面再疊後照鏡畫面
		"^[fill:6x2:12,17:#303030", "^[fill:26x16:17,10:#151515", "^[fill:24x14:18,11:#7f9fb8",
		"^[fill:6x2:142,17:#303030", "^[fill:26x16:117,10:#151515", "^[fill:24x14:118,11:#7f9fb8",
		TYPES[kind].rearcam and "^[fill:38x23:61,9:#151515^[fill:2x1:79,32:#303030" or "",   -- 倒車攝影機螢幕
	})
end

-- 後照鏡、倒車攝影機畫面：Luanti 只有一個相機，所以這些畫面是伺服器從鏡頭位置往後打射線、
-- 依碰到的東西上色拼成的小圖（每 MIRROR_DT 秒更新）。
-- 畫方塊、車輛（含自己的車：用實際掛著的零件方塊，位置、旋轉、貼圖照實）與沒在車上的玩家；遠處淡入天空色
local MIRROR_RANGE = 24                                         -- m
local MIRROR_DT = 0.35
local SKY = {0x9c, 0xc0, 0xe4}
-- 畫面：o 鏡頭位置（車身座標；swing → 挖土機用上部結構座標、跟著迴轉）、dir 中心朝向（從正後方往右偏的角度）、
-- down 往下的角度、hfov／vfov 視角、w × h 解析度、hud 在駕駛艙框（160×90）裡的左上角與大小
local function mirror_view(side, m)
	return {o = {x = side * m.x, y = m.y, z = m.z}, dir = side * math.rad(14), down = math.rad(5),
		hfov = math.rad(44), vfov = math.rad(26), w = 24, h = 14, swing = true,
		hud = {x = side < 0 and 18 or 118, y = 11, w = 24, h = 14}}
end
local REARCAM_HUD = {x = 62, y = 10, w = 36, h = 20.25}
local function views_of(kind)
	local def = TYPES[kind]
	local v = {mirror_view(-1, def.mirror), mirror_view(1, def.mirror)}
	if def.rearcam then
		v[3] = {o = def.rearcam, dir = 0, down = math.rad(24), hfov = math.rad(80), vfov = math.rad(42),
			w = 40, h = 22, hud = REARCAM_HUD}
	end
	return v
end

local function hex_rgb(h)
	return {tonumber(h:sub(2, 3), 16), tonumber(h:sub(4, 5), 16), tonumber(h:sub(6, 7), 16)}
end
-- 方塊顏色：岩石用岩性顏色、碎石用碎石顏色，其他依群組大略給
local node_rgb = {}
local function rgb_of(name)
	local c = node_rgb[name]
	if c then return c end
	local lith, base = rockmech.lith_of_node[name], rockmech.rubble_base[name]
	local h
	if lith then h = lith.color
	elseif base == rockmech.RUBBLE_GRANITE then h = rockmech.cfg.lithologies.granite.color
	elseif base then h = "#6a6058"
	else
		local g = (core.registered_nodes[name] or {}).groups or {}
		h = name:find("grass") and "#5a8a38" or g.leaves and "#356a28" or g.tree and "#6b5030"
			or g.sand and "#d8c890" or g.soil and "#6b4a2b" or g.water and "#3a68b0" or "#808080"
	end
	c = hex_rgb(h)
	node_rgb[name] = c
	return c
end

-- [fill 組合貼圖 → 色塊清單（後面的蓋前面的）；不是 [fill 組合（例如碎石方塊貼圖）→ false
local tex_cache = {}
local function tex_rects(t)
	local r = tex_cache[t]
	if r ~= nil then return r end
	r = {}
	for op in (t .. "^"):gmatch("(.-)%^") do
		local w, h, x, y, c = op:match("^%[fill:(%d+)x(%d+):(%d+),(%d+):(#%x+)$")
		if not w then w, h, c = op:match("^%[fill:(%d+)x(%d+):(#%x+)$"); x, y = 0, 0 end
		if not w then r = false; break end
		r[#r + 1] = {tonumber(x), tonumber(y), tonumber(w), tonumber(h), c}
	end
	if r and #r == 0 then r = false end
	if r then r.W, r.H = r[1][3], r[1][4] end
	tex_cache[t] = r
	return r
end
-- 貼圖在 (u, v)（0～1，v 往下）的顏色；不認得的貼圖當碎石色
local function tex_color(t, u, v)
	local r = tex_rects(t)
	if not r then return "#6a6058" end
	local px, py = u * r.W, v * r.H
	for k = #r, 1, -1 do
		local q = r[k]
		if px >= q[1] and px < q[1] + q[3] and py >= q[2] and py < q[2] + q[4] then return q[5] end
	end
	return r[1][5]
end

-- 掛載旋轉（度；先繞 X、再繞 Y，與 seg_attach 相同）作用在零件座標的向量上
local function attach_rot(v, rx, ry)
	local cx, sx = math.cos(math.rad(rx)), math.sin(math.rad(rx))
	return h2v({x = v.x, y = v.y * cx - v.z * sx, z = v.y * sx + v.z * cx}, math.rad(ry))
end
local AXES = {{x = 1, y = 0, z = 0}, {x = 0, y = 1, z = 0}, {x = 0, y = 0, z = 1}}
-- 一台車（本體看得見時）與它的零件 → 世界座標的有向箱子 {c 中心, ax 三軸, h 半邊長, tex 六面貼圖}。
-- 只用車子的 yaw（地形傾斜不算）。實體 yaw 對應 h2v(·, −yaw)
local function vehicle_boxes(o, boxes)
	local p, yaw = o:get_pos(), o:get_yaw()
	local function add(off, rx, ry, size, textures)
		local ax = {}
		for i, e in ipairs(AXES) do ax[i] = h2v(attach_rot(e, rx, ry), -yaw) end
		boxes[#boxes + 1] = {c = vector.add(p, h2v(off, -yaw)), ax = ax,
			h = {size.x / 2, size.y / 2, size.z / 2}, tex = textures}
	end
	local pr = o:get_properties()
	if pr.textures[1] ~= CLEAR then add({x = 0, y = 0, z = 0}, 0, 0, pr.visual_size, pr.textures) end
	for _, ch in ipairs(o:get_children()) do
		local e = ch:get_luaentity()
		if e and e.name == PART then
			local cp = ch:get_properties()
			if cp.is_visible ~= false then
				local _, _, ap, ar = ch:get_attach()
				add(vector.multiply(ap, 0.1), ar.x, ar.y, cp.visual_size, cp.textures)
			end
		end
	end
end
local PLAYER_TEX = {}
for i = 1, 6 do PLAYER_TEX[i] = "[fill:4x8:#3a5a9a^[fill:4x2:0,0:#c8a080^[fill:4x3:0,5:#30304a" end

-- 射線（從 eye、單位方向 dir）打到箱子：回傳距離、進入面的軸（1～3）與正負；只找比 tmax 近的
local function hit_box(bx, eye, dir, tmax)
	local dx, dy, dz = bx.c.x - eye.x, bx.c.y - eye.y, bx.c.z - eye.z
	local tmin, axis, sgn = 0, nil, 0
	for i = 1, 3 do
		local a, h = bx.ax[i], bx.h[i]
		local e = a.x * dx + a.y * dy + a.z * dz
		local fd = a.x * dir.x + a.y * dir.y + a.z * dir.z
		if math.abs(fd) > 1e-9 then
			local tn, tf, sg
			if fd > 0 then tn, tf, sg = (e - h) / fd, (e + h) / fd, -1 else tn, tf, sg = (e + h) / fd, (e - h) / fd, 1 end
			if tn > tmin then tmin, axis, sgn = tn, i, sg end
			if tf < tmax then tmax = tf end
			if tmin > tmax then return nil end
		elseif math.abs(e) > h then
			return nil
		end
	end
	if not axis then return nil end   -- 鏡子在箱子裡面
	return tmin, axis, sgn
end
-- 打到箱子那一點的顏色：面（貼圖順序 +Y −Y +X −X +Z −Z）與面上的 (u, v)
local FACE = {{4, 3}, {2, 1}, {6, 5}}
local function box_color(bx, eye, dir, t, axis, sgn)
	local q = {}
	for i = 1, 3 do
		local a = bx.ax[i]
		q[i] = a.x * (eye.x + dir.x * t - bx.c.x) + a.y * (eye.y + dir.y * t - bx.c.y) + a.z * (eye.z + dir.z * t - bx.c.z)
		q[i] = math.max(0, math.min(0.999, (q[i] / bx.h[i] + 1) / 2))
	end
	local u, v
	if axis == 1 then u, v = q[3], 1 - q[2]
	elseif axis == 2 then u, v = q[1], q[3]
	else u, v = q[1], 1 - q[2] end
	local t6 = bx.tex[FACE[axis][sgn > 0 and 2 or 1]] or bx.tex[1]
	return hex_rgb(tex_color(t6, u, v)), {x = bx.ax[axis].x * sgn, y = bx.ax[axis].y * sgn, z = bx.ax[axis].z * sgn}
end

-- 畫一個畫面（view 見 views_of）。看往後方，和照後鏡一樣：畫面左邊 = 車身左側（−X），上 = 上
local function render_view(self, view)
	local p, yaw = self.object:get_pos(), self.object:get_yaw()
	local psi = view.swing and self.vkind == "excavator" and self.swing or 0
	local cy, sy = math.cos(yaw), math.sin(yaw)
	local function world(l)   -- 上部結構（挖土機）／車身座標 → 世界方向
		l = h2v(l, psi)
		return {x = l.x * cy - l.z * sy, y = l.y, z = l.x * sy + l.z * cy}
	end
	local eye = vector.add(p, world(view.o))
	-- 附近的車輛（含自己）與沒在車上的玩家
	-- 每台車（或玩家）一組：箱子與外接球（射線先比外接球，碰不到整組跳過）
	local groups = {}
	for _, o in ipairs(core.get_objects_inside_radius(eye, MIRROR_RANGE + 8)) do
		local e = o:get_luaentity()
		local boxes = {}
		if e and e.vkind and TYPES[e.vkind] then
			vehicle_boxes(o, boxes)
		elseif o:is_player() and not o:get_attach() then
			boxes[1] = {c = vector.add(o:get_pos(), {x = 0, y = 0.9, z = 0}), ax = AXES, h = {0.3, 0.9, 0.3}, tex = PLAYER_TEX}
		end
		if #boxes > 0 then
			local c = {x = 0, y = 0, z = 0}
			for _, bx in ipairs(boxes) do c = vector.add(c, bx.c) end
			c = vector.divide(c, #boxes)
			local r = 0
			for _, bx in ipairs(boxes) do
				r = math.max(r, vector.distance(c, bx.c) + math.sqrt(bx.h[1] ^ 2 + bx.h[2] ^ 2 + bx.h[3] ^ 2))
			end
			groups[#groups + 1] = {c = c, r = r, boxes = boxes}
		end
	end
	local W, H = view.w, view.h
	local out = {("[fill:%dx%d:#%02x%02x%02x"):format(W, H, SKY[1], SKY[2], SKY[3])}
	for v = 0, H - 1 do
		local b = -view.down + (0.5 - (v + 0.5) / H) * view.vfov
		local cb, sb = math.cos(b), math.sin(b)
		local run, run_x = nil, 0
		local function flush(u)
			if run then out[#out + 1] = ("^[fill:%dx1:%d,%d:%s"):format(u - run_x, run_x, v, run) end
		end
		for u = 0, W - 1 do
			local col
			local a = view.dir + ((u + 0.5) / W - 0.5) * view.hfov
			local dw = world({x = math.sin(a) * cb, y = sb, z = -math.cos(a) * cb})
			local hit = core.raycast(eye, vector.add(eye, vector.multiply(dw, MIRROR_RANGE)), false, false):next()
			local c, n, dist
			if hit and hit.type == "node" then
				c, n = rgb_of(core.get_node(hit.under).name), hit.intersection_normal
				dist = vector.distance(eye, hit.intersection_point)
			end
			local best, bt, bax, bsg = nil, dist or MIRROR_RANGE, nil, nil
			for _, g in ipairs(groups) do
				local ox, oy, oz = g.c.x - eye.x, g.c.y - eye.y, g.c.z - eye.z
				local along = ox * dw.x + oy * dw.y + oz * dw.z
				if along + g.r > 0 and along - g.r < bt and ox * ox + oy * oy + oz * oz - along * along < g.r * g.r then
					for _, bx in ipairs(g.boxes) do
						local t, axis, sg = hit_box(bx, eye, dw, bt)
						if t then best, bt, bax, bsg = bx, t, axis, sg end
					end
				end
			end
			if best then
				dist = bt
				c, n = box_color(best, eye, dw, bt, bax, bsg)
			end
			if c then
				local shade = n.y > 0.5 and 1 or n.y < -0.5 and 0.55 or math.abs(n.x) > math.abs(n.z) and 0.82 or 0.7
				local t = 0.6 * dist / MIRROR_RANGE
				col = {c[1] * shade * (1 - t) + SKY[1] * t, c[2] * shade * (1 - t) + SKY[2] * t,
					c[3] * shade * (1 - t) + SKY[3] * t}
			end
			local hx = col and ("#%02x%02x%02x"):format(math.floor(col[1]), math.floor(col[2]), math.floor(col[3]))
			if hx ~= run then flush(u); run, run_x = hx, u end
		end
		flush(W)
	end
	return table.concat(out)
end

rockmech.vehicle_render_view, rockmech.vehicle_views = render_view, views_of   -- 測試用

local function update_mirrors(self, d, dtime)
	if not self.hud_mirror then return end
	local views = views_of(self.vkind)
	self.mirror_t = (self.mirror_t or MIRROR_DT) + dtime
	if self.mirror_t < MIRROR_DT / #views then return end
	self.mirror_t = 0
	local i = (self.mirror_i or 0) % #views + 1
	self.mirror_i = i
	local tex = render_view(self, views[i])
	if tex ~= self.mirror_last[i] then
		d:hud_change(self.hud_mirror[i], "text", tex)
		self.mirror_last[i] = tex
	end
end

-- 移除駕駛的 HUD（說明文字、駕駛艙框、後照鏡與倒車攝影機畫面）
local function hud_clear(self, player)
	if player then
		if self.hud then player:hud_remove(self.hud) end
		if self.hud_cockpit then player:hud_remove(self.hud_cockpit) end
		for _, id in ipairs(self.hud_mirror or {}) do player:hud_remove(id) end
	end
	self.hud, self.hud_cockpit, self.hud_mirror = nil, nil, nil
end

local function update_hud(self)
	local d = self.driver and core.get_player_by_name(self.driver)
	if not d then return end
	if not self.hud_cockpit then
		self.hud_cockpit = d:hud_add({type = "image", position = {x = 0.5, y = 0.5}, alignment = {x = 0, y = 0},
			scale = {x = -100, y = -100}, text = cockpit_tex(self.vkind), z_index = -10})
	end
	if not self.hud_mirror then
		self.hud_mirror, self.mirror_last, self.mirror_t = {}, {}, nil
		for i, view in ipairs(views_of(self.vkind)) do
			local r = view.hud
			self.hud_mirror[i] = d:hud_add({type = "image", alignment = {x = 0, y = 0},
				position = {x = (r.x + r.w / 2) / 160, y = (r.y + r.h / 2) / 90},
				scale = {x = -r.w / 160 * 100, y = -r.h / 90 * 100}, text = "[fill:1x1:#7f9fb8", z_index = -9})
		end
	end
	if self.hud then d:hud_change(self.hud, "text", hud_text(self))
	else
		self.hud = d:hud_add({type = "text", position = {x = 0.5, y = 0.85}, alignment = {x = 0, y = 0},
			text = hud_text(self), number = 0xFFE080, z_index = 100})
	end
	refresh_look(self)
end

-- 駕駛的姿勢（有 player_api 時）：上車坐著、下車恢復
local function set_seated(player, on)
	if not (player_api and player) then return end
	local name = player:get_player_name()
	player_api.player_attached[name] = on or nil
	player_api.set_animation(player, on and "sit" or "stand")
end

local function drop_chase(self)
	if self.chase then
		if self.chase:get_pos() then self.chase:remove() end
		self.chase = nil
	end
end

local function get_off(self)
	local d = self.driver and core.get_player_by_name(self.driver)
	drop_chase(self)
	if d then
		d:set_detach()
		d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		d:set_camera({mode = "any"})
		set_seated(d, false)
		hud_clear(self, d)
		local p = self.object:get_pos()
		local _, s = dirs(self.object:get_yaw())
		core.after(0.1, function()
			if d:get_pos() then d:set_pos({x = p.x - s.z * 2, y = p.y + 0.5, z = p.z + s.x * 2}) end
		end)
	end
	self.driver = nil
	hud_clear(self, nil)
end

for kind, def in pairs(TYPES) do
	local ename = "rockmech:" .. kind
	core.register_entity(ename, {
		initial_properties = {
			physical = true,
			collide_with_objects = false,
			collisionbox = {-def.half + 0.02, -def.half, -def.half + 0.02, def.half - 0.02, def.half - 0.02, def.half - 0.02},
			selectionbox = def.rear and {-def.half, -def.half, -def.rear, def.half, def.half, def.half, rotate = true}
				or {-def.half, -def.half, -def.half, def.half, def.half, def.half},
			visual = "cube",
			-- 外觀都由零件組成：車身不能放大（掛在上面的零件位置與大小會跟著放大），
			-- 用全透明貼圖（不能設 is_visible = false，掛在上面的零件會一起被隱藏）
			visual_size = {x = 1, y = 1, z = 1},
			textures = {CLEAR, CLEAR, CLEAR, CLEAR, CLEAR, CLEAR},
			use_texture_alpha = true,
			backface_culling = true,       -- 從車身裡面往外看是透明的
			stepheight = kind == "dozer" and 0.3 or 1.1,   -- 推土機放鏟時只壓得過很薄的碎石（要推走，不是爬過去）
			static_save = true,
		},
		vkind = kind,
		on_activate = function(self, staticdata)
			self.load = {}
			local d = staticdata ~= "" and core.deserialize(staticdata) or nil
			if d then
				self.load = d.load or {}
				if d.yaw then self.object:set_yaw(d.yaw) end
				if d.blade ~= nil then self.blade = d.blade end
				self.swing = d.swing
			end
			if kind == "dozer" and self.blade == nil then self.blade = true end
			self.object:set_acceleration({x = 0, y = -9.81, z = 0})
			self.object:set_armor_groups({immortal = 1})
			refresh_look(self)
			self.t_act = 0
			if kind == "excavator" then
				core.after(0, function()
					if self.object:get_pos() then spawn_parts(self, EXC_PARTS); place_arm(self, BUCKET_REST) end
				end)
			elseif kind == "truck" then
				core.after(0, function()
					if self.object:get_pos() then spawn_parts(self, TRUCK_PARTS); self.fill_key = nil; place_bed(self, 0) end
				end)
			else
				self.blade_h = self.blade and 0 or BLADE_UP
				core.after(0, function()
					if self.object:get_pos() then spawn_parts(self, DOZER_PARTS); place_blade(self, self.blade_h) end
				end)
			end
		end,
		on_deactivate = function(self)
			remove_parts(self)
			drop_chase(self)
		end,
		get_staticdata = function(self)
			return core.serialize({load = self.load, yaw = self.object:get_yaw(), blade = self.blade, swing = self.swing})
		end,
		on_rightclick = function(self, clicker)
			if not clicker or not clicker:is_player() then return end
			local name = clicker:get_player_name()
			if self.driver == name then get_off(self); return end
			if self.driver then return end
			-- 從別台車直接換過來：先把原本那台的駕駛清掉（否則兩台都聽這個玩家的）
			local parent = clicker:get_attach()
			local pe = parent and parent:get_luaentity()
			if pe and pe ~= self and pe.driver == name then
				hud_clear(pe, clicker)
				pe.driver = nil
			end
			self.driver = name
			clicker:set_attach(self.object, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
			-- 第三人稱：盡量抬高（上限 y 1.5 m、前後 ±0.5 m），從後上方看得到駕駛艙與手臂
			clicker:set_eye_offset(eye_offset(def), {x = 0, y = 15, z = -5})
			self.third = false
			clicker:set_camera({mode = "first"})
			set_seated(clicker, true)
			update_hud(self)
		end,
		on_punch = function(self, puncher)
			if not puncher or not puncher:is_player() or self.driver then return true end
			local inv = puncher:get_inventory()
			local left = inv:add_item("main", ItemStack(ename .. "_item"))
			if not left:is_empty() then core.add_item(self.object:get_pos(), left) end
			for base, lv in pairs(self.load) do
				local n = math.floor(lv / NLEV + 0.5)
				if n > 0 then
					local l2 = inv:add_item("main", ItemStack(base .. " " .. n))
					if not l2:is_empty() then core.add_item(self.object:get_pos(), l2) end
				end
			end
			remove_parts(self)
			self.object:remove()
			return true
		end,
		on_step = function(self, dtime)
			local obj = self.object
			local pos = obj:get_pos()
			local yaw = obj:get_yaw()
			local vel = obj:get_velocity()
			local d = self.driver and core.get_player_by_name(self.driver)
			if self.driver and not d then self.driver = nil; hud_clear(self, nil) end
			-- 駕駛已經不在這台車上（換到別台、被傳送、死亡等）：不再聽他的
			if d then
				local parent = d:get_attach()
				local pe = parent and parent:get_luaentity()
				if not (pe == self or (self.chase and parent and pe and pe.name == CHASE and pe.vehicle == self)) then
					hud_clear(self, d)
					if not parent then
						d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
						d:set_camera({mode = "any"})
						set_seated(d, false)
					end
					self.driver, d = nil, nil
				end
			end
			if d then update_mirrors(self, d, dtime) end
			local fwd, turn = 0, 0
			-- self.autopilot：沒有駕駛時的控制輸入（測試、指令用），格式同 get_player_control
			local ctrl = d and d:get_player_control() or self.autopilot or {}
			local driven = d or self.autopilot
			if driven then
				if d and ctrl.sneak then get_off(self); return end
				fwd = (ctrl.up and 1 or 0) - (ctrl.down and 1 or 0)
				turn = (ctrl.left and 1 or 0) - (ctrl.right and 1 or 0)
			end
			if def.rear and (self.tip or (turn ~= 0 and truck_blocked(pos, yaw, pos, yaw + turn * TURN_RATE * dtime, def))) then
				turn = 0   -- 車斗那段會撞到（或正在倒土）：不轉
			end
			if turn ~= 0 then
				yaw = yaw + turn * TURN_RATE * dtime
				obj:set_yaw(yaw)
			end
			-- 外觀隨地形傾斜（角度平滑趨近）
			if def.tilt then
				local tp, tr = ground_tilt(pos, yaw, def)
				local k = math.min(1, dtime * 6)
				self.pitch = (self.pitch or 0) + (tp - (self.pitch or 0)) * k
				self.roll = (self.roll or 0) + (tr - (self.roll or 0)) * k
				obj:set_rotation({x = self.pitch, y = yaw, z = self.roll})
			end
			local dir, s = dirs(yaw)
			local speed = def.speed * fwd
			if def.rear and speed ~= 0 then
				-- 前進時車斗跟著駕駛艙走過的路，不必檢查；倒車看後面一點（全速 0.5 m）
				local la = speed * 0.1
				if self.tip or (speed < 0 and truck_blocked(pos, yaw, {x = pos.x + dir.x * la, y = pos.y, z = pos.z + dir.z * la}, yaw, def)) then
					speed = 0
				end
			end
			-- 推土機：往前開時推碎石，推不動就停。鏟刀與車尾伸出碰撞箱：前面（收鏟時看鏟刀抬起的高度）、
			-- 後面（配重的高度）是岩石就停
			if kind == "dozer" then
				if self.blade and fwd > 0 then
					local why = push(self, pos, s)
					if why then speed = 0; settle_pile(self) end
					if why ~= self.push_msg then self.push_msg = why; update_hud(self) end
				else
					settle_pile(self)
					if fwd > 0 and overhang_blocked(pos, s, 1, {1, 2}) then speed = 0 end
					if self.push_msg then self.push_msg = nil; update_hud(self) end
				end
				if fwd < 0 and overhang_blocked(pos, s, -1, {1}) then speed = 0 end
				-- 越障高度：放鏟往前（含停著）只壓得過很薄的碎石（要推走，不是爬過去）；倒車、收鏟可爬 1 格
				local sh = (self.blade and fwd >= 0) and 0.3 or 1.1
				if sh ~= self.step_h then self.step_h = sh; obj:set_properties({stepheight = sh}) end
				-- 鏟刀抬放
				local goal = self.blade and 0 or BLADE_UP
				if self.blade_h ~= goal then
					local st = BLADE_RATE * dtime
					self.blade_h = math.abs(goal - self.blade_h) <= st and goal or self.blade_h + (goal > self.blade_h and st or -st)
					place_blade(self, self.blade_h)
				end
				-- 鏟刀前碎石量（有變才更新 HUD）
				self.pile_t = (self.pile_t or 0) + dtime
				if self.pile_t >= 0.3 then
					self.pile_t = 0
					local lv = pile_amount(pos, s)
					if lv ~= self.pile_lv then self.pile_lv = lv; update_hud(self) end
				end
			end
			obj:set_velocity({x = dir.x * speed, y = vel.y, z = dir.z * speed})
			-- 挖斗：抬到目標上方 → 往下插進目標（挖）→ 抬回目標上方 → 收回
			if self.dig then
				local dg = self.dig
				dg.t = dg.t + dtime
				local p1 = DIG_PHASES[1] + DIG_PHASES[2]
				if not dg.done and dg.t >= p1 and dg.mode == "dump" then
					dg.done = true
					local truck = dg.truck
					if truck and truck.object:get_pos() then
						local room = TYPES.truck.cap - load_total(truck)
						for base, lv in pairs(self.load) do
							local m = math.min(lv, room)
							if m > 0 then
								truck.load[base] = (truck.load[base] or 0) + m
								room = room - m
								self.load[base] = lv - m > 0 and (lv - m) or nil
							end
						end
						if load_total(self) > 0 then self.msg = "卡車滿了" end
						refresh_look(truck)
						update_hud(truck)
					elseif dg.target then
						-- 倒在指到的那格（與周圍 3×3 欄），之後依安息角攤開
						local a = dg.target
						local cells = {}
						for dx = -1, 1 do for dz = -1, 1 do cells[#cells + 1] = {x = a.x + dx, y = a.y, z = a.z + dz} end end
						table.sort(cells, function(u, v) return math.abs(u.x - a.x) + math.abs(u.z - a.z) < math.abs(v.x - a.x) + math.abs(v.z - a.z) end)
						dump_to_ground(self, cells, a.y + 1)
					end
					update_hud(self)
				end
				if not dg.done and dg.t >= p1 then
					dg.done = true
					local want = def.cap - load_total(self)
					local cells = {}
					for dx = -1, 1 do for dz = -1, 1 do for dy = 1, -1, -1 do
						cells[#cells + 1] = {x = dg.target.x + dx, y = dg.target.y + dy, z = dg.target.z + dz}
					end end end
					table.sort(cells, function(a, b)
						if a.y ~= b.y then return a.y > b.y end
						return math.abs(a.x - dg.target.x) + math.abs(a.z - dg.target.z)
							< math.abs(b.x - dg.target.x) + math.abs(b.z - dg.target.z)
					end)
					local got = 0
					for _, c in ipairs(cells) do
						if want <= 0 then break end
						local t, base = take_rubble(c, want)
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
			-- 挖土機第一人稱駕駛：上部結構轉向視線的水平方向（車身座標的迴轉角 ψ 往右為正，實體 yaw 往左為正）
			self.follow = kind == "excavator" and d ~= nil and not self.chase
			if self.follow and not self.dig and self.parts then
				local goal = yaw - d:get_look_horizontal()
				local cur = self.swing or 0
				local diff = (goal - cur + math.pi) % (2 * math.pi) - math.pi
				if math.abs(diff) > 1e-3 then
					local st = SWING_RATE * dtime
					self.swing = cur + math.max(-st, math.min(st, diff))
					place_arm(self, BUCKET_REST)
				end
			end
			-- 卡車倒土：車斗抬起 TIP_UP 秒到 TIP_ANGLE → 倒在車尾 → 停 TIP_HOLD 秒 → 放下 TIP_DOWN 秒
			if self.tip then
				local tp = self.tip
				tp.t = tp.t + dtime
				local a
				if tp.t < TIP_UP then a = TIP_ANGLE * tp.t / TIP_UP
				elseif tp.t < TIP_UP + TIP_HOLD then a = TIP_ANGLE
				else a = TIP_ANGLE * math.max(0, 1 - (tp.t - TIP_UP - TIP_HOLD) / TIP_DOWN) end
				if not tp.done and tp.t >= TIP_UP then
					tp.done = true
					local y0 = ground_y(pos, def.half)
					-- 車尾正後方（用實際朝向，不對齊格線：車子斜停時倒的位置才會在車尾）
					local d0 = def.rear + 0.5
					local cx, cz = pos.x - dir.x * d0, pos.z - dir.z * d0
					local cells = {}
					for _, l in ipairs(def.lat) do
						cells[#cells + 1] = {x = math.floor(cx - dir.z * l + 0.5), y = y0, z = math.floor(cz + dir.x * l + 0.5)}
					end
					dump_to_ground(self, cells, y0 + 1)
					self.fill_key = nil
					update_hud(self)
				end
				place_bed(self, a)
				if tp.t >= TIP_TOTAL then self.tip = nil; place_bed(self, 0) end
			end
			-- 卡車：載量一有變化就重畫車斗裡的碎石與名牌（不管是誰改的）
			if kind == "truck" and not self.tip then
				local tot = load_total(self)
				if tot ~= self.shown_total then
					self.shown_total = tot
					refresh_look(self)
				end
			end
			-- Z（zoom 鍵）：切換追蹤相機（駕駛掛到車子後上方的點上）／車頂第一人稱
			if d then
				if ctrl.zoom and not self.zoom_held then
					if self.chase then
						drop_chase(self)
						d:set_detach()
						d:set_attach(obj, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
						d:set_eye_offset(eye_offset(def), {x = 0, y = 15, z = -5})
					else
						local c = core.add_entity(chase_pos(self, def), CHASE)
						if c then
							c:get_luaentity().vehicle = self
							self.chase = c
							d:set_detach()
							d:set_attach(c, "", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
							d:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
						end
					end
					d:set_camera({mode = "first"})
					set_seated(d, true)
				end
				self.zoom_held = ctrl.zoom
			end
			-- 追蹤相機跟著車子
			if self.chase then
				if self.chase:get_pos() and d then self.chase:move_to(chase_pos(self, def), true)
				else drop_chase(self) end
			end
			-- 作業鍵（防連按：0.4 s）
			self.t_act = self.t_act - dtime
			if driven and self.t_act <= 0 then
				if kind == "dozer" and ctrl.aux1 then
					self.t_act = 0.5
					self.blade = not self.blade
					update_hud(self)
					refresh_look(self)
				elseif kind == "excavator" and ctrl.aux1 and not self.dig then
					self.t_act = DIG_TOTAL + 0.1
					-- 滑鼠指的方塊：從相機沿視線找第一個方塊
					local target = self.autopilot and self.autopilot.target
					if d then
						local hit = aim(self, d, pos, def, false)
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
				elseif ctrl.jump and kind == "excavator" and load_total(self) > 0 and not self.dig then
					self.t_act = DIG_TOTAL + 0.1
					local hit
					if d then hit = aim(self, d, pos, def, true)
					elseif self.autopilot then
						local t = self.autopilot.dump_target
						hit = self.autopilot.dump_truck and {truck = self.autopilot.dump_truck}
							or t and {above = {x = t.x, y = t.y + 1, z = t.z}}
					end
					local dg
					if hit and hit.truck then
						local tp = hit.truck.object:get_pos()
						local ty = hit.truck.object:get_yaw()
						local bz = -3.1   -- 車斗中心（卡車座標）
						dg = {t = 0, mode = "dump", truck = hit.truck,
							to = to_local(self, {x = tp.x - bz * math.sin(ty), y = tp.y + 1.6, z = tp.z + bz * math.cos(ty)})}   -- 卡車座標 +Z → (−sin, cos)
					elseif hit and hit.above then
						local a = hit.above
						dg = {t = 0, mode = "dump", target = a, to = to_local(self, {x = a.x, y = a.y + 0.8, z = a.z})}
					end
					local reach
					if dg then
						dg.psi, dg.to, reach = swing_to(dg.to)
						dg.psi0 = self.swing or 0
						if reach > ARM_REACH then
							self.msg = ("超出手臂範圍（%.1f m，手臂約 %.1f m）"):format(reach, ARM_REACH)
						else
							self.dig = dg
							self.msg = nil
						end
					else
						self.msg = "要倒在哪裡？（10 m 內沒有方塊或卡車）"
					end
					update_hud(self)
				elseif ctrl.jump and kind == "truck" and load_total(self) > 0 and not self.tip then
					self.t_act = TIP_TOTAL + 0.1
					self.tip = {t = 0}
				end
			end
		end,
	})
	core.register_craftitem(ename .. "_item", {
		description = def.desc .. "\n" .. ({
			excavator = "右鍵上車；E 挖滑鼠指的位置（鏟斗 4 m³）、空白鍵倒在滑鼠指的位置（指著卡車就倒進卡車）",
			truck = "右鍵上車；空白鍵把車斗倒在車尾（載量 8 m³）",
			dozer = "右鍵上車；E 放鏟／收鏟，放鏟時往前開把碎石推走",
		})[kind],
		inventory_image = tex(kind, 0, true)[5],
		stack_max = 1,
		on_place = function(itemstack, placer, pointed)
			if pointed.type ~= "node" then return itemstack end
			local a = pointed.above
			local odd = (def.half * 2) % 2 == 1
			local off = odd and 0 or 0.5
			local obj = core.add_entity({x = a.x + off, y = a.y - 0.5 + def.half, z = a.z + off}, ename)
			if obj and placer then obj:set_yaw(placer:get_look_horizontal()) end
			if not core.is_creative_enabled(placer and placer:get_player_name() or "") then itemstack:take_item() end
			return itemstack
		end,
	})
end
